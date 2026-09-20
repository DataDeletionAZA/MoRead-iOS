import SwiftUI
import MoReadCore

struct SummarySettingsView: View {
    @EnvironmentObject private var companion: CompanionModel
    private var settings: SummarySettings { companion.settings.summarySettings ?? SummarySettings() }
    private func field<T>(_ key: WritableKeyPath<SummarySettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: key] }, set: {
            companion.summaryTask?.cancel()
            var value = settings; value[keyPath: key] = $0; companion.settings.summarySettings = value; companion.saveSettings()
        })
    }
    var body: some View {
        Form {
            Section("前情提要") {
                Toggle("启用前情提要", isOn: field(\.enabled)).accessibilityIdentifier("summary-enabled")
                Picker("整理服务商", selection: field(\.providerID)) {
                    Text("请选择服务商").tag(UUID?.none)
                    ForEach(companion.settings.providers) { Text("\($0.name) · \($0.model)").tag(Optional($0.id)) }
                }.accessibilityIdentifier("summary-provider")
                Text("选择服务商后，较长的对话会自动整理成最多 600 字的提要，供后续回复参考。整理会发送对话内容并按服务商规则计费，原始聊天记录会保留。").font(.caption).foregroundStyle(.secondary)
            }
            NavigationLink("管理 AI 服务商") { AISettingsView() }
        }.navigationTitle("对话记忆")
    }
}

struct ConversationSummaryView: View {
    let conversationID: UUID
    @EnvironmentObject private var companion: CompanionModel
    @EnvironmentObject private var library: LibraryModel
    private var conversation: Conversation? { companion.conversations.first { $0.id == conversationID } }
    private var summary: ConversationSummary? { conversation.flatMap { value in value.summary.flatMap { $0.matches(value.messages) ? $0 : nil } } }
    var body: some View {
        Form {
            Section("本次对话的前情提要") {
                if let summary {
                    Text(summary.text).textSelection(.enabled).accessibilityIdentifier("conversation-summary")
                    Text(summary.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                } else { Text("还没有前情提要。较早的对话积累到一定数量后，会自动整理。").foregroundStyle(.secondary) }
            }
            if let status = companion.summaryStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            if companion.summarizingConversation == conversationID {
                Button("停止整理", role: .cancel) { companion.stopSummary(for: conversationID) }
            } else {
                Button("现在整理") { companion.refreshSummary(conversationID, library: library, explain: true) }
                    .disabled(!(companion.settings.summarySettings ?? SummarySettings()).enabled)
                if summary != nil { Button("清除提要", role: .destructive) { companion.clearSummary(conversationID) } }
            }
            NavigationLink("对话记忆设置") { SummarySettingsView() }
            if let conversation { NavigationLink("角色长期记忆") { PersonaMemoryView(characterID: conversation.characterID, conversationID: conversationID) } }
        }.navigationTitle("前情提要")
    }
}

extension CompanionModel {
    func stopSummary(for id: UUID) { if summarizingConversation == id { summaryTask?.cancel() } }
    func clearSummary(_ id: UUID) {
        stopSummary(for: id)
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        perform {
            guard let store else { throw MoReadError.invalid("对话存储尚未打开。") }
            var copy = conversations[index]; copy.summary = nil
            try store.save(copy); conversations[index] = copy
        }
    }
    func refreshSummary(_ id: UUID, library: LibraryModel, explain: Bool = false) {
        let policy = settings.summarySettings ?? SummarySettings()
        guard summaryTask == nil, !library.maintenance, policy.enabled,
              let conversation = conversations.first(where: { $0.id == id }) else { return }
        guard let provider = settings.providers.first(where: { $0.id == policy.providerID }) else {
            if explain { summaryStatus = "请先在对话记忆设置中选择整理服务商。" }; return
        }
        guard let work = RollingSummary.plan(messages: conversation.messages, summary: conversation.summary) else {
            if explain { summaryStatus = "较早的对话还不足 6 条，暂时不需要整理。" }; return
        }
        do {
            try conversation.validateSources(books: library.books)
            let key: String
            #if DEBUG
            key = simulatedSummary ? "local-test" : try KeychainStore.read(provider.id)
            #else
            key = try KeychainStore.read(provider.id)
            #endif
            _ = try ChatRequest.make(provider: provider, key: key, messages: work.messages)
            summarizingConversation = id; summaryStatus = "正在整理前情提要…"
            summaryTask = Task {
                defer { self.summaryTask = nil; self.summarizingConversation = nil }
                do {
                    let raw = try await self.summaryReply(provider: provider, key: key, messages: work.messages)
                    try Task.checkCancellation()
                    guard !library.maintenance, (self.settings.summarySettings ?? SummarySettings()) == policy,
                          self.settings.providers.contains(provider), let index = self.conversations.firstIndex(where: { $0.id == id }),
                          RollingSummary.fingerprint(self.conversations[index].messages, through: work.throughMessageID) == work.sourceFingerprint else { throw CancellationError() }
                    try self.conversations[index].validateSources(books: library.books)
                    var copy = self.conversations[index]
                    copy.summary = ConversationSummary(text: raw, work: work)
                    guard copy.summary?.text.isEmpty == false else { throw MoReadError.invalid("服务商返回了空提要。") }
                    guard let store = self.store else { throw MoReadError.invalid("对话存储尚未打开。") }
                    try store.save(copy); self.conversations[index] = copy
                    self.summaryStatus = "前情提要已保存。"
                } catch is CancellationError { self.summaryStatus = "整理已停止。" }
                catch { self.summaryStatus = Task.isCancelled ? "整理已停止。" : error.localizedDescription }
            }
        } catch { if explain { summaryStatus = error.localizedDescription } }
    }
    #if DEBUG
    var simulatedSummary: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.arguments.contains("--simulate-summary")
    }
    #endif
    private func summaryReply(provider: AIProvider, key: String, messages: [ChatMessage]) async throws -> String {
        #if DEBUG
        if simulatedSummary {
            try await Task.sleep(for: .milliseconds(400))
            return "用户喜欢雨后的书店，希望我陪着慢慢读。"
        }
        #endif
        return try await ChatClient.complete(provider: provider, key: key, messages: messages)
    }
}
