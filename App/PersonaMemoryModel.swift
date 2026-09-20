import Foundation
import MoReadCore

extension CompanionModel {
    func consolidateMemory(_ id: UUID, library: LibraryModel, onClose: Bool = false, explain: Bool = false) {
        let policy = settings.personaMemory ?? PersonaMemorySettings()
        guard personaMemoryTask == nil, !library.maintenance, policy.enabled, let conversation = conversations.first(where: { $0.id == id }),
              !policy.disabledCharacters.contains(conversation.characterID), let root = library.store?.root else { return }
        do {
            let memory = try PersonaMemoryStore(root: root)
            guard try MemoryBatch.plan(conversation, checkpoint: memory.checkpoint(id), onClose: onClose) != nil else {
                if explain { personaMemoryStatus = "这段对话尚无足够的新内容可整理。" }; return
            }
            guard let provider = settings.providers.first(where: { $0.id == policy.providerID }) else { throw MoReadError.invalid("请在长期记忆设置中选择整理服务商。") }
            let key = try memoryChatKey(provider)
            let (embedding, embeddingKey, fingerprint) = try memoryEmbeddingConnection()
            _ = try ChatRequest.make(provider: provider, key: key, messages: [.init(role: "user", content: "记忆配置检查")])
            consolidatingConversation = id; personaMemoryStatus = "正在整理角色记忆…"
            personaMemoryTask = Task {
                defer { self.personaMemoryTask = nil; self.consolidatingConversation = nil }
                do {
                    var changed = 0
                    while let current = self.conversations.first(where: { $0.id == id }), let batch = try MemoryBatch.plan(current, checkpoint: memory.checkpoint(id), onClose: onClose) {
                        try Task.checkCancellation(); try current.validateSources(books: library.books)
                        guard self.memoryConfigurationMatches(policy, provider: provider, embedding: embedding, library: library) else { throw CancellationError() }
                        let revision = try memory.revision
                        let storedProfile = try memory.profile(batch.characterID)
                        let profile = batch.identity?.maskID == nil && (batch.bookID == nil || policy.crossBook) && storedProfile.isValid(books: library.books, conversations: self.conversations) ? storedProfile : MemoryProfile()
                        let candidates = try MemoryDraft.candidates(await self.memoryReply(provider: provider, key: key, messages: batch.extractionMessages, resolve: false))
                        var vectors: [String: [Float]] = [:], neighbours: [PersonaMemory] = []
                        if !candidates.isEmpty {
                            let values = try await self.memoryEmbed(provider: embedding, key: embeddingKey, texts: candidates)
                            guard values.count == candidates.count else { throw MoReadError.invalid("记忆向量数量不一致。") }
                            for (index, text) in candidates.enumerated() {
                                vectors[text] = values[index]
                                for entry in try memory.search(characterID: batch.characterID, bookID: batch.bookID, maskID: batch.identity?.maskID, crossBook: false, exactScope: true, fingerprint: fingerprint, vector: values[index], books: library.books, conversations: self.conversations, limit: 3) where !neighbours.contains(where: { $0.id == entry.id }) { neighbours.append(entry) }
                            }
                        }
                        try Task.checkCancellation()
                        guard self.memoryConfigurationMatches(policy, provider: provider, embedding: embedding, library: library), batch.origin.isValid(books: library.books, conversations: self.conversations) else { throw CancellationError() }
                        let raw = candidates.isEmpty ? "{\"operations\":[]}" : try await self.memoryReply(provider: provider, key: key, messages: batch.resolutionMessages(candidates: candidates, neighbours: neighbours, profile: profile), resolve: true)
                        let draft = try MemoryDraft.parse(raw)
                        let missing = Array(Set(draft.operations.filter { $0.action == .add || $0.action == .update }.map(\.text))).filter { vectors[$0] == nil }
                        if !missing.isEmpty {
                            let values = try await self.memoryEmbed(provider: embedding, key: embeddingKey, texts: missing)
                            guard values.count == missing.count else { throw MoReadError.invalid("改写后的记忆向量不完整。") }
                            for (index, text) in missing.enumerated() { vectors[text] = values[index] }
                        }
                        try Task.checkCancellation()
                        guard self.memoryConfigurationMatches(policy, provider: provider, embedding: embedding, library: library),
                              let latest = self.conversations.first(where: { $0.id == id }), batch.origin.matches(latest),
                              batch.origin.isValid(books: library.books, conversations: self.conversations) else { throw CancellationError() }
                        guard profile.isValid(books: library.books, conversations: self.conversations), neighbours.allSatisfy({ $0.origins.allSatisfy { $0.isValid(books: library.books, conversations: self.conversations) } }) else { throw CancellationError() }
                        try latest.validateSources(books: library.books)
                        changed += try memory.apply(batch: batch, draft: draft, vectors: vectors, fingerprint: fingerprint, expectedRevision: revision,
                                                    allowedIDs: Set(neighbours.map(\.id)), allowProfile: batch.bookID == nil || policy.crossBook,
                                                    profile: MemoryProfile(text: profile.text, origins: Array(Set(profile.origins + neighbours.flatMap(\.origins)))))
                        self.personaMemoryRevision = UUID()
                    }
                    self.personaMemoryStatus = "已整理角色记忆，更新 \(changed) 条。"
                } catch is CancellationError { self.personaMemoryStatus = "记忆整理已停止。" }
                catch { self.personaMemoryStatus = Task.isCancelled ? "记忆整理已停止。" : error.localizedDescription }
            }
        } catch { if explain { personaMemoryStatus = error.localizedDescription } }
    }
    private func memoryConfigurationMatches(_ policy: PersonaMemorySettings, provider: AIProvider, embedding: AIProvider, library: LibraryModel) -> Bool {
        guard !library.maintenance, (settings.personaMemory ?? PersonaMemorySettings()) == policy, settings.providers.contains(provider),
              var current = settings.providers.first(where: { $0.id == settings.embeddingProvider }) else { return false }
        current.model = (settings.embeddingModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return current == embedding
    }
    func recallPersonaMemory(query: String, conversation: Conversation, identity: ChatIdentity, library: LibraryModel) async throws -> String {
        let policy = settings.personaMemory ?? PersonaMemorySettings()
        guard policy.enabled, !policy.disabledCharacters.contains(conversation.characterID), let root = library.store?.root,
              FileManager.default.fileExists(atPath: PersonaMemoryStore.url(in: root).path) else { return "" }
        do {
            let memory = try PersonaMemoryStore(root: root), revision = try memory.revision
            var entries: [PersonaMemory] = []
            if try !memory.list(conversation.characterID).isEmpty {
                let (provider, key, fingerprint) = try memoryEmbeddingConnection()
                let vector = try await memoryEmbed(provider: provider, key: key, texts: [TextBoundary.prefix(query, end: 2000)])
                try Task.checkCancellation()
                guard let first = vector.first, try memory.revision == revision, (settings.personaMemory ?? PersonaMemorySettings()) == policy else { return "" }
                entries = try memory.search(characterID: conversation.characterID, bookID: conversation.bookID, maskID: identity.maskID, crossBook: policy.crossBook, fingerprint: fingerprint, vector: first, books: library.books, conversations: conversations)
            }
            var profile = try memory.profile(conversation.characterID)
            if !(conversation.bookID == nil || policy.crossBook) || !profile.isValid(books: library.books, conversations: conversations) { profile = MemoryProfile() }
            let origins = entries.flatMap(\.origins) + profile.origins
            if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
                for scope in origins.flatMap(\.books) {
                    guard let book = library.books.first(where: { $0.id == scope.id }), scope.isValid(in: library.books) else { return "" }
                    conversations[index].sourceLimits[scope.id] = max(conversations[index].sourceLimits[scope.id] ?? ReadingPosition(), scope.through)
                    conversations[index].sourceRevisions[scope.id] = book.chapters.map(\.revision)
                }
            }
            let lines = entries.map { "- [\($0.identity?.label ?? "本人")] \($0.text)" }.joined(separator: "\n")
            return (profile.text.isEmpty ? "" : "\n\n【对用户本人的了解】\n" + profile.text) + (lines.isEmpty ? "" : "\n\n【相关长期记忆】来自过去对话，仅作交流背景，不替代原文证据；保持本人和扮演身份的区别：\n" + lines)
        } catch is CancellationError { throw CancellationError() }
        catch { personaMemoryStatus = error.localizedDescription; return "" }
    }
    func forgetMemory(_ id: UUID?, characterID: UUID, library: LibraryModel) {
        guard !library.maintenance, let root = library.store?.root else { return }
        stop(); personaMemoryTask?.cancel()
        perform {
            let memory = try PersonaMemoryStore(root: root)
            if let id { try memory.forget(id) } else { try memory.clear(characterID) }
            personaMemoryRevision = UUID(); personaMemoryStatus = "记忆已清除，原始聊天记录保留。"
        }
    }
    func saveMemoryProfile(_ text: String, characterID: UUID, library: LibraryModel, onSaved: () -> Void) {
        guard !library.maintenance, let root = library.store?.root else { return }
        stop(); personaMemoryTask?.cancel()
        perform { try PersonaMemoryStore(root: root).setProfile(characterID, text: text); personaMemoryRevision = UUID(); onSaved() }
    }
    func editMemory(_ entry: PersonaMemory, text: String, library: LibraryModel, onSaved: @escaping () -> Void) {
        guard personaMemoryTask == nil, !library.maintenance, let root = library.store?.root else { return }
        do {
            let memory = try PersonaMemoryStore(root: root), revision = try memory.revision
            let (provider, key, fingerprint) = try memoryEmbeddingConnection()
            let value = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
            guard !value.isEmpty else { throw MoReadError.invalid("请填写记忆内容。") }
            personaMemoryTask = Task {
                defer { self.personaMemoryTask = nil }
                do {
                    let vectors = try await self.memoryEmbed(provider: provider, key: key, texts: [value]); try Task.checkCancellation()
                    guard !library.maintenance, let vector = vectors.first else { throw CancellationError() }
                    try memory.edit(entry.id, text: value, vector: vector, fingerprint: fingerprint, expectedRevision: revision)
                    self.personaMemoryRevision = UUID(); self.personaMemoryStatus = "记忆已修改。"; onSaved()
                } catch { self.personaMemoryStatus = Task.isCancelled ? "修改已停止。" : error.localizedDescription }
            }
        } catch { personaMemoryStatus = error.localizedDescription }
    }
    func reindexMemories(characterID: UUID, library: LibraryModel) {
        guard personaMemoryTask == nil, !library.maintenance, let root = library.store?.root else { return }
        do {
            let memory = try PersonaMemoryStore(root: root), entries = try memory.list(characterID)
            let (provider, key, fingerprint) = try memoryEmbeddingConnection()
            personaMemoryTask = Task {
                defer { self.personaMemoryTask = nil }
                do {
                    for start in stride(from: 0, to: entries.count, by: 8) {
                        let batch = Array(entries[start..<min(start + 8, entries.count)]), revision = try memory.revision
                        let vectors = try await self.memoryEmbed(provider: provider, key: key, texts: batch.map(\.text)); try Task.checkCancellation()
                        guard !library.maintenance else { throw CancellationError() }
                        try memory.reindex(batch, vectors: vectors, fingerprint: fingerprint, expectedRevision: revision)
                        self.personaMemoryStatus = "已更新 \(min(start + 8, entries.count)) / \(entries.count) 条记忆向量。"
                    }
                    self.personaMemoryRevision = UUID()
                } catch { self.personaMemoryStatus = Task.isCancelled ? "向量整理已停止。" : error.localizedDescription }
            }
        } catch { personaMemoryStatus = error.localizedDescription }
    }
    #if DEBUG
    var simulatedMemory: Bool { ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.arguments.contains("--simulate-memory") }
    #endif
    private func memoryChatKey(_ provider: AIProvider) throws -> String {
        #if DEBUG
        if simulatedMemory { return "local-test" }
        #endif
        return try KeychainStore.read(provider.id)
    }
    private func memoryEmbeddingConnection() throws -> (AIProvider, String, String) {
        #if DEBUG
        if simulatedMemory, var provider = settings.providers.first(where: { $0.id == settings.embeddingProvider }) {
            provider.model = settings.embeddingModel ?? "fixture-vector"; return (provider, "local-test", try EmbeddingClient.fingerprint(provider))
        }
        #endif
        return try embeddingConnection()
    }
    private func memoryReply(provider: AIProvider, key: String, messages: [ChatMessage], resolve: Bool) async throws -> String {
        #if DEBUG
        if simulatedMemory {
            try await Task.sleep(for: .milliseconds(250))
            return resolve ? "{\"operations\":[{\"action\":\"ADD\",\"summary\":\"用户喜欢安静的书店。\"}],\"user_profile\":\"用户喜欢安静的阅读环境。\"}" : "[\"用户喜欢安静的书店。\"]"
        }
        #endif
        return try await ChatClient.complete(provider: provider, key: key, messages: messages)
    }
    private func memoryEmbed(provider: AIProvider, key: String, texts: [String]) async throws -> [[Float]] {
        #if DEBUG
        if simulatedMemory { try await Task.sleep(for: .milliseconds(100)); return texts.map { _ in [1, 0, 0] } }
        #endif
        return try await EmbeddingClient.embed(provider: provider, key: key, texts: texts)
    }
}
