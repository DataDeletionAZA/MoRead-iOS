import Foundation

public struct ReviewCardSyntaxRule: Codable, Equatable, Identifiable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case delimited = "成对符号", regex = "正则表达式" }
    public var id = UUID()
    public var name = "文字规则"
    public var enabled = true
    public var mode: Mode = .delimited
    public var start = "「"
    public var end = "」"
    public var includeDelimiters = true
    public var pattern = ""
    public var ignoreCase = false
    public var foreground = 0xB45F8A
    public var background: Int?
    public var font: ReaderTypography.Font?
    public var customFontID: UUID?
    public var bold = false
    public var italic = false
    public var underline = false
    public var strikethrough = false
    public var css = ""
    public init() {}
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              start.utf16.count <= 32, end.utf16.count <= 32, pattern.utf16.count <= 256,
              (0...0xFFFFFF).contains(foreground), background.map({ (0...0xFFFFFF).contains($0) }) ?? true else { throw MoReadError.invalid("请检查规则名称、符号或颜色。") }
        if mode == .delimited {
            guard !start.isEmpty, !end.isEmpty else { throw MoReadError.invalid("请填写开始符号和结束符号。") }
        } else { _ = try expression() }
        _ = try style()
    }
    public func style() throws -> ReviewCardCSS {
        var style = try ReviewCardCSS.parse(css)
        guard style.alignment == nil, style.size == nil, style.lineHeight == nil, style.letterSpacing == nil,
              style.padding == nil, style.inset == nil, style.top == nil, style.bottom == nil,
              style.borderWidth == nil, style.borderColor == nil, style.radius == nil else { throw MoReadError.invalid("文字规则只调整颜色、背景、字体和字形；整张卡片的排版请在模板里设置。") }
        if style.color == nil { style.color = .init(rgba: UInt32(foreground) << 8 | 255) }
        if style.background == nil && !style.clipsText, let background { style.background = .init(rgba: UInt32(background) << 8 | 255) }
        if !style.fontSpecified { style.font = font; style.customFontID = customFontID; style.fontSpecified = font != nil || customFontID != nil }
        style.bold = style.bold ?? bold; style.italic = style.italic ?? italic
        style.underline = style.underline ?? underline; style.strikethrough = style.strikethrough ?? strikethrough
        return style
    }
    fileprivate func expression() throws -> NSRegularExpression {
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, pattern.utf16.count <= 256 else { throw MoReadError.invalid("匹配表达式需要填写，最多 256 字。") }
        do { return try NSRegularExpression(pattern: pattern, options: ignoreCase ? [.anchorsMatchLines, .caseInsensitive] : [.anchorsMatchLines]) }
        catch { throw MoReadError.invalid("规则“\(name)”的匹配表达式无效。") }
    }
    public static var examples: [Self] {
        [("人物对白", "“", "”", 0xD06B42), ("直角引号", "「", "」", 0xB45F8A), ("书名与作品", "《", "》", 0x3D7FA6)].map { row in
            var rule = Self(); rule.name = row.0; rule.start = row.1; rule.end = row.2; rule.foreground = row.3; return rule
        }
    }
}

public enum ReviewCardSyntax {
    public struct Match: Equatable, Sendable {
        public let range: NSRange
        public let ruleID: UUID
        public let glyphsOnly: Bool
    }
    public static func matches(_ text: String, rules: [ReviewCardSyntaxRule]) throws -> [Match] {
        guard rules.count <= 64, text.utf16.count <= 50_000 else { throw MoReadError.invalid("文字规则最多 64 条，匹配文字最多 50000 字。") }
        let body = text as NSString, deadline = ProcessInfo.processInfo.systemUptime + 0.3
        var boundaries = IndexSet(integer: 0), offset = 0
        for character in text { offset += String(character).utf16.count; boundaries.insert(offset) }
        var occupied = IndexSet(), matches: [Match] = []
        func check() throws {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw MoReadError.invalid("文字匹配耗时过长，请精简规则或匹配表达式。") }
        }
        func add(_ range: NSRange, rule: ReviewCardSyntaxRule, glyphsOnly: Bool = false) throws {
            guard range.length > 0 else { return }
            guard range.location >= 0, NSMaxRange(range) <= body.length,
                  boundaries.contains(range.location), boundaries.contains(NSMaxRange(range)) else { throw MoReadError.invalid("规则“\(rule.name)”切断了完整字符，请调整匹配内容。") }
            let indices = range.location..<NSMaxRange(range)
            guard !occupied.intersects(integersIn: indices) else { return }
            occupied.insert(integersIn: indices); matches.append(.init(range: range, ruleID: rule.id, glyphsOnly: glyphsOnly))
        }
        for rule in rules where rule.enabled {
            try check(); try rule.validate()
            if rule.mode == .regex {
                var failure: Error?
                try rule.expression().enumerateMatches(in: text, options: [.reportProgress, .reportCompletion], range: NSRange(location: 0, length: body.length)) { match, flags, stop in
                    do {
                        try check()
                        guard !flags.contains(.internalError) else { throw MoReadError.invalid("文字匹配过于复杂，请精简表达式。") }
                        if let match { try add(match.range, rule: rule) }
                    } catch { failure = error; stop.pointee = true }
                }
                if let failure { throw failure }
            } else {
                var cursor = 0
                let style = try rule.style()
                while cursor < body.length {
                    try check()
                    let open = body.range(of: rule.start, range: NSRange(location: cursor, length: body.length - cursor))
                    guard open.location != NSNotFound else { break }
                    let start = NSMaxRange(open), close = body.range(of: rule.end, range: NSRange(location: start, length: body.length - start))
                    guard close.location != NSNotFound else { break }
                    let from = rule.includeDelimiters ? open.location : start, to = rule.includeDelimiters ? NSMaxRange(close) : close.location
                    try add(NSRange(location: from, length: to - from), rule: rule)
                    if !rule.includeDelimiters && (style.fontSpecified || style.bold == true || style.italic == true) {
                        try add(open, rule: rule, glyphsOnly: true); try add(close, rule: rule, glyphsOnly: true)
                    }
                    cursor = NSMaxRange(close)
                }
            }
        }
        return matches.sorted { $0.range.location < $1.range.location }
    }
}
