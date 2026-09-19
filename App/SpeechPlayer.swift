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
final class SpeechPlayer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var bookID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var title = ""
    @Published private(set) var location: SpeechLocation?
    @Published var rate: Float = 0.45
    @Published var voiceIdentifier = ""
    private let synthesizer = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?
    private var segment: SpeechSegment?
    private var chapter: Chapter?
    private var position = ReadingPosition()
    private weak var library: LibraryModel?

    override init() {
        super.init()
        synthesizer.delegate = self
        let remote = MPRemoteCommandCenter.shared()
        remote.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        remote.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        remote.stopCommand.addTarget { [weak self] _ in Task { @MainActor in self?.stop() }; return .success }
        remote.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.nextChapter() }; return .success }
        NotificationCenter.default.addObserver(self, selector: #selector(interruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
    }
    var voices: [AVSpeechSynthesisVoice] { AVSpeechSynthesisVoice.speechVoices().sorted { $0.language == $1.language ? $0.name < $1.name : $0.language < $1.language } }
    func play(_ book: Book, library: LibraryModel) {
        guard !library.maintenance else { return }
        stop()
        self.library = library; bookID = book.id; title = book.title; position = book.position
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            isPlaying = true; speakNext()
        } catch { library.error = "无法启动听书，请检查设备的音频设置。"; stop() }
    }
    func pause() {
        guard bookID != nil, library?.maintenance != true else { return }
        synthesizer.pauseSpeaking(at: .word); isPlaying = false; updateNowPlaying()
    }
    func resume() {
        guard bookID != nil, library?.maintenance != true else { return }
        do { try AVAudioSession.sharedInstance().setActive(true) }
        catch { library?.error = "无法恢复播放。"; return }
        isPlaying = true
        if synthesizer.isPaused { synthesizer.continueSpeaking() } else if !synthesizer.isSpeaking { speakNext() }
        updateNowPlaying()
    }
    func stop() {
        current = nil; segment = nil; chapter = nil; bookID = nil; isPlaying = false; location = nil
        synthesizer.stopSpeaking(at: .immediate)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func nextChapter() {
        guard library?.maintenance != true else { return }
        guard let library, let book = library.books.first(where: { $0.id == bookID }), book.chapters.indices.contains(position.chapter + 1) else { stop(); return }
        current = nil; synthesizer.stopSpeaking(at: .immediate)
        position = ReadingPosition(chapter: position.chapter + 1, offset: 0); chapter = nil; isPlaying = true; speakNext()
    }
    func validateBooks(_ books: [Book]) { if let bookID, !books.contains(where: { $0.id == bookID && !$0.removed }) { stop() } }
    private func speakNext() {
        guard isPlaying else { return }
        guard let library, let book = library.books.first(where: { $0.id == bookID && !$0.removed }), let store = library.store else { stop(); return }
        do {
            while book.chapters.indices.contains(position.chapter) {
                if chapter?.id != position.chapter { chapter = try store.chapter(position.chapter, in: book) }
                if let chapter, let next = SpeechText.next(in: chapter.text, from: position.offset) {
                    segment = next
                    let utterance = AVSpeechUtterance(string: next.text)
                    utterance.rate = rate
                    utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) ?? AVSpeechSynthesisVoice(language: "zh-CN")
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
    private func finished(_ id: ObjectIdentifier) {
        guard let current, ObjectIdentifier(current) == id, let segment else { return }
        if let library, let index = library.books.firstIndex(where: { $0.id == bookID }) {
            var book = library.books[index]
            let end = ReadingPosition(chapter: position.chapter, offset: segment.end)
            book.record(position: end, visibleEnd: end); library.update(book)
        }
        position.offset = segment.end; self.current = nil
        speakNext()
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.speaking(characterRange, id: id) }
    }
    private func speaking(_ characterRange: NSRange, id: ObjectIdentifier) {
        guard let current, ObjectIdentifier(current) == id, let segment, let library, let index = library.books.firstIndex(where: { $0.id == bookID }) else { return }
        let range = NSRange(location: segment.offset + characterRange.location, length: characterRange.length)
        var book = library.books[index]
        book.record(position: ReadingPosition(chapter: position.chapter, offset: range.location), visibleEnd: ReadingPosition(chapter: position.chapter, offset: range.location + range.length))
        library.update(book)
        location = SpeechLocation(bookID: book.id, chapter: position.chapter, range: range)
    }
    private func updateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: chapter?.title ?? title, MPMediaItemPropertyAlbumTitle: title, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0, MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue]
    }
    @objc private func interruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        pause()
    }
}

struct SpeechControls: View {
    let book: Book
    @EnvironmentObject private var speech: SpeechPlayer
    @EnvironmentObject private var library: LibraryModel
    var body: some View {
        Form {
            Section("听书") {
                if speech.bookID == book.id {
                    Button(speech.isPlaying ? "暂停" : "继续", systemImage: speech.isPlaying ? "pause.fill" : "play.fill") { if speech.isPlaying { speech.pause() } else { speech.resume() } }
                    Button("下一章", systemImage: "forward.end") { speech.nextChapter() }
                    Button("结束听书", systemImage: "stop") { speech.stop() }
                } else { Button("从这里开始朗读", systemImage: "play.fill") { speech.play(book, library: library) } }
            }
            Section("声音") {
                Picker("系统声音", selection: $speech.voiceIdentifier) {
                    Text("中文默认声音").tag("")
                    ForEach(speech.voices, id: \.identifier) { voice in Text("\(voice.name) · \(voice.language)").tag(voice.identifier) }
                }
                Slider(value: $speech.rate, in: 0.25...0.65).accessibilityLabel("语速")
                Text("语速和声音从下一句生效。").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("听书")
    }
}
