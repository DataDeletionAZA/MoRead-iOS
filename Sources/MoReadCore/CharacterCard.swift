import Foundation

public struct LoreEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var content: String
    public var enabled: Bool
    public var constant: Bool
    public var keys: [String]
    public var order: Double
    public var sourceJSON: Data?
    public init(title: String = "新设定", content: String = "", enabled: Bool = true, constant: Bool = true, keys: [String] = [], order: Double = 0) {
        self.title = title; self.content = content; self.enabled = enabled; self.constant = constant; self.keys = keys; self.order = order
    }
}

public struct CharacterCard: Codable, Identifiable, Hashable, Sendable {
    public var enabledTools: [String]?
    public var id: UUID = UUID()
    public var name: String
    public var description: String
    public var personality: String
    public var scenario: String
    public var greeting: String
    public var exampleDialogue: String
    public var systemPrompt: String
    public var worldBook: [LoreEntry]
    public var avatar: Data?
    public var sourceJSON: Data?

    public init(name: String = "阿翎", description: String = "你是一位耐心、敏锐的共读伙伴。和用户一起读书，认真区分原文事实与推测。") {
        self.name = name; self.description = description
        personality = ""; scenario = ""; greeting = "今天读到哪里了？"; exampleDialogue = ""; systemPrompt = ""; worldBook = []
    }
    public func substitute(_ text: String, user: String) -> String {
        text.replacingOccurrences(of: "{{char}}", with: name, options: .caseInsensitive)
            .replacingOccurrences(of: "{{user}}", with: user, options: .caseInsensitive)
    }
    public func prompt(user: String, conversation: String, loreBudget: Int = 12_000) -> String {
        var sections = ["角色：\(name)", description, personality, scenario, systemPrompt]
        if !exampleDialogue.isEmpty { sections.append("对话风格示例：\n\(exampleDialogue)") }
        var remaining = max(0, loreBudget)
        for entry in worldBook.sorted(by: { $0.order < $1.order }) where entry.enabled {
            guard entry.constant || entry.keys.contains(where: { let key = $0.trimmingCharacters(in: .whitespacesAndNewlines); return !key.isEmpty && conversation.localizedCaseInsensitiveContains(key) }) else { continue }
            let value = substitute(entry.content, user: user)
            guard value.utf16.count <= remaining else { continue }
            sections.append(value); remaining -= value.utf16.count
        }
        return substitute(sections.filter { !$0.isEmpty }.joined(separator: "\n\n"), user: user)
    }
}

public enum CharacterCardImporter {
    public static func read(_ url: URL, limit: Int = 32 * 1024 * 1024) throws -> Data {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var data = Data()
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard chunk.count <= limit - data.count else { throw MoReadError.invalid("文件过大，请选择较小的文件。") }
            data.append(chunk)
        }
        return data
    }
    public static func parse(_ data: Data) throws -> CharacterCard {
        guard data.count <= 32 * 1024 * 1024 else { throw MoReadError.invalid("角色卡超过 32 MB。") }
        let png = data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        let json = try png ? payload(fromPNG: data) : data
        guard json.count <= 4 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw MoReadError.invalid("角色卡内容无效。") }
        let fields = root["data"] as? [String: Any] ?? root
        func string(_ key: String) -> String { fields[key] as? String ?? "" }
        let name = string("name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MoReadError.invalid("这份文件缺少角色名称。") }
        var card = CharacterCard(name: name, description: string("description"))
        card.personality = string("personality"); card.scenario = string("scenario")
        card.greeting = string("first_mes"); card.exampleDialogue = string("mes_example"); card.systemPrompt = string("system_prompt")
        card.sourceJSON = json; card.avatar = png ? data : nil
        if let book = fields["character_book"] as? [String: Any] {
            card.worldBook = try WorldBookImporter.parse(JSONSerialization.data(withJSONObject: book))
        }
        return card
    }
    private static func payload(fromPNG data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var offset = 8
        var payloads: [String: Data] = [:]
        while bytes.count - offset >= 12 {
            let size = bytes[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let length = Int(size)
            guard length <= bytes.count - offset - 12 else { throw MoReadError.invalid("PNG 角色卡不完整。") }
            let type = String(bytes: bytes[offset + 4..<offset + 8], encoding: .ascii)
            let start = offset + 8
            if type == "tEXt", let zero = bytes[start..<start + length].firstIndex(of: 0),
               let key = String(bytes: bytes[start..<zero], encoding: .isoLatin1)?.lowercased(), ["chara", "ccv3"].contains(key) {
                let encoded = bytes[zero + 1..<start + length].filter { ![9, 10, 13, 32].contains($0) }
                guard let value = Data(base64Encoded: Data(encoded)), value.count <= 4 * 1024 * 1024 else { throw MoReadError.invalid("角色卡中的人物资料损坏。") }
                payloads[key] = value
            }
            offset += length + 12
            if type == "IEND" { break }
        }
        guard let value = payloads["ccv3"] ?? payloads["chara"] else { throw MoReadError.invalid("这张 PNG 中没有角色卡资料。") }
        return value
    }
}

public enum WorldBookImporter {
    public static func parse(_ data: Data) throws -> [LoreEntry] {
        guard data.count <= 4 * 1024 * 1024 else { throw MoReadError.invalid("世界书超过 4 MB。") }
        let object = try JSONSerialization.jsonObject(with: data)
        let root = object as? [String: Any]
        let body = root?["data"] as? [String: Any] ?? root
        let book = body?["character_book"] as? [String: Any] ?? body
        let raw = book?["entries"] ?? object
        let entries: [[String: Any]]
        if let array = raw as? [[String: Any]] { entries = array }
        else if let dictionary = raw as? [String: [String: Any]], book?["entries"] != nil {
            entries = dictionary.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { dictionary[$0] }
        } else { throw MoReadError.invalid("没有找到世界书条目，请选择世界书 JSON 文件。") }
        guard entries.count <= 10000 else { throw MoReadError.invalid("世界书条目超过 10000 条。") }
        return try entries.enumerated().map { index, entry in
            guard let content = entry["content"] as? String else { throw MoReadError.invalid("第 \(index + 1) 条世界书缺少正文。") }
            let keys = (entry["keys"] as? [String] ?? entry["key"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let order = (entry["insertion_order"] as? NSNumber ?? entry["order"] as? NSNumber)?.doubleValue ?? Double(index)
            var value = LoreEntry(title: entry["comment"] as? String ?? entry["name"] as? String ?? keys.first ?? "设定 \(index + 1)", content: content,
                enabled: (entry["enabled"] as? Bool ?? true) && !(entry["disable"] as? Bool ?? false),
                constant: entry["constant"] as? Bool ?? keys.isEmpty, keys: keys, order: order.isFinite ? order : Double(index))
            value.sourceJSON = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            return value
        }.sorted { $0.order < $1.order }
    }
}
