import Foundation

public enum GlobalPromptPosition: String, Codable, CaseIterable, Sendable {
    case beforeSystem = "BEFORE_SYSTEM", afterSystem = "AFTER_SYSTEM"
    case beforeUser = "BEFORE_LAST_USER", afterUser = "AFTER_LAST_USER"
    public var label: String {
        switch self {
        case .beforeSystem: "系统提示词之前"
        case .afterSystem: "系统提示词之后"
        case .beforeUser: "最近一条用户消息之前"
        case .afterUser: "最近一条用户消息之后"
        }
    }
}

public struct GlobalPromptPreset: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var prompt: String
    public var enabled: Bool
    public var position: GlobalPromptPosition
    public var builtIn: Bool
    public init(id: String = UUID().uuidString, name: String = "", prompt: String = "", enabled: Bool = true, position: GlobalPromptPosition = .afterSystem, builtIn: Bool = false) {
        self.id = id; self.name = name; self.prompt = prompt; self.enabled = enabled; self.position = position; self.builtIn = builtIn
    }
    public static let defaults: [GlobalPromptPreset] = [
        .init(id: "builtin-natural-style", name: "自然表达", prompt: "使用自然、具体、连贯的中文回答，避免空泛套话和不必要的重复总结。", enabled: false, builtIn: true),
        .init(id: "builtin-immersive-roleplay", name: "沉浸式角色扮演", prompt: "保持角色视角与说话方式，通过动作、语气和细节增强沉浸感；不要代替用户决定其言行。", enabled: false, builtIn: true),
        .init(id: "builtin-concise", name: "简洁回答", prompt: "优先直接回答问题；除非用户要求展开，否则控制篇幅并省略重复背景。", enabled: false, position: .beforeUser, builtIn: true)
    ]
    public static func validate(_ presets: [Self]) throws {
        guard presets.count <= 100, Set(presets.map(\.id)).count == presets.count else { throw MoReadError.invalid("预设最多保存 100 个，且不能有重复标识。") }
        var total = 0
        for value in presets {
            guard !value.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.id.utf16.count <= 128,
                  !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.name.utf16.count <= 80,
                  !value.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.prompt.utf16.count <= 12_000 else {
                throw MoReadError.invalid("请填写预设名称和提示词；名称最多 80 字，提示词最多 12000 字。")
            }
            total += value.prompt.utf16.count
        }
        guard total <= 120_000 else { throw MoReadError.invalid("全部预设的提示词合计不能超过 120000 字。") }
    }
}

public enum GlobalPromptInjector {
    public static func inject(_ messages: [ChatMessage], presets: [GlobalPromptPreset]) throws -> [ChatMessage] {
        try GlobalPromptPreset.validate(presets)
        let enabled = presets.filter(\.enabled)
        guard !enabled.isEmpty else { return messages }
        func block(_ position: GlobalPromptPosition) -> String {
            enabled.filter { $0.position == position }.map { "【全局预设·\($0.name)】\n" + $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n")
        }
        func joined(_ texts: String...) -> String { texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n") }
        var copy = messages
        let before = block(.beforeSystem), after = block(.afterSystem)
        if !before.isEmpty || !after.isEmpty {
            if let index = copy.firstIndex(where: { $0.role == "system" }) {
                copy[index].content = joined(before, copy[index].content, after)
            } else { copy.insert(ChatMessage(role: "system", content: joined(before, after)), at: 0) }
        }
        if let index = copy.lastIndex(where: { $0.role == "user" }) {
            let before = block(.beforeUser), after = block(.afterUser)
            if !before.isEmpty || !after.isEmpty { copy[index].content = joined(before, copy[index].content, after) }
        }
        return copy
    }
}

extension CompanionSettings {
    public var resolvedGlobalPrompts: [GlobalPromptPreset] { globalPrompts ?? GlobalPromptPreset.defaults }
}
