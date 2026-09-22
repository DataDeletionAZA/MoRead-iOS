import Foundation
import MoReadCore

struct CharacterGenerationPlan: Identifiable {
    let id = UUID()
    let source: BookCharactersPlan
    let provider: AIProvider
    var job: KnowledgeJobKey { .init(bookID: source.bookID, chapter: nil) }
}

extension CompanionModel {
    func previewCharacters(bookID: UUID, progressBounded: Bool, library: LibraryModel) throws -> CharacterGenerationPlan {
        guard !library.maintenance, let storage = library.store else { throw MoReadError.invalid("书库忙碌，请稍后再试。") }
        library.flush()
        let provider = try knowledgeProvider()
        let source = try BookCharactersStore(library: storage, bookID: bookID).preview(modelFingerprint: provider.knowledgeFingerprint, modelLabel: provider.name + " · " + provider.model, progressBounded: progressBounded)
        return .init(source: source, provider: provider)
    }
    func startCharacters(_ plan: CharacterGenerationPlan, library: LibraryModel) {
        guard knowledgeTasks[plan.job] == nil, !library.maintenance, let storage = library.store else { return }
        prepareKnowledgeJob(plan.job)
        knowledgeTasks[plan.job] = Task {
            defer { self.knowledgeTasks[plan.job] = nil; library.recordsRevision = UUID() }
            do {
                try self.validateCharacterPlan(plan, library: library)
                let key: String
                #if DEBUG
                key = self.simulatedCharacters ? "local-test" : try KeychainStore.read(plan.provider.id)
                #else
                key = try KeychainStore.read(plan.provider.id)
                #endif
                let store = BookCharactersStore(library: storage, bookID: plan.source.bookID)
                let result = try await store.generate(plan.source, stream: { messages, tool, exchanges in
                    try await self.characterReply(provider: plan.provider, key: key, messages: messages, tool: tool, exchanges: exchanges)
                }, validate: { try await self.validateCharacterPlan(plan, library: library) }, progress: { done, total, detail in
                    await self.characterProgress(plan.job, done: done, total: total, detail: detail)
                })
                self.knowledgeStates[plan.job] = "已保存 \(result.characters.count) 位人物。"
            } catch is CancellationError { self.knowledgeStates[plan.job] = "已停止，已核对的分段会保留。" }
            catch { self.knowledgeStates[plan.job] = Task.isCancelled ? "已停止，已核对的分段会保留。" : error.localizedDescription }
        }
    }
    private func characterProgress(_ key: KnowledgeJobKey, done: Int, total: Int, detail: String) { knowledgeStates[key] = "已整理 \(done) / \(total) 章 · \(detail)" }
    private func validateCharacterPlan(_ plan: CharacterGenerationPlan, library: LibraryModel) throws {
        try Task.checkCancellation()
        guard !library.maintenance, library.books.contains(where: { book in book.id == plan.source.bookID && !book.removed && book.hasBody && (plan.source.sourceThrough.map { through in through <= book.readThrough } ?? true) }) else { throw CancellationError() }
        guard try knowledgeProvider() == plan.provider else { throw MoReadError.invalid("整理模型已变化，请重新确认。") }
        library.flush()
    }
    private func characterReply(provider: AIProvider, key: String, messages: [ChatMessage], tool: ChatTool, exchanges: [ChatToolExchange]) async throws -> ChatToolRound {
        #if DEBUG
        if simulatedCharacters {
            try await Task.sleep(nanoseconds: ProcessInfo.processInfo.arguments.contains("--characters-slow") ? 8_000_000_000 : 1_000_000_000)
            if ProcessInfo.processInfo.arguments.contains("--characters-fail") { throw MoReadError.invalid("人物整理服务暂不可用。") }
            let source = messages.last?.content.components(separatedBy: "<source>\n").last?.components(separatedBy: "\n</source>").first ?? ""
            let quote = TextBoundary.prefix(source.trimmingCharacters(in: .whitespacesAndNewlines), end: 40)
            let people: [[String: Any]] = ["林遥", "江舟"].filter { source.contains($0) }.map { ["name": $0, "facts": [["text": "\($0)出现在这段原文中。", "quote": quote]]] }
            let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["characters": people]), as: UTF8.self)
            return .init(text: "", calls: [.init(id: UUID().uuidString, name: tool.name, arguments: raw)], replay: Data("{}".utf8))
        }
        #endif
        var provider = provider; provider.maxTokens = min(provider.maxTokens, 6000)
        return try await ChatClient.turn(provider: provider, key: key, messages: messages, tools: [tool], exchanges: exchanges, temperature: 0.2, onDelta: { _ in })
    }
    #if DEBUG
    var simulatedCharacters: Bool { ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.arguments.contains("--simulate-characters") }
    #endif
}
