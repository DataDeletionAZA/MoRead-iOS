import Foundation

public struct SavedVoice: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var voiceId: String
    public var displayName: String
    public var tags: String
    public var gender: String
    public var providerHint: String
    public var extraJson: String
    public var pinned: Bool
    public var sortOrder: Int
    public init(voiceId: String = "", displayName: String = "", providerHint: String = "", tags: String = "", gender: String = "UNSPECIFIED") {
        id = UUID(); self.voiceId = voiceId; self.displayName = displayName; self.providerHint = providerHint
        self.tags = tags; self.gender = gender; extraJson = ""; pinned = false; sortOrder = 0
    }
    enum CodingKeys: String, CodingKey { case id, voiceId, displayName, tags, gender, providerHint, extraJson, pinned, sortOrder }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        voiceId = try c.decode(String.self, forKey: .voiceId); displayName = try c.decode(String.self, forKey: .displayName)
        tags = try c.decodeIfPresent(String.self, forKey: .tags) ?? ""
        gender = try c.decodeIfPresent(String.self, forKey: .gender) ?? "UNSPECIFIED"
        providerHint = try c.decodeIfPresent(String.self, forKey: .providerHint) ?? ""
        extraJson = try c.decodeIfPresent(String.self, forKey: .extraJson) ?? ""
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
    public var tagList: [String] { tags.components(separatedBy: CharacterSet(charactersIn: ",，")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    public static func hint(for service: SpeechService) -> String {
        switch service { case .openAI: "OPENAI"; case .miniMax: "MINIMAX"; case .gmi: "GMI"; case .gemini: "GEMINI"; case .mimo: "MIMO"; case .fish: "FISH" }
    }
    public func compatible(with service: SpeechService) -> Bool {
        providerHint.isEmpty || providerHint == Self.hint(for: service) || (service == .gmi && providerHint == "MINIMAX")
    }
    public func applying(to settings: CloudSpeechSettings) throws -> CloudSpeechSettings {
        let value = try normalized()
        guard value.compatible(with: settings.service), !(settings.service == .mimo && settings.model.lowercased().hasSuffix("-voicedesign")) else {
            throw MoReadError.invalid("请先在云端声音中选择与这个音色对应的语音服务和模型。")
        }
        var result = settings; result.voice = value.voiceId
        _ = try CloudSpeechClient.request(settings: result, key: "configuration-check", text: "试听")
        return result
    }
    public func normalized() throws -> Self {
        var v = self
        v.voiceId = voiceId.trimmingCharacters(in: .whitespacesAndNewlines)
        v.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        v.providerHint = providerHint.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var seen: Set<String> = []; v.tags = tagList.filter { seen.insert($0.lowercased()).inserted }.joined(separator: ",")
        guard !v.voiceId.isEmpty, v.voiceId.utf8.count <= 512, !v.voiceId.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !v.displayName.isEmpty, v.displayName.count <= 80, !v.displayName.contains(where: \.isNewline), v.tags.count <= 1000,
              v.providerHint.count <= 80, !v.providerHint.contains(where: \.isNewline), ["MALE", "FEMALE", "UNSPECIFIED"].contains(v.gender),
              v.extraJson.utf8.count <= 8192 else { throw MoReadError.invalid("请检查音色名称、声音 ID、标签和性别；名称最多 80 字。") }
        return v
    }
    var identity: String { providerHint + ":" + (providerHint == "GEMINI" ? voiceId.lowercased() : voiceId) }
}

public struct VoiceLibrary: Sendable {
    public static let maximumBytes = 2 * 1024 * 1024
    public let root: URL
    public init(root: URL) { self.root = root }
    private var file: URL { root.appendingPathComponent("voice-library.json") }
    public func voices() throws -> [SavedVoice] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw MoReadError.invalid("音色库文件无效。") }
        let data = try CharacterCardImporter.read(file, limit: Self.maximumBytes)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.allSatisfy({ ($0["id"] as? String).flatMap(UUID.init(uuidString:)) != nil }) else { throw MoReadError.invalid("音色库缺少有效编号。") }
        let values = try JSONDecoder().decode([SavedVoice].self, from: data)
        try Self.validate(values)
        return values.sorted { a, b in a.pinned != b.pinned ? a.pinned : a.sortOrder != b.sortOrder ? a.sortOrder < b.sortOrder : a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending }
    }
    static func validate(_ values: [SavedVoice]) throws {
        guard values.count <= 2000, Set(values.map(\.id)).count == values.count, Set(values.map(\.identity)).count == values.count else { throw MoReadError.invalid("音色库包含重复记录或超过 2000 个音色。") }
        for v in values { guard try v.normalized() == v else { throw MoReadError.invalid("音色库记录无效。") } }
    }
    private func write(_ values: [SavedVoice]) throws {
        try Self.validate(values)
        let data = try JSONEncoder().encode(values)
        guard data.count <= Self.maximumBytes else { throw MoReadError.invalid("音色库内容超过 2 MB。") }
        try data.write(to: file, options: .atomic)
    }
    public func save(_ voice: SavedVoice) throws {
        let v = try voice.normalized(); var all = try voices()
        if let index = all.firstIndex(where: { $0.id == v.id }) { all[index] = v } else { all.append(v) }
        try write(all)
    }
    public func remove(_ id: UUID) throws { try write(voices().filter { $0.id != id }) }
    @discardableResult public func merge(_ values: [SavedVoice]) throws -> Int {
        guard values.count <= 2000 else { throw MoReadError.invalid("一次最多导入 2000 个音色。") }
        let incoming = try values.map { try $0.normalized() }
        var all = try voices(), identities = Set(all.map(\.identity)), added = 0
        for var value in incoming where identities.insert(value.identity).inserted {
            value.id = UUID(); all.append(value); added += 1
        }
        try write(all); return added
    }
    @discardableResult public func importJSON(_ data: Data) throws -> Int {
        guard data.count <= Self.maximumBytes else { throw MoReadError.invalid("音色文件不能超过 2 MB。") }
        return try merge(JSONDecoder().decode([SavedVoice].self, from: data))
    }
    public func exportJSON() throws -> Data {
        let data = try JSONEncoder().encode(voices())
        var values = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        for i in values.indices { values[i].removeValue(forKey: "id") }
        return try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
    }
    public static var geminiPresets: [SavedVoice] { GeminiSpeech.voices.map { SavedVoice(voiceId: $0.id, displayName: $0.id + " · " + $0.style, providerHint: "GEMINI", tags: $0.style) } }
    public static var miniMaxPresets: [SavedVoice] { [
        SavedVoice(voiceId: "male-qn-qingse", displayName: "青涩青年男声", providerHint: "MINIMAX", tags: "男声,青年,对白", gender: "MALE"),
        SavedVoice(voiceId: "male-qn-jingying", displayName: "精英青年男声", providerHint: "MINIMAX", tags: "男声,沉稳,旁白", gender: "MALE"),
        SavedVoice(voiceId: "female-shaonv", displayName: "少女女声", providerHint: "MINIMAX", tags: "女声,年轻,温柔", gender: "FEMALE")
    ] }
}
