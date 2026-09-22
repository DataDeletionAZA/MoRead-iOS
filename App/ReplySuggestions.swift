import SwiftUI
import MoReadCore

struct SuggestedReplies {
    let conversationID: UUID
    let history: [ChatMessage]
    let identity: ChatIdentity
    let provider: AIProvider
    let characterName: String
    let focusedBookIDs: [UUID]?
    var texts: [String] = []
}

extension CompanionModel {
    func showSuggestionChat(_ id: UUID?) {
        guard suggestionChatID != id else { return }
        dismissSuggestions(); suggestionChatID = id
    }
    func dismissSuggestions() {
        suggestionTask?.cancel(); suggestionTask = nil; suggestionRequestID = nil; suggestedReplies = nil
    }
    func suggestions(in id: UUID, library: LibraryModel) -> [String] {
        guard let result = suggestedReplies, result.conversationID == id, suggestionMatches(result, library: library) else { return [] }
        return result.texts
    }
    private func suggestionMatches(_ result: SuggestedReplies, library: LibraryModel) -> Bool {
        guard !library.maintenance, activeConversation == nil, suggestionChatID == result.conversationID,
              settings.suggestionRepliesEnabled != false, settings.currentIdentity == result.identity,
              settings.resolvedProvider(for: .suggestion) == result.provider,
              let current = conversations.first(where: { $0.id == result.conversationID }),
              current.focusedBookIDs == result.focusedBookIDs,
              ReplySuggestions.history(current.messages) == result.history,
              characters.first(where: { $0.id == current.characterID })?.name == result.characterName else { return false }
        do { try current.validateSources(books: library.books); return true } catch { return false }
    }
    func refreshSuggestions(_ id: UUID, library: LibraryModel) {
        dismissSuggestions()
        guard suggestionChatID == id, !library.maintenance, settings.suggestionRepliesEnabled != false,
              let conversation = conversations.first(where: { $0.id == id }),
              let card = characters.first(where: { $0.id == conversation.characterID }),
              let provider = settings.resolvedProvider(for: .suggestion) else { return }
        do {
            let identity = settings.currentIdentity
            guard let messages = try ReplySuggestions.messages(conversation: conversation, books: library.books, personaName: card.name, identity: identity) else { return }
            let key: String
            #if DEBUG
            key = simulatedSuggestions ? "local-test" : try KeychainStore.read(provider.id)
            #else
            key = try KeychainStore.read(provider.id)
            #endif
            _ = try ChatRequest.make(provider: provider, key: key, messages: messages)
            let token = UUID(); suggestionRequestID = token
            let source = SuggestedReplies(conversationID: id, history: ReplySuggestions.history(conversation.messages), identity: identity, provider: provider, characterName: card.name, focusedBookIDs: conversation.focusedBookIDs)
            suggestionTask = Task {
                defer { if self.suggestionRequestID == token { self.suggestionTask = nil; self.suggestionRequestID = nil } }
                do {
                    guard self.suggestionMatches(source, library: library) else { return }
                    let raw = try await self.suggestionReply(provider: provider, key: key, messages: messages)
                    try Task.checkCancellation()
                    guard self.suggestionRequestID == token, self.suggestionMatches(source, library: library) else { return }
                    var result = source; result.texts = ReplySuggestions.parse(raw)
                    self.suggestedReplies = result.texts.isEmpty ? nil : result
                } catch { }
            }
        } catch { }
    }
    private func suggestionReply(provider: AIProvider, key: String, messages: [ChatMessage]) async throws -> String {
        #if DEBUG
        if simulatedSuggestions {
            let text = messages.last?.content ?? ""
            try await Task.sleep(for: .milliseconds(text.contains("slow") ? 5000 : 400))
            if text.contains("fail") { throw MoReadError.invalid("本地建议服务暂不可用。") }
            return "```json\n[\"想听你接着说\",\"聊聊 \(provider.model)\",\"换个轻松的话题\",\"想听你接着说\"]\n```"
        }
        #endif
        return try await ChatClient.complete(provider: provider, key: key, messages: messages, maximumBytes: 16_384)
    }
    #if DEBUG
    var simulatedSuggestions: Bool { ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.arguments.contains("--simulate-suggestions") }
    #endif
}

struct ReplySuggestionSettingsView: View {
    @EnvironmentObject private var companion: CompanionModel
    var body: some View {
        Form {
            Section {
                Toggle("AI 建议回复", isOn: Binding(get: { companion.settings.suggestionRepliesEnabled != false }, set: { enabled in
                    companion.perform { var settings = companion.settings; settings.suggestionRepliesEnabled = enabled; try companion.saveModelSettings(settings) }
                })).accessibilityIdentifier("suggestions-enabled")
            } footer: { Text("角色回复后，用最近几轮对话拟最多三条短回复，点选即可发送。开启时会额外调用所选模型，按服务商规则计费；关闭后停止生成建议。") }
            Section("模型") { ModelAssignmentPicker(task: .suggestion) }
        }.navigationTitle("建议回复")
    }
}
