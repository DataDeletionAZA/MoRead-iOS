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
    @Published private(set) var location: SpeechLocation?
    @Published var preferences = SpeechPreferences() {
        didSet { if let data = try? JSONEncoder().encode(preferences.validated()) { UserDefaults.standard.set(data, forKey: "speech.preferences") } }
    }
    @Published private(set) var cloudSettings = CloudSpeechSettings()
    private var cloudTask: Task<Void, Never>?
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
                var settings = CloudSpeechSettings(); settings.enabled = true; settings.baseURL = "https://example.invalid/v1"
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
    func stopAndWait() async {
        let pending = cloudTask; stop(); await pending?.value
    }
    private func cancelCloud() {
        cloudGeneration = UUID(); cloudTask?.cancel(); cloudTask = nil
        cloudPlayer?.stop(); cloudPlayer = nil
    }
    @objc nonisolated private func voicesChanged() { Task { @MainActor [weak self] in self?.refreshVoices() } }
    private func refreshVoices() {
        voices = AVSpeechSynthesisVoice.speechVoices().sorted { $0.language == $1.language ? $0.name < $1.name : $0.language < $1.language }
    }
    func preview() {
        if isPlaying || isPreparing { pause() }
        stopPreview()
        let utterance = AVSpeechUtterance(string: "雨停了，书页轻轻翻过。我们继续读这个故事。")
        let settings = preferences.validated()
        utterance.rate = settings.rate; utterance.pitchMultiplier = settings.pitch
        utterance.voice = AVSpeechSynthesisVoice(identifier: settings.voiceIdentifier) ?? AVSpeechSynthesisVoice(language: "zh-CN")
        previewUtterance = utterance; isPreviewing = true; previewSynthesizer.speak(utterance)
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
                else if self.cloudTask != nil { self.isPlaying = false; self.isPreparing = true }
                else if self.current != nil { if self.synthesizer.isPaused { self.synthesizer.continueSpeaking() } }
                else { self.speakNext() }
                self.updateNowPlaying()
            }
        }
    }
    func pause() {
        tickTimer()
        guard bookID != nil, library?.maintenance != true else { return }
        audioRequest = UUID(); isPreparing = false; wantsPlayback = false; cloudPlayer?.pause()
        synthesizer.pauseSpeaking(at: .word); isPlaying = false; updateNowPlaying()
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
        current = nil; segment = nil; chapter = nil; bookID = nil; isPlaying = false; location = nil
        synthesizer.stopSpeaking(at: .immediate)
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
            chapter = target; location = nil
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
                    segment = next
                    if cloudSettings.enabled { playCloud(next, book: book, store: store); return }
                    let utterance = AVSpeechUtterance(string: next.text)
                    let settings = preferences.validated()
                    utterance.rate = settings.rate; utterance.pitchMultiplier = settings.pitch
                    utterance.voice = AVSpeechSynthesisVoice(identifier: settings.voiceIdentifier) ?? AVSpeechSynthesisVoice(language: "zh-CN")
                    current = utterance; synthesizer.speak(utterance); updateNowPlaying(); return
                }
                position = ReadingPosition(chapter: position.chapter + 1, offset: 0); chapter = nil
            }
            stop()
        } catch { library.error = error.localizedDescription; stop() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finished(id) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.previewUtterance.map(ObjectIdentifier.init) == id { self.previewUtterance = nil; self.isPreviewing = false }
            else if self.current.map(ObjectIdentifier.init) == id {
                self.tickTimer(); self.current = nil; self.segment = nil; self.isPlaying = false; self.updateNowPlaying()
            }
        }
    }
    private func finished(_ id: ObjectIdentifier) {
        if let previewUtterance, ObjectIdentifier(previewUtterance) == id { self.previewUtterance = nil; isPreviewing = false; return }
        guard let current, ObjectIdentifier(current) == id else { return }
        completeSegment()
    }
    private func completeSegment() {
        guard let segment else { return }
        tickTimer()
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
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.speaking(characterRange, id: id) }
    }
    private func speaking(_ characterRange: NSRange, id: ObjectIdentifier) {
        guard let current, ObjectIdentifier(current) == id, let segment, let library, let index = library.books.firstIndex(where: { $0.id == bookID }) else { return }
        let range = NSRange(location: segment.offset + characterRange.location, length: characterRange.length)
        position.offset = range.location
        var book = library.books[index]
        book.record(position: ReadingPosition(chapter: position.chapter, offset: range.location), visibleEnd: ReadingPosition(chapter: position.chapter, offset: range.location + range.length))
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
