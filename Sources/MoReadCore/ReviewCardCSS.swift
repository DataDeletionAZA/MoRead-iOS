import Foundation

public struct ReviewCardColor: Equatable, Sendable {
    public let rgba: UInt32
    public init(rgba: UInt32) { self.rgba = rgba }
    public static func parse(_ text: String) throws -> Self {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let value: UInt32 = ["transparent": 0, "black": 0x000000FF, "white": 0xFFFFFFFF, "red": 0xFF0000FF][text] { return .init(rgba: value) }
        if text.hasPrefix("#") {
            var hex = String(text.dropFirst())
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            if hex.count == 6 { hex += "ff" }
            if hex.count == 8, let value = UInt32(hex, radix: 16) { return .init(rgba: value) }
        }
        if (text.hasPrefix("rgb(") || text.hasPrefix("rgba(")), text.hasSuffix(")"), let start = text.firstIndex(of: "(") {
            let parts = text[text.index(after: start)..<text.index(before: text.endIndex)].split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let count = text.hasPrefix("rgba(") ? 4 : 3
            if parts.count == count {
                var bytes: [UInt32] = []
                for (index, part) in parts.enumerated() {
                    let percent = part.hasSuffix("%")
                    guard index < 3 || !percent, let number = Double(percent ? String(part.dropLast()) : part), number.isFinite else { throw MoReadError.invalid("颜色数值无效。") }
                    let channel = index == 3 ? number * 255 : percent ? number * 255 / 100 : number
                    bytes.append(UInt32(min(255, max(0, channel))))
                }
                if count == 3 { bytes.append(255) }
                return .init(rgba: bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3])
            }
        }
        throw MoReadError.invalid("请使用十六进制、rgb 或 rgba 颜色。")
    }
}

public struct ReviewCardGradient: Equatable, Sendable {
    public let angle: Double
    public let colors: [ReviewCardColor]
    public let stops: [Double]
    public static func parse(_ text: String) throws -> Self {
        guard text.lowercased().hasPrefix("linear-gradient("), text.hasSuffix(")") else { throw MoReadError.invalid("请使用 linear-gradient(...)。") }
        var depth = 0, part = "", parts: [String] = []
        for character in text.dropFirst(16).dropLast() {
            if character == "(" { depth += 1 }; if character == ")" { depth -= 1 }
            guard depth >= 0 else { throw MoReadError.invalid("渐变括号不完整。") }
            if character == "," && depth == 0 { parts.append(part.trimmingCharacters(in: .whitespacesAndNewlines)); part = "" } else { part.append(character) }
        }
        guard depth == 0 else { throw MoReadError.invalid("渐变括号不完整。") }
        parts.append(part.trimmingCharacters(in: .whitespacesAndNewlines))
        let first = parts.first?.lowercased() ?? ""
        let directions = ["to top": 0.0, "to right": 90, "to bottom": 180, "to left": 270, "to top right": 45, "to right top": 45, "to bottom right": 135, "to right bottom": 135, "to bottom left": 225, "to left bottom": 225, "to top left": 315, "to left top": 315]
        var angle = 180.0
        if first.hasSuffix("deg") {
            guard let number = Double(first.dropLast(3)), number.isFinite else { throw MoReadError.invalid("渐变角度无效。") }
            angle = number; parts.removeFirst()
        } else if first.hasPrefix("to ") {
            guard let number = directions[first] else { throw MoReadError.invalid("渐变方向无效。") }
            angle = number; parts.removeFirst()
        }
        guard (2...16).contains(parts.count) else { throw MoReadError.invalid("渐变需要 2～16 个色标。") }
        var colors: [ReviewCardColor] = [], stops: [Double?] = []
        for part in parts {
            var color = part, stop: Double?
            if part.hasSuffix("%"), let space = part.lastIndex(where: \.isWhitespace) {
                guard let number = Double(part[part.index(after: space)..<part.index(before: part.endIndex)]), number.isFinite, (0...100).contains(number) else { throw MoReadError.invalid("色标位置需要在 0%～100%。") }
                stop = number / 100; color = String(part[..<space])
            }
            colors.append(try ReviewCardColor.parse(color)); stops.append(stop)
        }
        if stops[0] == nil { stops[0] = 0 }; if stops[stops.count - 1] == nil { stops[stops.count - 1] = 1 }
        var previous = 0
        for index in 1..<stops.count where stops[index] != nil {
            let from = stops[previous]!, to = max(from, stops[index]!)
            stops[index] = to
            for middle in (previous + 1)..<index { stops[middle] = from + (to - from) * Double(middle - previous) / Double(index - previous) }
            previous = index
        }
        return .init(angle: (angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360), colors: colors, stops: stops.map { $0! })
    }
}

public struct ReviewCardCSS: Equatable, Sendable {
    public var clipsText = false
    public var color: ReviewCardColor?
    public var quoteColor: ReviewCardColor?
    public var background: ReviewCardColor?
    public var borderColor: ReviewCardColor?
    public var textGradient: ReviewCardGradient?
    public var backgroundGradient: ReviewCardGradient?
    public var backgroundSpecified = false
    public var backgroundImageID: UUID?
    public var fontSpecified = false
    public var font: ReaderTypography.Font?
    public var customFontID: UUID?
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strikethrough: Bool?
    public var alignment: String?
    public var size: Double?
    public var lineHeight: Double?
    public var letterSpacing: Double?
    public var padding: Double?
    public var inset: Double?
    public var top: Double?
    public var bottom: Double?
    public var borderWidth: Double?
    public var radius: Double?
    public static func parse(_ text: String) throws -> Self {
        guard text.utf16.count <= 4000 else { throw MoReadError.invalid("样式最多 4000 字。") }
        let text = text.replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
        var result = Self(), clipText = false
        for declaration in text.split(separator: ";") {
            let declaration = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !declaration.isEmpty else { continue }
            guard let separator = declaration.firstIndex(of: ":") else { throw MoReadError.invalid("请用“属性: 值;”填写样式。") }
            let key = declaration[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = declaration[declaration.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasSuffix("!important") { value = String(value.dropLast(10)).trimmingCharacters(in: .whitespacesAndNewlines) }
            let lower = value.lowercased()
            func number(_ range: ClosedRange<Double>, em: Bool = true) throws -> Double {
                let suffix = lower.hasSuffix("em"), source = suffix ? String(lower.dropLast(2)) : lower
                guard let number = Double(source), number.isFinite, range.contains(number), !em || suffix || number == 0 else { throw MoReadError.invalid("\(key)：数值需在 \(range.lowerBound)～\(range.upperBound)\(em ? "em" : "")。") }
                return number
            }
            switch key {
            case "color":
                if lower.hasPrefix("linear-gradient(") { result.textGradient = try .parse(value) }
                else { result.color = try .parse(value); result.textGradient = nil }
            case "-webkit-text-fill-color":
                if lower.hasPrefix("linear-gradient(") { result.textGradient = try .parse(value) }
                else { result.quoteColor = try .parse(value); result.textGradient = nil }
            case "background-clip", "-webkit-background-clip":
                guard ["text", "border-box", "padding-box", "content-box"].contains(lower) else { throw MoReadError.invalid("background-clip：请选择 text 或 box 裁剪。") }
                clipText = lower == "text"
            case "background", "background-image":
                result.backgroundSpecified = true; result.backgroundGradient = nil; result.backgroundImageID = nil
                if key == "background" { result.background = .init(rgba: 0) }
                if lower.hasPrefix("linear-gradient(") { result.backgroundGradient = try .parse(value) }
                else if lower.hasPrefix("url(") && value.hasSuffix(")") {
                    let asset = value.dropFirst(4).dropLast().trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    guard asset.hasPrefix("asset:"), let id = UUID(uuidString: String(asset.dropFirst(6))) else { throw MoReadError.invalid("背景图片请从图片库插入。") }
                    result.backgroundImageID = id
                } else if lower != "none" {
                    guard key == "background" else { throw MoReadError.invalid("背景图片请使用渐变或图片库资源。") }
                    result.background = try .parse(value)
                }
            case "background-color": result.background = try .parse(value)
            case "border-color": result.borderColor = try .parse(value)
            case "font-family":
                let family = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                result.fontSpecified = family.lowercased() != "inherit"; result.customFontID = nil
                switch family.lowercased() {
                case "inherit": result.font = nil
                case "system-ui": result.font = .system
                case "serif": result.font = .serif
                case "sans-serif": result.font = .sansSerif
                case "monospace": result.font = .monospace
                default:
                    guard family.hasPrefix("asset:"), let id = UUID(uuidString: String(family.dropFirst(6))) else { throw MoReadError.invalid("字体请使用通用字体名或从字体库插入。") }
                    result.customFontID = id
                }
            case "font-weight":
                guard ["normal", "bold", "100", "200", "300", "400", "500", "600", "700", "800", "900"].contains(lower) else { throw MoReadError.invalid("字重无效。") }
                result.bold = ["bold", "600", "700", "800", "900"].contains(lower)
            case "font-style":
                guard ["italic", "normal"].contains(lower) else { throw MoReadError.invalid("字形请选择 italic 或 normal。") }; result.italic = lower == "italic"
            case "text-decoration":
                let tokens = lower.split(whereSeparator: \.isWhitespace)
                guard !tokens.isEmpty, tokens.allSatisfy({ ["none", "underline", "line-through"].contains($0) }) else { throw MoReadError.invalid("文字装饰无效。") }
                result.underline = tokens.contains("underline"); result.strikethrough = tokens.contains("line-through")
            case "text-align":
                guard ["left", "start", "center", "right", "end"].contains(lower) else { throw MoReadError.invalid("对齐方式无效。") }
                result.alignment = lower == "start" ? "left" : lower == "end" ? "right" : lower
            case "font-size": result.size = try number(0.5...3) * 47
            case "line-height": result.lineHeight = try number(1...2.5, em: false)
            case "letter-spacing": result.letterSpacing = try number(-0.05...0.3)
            case "padding": result.padding = try number(0...6) * 47
            case "margin-inline": result.inset = try number(0...6) * 47
            case "margin-top": result.top = try number(0...6) * 47
            case "margin-bottom": result.bottom = try number(0...6) * 47
            case "border-width": result.borderWidth = try number(0...0.5) * 47
            case "border-radius": result.radius = try number(0...3) * 47
            default: throw MoReadError.invalid("样式属性“\(key)”无效。")
            }
        }
        result.clipsText = clipText
        if clipText {
            guard let gradient = result.backgroundGradient, result.backgroundImageID == nil else { throw MoReadError.invalid("文字渐变需要搭配 linear-gradient。") }
            result.textGradient = gradient; result.backgroundGradient = nil; result.background = nil; result.backgroundSpecified = false
        }
        return result
    }
}
