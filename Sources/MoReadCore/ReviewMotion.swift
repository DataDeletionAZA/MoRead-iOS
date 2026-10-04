import Foundation

public enum ReviewFocusMotion: String, CaseIterable, Sendable {
    case paper = "PAPER", cube = "CUBE", flow = "FLOW"
    public init(saved: String?) { self = saved.flatMap(Self.init(rawValue:)) ?? .paper }
    public var label: String { switch self { case .paper: "纸片"; case .cube: "立方体"; case .flow: "流动" } }
    public struct Frame: Equatable, Sendable {
        public var scale = 1.0, alpha = 1.0
        public var rotationX = 0.0, rotationY = 0.0, rotationZ = 0.0
        public var translationX = 0.0, drop = 0.0, pivotX = 0.5, shade = 0.0, glare = 0.5
    }
    public func frame(position raw: Double, tiltX: Double = 0, tiltY: Double = 0, reduceMotion: Bool = false) -> Frame {
        guard !reduceMotion else { return Frame() }
        let position = raw.isFinite ? raw : 0, clamped = min(1, max(-1, position)), distance = abs(clamped), focus = 1 - distance
        var frame = Frame()
        if self == .paper {
            frame.scale = 1 - distance * 0.055; frame.alpha = 1 - distance * 0.38
            frame.rotationZ = clamped * 2.5; frame.drop = distance * 12
            return frame
        }
        let x = tiltX.isFinite ? min(8, max(-8, tiltX)) : 0, y = tiltY.isFinite ? min(8, max(-8, tiltY)) : 0
        frame.rotationX = x * focus; frame.glare = min(1, max(0, 0.5 + y / 16 - clamped * 0.6))
        if self == .flow {
            frame.rotationY = -52 * clamped + y * focus; frame.scale = 1 - distance * 0.2
            frame.alpha = (1 - distance * 0.28) * min(1, max(0, 2 - abs(position)))
            frame.translationX = -position * 0.4; frame.shade = distance * 0.22
        } else {
            frame.rotationY = 90 * clamped + y * focus; frame.alpha = abs(position) >= 0.999 ? 0 : 1
            frame.pivotX = clamped < 0 ? 1 : 0; frame.shade = distance * 0.34
        }
        return frame
    }
}

public struct ReviewTiltState: Sendable {
    public private(set) var x = 0.0, y = 0.0
    private var restingY: Double?
    public init() {}
    public mutating func update(gravityX: Double, gravityY: Double) {
        guard gravityX.isFinite, gravityY.isFinite else { return }
        let rest = restingY ?? gravityY, scale = 8.0 * 1.6 / 9.81
        x += (min(8, max(-8, (gravityY - rest) * scale)) - x) * 0.18
        y += (min(8, max(-8, -gravityX * scale)) - y) * 0.18
        restingY = rest + (gravityY - rest) * 0.004
    }
}
