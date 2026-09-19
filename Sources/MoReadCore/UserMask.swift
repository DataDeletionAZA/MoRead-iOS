import Foundation

public struct UserMask: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var description: String
    public init(name: String = "", description: String = "") { self.name = name; self.description = description }
    public func validated() throws -> Self {
        var copy = self
        copy.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        copy.description = String(description.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        guard !copy.name.isEmpty else { throw MoReadError.invalid("请填写身份名称。") }
        return copy
    }
}

public struct UserMaskSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var activeMaskID: UUID?
    public var masks: [UserMask] = []
    public init() {}
    public var activeMask: UserMask? { enabled ? masks.first { $0.id == activeMaskID } : nil }
    public mutating func save(_ mask: UserMask) throws {
        let value = try mask.validated()
        if let index = masks.firstIndex(where: { $0.id == value.id }) { masks[index] = value } else { masks.append(value) }
        if activeMaskID == nil { activeMaskID = value.id }
    }
    public mutating func remove(_ ids: Set<UUID>) {
        masks.removeAll { ids.contains($0.id) }
        if let activeMaskID, ids.contains(activeMaskID) { self.activeMaskID = masks.first?.id }
        if masks.isEmpty { enabled = false }
    }
}

public struct ChatIdentity: Codable, Hashable, Sendable {
    public var maskID: UUID?
    public var name: String
    public var description: String
    public init(name: String, mask: UserMask? = nil) {
        maskID = mask?.id; self.name = mask?.name ?? name; description = mask?.description ?? ""
    }
    public var label: String { maskID == nil ? "本人：\(name)" : "扮演：\(name)" }
    public var prompt: String {
        if maskID == nil { return "【用户身份】用户当前以本人身份交流，称呼：\(name)。历史消息中的扮演身份与经历不能当作本人的事实。" }
        return "【用户身份】用户当前扮演「\(name)」。以下为用户侧设定，角色保持自己的身份；扮演经历不能当作用户本人的事实，也不能扩大已读范围：\n\(description)"
    }
}

extension CompanionSettings {
    public var currentIdentity: ChatIdentity { ChatIdentity(name: userName, mask: userMasks?.activeMask) }
}

extension ChatMessage {
    public var dialogueLabel: String { role == "user" ? identity.map { "用户（\($0.label)）" } ?? "用户" : "我" }
    public var withIdentityLabel: Self {
        guard role == "user", identity != nil else { return self }
        var copy = self; copy.content = "【\(dialogueLabel)】\n" + content; return copy
    }
}
