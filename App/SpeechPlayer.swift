import SwiftUI
import AVFoundation
import MediaPlayer
import MoReadCore

struct SpeechLocation: Equatable {
    let bookID: UUID
    let chapter: Int
    let range: NSRange
}

@MainActor
final class SpeechPlayer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published private(set) var bookID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = false
    private let audioQueue = DispatchQueue(label: "io.github.datadeletionaza.MoRead.audio")
    private var audioRequest = UUID()
    @Published private(set) var title = ""
    @Published private(set) var spokenText = ""
    @Published private(set) var location: SpeechLocation?
    @Published var preferences = SpeechPreferences() {
        didSet { if let data = try? JSONEncoder().encode(preferences.validated()) { UserDefaults.standard.set(data, forKey: "speech.preferences") } }
    }
    @Published private(set) var cloudSettings = CloudSpeechSettings()
    private var cloudTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var cloudGeneration = UUID()
    private var cloudPlayer: AVAudioPlayer?
    private var wantsPlayback = false
    @Published private(set) var sleepTimer: ListeningTimer?
    @Published private(set) var stopReason: String?
    private(set) var stoppedBookID: UUID?
    @Published private(set) var position = ReadingPosition()
    @Published private(set) var voices: [AVSpeechSynthesisVoice] = []
    private var timerTask: Task<Void, Never>?
    private var lastTick = ContinuousClock.now
    private let synthesizer = AVSpeechSynthesizer()
    private let previewSynthesizer = AVSpeechSynthesizer()
    private var previewUtterance: AVSpeechUtterance?
    @Published private(set) var isPreviewing = false
    private var current: AVSpeechUtterance?
    private var segment: SpeechSegment?
    private var chapter: Chapter?
    private weak var library: LibraryModel?

    override init() {
        super.init()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--reset-test-library") {
            UserDefaults.standard.removeObject(forKey: "speech.cloud")
            if ProcessInfo.processInfo.environment["MOREAD_TEST_SPEECH_AUDIO"] != nil {
                var settings = CloudSpeechSettings()
                settings.preset(SpeechService(rawValue: ProcessInfo.processInfo.environment["MOREAD_TEST_SPEECH_SERVICE"] ?? "") ?? .openAI)
                settings.enabled = true; settings.baseURL = "https://example.invalid/v1"
                UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: "speech.cloud")
            }
        }
        #endif
        loadPreferences(); loadCloudSettings(); refreshVoices()
        synthesizer.delegate = self
        previewSynthesizer.delegate = self; previewSynthesizer.usesApplicationAudioSession = false
        let remote = MPRemoteCommandCenter.shared()
        remote.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        remote.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        remote.stopCommand.addTarget { [weak self] _ in Task { @MainActor in self?.stop() }; return .success }
        remote.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previousChapter() }; return .success }
        remote.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.nextChapter() }; return .success }
        NotificationCenter.default.addObserver(self, selector: #selector(interruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(voicesChanged), name: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil)
    }
    private func trace(_ event: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--trace-system-speech") else { return }
        NSLog("%@", "MoReadSpeech \(event) wanted=\(wantsPlayback) playing=\(isPlaying) preparing=\(isPreparing) nativeSpeaking=\(synthesizer.isSpeaking) nativePaused=\(synthesizer.isPaused) current=\(current != nil) chapter=\(position.chapter) offset=\(position.offset)")
        #endif
    }
    func loadPreferences() {
        let data = UserDefaults.standard.data(forKey: "speech.preferences") ?? Data()
        preferences = ((try? JSONDecoder().decode(SpeechPreferences.self, from: data)) ?? SpeechPreferences()).validated()
    }
    func loadCloudSettings() {
        cloudSettings = ((try? JSONDecoder().decode(CloudSpeechSettings.self, from: UserDefaults.standard.data(forKey: "speech.cloud") ?? Data())) ?? CloudSpeechSettings()).validated()
    }
    func saveCloudSettings(_ value: CloudSpeechSettings, key: String) throws {
        let settings = value.validated()
        if settings.enabled { _ = try CloudSpeechClient.request(settings: settings, key: key.isEmpty ? "configuration-check" : key, text: "试听") }
        let data = try JSONEncoder().encode(settings)
        try KeychainStore.save(key, for: settings.id)
        stop(); cloudSettings = settings; UserDefaults.standard.set(data, forKey: "speech.cloud")
    }
    func selectCloudVoice(_ voice: SavedVoice) throws {
        let value = try voice.applying(to: cloudSettings)
        let data = try JSONEncoder().encode(value)
        stop(); cloudSettings = value; UserDefaults.standard.set(data, forKey: "speech.cloud")
    }
    func stopAndWait() async {
        let pending = cloudTask, preparation = preparationTask; stop(); await preparation?.value; await pending?.value
    }
    private func cancelCloud() {
        cloudGeneration = UUID(); cloudTask?.cancel(); cloudTask = nil
        preparationTask?.cancel(); preparationTask = nil
        cloudPlayer?.stop(); cloudPlayer = nil
    }
    @objc nonisolated private func voicesChanged() { Task { @MainActor [weak self] in self?.refreshVoices() } }
    private func refreshVoices() {
        voices = AVSpeechSynthesisVoice.speechVoices().sorted { $0.language == $1.language ? $0.name < $1.name : $0.language < $1.language }
    }
    private func utterance(_ text: String) throws -> AVSpeechUtterance {
        var available = voices
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--simulate-unavailable-system-voice") { available = [] }
        #endif
        let settings = preferences.validated()
        let preferred = AVSpeechSynthesisVoice(language: "zh-CN")
        guard let voice = available.first(where: { $0.identifier == settings.voiceIdentifier })
            ?? available.first(where: { $0.identifier == preferred?.identifier && $0.language.hasPrefix("zh") })
            ?? available.first(where: { $0.language == "zh-CN" }) else {
            throw MoReadError.invalid("没有可用的中文朗读声音。请在 iPhone 的辅助功能中下载中文声音，或在「系统声音」选择已安装的声音。")
        }
        let value = AVSpeechUtterance(string: text)
        value.rate = settings.rate; value.pitchMultiplier = settings.pitch; value.voice = voice
        trace("voice=\(voice.identifier) rate=\(value.rate) length=\(text.utf16.count)")
        return value
    }
    func preview(library: LibraryModel) {
        if isPlaying || isPreparing { pause() }
        stopPreview()
        do {
            let value = try utterance("雨停了，书页轻轻翻过。我们继续读这个故事。")
            previewUtterance = value; isPreviewing = true; previewSynthesizer.speak(value)
        } catch { library.error = error.localizedDescription }
    }
    func stopPreview() { previewUtterance = nil; isPreviewing = false; previewSynthesizer.stopSpeaking(at: .immediate) }
    func setTimer(_ value: ListeningTimer?) {
        guard bookID != nil else { return }
        timerTask?.cancel(); sleepTimer = value; lastTick = .now
        guard value?.remainingSeconds != nil else { timerTask = nil; return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.sleepTimer != nil else { return }
                self.tickTimer()
            }
        }
    }
    private func tickTimer() {
        let now = ContinuousClock.now
        let elapsed = lastTick.duration(to: now).components
        lastTick = now
        guard var timer = sleepTimer, timer.remainingSeconds != nil else { return }
        timer.elapse(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18, playing: isPlaying)
        if timer != sleepTimer { sleepTimer = timer }
        if timer.expired { stop(reason: "定时结束") }
    }
    func play(_ book: Book, library: LibraryModel) {
        guard !library.maintenance, !book.removed, book.hasBody else { return }
        stop()
        self.library = library; bookID = book.id; title = book.title; position = book.position
        activateAudio()
    }
    private func activateAudio() {
        trace("activate")
        let request = UUID(); audioRequest = request; isPreparing = true; wantsPlayback = true
        audioQueue.async { [weak self] in
            let succeeded: Bool
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                succeeded = true
            } catch { succeeded = false }
            Task { @MainActor [weak self] in
                guard let self, self.audioRequest == request, self.bookID != nil else { return }
                self.isPreparing = false
                guard succeeded else { self.library?.error = "无法启动听书，请检查设备的音频设置。"; self.stop(); return }
                self.lastTick = .now; self.isPlaying = true
                if let player = self.cloudPlayer { self.isPlaying = player.play() }
                else if self.cloudTask != nil || self.preparationTask != nil { self.isPlaying = false; self.isPreparing = true }
                else if self.current != nil { if self.synthesizer.isPaused { self.synthesizer.continueSpeaking() } }
                else { self.speakNext() }
                self.updateNowPlaying(); self.trace("activated")
            }
        }
    }
    func pause() {
        tickTimer()
        guard bookID != nil, library?.maintenance != true else { return }
        audioRequest = UUID(); isPreparing = false; wantsPlayback = false; cloudPlayer?.pause()
        synthesizer.pauseSpeaking(at: .word); isPlaying = false; updateNowPlaying(); trace("pause-request")
    }
    func resume() {
        stopPreview(); tickTimer()
        guard bookID != nil, !isPreparing, library?.maintenance != true else { return }
        activateAudio()
    }
    func stop(reason: String? = nil) {
        stopPreview(); audioRequest = UUID(); isPreparing = false; wantsPlayback = false; cancelCloud()
        timerTask?.cancel(); timerTask = nil; sleepTimer = nil; stoppedBookID = bookID; stopReason = reason
        library?.flush()
        current = nil; segment = nil; chapter = nil; bookID = nil; spokenText = ""; isPlaying = false; location = nil
        synthesizer.stopSpeaking(at: .immediate); trace("stop")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        audioQueue.async { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    func nextChapter() {
        guard let library, let book = library.books.first(where: { $0.id == bookID }), book.chapters.indices.contains(position.chapter + 1) else { stop(); return }
        seek(chapter: position.chapter + 1)
    }
    func previousChapter() { seek(chapter: max(0, position.chapter - 1)) }
    func seek(chapter id: Int, offset: Int = 0) {
        guard let library, !library.maintenance, let book = library.books.first(where: { $0.id == bookID && !$0.removed }), book.chapters.indices.contains(id) else { return }
        do {
            let target = try library.store?.chapter(id, in: book)
            guard let target else { return }
            let continuing = wantsPlayback
            current = nil; segment = nil; cancelCloud(); isPreparing = false; synthesizer.stopSpeaking(at: .immediate)
            position = ReadingPosition(chapter: id, offset: TextBoundary.floor(offset, in: target.text))
            chapter = target; location = nil; spokenText = ""; trace("seek")
            if continuing { isPlaying = true; speakNext() } else { updateNowPlaying() }
        } catch { library.error = error.localizedDescription }
    }
    func seek(fraction: Double) {
        guard fraction.isFinite, let chapter else { return }
        seek(chapter: chapter.id, offset: Int(Double(chapter.text.utf16.count) * min(1, max(0, fraction))))
    }
    func validateBooks(_ books: [Book]) { if let bookID, !books.contains(where: { $0.id == bookID && !$0.removed }) { stop() } }
    private func speakNext() {
        guard isPlaying else { return }
        guard let library, let book = library.books.first(where: { $0.id == bookID && !$0.removed }), let store = library.store else { stop(); return }
        do {
            while book.chapters.indices.contains(position.chapter) {
                if chapter?.id != position.chapter { chapter = try store.chapter(position.chapter, in: book) }
                if let chapter, let next = SpeechText.next(in: chapter.text, from: position.offset, maximumLength: cloudSettings.enabled ? cloudSettings.maximumCharacters : 1000) {
                    prepare(next, book: book, store: store); return
                }
                position = ReadingPosition(chapter: position.chapter + 1, offset: 0); chapter = nil
            }
            stop(reason: "已读到书末")
        } catch { library.error = error.localizedDescription; stop() }
    }
    private func prepare(_ source: SpeechSegment, book: Book, store: LibraryStore) {
        let token = cloudGeneration, root = store.root
        isPlaying = false; isPreparing = true; updateNowPlaying()
        preparationTask = Task { [weak self] in
            do {
                let worker = Task.detached { try source.purified(rules: TextReplacementStore(root: root).rules()) }
                let next = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.cloudGeneration == token, self.bookID == book.id, self.library?.maintenance != true else { return }
                guard self.library?.books.contains(where: { $0.id == book.id && !$0.removed && $0.hasBody && $0.chapters == book.chapters }) == true else { self.stop(); return }
                self.preparationTask = nil; self.isPreparing = false
                guard self.wantsPlayback else { return }
                self.segment = next; self.spokenText = next.text
                if next.text.isEmpty { self.isPlaying = true; self.completeSegment(countPlayback: false); return }
                if self.cloudSettings.enabled { self.playCloud(next, book: book, store: store); return }
                let value = try self.utterance(next.text)
                self.current = value; self.isPreparing = true
                self.trace("enqueue-before"); self.synthesizer.speak(value); self.trace("enqueue-after"); self.updateNowPlaying()
            } catch {
                guard let self, self.cloudGeneration == token else { return }
                self.preparationTask = nil
                if !(error is CancellationError) { self.library?.error = error.localizedDescription }
                self.stop()
            }
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.current === utterance else { return }
            self.trace("did-start")
            self.isPreparing = false; self.lastTick = .now; self.isPlaying = self.wantsPlayback
            if !self.wantsPlayback { self.synthesizer.pauseSpeaking(at: .immediate) }
            self.updateNowPlaying()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.trace("did-pause") }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.trace("did-continue") }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finished(utterance) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.trace("did-cancel matching=\(self.current === utterance)")
            if self.previewUtterance === utterance { self.previewUtterance = nil; self.isPreviewing = false }
            else if self.current === utterance {
                self.tickTimer(); self.current = nil; self.segment = nil; self.isPreparing = false; self.isPlaying = false; self.updateNowPlaying()
            }
        }
    }
    private func finished(_ utterance: AVSpeechUtterance) {
        trace("did-finish matching=\(current === utterance)")
        if previewUtterance === utterance { previewUtterance = nil; isPreviewing = false; return }
        guard current === utterance else { return }
        completeSegment()
    }
    private func completeSegment(countPlayback: Bool = true) {
        guard let segment else { return }
        if countPlayback { tickTimer() } else { lastTick = .now }
        guard bookID != nil else { return }
        if let library, let index = library.books.firstIndex(where: { $0.id == bookID }) {
            var book = library.books[index]
            let end = ReadingPosition(chapter: position.chapter, offset: segment.end)
            book.record(position: end, visibleEnd: end); library.update(book)
        }
        position.offset = segment.end; self.current = nil
        if let chapter, SpeechText.next(in: chapter.text, from: segment.end) == nil {
            sleepTimer?.completeChapter()
            if sleepTimer?.expired == true { stop(reason: "定时结束"); return }
        }
        speakNext()
    }
    private func playCloud(_ next: SpeechSegment, book: Book, store: LibraryStore) {
        tickTimer()
        guard bookID == book.id, wantsPlayback else { return }
        isPlaying = false; isPreparing = true; updateNowPlaying()
        let token = UUID(); cloudGeneration = token
        let settings = cloudSettings.validated()
        let directory = store.directory(book.id)
        cloudTask = Task { [weak self] in
            do {
                let cacheKey = try CloudSpeechClient.cacheKey(settings: settings, text: next.text)
                let cached = try SpeechAudioCache.read(in: directory, key: cacheKey)
                let audio: Data
                if let cached { audio = cached }
                else {
                    let key = try KeychainStore.read(settings.id)
                    audio = try await CloudSpeechClient.synthesize(settings: settings, key: key, text: next.text)
                    try Task.checkCancellation()
                }
                guard let self, self.cloudGeneration == token, self.bookID == book.id, self.library?.maintenance != true,
                      self.library?.books.contains(where: { $0.id == book.id && !$0.removed && $0.hasBody }) == true else { return }
                let player = try AVAudioPlayer(data: audio)
                guard player.prepareToPlay() else { throw MoReadError.invalid("这段云端音频无法播放。") }
                if cached == nil { try SpeechAudioCache.write(audio, in: directory, key: cacheKey, megabytes: settings.cacheMegabytes) }
                self.cloudPlayer = player; player.delegate = self; self.cloudTask = nil; self.isPreparing = false
                self.location = SpeechLocation(bookID: book.id, chapter: self.position.chapter, range: NSRange(location: next.offset, length: next.end - next.offset))
                self.lastTick = .now
                if self.wantsPlayback {
                    guard player.play() else { throw MoReadError.invalid("无法播放云端声音，请重试。") }
                    self.isPlaying = true
                }
                self.updateNowPlaying()
            } catch {
                guard let self, self.cloudGeneration == token else { return }
                self.cloudTask = nil
                if !(error is CancellationError) { self.library?.error = error.localizedDescription }
                self.stop()
            }
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.cloudPlayer.map(ObjectIdentifier.init) == id else { return }
            self.cloudPlayer = nil
            if flag { self.completeSegment() }
            else { self.library?.error = "云端音频播放中断，请重试。"; self.stop() }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.cloudPlayer.map(ObjectIdentifier.init) == id else { return }
            self.library?.error = "这段云端音频无法解码，请更换声音或重新生成。"; self.stop()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.speaking(characterRange, utterance: utterance) }
    }
    private func speaking(_ characterRange: NSRange, utterance: AVSpeechUtterance) {
        guard current === utterance, let segment, let library, let index = library.books.firstIndex(where: { $0.id == bookID }) else { return }
        let range = segment.sourceRange(forSpokenRange: characterRange)
        position.offset = range.location
        var book = library.books[index]
        book.record(position: ReadingPosition(chapter: position.chapter, offset: range.location), visibleEnd: ReadingPosition(chapter: position.chapter, offset: segment.transformed ? segment.offset : range.location + range.length))
        library.update(book)
        location = SpeechLocation(bookID: book.id, chapter: position.chapter, range: range)
    }
    private func updateNowPlaying() {
        guard bookID != nil else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: chapter?.title ?? title, MPMediaItemPropertyAlbumTitle: title, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0, MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue]
    }
    @objc nonisolated private func routeChanged(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        Task { @MainActor [weak self] in self?.pause() }
    }
    @objc nonisolated private func interruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        Task { @MainActor [weak self] in self?.pause() }
    }
}
