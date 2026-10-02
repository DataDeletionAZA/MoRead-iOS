import Foundation

public struct ExtractedCharacterCard: Identifiable, Sendable {
    public let id = UUID()
    public var name: String
    public var description: String

    public func json() throws -> Data {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= 80, !description.isEmpty, description.utf16.count <= 24_000 else {
            throw MoReadError.invalid("请填写姓名与人物资料；姓名最多 80 字，资料最多 24000 字。")
        }
        let fields: [String: Any] = ["name": name, "description": description, "personality": "", "scenario": "",
            "first_mes": "", "mes_example": "", "creator": "MoRead", "character_version": "1.0",
            "creator_notes": "来自书中人物资料，可能包含用户手动补充；原文依据仅来自所选提取范围。",
            "system_prompt": "", "post_history_instructions": "", "alternate_greetings": [String](),
            "tags": ["书中人物"], "extensions": [String: String]()]
        return try JSONSerialization.data(withJSONObject: ["spec": "chara_card_v2", "spec_version": "2.0", "data": fields], options: [.prettyPrinted, .sortedKeys])
    }
    public func characterCard() throws -> CharacterCard {
        var card = try CharacterCardImporter.parse(json()); card.id = id; return card
    }
}

extension BookCharactersStore {
    public func extractedCard(from guide: BookCharacterGuide, named name: String) throws -> ExtractedCharacterCard {
        guard let person = try displayedCharacters(from: guide).first(where: { $0.name == name }) else {
            throw MoReadError.invalid("人物资料已变化，请关闭草稿后重新提取角色卡。")
        }
        if person.manualDescription == nil { for evidence in person.evidence { _ = try locate(guide, evidence: evidence) } }
        return .init(name: person.name, description: person.editableDescription)
    }
}
