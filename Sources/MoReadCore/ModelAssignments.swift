import Foundation

public enum ModelTask: String, CaseIterable, Sendable {
    case chat, batch, knowledge, summary, memory, annotation, coverQuery, suggestion
    public var label: String {
        switch self {
        case .chat: "主对话"
        case .batch: "批量整理"
        case .knowledge: "章节与人物"
        case .summary: "对话提要"
        case .memory: "长期记忆整理"
        case .annotation: "随读段评"
        case .coverQuery: "封面搜索词"
        case .suggestion: "建议回复"
        }
    }
}

extension CompanionSettings {
    public func assignedProvider(for task: ModelTask) -> UUID? {
        switch task {
        case .chat: selectedProvider
        case .batch: batchProvider
        case .knowledge: knowledgeProvider
        case .summary: summarySettings?.providerID
        case .memory: personaMemory?.providerID
        case .annotation: proactive?.providerID
        case .coverQuery: coverQueryProvider
        case .suggestion: suggestionProvider
        }
    }
    public func resolvedProvider(for task: ModelTask) -> AIProvider? {
        let fallback: UUID?
        switch task {
        case .chat, .batch: fallback = nil
        case .summary, .memory: fallback = batchProvider
        case .knowledge, .annotation, .coverQuery, .suggestion: fallback = batchProvider ?? selectedProvider
        }
        let id = assignedProvider(for: task) ?? fallback
        return providers.first { $0.id == id }
    }
    public mutating func assignProvider(_ id: UUID?, to task: ModelTask) throws {
        guard id == nil || providers.contains(where: { $0.id == id }) else { throw MoReadError.invalid("这个模型已不可用，请重新选择服务商。") }
        switch task {
        case .chat: selectedProvider = id
        case .batch: batchProvider = id
        case .knowledge: knowledgeProvider = id
        case .summary:
            var value = summarySettings ?? SummarySettings(); value.providerID = id; summarySettings = value
        case .memory:
            var value = personaMemory ?? PersonaMemorySettings(); value.providerID = id; personaMemory = value
        case .annotation:
            var value = proactive ?? ProactiveSettings(); value.providerID = id; proactive = value
        case .coverQuery: coverQueryProvider = id
        case .suggestion: suggestionProvider = id
        }
    }
}
