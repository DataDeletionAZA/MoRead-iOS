import Foundation
import MoReadCore

struct KnowledgeJobKey: Hashable { let bookID: UUID; let chapter: Int }
struct KnowledgePlan: Identifiable {
    let id = UUID()
    let source: KnowledgeSource
    let provider: AIProvider
    var job: KnowledgeJobKey { .init(bookID: source.bookID, chapter: source.chapter) }
}

extension CompanionModel {
    func previewKnowledge(bookID: UUID, chapter: Int, library: LibraryModel) throws -> KnowledgePlan {
        guard !library.maintenance, let storage = library.store else { throw MoReadError.invalid("书库忙碌，请稍后再试。") }
        library.flush()
        let source = try storage.knowledgeSource(bookID: bookID, chapter: chapter)
        var provider = settings.providers.first { $0.id == (settings.knowledgeProvider ?? settings.selectedProvider) }
        #if DEBUG
        if simulatedKnowledge { var mock = AIProvider(); mock.name = "本地模拟"; mock.model = "本地模拟"; provider = mock }
        #endif
        guard let provider else { throw MoReadError.invalid("请先在设置中添加 AI 服务商，再选择整理模型。") }
        guard (provider.name + " · " + provider.model).utf16.count <= 500 else { throw MoReadError.invalid("服务商或模型名称过长，请在设置中缩短后重试。") }
        _ = try ChatRequest.make(provider: provider, key: "configuration-check", messages: [])
        return .init(source: source, provider: provider)
    }
    func startKnowledge(_ plan: KnowledgePlan, library: LibraryModel) {
        guard knowledgeTasks[plan.job] == nil, !library.maintenance else { return }
        knowledgeStates[plan.job] = "等待整理…"
        if knowledgeStates.count > 128 {
            for key in Array(knowledgeStates.keys) where key != plan.job && knowledgeTasks[key] == nil {
                if knowledgeStates.count <= 128 { break }; knowledgeStates.removeValue(forKey: key)
            }
        }
        knowledgeTasks[plan.job] = Task {
            defer { self.knowledgeTasks[plan.job] = nil }
            do {
                try self.validateKnowledgePlan(plan, library: library)
                let key: String
                #if DEBUG
                key = self.simulatedKnowledge ? "local-test" : try KeychainStore.read(plan.provider.id)
                #else
                key = try KeychainStore.read(plan.provider.id)
                #endif
                let content = try await ChapterKnowledgeAgent.generate(source: plan.source, stream: { messages, tool, exchanges in
                    try await self.knowledgeReply(plan: plan, key: key, messages: messages, tool: tool, exchanges: exchanges)
                }, validate: { try await self.validateKnowledgePlan(plan, library: library) }, progress: { done, total in
                    await self.knowledgeProgress(plan.job, done: done, total: total)
                })
                try self.validateKnowledgePlan(plan, library: library)
                guard let storage = library.store else { throw CancellationError() }
                let provider = plan.provider
                let fingerprint = MemoryBookScope.fingerprint([provider.id.uuidString, provider.baseURL, provider.model, provider.dialect.rawValue, String(min(max(256, provider.maxTokens), 6000)), provider.chatTokenLimitParameter?.rawValue ?? "auto", "temperature=0.2"])
                try storage.saveKnowledge(content, source: plan.source, modelFingerprint: fingerprint, modelLabel: provider.name + " · " + provider.model)
                library.recordsRevision = UUID()
                self.knowledgeStates[plan.job] = "已保存"
            } catch is CancellationError { self.knowledgeStates[plan.job] = "已停止，可重新生成。" }
            catch { self.knowledgeStates[plan.job] = Task.isCancelled ? "已停止，可重新生成。" : error.localizedDescription }
        }
    }
    func stopKnowledge(_ key: KnowledgeJobKey) {
        guard let task = knowledgeTasks[key] else { return }
        task.cancel(); knowledgeStates[key] = "正在停止…"
    }
    private func knowledgeProgress(_ key: KnowledgeJobKey, done: Int, total: Int) { knowledgeStates[key] = "正在整理 \(done) / \(total)…" }
    private func validateKnowledgePlan(_ plan: KnowledgePlan, library: LibraryModel) throws {
        try Task.checkCancellation()
        guard !library.maintenance, let storage = library.store,
              library.books.contains(where: { $0.id == plan.source.bookID && !$0.removed && $0.hasBody && ReadingScope(through: $0.readThrough).allows(chapter: plan.source.chapter, range: NSRange(location: 0, length: plan.source.text.utf16.count)) }) else { throw CancellationError() }
        #if DEBUG
        if !simulatedKnowledge && !settings.providers.contains(plan.provider) { throw MoReadError.invalid("整理服务商设置已变化，请重新生成。") }
        #else
        guard settings.providers.contains(plan.provider) else { throw MoReadError.invalid("整理服务商设置已变化，请重新生成。") }
        #endif
        library.flush(); try storage.validateKnowledgeSource(plan.source)
    }
    private func knowledgeReply(plan: KnowledgePlan, key: String, messages: [ChatMessage], tool: ChatTool, exchanges: [ChatToolExchange]) async throws -> ChatToolRound {
        #if DEBUG
        if simulatedKnowledge {
            try await Task.sleep(nanoseconds: ProcessInfo.processInfo.arguments.contains("--knowledge-slow") ? 8_000_000_000 : 2_000_000_000)
            if ProcessInfo.processInfo.arguments.contains("--knowledge-fail") { throw MoReadError.invalid("整理服务暂不可用。") }
            let quote = TextBoundary.prefix(plan.source.parts[0].text.trimmingCharacters(in: .whitespacesAndNewlines), end: 14)
            let raw = try JSONSerialization.data(withJSONObject: ["outline": "林遥推开书店的大门，开始了这一天的阅读。", "summary": [["text": "林遥走进书店。", "quote": quote]]])
            return .init(text: "", calls: [.init(id: UUID().uuidString, name: tool.name, arguments: String(decoding: raw, as: UTF8.self))], replay: Data("{}".utf8))
        }
        #endif
        var provider = plan.provider; provider.maxTokens = min(provider.maxTokens, 6000)
        return try await ChatClient.turn(provider: provider, key: key, messages: messages, tools: [tool], exchanges: exchanges, temperature: 0.2, onDelta: { _ in })
    }
    #if DEBUG
    var simulatedKnowledge: Bool { ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.arguments.contains("--simulate-knowledge") }
    #endif
}
