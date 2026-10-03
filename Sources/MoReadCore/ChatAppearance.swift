import Foundation

public struct ChatAppearance: Codable, Hashable, Sendable {
    public enum Bubble: String, Codable, CaseIterable, Sendable {
        case rounded, outlined, paper, glass
        public var label: String {
            switch self { case .rounded: return "圆角"; case .outlined: return "描边"; case .paper: return "纸片"; case .glass: return "玻璃" }
        }
    }
    public var backgroundID: UUID?
    public var backgroundDim = 0.55
    public var fontID: UUID?
    public var fontScale = 1.0
    public var bubble = Bubble.rounded
    public var assistantRGB: Int?
    public var userRGB: Int?
    public init() {}
    public func validated() -> Self {
        var value = self
        value.backgroundDim = backgroundDim.isFinite ? min(1, max(0, backgroundDim)) : 0.55
        value.fontScale = fontScale.isFinite ? min(1.6, max(0.8, fontScale)) : 1
        if let assistantRGB, !(0...0xFFFFFF).contains(assistantRGB) { value.assistantRGB = nil }
        if let userRGB, !(0...0xFFFFFF).contains(userRGB) { value.userRGB = nil }
        return value
    }
    public static func darkText(onRGB rgb: Int) -> Bool {
        let rgb = (0...0xFFFFFF).contains(rgb) ? rgb : 0x476153
        func linear(_ byte: Int) -> Double {
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = linear((rgb >> 16) & 255) * 0.2126 + linear((rgb >> 8) & 255) * 0.7152 + linear(rgb & 255) * 0.0722
        return luminance > 0.179
    }
    private enum CodingKeys: String, CodingKey { case backgroundID, backgroundDim, fontID, fontScale, bubble, assistantRGB, userRGB }
    public init(from decoder: Decoder) throws {
        self.init()
        guard let fields = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        backgroundID = try? fields.decode(UUID.self, forKey: .backgroundID)
        backgroundDim = (try? fields.decode(Double.self, forKey: .backgroundDim)) ?? 0.55
        fontID = try? fields.decode(UUID.self, forKey: .fontID)
        fontScale = (try? fields.decode(Double.self, forKey: .fontScale)) ?? 1
        bubble = (try? fields.decode(Bubble.self, forKey: .bubble)) ?? .rounded
        assistantRGB = try? fields.decode(Int.self, forKey: .assistantRGB)
        userRGB = try? fields.decode(Int.self, forKey: .userRGB)
        self = validated()
    }
}
