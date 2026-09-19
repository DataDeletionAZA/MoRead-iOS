import Foundation

public struct ReaderTypography: Codable, Equatable, Sendable {
    public enum Font: String, Codable, CaseIterable, Sendable {
        case system, serif, sansSerif, monospace
        public var label: String {
            switch self { case .system: return "系统字体"; case .serif: return "衬线字体"; case .sansSerif: return "无衬线字体"; case .monospace: return "等宽字体" }
        }
    }
    public var font: Font = .system
    public var customFontID: UUID?
    public var epubScroll: Bool?
    public var backgroundOpacity: Double?
    public var backgroundRGB: Int?
    public var textRGB: Int?
    public var weight = 400
    public var letterSpacing = 0.0
    public var paragraphSpacing = 12.0
    public var firstLineIndent = 0.0
    public var justified = false
    public var marginLeft = 22.0
    public var marginRight = 22.0
    public var marginTop = 24.0
    public var marginBottom = 24.0
    public var publisherStyles = true
    public var epubPageMargins = 1.0
    public init() {}
    public init(data: Data) { self = ((try? JSONDecoder().decode(Self.self, from: data)) ?? Self()).validated() }
    public func encoded() -> Data { (try? JSONEncoder().encode(validated())) ?? Data() }
    public func validated() -> Self {
        var value = self
        func bound(_ number: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            number.isFinite ? min(range.upperBound, max(range.lowerBound, number)) : fallback
        }
        if let backgroundRGB, !(0...0xFFFFFF).contains(backgroundRGB) { value.backgroundRGB = nil }
        if let textRGB, !(0...0xFFFFFF).contains(textRGB) { value.textRGB = nil }
        if let backgroundOpacity { value.backgroundOpacity = bound(backgroundOpacity, 0.05...1, 0.25) }
        value.weight = min(900, max(100, weight / 100 * 100))
        value.letterSpacing = bound(letterSpacing, 0...0.5, 0)
        value.paragraphSpacing = bound(paragraphSpacing, 0...60, 12)
        value.firstLineIndent = bound(firstLineIndent, 0...4, 0)
        value.marginLeft = bound(marginLeft, 0...64, 22); value.marginRight = bound(marginRight, 0...64, 22)
        value.marginTop = bound(marginTop, 0...80, 24); value.marginBottom = bound(marginBottom, 0...80, 24)
        value.epubPageMargins = bound(epubPageMargins, 0...3, 1)
        return value
    }
}
