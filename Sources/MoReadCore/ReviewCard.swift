import Foundation

public struct ReviewCardTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name = "我的卡片"
    public var background = 0xF7F5EF
    public var foreground = 0x38444B
    public var accent = 0x7E9CB5
    public var gradientEnd: Int?
    public var useBookCover = false
    public var backgroundImageID: UUID?
    public var font: ReaderTypography.Font = .serif
    public var customFontID: UUID?
    public var fontSize = 47.0
    public var lineHeight = 1.55
    public var letterSpacing = 0.0
    public var padding = 96.0
    public var cornerRadius = 0.0
    public var borderWidth = 0.0
    public var alignment = "left"
    public var bold = false
    public var italic = false
    public var underline = false
    public var strikethrough = false
    public var css: String?
    public var syntaxEnabled: Bool?
    public var syntaxRules: [ReviewCardSyntaxRule]?
    public init() {}
    public func validate() throws {
        _ = try ReviewCardCSS.parse(css ?? "")
        let rules = syntaxRules ?? []
        guard rules.count <= 64, Set(rules.map(\.id)).count == rules.count else { throw MoReadError.invalid("文字规则最多 64 条，标识不能重复。") }
        for rule in rules { try rule.validate() }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              [background, foreground, accent].allSatisfy({ (0...0xFFFFFF).contains($0) }),
              gradientEnd.map({ (0...0xFFFFFF).contains($0) }) ?? true,
              fontSize.isFinite, (23.5...141).contains(fontSize), lineHeight.isFinite, (1...2.5).contains(lineHeight),
              letterSpacing.isFinite, (-0.05...0.3).contains(letterSpacing), padding.isFinite, (24...280).contains(padding),
              cornerRadius.isFinite, (0...141).contains(cornerRadius), borderWidth.isFinite, (0...23.5).contains(borderWidth),
              ["left", "center", "right"].contains(alignment) else { throw MoReadError.invalid("卡片模板的名称、颜色或排版数值无效。") }
    }
    public static var presets: [Self] {
        let values = [("纸白", 0xF7F5EF, 0x38444B, 0x7E9CB5), ("雾蓝", 0xD7E6F2, 0x354C5E, 0x6A94B5),
                      ("暗夜", 0x202930, 0xD3DEE8, 0x9BBEDC), ("书影", 0x202930, 0xE8EDF3, 0xB6CCE0), ("青竹", 0xE0E9DD, 0x384B3B, 0x739278)]
        return values.enumerated().map { index, row in
            var value = Self(); value.id = UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 1)")!
            value.useBookCover = index == 3
            value.name = row.0; value.background = row.1; value.foreground = row.2; value.accent = row.3
            return value
        }
    }
}

public struct ReviewCardLibrary: Sendable {
    private let url: URL
    public init(root: URL) { url = root.appendingPathComponent("review-card-templates.json") }
    public func templates() throws -> [ReviewCardTemplate] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw MoReadError.invalid("卡片模板文件无效。") }
        let values = try JSONDecoder().decode([ReviewCardTemplate].self, from: CharacterCardImporter.read(url, limit: 1_048_576))
        guard values.count <= 200, Set(values.map(\.id)).count == values.count,
              Set(values.map(\.id)).isDisjoint(with: ReviewCardTemplate.presets.map(\.id)) else { throw MoReadError.invalid("卡片模板数量或标识无效。") }
        for value in values { try value.validate() }
        return values
    }
    public func save(_ value: ReviewCardTemplate) throws {
        try value.validate()
        guard !ReviewCardTemplate.presets.contains(where: { $0.id == value.id }) else { throw MoReadError.invalid("请为自定义模板使用独立标识。") }
        var values = try templates()
        if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value } else { values.append(value) }
        guard values.count <= 200 else { throw MoReadError.invalid("最多保存 200 个卡片模板。") }
        let data = try JSONEncoder().encode(values)
        guard data.count <= 1_048_576 else { throw MoReadError.invalid("卡片模板总大小超过 1 MB，请精简样式或删除不用的模板。") }
        try data.write(to: url, options: .atomic)
    }
    public func remove(_ id: UUID) throws {
        let values = try templates().filter { $0.id != id }
        try JSONEncoder().encode(values).write(to: url, options: .atomic)
    }
}
