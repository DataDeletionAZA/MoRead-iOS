import Foundation

public struct ListeningTimer: Equatable, Sendable {
    public private(set) var remainingSeconds: TimeInterval?
    public private(set) var remainingChapters: Int?
    public init(minutes: Int) { remainingSeconds = Double(min(1440, max(1, minutes))) * 60 }
    public init(chapters: Int) { remainingChapters = min(999, max(1, chapters)) }
    public var expired: Bool { remainingSeconds.map { $0 <= 0 } ?? (remainingChapters == 0) }
    public mutating func elapse(_ seconds: TimeInterval, playing: Bool) {
        guard playing, seconds.isFinite, seconds > 0, let remainingSeconds else { return }
        self.remainingSeconds = max(0, remainingSeconds - seconds)
    }
    public mutating func completeChapter() {
        if let remainingChapters { self.remainingChapters = max(0, remainingChapters - 1) }
    }
}

public struct SpeechPreferences: Codable, Equatable, Sendable {
    public var rate: Float = 0.45
    public var pitch: Float = 1
    public var voiceIdentifier = ""
    public init() {}
    public func validated() -> Self {
        var result = self
        result.rate = rate.isFinite ? min(1, max(0, rate)) : 0.45
        result.pitch = pitch.isFinite ? min(2, max(0.5, pitch)) : 1
        result.voiceIdentifier = String(voiceIdentifier.prefix(512))
        return result
    }
}
