import Foundation

public struct AutoReadSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case scroll, page }
    public var mode: Mode = .scroll
    public var speed: Double = 24
    public var interval: Double = 15
    public var showGuide = false
    public init() {}
    public init(data: Data) { self = ((try? JSONDecoder().decode(Self.self, from: data)) ?? Self()).validated() }
    public func validated() -> Self {
        var value = self
        value.speed = speed.isFinite ? min(96, max(8, speed)) : 24
        value.interval = interval.isFinite ? min(120, max(3, interval)) : 15
        return value
    }
    public func encoded() -> Data { (try? JSONEncoder().encode(validated())) ?? Data() }
}

/// A fresh clock starts at readiness. Missed frames never accumulate scroll distance.
public struct AutoReadClock: Sendable {
    private var lastFrame: TimeInterval?
    private var pageStarted: TimeInterval?
    public init() {}
    public mutating func reset() { lastFrame = nil; pageStarted = nil }
    public mutating func step(at time: TimeInterval, settings: AutoReadSettings) -> Double {
        guard time.isFinite else { return 0 }
        let previous = lastFrame ?? time
        lastFrame = time
        if pageStarted == nil { pageStarted = time }
        let settings = settings.validated()
        if settings.mode == .scroll { return min(0.1, max(0, time - previous)) * settings.speed }
        return time - (pageStarted ?? time) >= settings.interval ? 1 : 0
    }
    public mutating func pageCommitted(at time: TimeInterval) { pageStarted = time }
}
