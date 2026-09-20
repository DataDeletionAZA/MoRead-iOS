import Foundation
import MoReadCore

extension CompanionModel {
    #if DEBUG
    var simulatedTools: Bool { ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.arguments.contains("--simulate-tools") }
    #endif
    func runToolChat(provider: AIProvider, key: String, messages: [ChatMessage], conversationID: UUID, responseID: UUID, library: LibraryModel, books: [Book], card: CharacterCard) async throws {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { throw CancellationError() }
        let memory = settings.personaMemory ?? PersonaMemorySettings()
        let enabled = settings.toolsEnabled ?? true
        let specs = enabled ? try ReaderTools.specs(currentBook: conversation.bookID, memory: memory.enabled && !memory.disabledCharacters.contains(card.id), enabled: card.enabledTools) : []
        if specs.isEmpty {
            try await ChatClient.stream(provider: provider, key: key, messages: messages) { delta in await self.append(delta, to: conversationID, messageID: responseID) }
            return
        }
        var accessed = Set<UUID>()
        let availableBooks = books.filter { !$0.removed && $0.hasBody && (conversation.bookID == nil || $0.id == conversation.bookID) }
        try await ChatToolLoop.run(tools: specs, stream: { exchanges in
            if let previous = exchanges.last, !previous.round.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.append("\n\n", to: conversationID, messageID: responseID)
            }
            #if DEBUG
            if self.simulatedTools { return try await self.simulateToolRound(exchanges: exchanges, specs: specs, provider: provider, key: key, messages: messages, conversationID: conversationID, responseID: responseID) }
            #endif
            return try await ChatClient.turn(provider: provider, key: key, messages: messages, tools: specs, exchanges: exchanges) { delta in
                await self.append(delta, to: conversationID, messageID: responseID)
            }
        }, execute: { call in
            guard let root = library.store?.root, let latest = self.conversations.first(where: { $0.id == conversationID }) else { throw CancellationError() }
            if call.name == "recall_memory" {
                let result = try await self.recallPersonaMemory(query: ReaderTools.query(call.object()), conversation: latest, identity: latest.messages.last?.identity ?? self.settings.currentIdentity, library: library)
                return result.isEmpty ? "没有找到可用的长期记忆。" : result
            }
            let args = try call.object()
            if call.name != "find_books" {
                let book = try ReaderTools.book(arguments: args, currentBook: conversation.bookID, books: availableBooks)
                guard accessed.contains(book.id) || accessed.count < 4 else { throw MoReadError.invalid("一轮最多查阅 4 本书，请缩小范围。") }
                try ReaderTools.validate(book, current: library.books); accessed.insert(book.id)
            }
            var output: ReaderToolOutput
            if call.name == "search_book" {
                let book = try ReaderTools.book(arguments: args, currentBook: conversation.bookID, books: availableBooks), query = try ReaderTools.query(args)
                var semantic: [SourcePassage] = []
                var notice = ""
                if (self.settings.vectorBooks ?? []).contains(book.id) {
                    do {
                        let (embedding, embeddingKey, fingerprint) = try self.embeddingConnection()
                        semantic = try await BookMemory.retrieve(query: query, books: [book], root: root, fingerprint: fingerprint, embed: { texts in try await EmbeddingClient.embed(provider: embedding, key: embeddingKey, texts: texts) })
                    } catch is CancellationError { throw CancellationError() }
                    catch { try Task.checkCancellation(); notice = "向量检索暂不可用，以下为本机关键词检索结果。\n" }
                }
                try ReaderTools.validate(book, current: library.books)
                let evidence = semantic
                let work = Task.detached { try CompanionContextBuilder.build(query: query, books: [book], currentBook: nil, store: LibraryStore(root: root), semantic: evidence) }
                var context = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                if let status = try await self.rerankContext(&context, query: query, selection: nil, library: library) { notice += status + "\n" }
                output = ReaderToolOutput(text: notice + (context.passages.isEmpty ? "没有找到相关已读原文。" : "检索到以下已读原文。"), passages: context.passages, books: [book])
            } else {
                let work = Task.detached { try ReaderTools.execute(call, currentBook: conversation.bookID, books: availableBooks, store: LibraryStore(root: root)) }
                output = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            }
            try Task.checkCancellation()
            for book in output.books { try ReaderTools.validate(book, current: library.books) }
            return try self.saveToolSources(output, conversationID: conversationID, responseID: responseID)
        }, validate: {
            guard !library.maintenance, (self.settings.toolsEnabled ?? true) == enabled, (self.settings.personaMemory ?? PersonaMemorySettings()) == memory,
                  self.settings.providers.contains(provider), self.characters.first(where: { $0.id == card.id })?.enabledTools == card.enabledTools,
                  let latest = self.conversations.first(where: { $0.id == conversationID }) else { throw CancellationError() }
            try latest.validateSources(books: books)
            try latest.validateSources(books: library.books)
            for book in availableBooks where accessed.contains(book.id) { try ReaderTools.validate(book, current: library.books) }
        }, report: { event in self.recordTool(event, conversationID: conversationID, responseID: responseID) })
    }
    private func saveToolSources(_ output: ReaderToolOutput, conversationID: UUID, responseID: UUID) throws -> String {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }), let message = conversations[index].messages.firstIndex(where: { $0.id == responseID }) else { throw CancellationError() }
        var conversation = conversations[index], passages = conversation.messages[message].sources
        var text = output.text
        for passage in output.passages {
            let offset: Int
            if let old = passages.firstIndex(where: { $0.id == passage.id }) {
                offset = old
                if passage.text.utf16.count > passages[old].text.utf16.count { passages[old] = passage }
            } else { offset = passages.count; passages.append(passage) }
            text += (text.isEmpty ? "" : "\n\n") + "【来源 \(offset + 1)】第 \(passage.chapter + 1) 章，偏移 \(passage.offset)\n" + passage.text
        }
        guard passages.count <= 128, passages.reduce(0, { $0 + $1.text.utf16.count }) <= 128_000, text.utf8.count <= 128 * 1024 else { throw MoReadError.invalid("本轮原文引用已达到上限，请缩小查询范围。") }
        for book in output.books {
            conversation.sourceLimits[book.id] = max(conversation.sourceLimits[book.id] ?? ReadingPosition(), book.readThrough)
            conversation.sourceRevisions[book.id] = book.chapters.map(\.revision)
        }
        conversation.messages[message].sources = passages
        let scopes = try MemoryBookScope.snapshot(conversation)
        conversation.messages[message].bookScopes = scopes
        if message > 0 { conversation.messages[message - 1].bookScopes = scopes }
        guard let store else { throw MoReadError.invalid("对话存储尚未打开。") }
        try store.save(conversation); conversations[index] = conversation
        return text
    }
    private func recordTool(_ event: ChatToolEvent, conversationID: UUID, responseID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }), let message = conversations[index].messages.firstIndex(where: { $0.id == responseID }) else { return }
        var traces = conversations[index].messages[message].toolTrace ?? []
        switch event {
        case .started(let call):
            traces.append(ChatToolTrace(call: call, title: ReaderTools.titles[call.name] ?? "查询资料"))
            memoryStatus = ReaderTools.titles[call.name] ?? "正在查询资料…"
        case .finished(let result):
            if let trace = traces.lastIndex(where: { $0.call.id == result.call.id && $0.state == "running" }) {
                traces[trace].state = result.failed ? "failed" : "succeeded"; traces[trace].preview = TextBoundary.prefix(result.content, end: 2000)
            }
            memoryStatus = nil
        }
        conversations[index].messages[message].toolTrace = traces; saveConversation(conversationID)
    }
    #if DEBUG
    private func simulateToolRound(exchanges: [ChatToolExchange], specs: [ChatTool], provider: AIProvider, key: String, messages: [ChatMessage], conversationID: UUID, responseID: UUID) async throws -> ChatToolRound {
        _ = try ChatRequest.make(provider: provider, key: key, messages: messages, tools: specs, exchanges: exchanges)
        try await Task.sleep(for: .milliseconds(200))
        let calls: [ChatToolCall]
        switch exchanges.count {
        case 0: calls = [ChatToolCall(id: "read-toc", name: "list_chapters", arguments: "{}")]
        case 1: calls = [ChatToolCall(id: "read-one", name: "read_book_section", arguments: "{\"from_chapter\":1}"), ChatToolCall(id: "read-future", name: "read_book_section", arguments: "{\"from_chapter\":3}")]
        default:
            let results = exchanges.flatMap(\.results)
            let visible = results.first { $0.call.id == "read-one" }?.content ?? ""
            let refused = results.first { $0.call.id == "read-future" }?.failed == true
            let answer = visible.contains("lighthouse first clue.") && refused && !visible.contains("secret identity") ? "已查到第一章，并拦住未读章节。" : "工具查询结果不完整。"
            append(answer, to: conversationID, messageID: responseID)
            return ChatToolRound(text: answer, calls: [], replay: Data("{}".utf8))
        }
        let native: [String: Any] = ["role": "assistant", "content": "", "tool_calls": calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }]
        return ChatToolRound(text: "", calls: calls, replay: try JSONSerialization.data(withJSONObject: native))
    }
    #endif
}
