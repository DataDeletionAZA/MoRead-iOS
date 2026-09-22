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
        let web = settings.webSearch ?? WebSearchSettings()
        let imageConnection = settings.imageConnection
        let imagesEnabled = settings.imageGeneration?.companionEnabled == true && imageConnection != nil
        let specs = enabled ? try ReaderTools.specs(currentBook: conversation.bookID, memory: memory.enabled && !memory.disabledCharacters.contains(card.id), webSearch: web.enabled, imageGeneration: imagesEnabled, enabled: card.enabledTools) : []
        if specs.isEmpty {
            try await ChatClient.stream(provider: provider, key: key, messages: messages) { delta in await self.append(delta, to: conversationID, messageID: responseID) }
            return
        }
        var accessed = Set<UUID>()
        var roundIndex = 0
        var imageRequests = 0
        let availableBooks = books.filter { !$0.removed && $0.hasBody && (conversation.bookID == nil || $0.id == conversation.bookID) }
        try await ChatToolLoop.run(tools: specs, stream: { exchanges in
            roundIndex = exchanges.count
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
            if WebSearchClient.tools.contains(call.name) { return try await self.runWebTool(call, policy: web) }
            if call.name == "recall_memory" {
                let result = try await self.recallPersonaMemory(query: ReaderTools.query(call.object()), conversation: latest, identity: latest.messages.last?.identity ?? self.settings.currentIdentity, library: library)
                return result.isEmpty ? "没有找到可用的长期记忆。" : result
            }
            let args = try call.object()
            if call.name == "propose_library_organization" {
                guard conversation.bookID == nil, let store = library.store else { throw MoReadError.invalid("请在书库伴读中准备整理方案。") }
                let plan = try LibraryOrganizationPlan.preview(arguments: args, books: library.books, shelf: store.organization())
                return try plan.encoded()
            }
            if call.name != "find_books" {
                let book = try ReaderTools.book(arguments: args, currentBook: conversation.bookID, books: availableBooks)
                guard accessed.contains(book.id) || accessed.count < 4 else { throw MoReadError.invalid("一轮最多查阅 4 本书，请缩小范围。") }
                guard conversation.bookID != nil || latest.sourceLimits[book.id] != nil || latest.sourceLimits.count < 32 else { throw MoReadError.invalid("本话题已涉及 32 本书，请新建话题。") }
                try ReaderTools.validate(book, current: library.books); accessed.insert(book.id)
                _ = try self.saveToolSources(.init(text: "", passages: [], books: [book]), conversationID: conversationID, responseID: responseID)
            }
            var output: ReaderToolOutput
            if call.name == "generate_illustration" {
                guard imagesEnabled, let imageConnection, let storage = library.store else { throw MoReadError.invalid("请开启伴读绘图并选择模型。") }
                guard imageRequests < 4 else { throw MoReadError.invalid("已达到本条回复 4 张插图的上限。") }
                let book = try ReaderTools.book(arguments: args, currentBook: conversation.bookID, books: availableBooks)
                guard conversation.bookID == book.id else { throw MoReadError.invalid("请在这本书的伴读中生成插图。") }
                let sources = latest.messages.first { $0.id == responseID }?.sources ?? []
                let request = try IllustrationToolRequest(call: call, book: book, sources: sources, store: storage)
                _ = try self.saveToolSources(.init(text: "", passages: request.source.map { [$0] } ?? [], books: [book]), conversationID: conversationID, responseID: responseID)
                let promptProvider = imageConnection.settings.optimizePrompt != false ? self.settings.resolvedProvider(for: .chat) : nil
                imageRequests += 1
                let result = try await library.generateIllustration(prompt: request.prompt, source: request.source, book: book, connection: imageConnection, promptProvider: promptProvider, anchor: request.anchor, character: card, validate: {
                    guard self.settings.imageConnection == imageConnection, self.settings.imageGeneration?.companionEnabled == true,
                          self.settings.toolsEnabled ?? true, self.settings.providers.contains(provider),
                          self.characters.first(where: { $0.id == card.id })?.enabledTools == card.enabledTools,
                          imageConnection.settings.optimizePrompt == false || self.settings.resolvedProvider(for: .chat) == promptProvider,
                          self.activeConversation == conversationID,
                          self.conversations.first(where: { $0.id == conversationID })?.messages.contains(where: { $0.id == responseID && $0.status == "receiving" }) == true else { throw CancellationError() }
                }, progress: { self.memoryStatus = $0 })
                return String(decoding: try JSONEncoder().encode(IllustrationReference(result.item)), as: UTF8.self)
            } else if ReaderTools.writing.contains(call.name) {
                let book = try ReaderTools.book(arguments: args, currentBook: conversation.bookID, books: availableBooks)
                guard conversation.bookID == book.id else { throw MoReadError.invalid("请在这本书的伴读中保存内容。") }
                let mutationKey = "tool:\(responseID):\(roundIndex):\(call.id)"
                var annotation: Annotation?
                if call.name == "add_annotation" {
                    let sources = latest.messages.first { $0.id == responseID }?.sources ?? []
                    let work = Task.detached { try ReaderTools.writingAnnotation(call, book: book, sources: sources, character: card, store: LibraryStore(root: root), mutationKey: mutationKey) }
                    annotation = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                }
                try Task.checkCancellation(); try ReaderTools.validate(book, current: library.books)
                guard !library.maintenance, self.settings.toolsEnabled ?? true, self.settings.providers.contains(provider),
                      let currentCard = self.characters.first(where: { $0.id == card.id }), currentCard.enabledTools == card.enabledTools else { throw CancellationError() }
                _ = try self.saveToolSources(.init(text: "", passages: annotation.map { [$0.passage] } ?? [], books: [book]), conversationID: conversationID, responseID: responseID)
                var result = ""
                try library.modifyRecords(for: book) { records in
                    if let annotation {
                        if !records.annotations.contains(where: { $0.generationKey == mutationKey }) { records.annotations.append(annotation) }
                        result = "已在第 \(annotation.passage.chapter + 1) 章保存\(card.name)的批注，可在阅读页的批注列表查看。"
                    } else {
                        let note = try ReaderTools.writingNote(call, book: book, records: records, character: card, conversationID: conversationID, mutationKey: mutationKey)
                        var notes = records.notes ?? []
                        if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index] = note } else { notes.append(note) }
                        records.notes = notes
                        result = "已保存\(note.kind == "plot_summary" ? "剧情梗概" : "读书笔记")《\(note.title)》，note_id=\(note.id)。可在阅读页的“读书笔记与梗概”查看。"
                    }
                }
                return result
            } else if call.name == "search_book" {
                let book = try ReaderTools.book(arguments: args, currentBook: conversation.bookID, books: availableBooks), query = try ReaderTools.query(args)
                let options = try ReaderTools.searchOptions(args, book: book)
                var semantic: [RetrievalCandidate] = []
                var notice = ""
                if (self.settings.vectorBooks ?? []).contains(book.id) {
                    do {
                        let (embedding, embeddingKey, fingerprint) = try self.embeddingConnection()
                        semantic = try await BookMemory.recall(query: query, books: [book], root: root, fingerprint: fingerprint, buildMissingIndex: conversation.bookID != nil, firstChapter: options.first, lastChapter: options.last, embed: { texts in try await EmbeddingClient.embed(provider: embedding, key: embeddingKey, texts: texts) })
                    } catch is CancellationError { throw CancellationError() }
                    catch { try Task.checkCancellation(); notice = "向量检索暂不可用，以下为本机关键词检索结果。\n" }
                }
                try ReaderTools.validate(book, current: library.books)
                let evidence = semantic
                let work = Task.detached { try CompanionContextBuilder.build(query: query, books: [book], currentBook: nil, store: LibraryStore(root: root), vector: evidence, firstChapter: options.first, lastChapter: options.last, topK: options.topK, chapterOrder: options.chapterOrder) }
                var context = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                if let status = try await self.rerankContext(&context, query: query, selection: nil, library: library) { notice += status + "\n" }
                if let coverage = context.retrievalNotice { notice += coverage + "\n" }
                output = ReaderToolOutput(text: notice + (context.passages.isEmpty ? "未检索到候选，但这不证明相关事件不存在。" : "以下为相关已读原文候选，需核验内容；不是全部匹配，也不代表问题前提成立。"), passages: context.passages, books: [book])
            } else {
                let work = Task.detached { try ReaderTools.execute(call, currentBook: conversation.bookID, books: availableBooks, store: LibraryStore(root: root)) }
                output = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            }
            try Task.checkCancellation()
            for book in output.books { try ReaderTools.validate(book, current: library.books) }
            return try self.saveToolSources(output, conversationID: conversationID, responseID: responseID)
        }, validate: {
            guard !library.maintenance, (self.settings.webSearch ?? WebSearchSettings()) == web, (self.settings.toolsEnabled ?? true) == enabled, (self.settings.personaMemory ?? PersonaMemorySettings()) == memory,
                  self.settings.providers.contains(provider), self.characters.first(where: { $0.id == card.id })?.enabledTools == card.enabledTools,
                  let latest = self.conversations.first(where: { $0.id == conversationID }) else { throw CancellationError() }
            try latest.validateSources(books: books)
            try latest.validateSources(books: library.books)
            for book in availableBooks where accessed.contains(book.id) { try ReaderTools.validate(book, current: library.books) }
        }, report: { event in try self.recordTool(event, conversationID: conversationID, responseID: responseID) })
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
            text += (text.isEmpty ? "" : "\n\n") + "【来源 \(offset + 1)】第 \(passage.chapter + 1) 章，偏移 \(passage.offset)，source_ref=\(passage.id)\n" + passage.text
        }
        guard passages.count <= 128, passages.reduce(0, { $0 + $1.text.utf16.count }) <= 128_000, text.utf8.count <= 128 * 1024 else { throw MoReadError.invalid("本轮原文引用已达到上限，请缩小查询范围。") }
        for book in output.books {
            conversation.sourceLimits[book.id] = max(conversation.sourceLimits[book.id] ?? ReadingPosition(), book.readThrough)
            conversation.sourceRevisions[book.id] = book.chapters.map(\.revision)
        }
        conversation.messages[message].sources = passages
        try conversation.associateTurnBooks(output.books.map(\.id))
        try conversation.validateLibraryLimit()
        try conversation.updateTurnScopes()
        guard let store else { throw MoReadError.invalid("对话存储尚未打开。") }
        try store.save(conversation); conversations[index] = conversation
        return text
    }
    private func recordTool(_ event: ChatToolEvent, conversationID: UUID, responseID: UUID) throws {
        guard let store, let index = conversations.firstIndex(where: { $0.id == conversationID }), let message = conversations[index].messages.firstIndex(where: { $0.id == responseID }) else { throw CancellationError() }
        var conversation = conversations[index], traces = conversation.messages[message].toolTrace ?? []
        switch event {
        case .started(let call):
            traces.append(ChatToolTrace(call: call, title: ReaderTools.titles[call.name] ?? "查询资料"))
            memoryStatus = ReaderTools.titles[call.name] ?? "正在查询资料…"
        case .finished(let result):
            if let trace = traces.lastIndex(where: { $0.call.id == result.call.id && $0.state == "running" }) {
                traces[trace].state = result.failed ? "failed" : "succeeded"
                let preview = result.content.replacingOccurrences(of: "，source_ref=[^\\n]+", with: "", options: .regularExpression)
                traces[trace].preview = TextBoundary.prefix(preview, end: 2000)
                if WebSearchClient.tools.contains(result.call.name), !result.failed {
                    let web = try WebSearchResult.decode(result.content)
                    traces[trace].webSources = web.pages.map(\.source)
                    traces[trace].preview = TextBoundary.prefix(web.preview, end: 2000)
                }
                if result.call.name == "propose_library_organization", !result.failed {
                    let plan = try LibraryOrganizationPlan.decode(result.content)
                    traces[trace].organizationPlan = plan
                    traces[trace].preview = "已准备 \(plan.changes.count) 本书的整理预览，等待你确认。"
                }
                if result.call.name == "generate_illustration", !result.failed {
                    traces[trace].illustration = try JSONDecoder().decode(IllustrationReference.self, from: Data(result.content.utf8))
                    traces[trace].preview = "插图已保存，可在聊天中查看，也可进入这本书的插图廊。"
                }
            }
            memoryStatus = nil
        }
        conversation.messages[message].toolTrace = traces
        try store.save(conversation); conversations[index] = conversation
    }
    #if DEBUG
    private func simulateToolRound(exchanges: [ChatToolExchange], specs: [ChatTool], provider: AIProvider, key: String, messages: [ChatMessage], conversationID: UUID, responseID: UUID) async throws -> ChatToolRound {
        _ = try ChatRequest.make(provider: provider, key: key, messages: messages, tools: specs, exchanges: exchanges)
        try await Task.sleep(for: .milliseconds(200))
        let calls: [ChatToolCall]
        if ProcessInfo.processInfo.arguments.contains("--simulate-tool-images") {
            if !specs.contains(where: { $0.name == "generate_illustration" }) {
                let answer = "伴读绘图已关闭。"; append(answer, to: conversationID, messageID: responseID)
                return ChatToolRound(text: answer, calls: [], replay: Data("{}".utf8))
            }
            if exchanges.isEmpty {
                let text = messages.last { $0.role == "user" }?.content ?? ""
                let args: [String: Any] = ["prompt": text.contains("slow") ? "slow lighthouse" : text.contains("fail") ? "fail lighthouse" : "A lighthouse", "chapter_number": text.contains("future") ? 3 : 1, "source_text": text.contains("future") ? "lighthouse secret identity." : "lighthouse first clue."]
                let encoded = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
                return try mockToolCalls((0..<(text.contains("many") ? 5 : 1)).map { .init(id: "illustration-\($0)", name: "generate_illustration", arguments: encoded) })
            }
            let result = exchanges.last?.results.last
            let saved = exchanges.flatMap(\.results).filter { !$0.failed }.count
            let answer = saved == 4 ? "本轮已保存 4 张插图。" : result?.failed == true ? "插图未生成：" + (result?.content ?? "") : "插图已生成并保存。"
            append(answer, to: conversationID, messageID: responseID)
            return ChatToolRound(text: answer, calls: [], replay: Data("{}".utf8))
        }
        if ProcessInfo.processInfo.arguments.contains("--simulate-presets") {
            if exchanges.isEmpty { return try mockToolCalls([.init(id: "preset-catalog", name: "list_chapters", arguments: "{}")]) }
            func names(_ role: String) -> String {
                let content = role == "system" ? messages.first { $0.role == role }?.content : messages.last { $0.role == role }?.content
                let values = (content ?? "").components(separatedBy: "\n").filter { $0.hasPrefix("【全局预设·") }.map { String($0.dropFirst("【全局预设·".count).dropLast()) }
                return values.isEmpty ? "无" : values.joined(separator: "、")
            }
            let answer = "本地请求核对：系统=\(names("system"))；用户=\(names("user"))；工具续接=\(exchanges.count)"
            append(answer, to: conversationID, messageID: responseID)
            return ChatToolRound(text: answer, calls: [], replay: Data("{}".utf8))
        }
        if ProcessInfo.processInfo.arguments.contains("--simulate-web") {
            if !specs.contains(where: { $0.name == "web_search" }) {
                let answer = messages.last?.content.contains("again") == true ? "联网已关闭，这次也未请求网页。" : "联网已关闭，本轮未请求网页。"; append(answer, to: conversationID, messageID: responseID)
                return ChatToolRound(text: answer, calls: [], replay: Data("{}".utf8))
            }
            if exchanges.isEmpty {
                let query = messages.last?.content.contains("unavailable") == true ? "unavailable" : "lighthouse history"
                return try mockToolCalls([.init(id: "web-search", name: "web_search", arguments: "{\"query\":\"\(query)\",\"limit\":3}")])
            }
            if exchanges.count == 1, exchanges[0].results[0].failed == false {
                return try mockToolCalls([.init(id: "web-page", name: "web_scrape", arguments: "{\"url\":\"https://example.invalid/lighthouse\"}")])
            }
            let answer = exchanges.last?.results.first?.failed == true ? "搜索暂不可用，未编造网页内容。" : "已核对网页资料，并保留来源链接。"
            append(answer, to: conversationID, messageID: responseID)
            return ChatToolRound(text: answer, calls: [], replay: Data("{}".utf8))
        }
        if ProcessInfo.processInfo.arguments.contains("--simulate-scope") {
            let conversation = conversations.first { $0.id == conversationID }
            if messages.last?.content.contains("Just chat") == true {
                let empty = conversation?.messages.last?.sources.isEmpty == true && messages.first?.content.contains("visible.") == false
                let answer = empty ? "本轮未发送书籍原文。" : "本轮包含额外原文。"
                append(answer, to: conversationID, messageID: responseID)
                return ChatToolRound(text: answer, calls: [], replay: Data("{}".utf8))
            }
            if exchanges.isEmpty { return try mockToolCalls([ChatToolCall(id: "catalog", name: "find_books", arguments: "{}")]) }
            let catalog = exchanges[0].results[0].content
            func bookID(_ title: String) -> String { catalog.components(separatedBy: "\n").first { $0.contains("《" + title + "》") }.map { String($0.dropFirst("book_id=".count).prefix(36)) } ?? "" }
            if exchanges.count == 1 {
                let calls = try ["森林", "海岸"].map { title -> ChatToolCall in
                    let args = try JSONSerialization.data(withJSONObject: ["book_id": bookID(title), "from_chapter": 1])
                    return ChatToolCall(id: title, name: "read_book_section", arguments: String(decoding: args, as: UTF8.self))
                }
                return try mockToolCalls(calls)
            }
            let results = exchanges.last!.results.map(\.content).joined()
            let focused = conversation?.messages.last(where: { $0.role == "user" })?.focusedBookIDs ?? []
            let forest = UUID(uuidString: bookID("森林")).map { focused.contains($0) } == true
            let valid = results.contains("Forest visible.") && results.contains("Harbor.") && !results.contains("Hidden future")
            let answer = valid ? "重点：\(forest ? "森林" : "海岸")；已核对两本书的已读原文。" : "多书范围检查失败。"
            append(answer, to: conversationID, messageID: responseID)
            return ChatToolRound(text: answer, calls: [], replay: Data("{}".utf8))
        }
        if ProcessInfo.processInfo.arguments.contains("--simulate-organization") {
            if exchanges.isEmpty { return try mockToolCalls([ChatToolCall(id: "catalog", name: "find_books", arguments: "{}")]) }
            if exchanges.count == 1 {
                let catalog = exchanges[0].results[0].content
                let ids = catalog.components(separatedBy: "book_id=").dropFirst().map { String($0.prefix(36)) }
                let tag = messages.last?.content.contains("Cancel") == true ? "待考虑" : "海岸故事"
                let rows: [[String: Any]] = ids.map { ["book_id": $0, "add_tags": [tag], "group_name": "旅途书单"] }
                let args = try JSONSerialization.data(withJSONObject: ["changes": rows])
                return try mockToolCalls([ChatToolCall(id: "organize", name: "propose_library_organization", arguments: String(decoding: args, as: UTF8.self))])
            }
            let valid = exchanges.last?.results.first?.failed == false
            let answer = valid ? "整理预览已准备好，等待你确认。" : "无法准备整理预览。"
            append(answer, to: conversationID, messageID: responseID)
            return ChatToolRound(text: answer, calls: [], replay: Data("{}".utf8))
        }
        let writing = ProcessInfo.processInfo.arguments.contains("--simulate-writing")
        if writing, messages.last?.content.contains("Update my edited note.") == true {
            switch exchanges.count {
            case 0: calls = [ChatToolCall(id: "notes", name: "list_notes", arguments: "{\"kind\":\"note\"}")]
            case 1:
                let index = exchanges[0].results[0].content
                let id = index.components(separatedBy: "note_id=").dropFirst().first.map { String($0.prefix(36)) } ?? ""
                let args = try JSONSerialization.data(withJSONObject: ["note_id": id, "title": "Overwritten", "content_md": "Overwritten by AI"])
                calls = [ChatToolCall(id: "protected", name: "write_note", arguments: String(decoding: args, as: UTF8.self))]
            default:
                let answer = exchanges.last?.results.first?.failed == true ? "已保留你编辑的笔记。" : "笔记保护失败。"
                append(answer, to: conversationID, messageID: responseID)
                return ChatToolRound(text: answer, calls: [], replay: Data("{}".utf8))
            }
            return try mockToolCalls(calls)
        }
        switch exchanges.count {
        case 0: calls = [ChatToolCall(id: "read-toc", name: "list_chapters", arguments: "{}")]
        case 1: calls = [ChatToolCall(id: "read-one", name: "read_book_section", arguments: "{\"from_chapter\":1}"), ChatToolCall(id: "read-future", name: "read_book_section", arguments: "{\"from_chapter\":3}")]
        case 2 where writing:
            calls = [ChatToolCall(id: "annotation", name: "add_annotation", arguments: "{\"quote\":\"lighthouse first clue.\",\"comment\":\"Watch the lighthouse.\",\"style\":\"underline\"}"),
                     ChatToolCall(id: "note", name: "write_note", arguments: "{\"title\":\"Lighthouse notes\",\"content_md\":\"The lighthouse is bright.\"}"),
                     ChatToolCall(id: "summary", name: "save_plot_summary", arguments: "{\"title\":\"Plot recap\",\"content_md\":\"Arrived at the lighthouse.\"}")]
        case 3 where writing:
            calls = [ChatToolCall(id: "summary", name: "save_plot_summary", arguments: "{\"title\":\"Plot recap\",\"content_md\":\"Reached the lighthouse and saw its light.\"}")]
        default:
            let results = exchanges.flatMap(\.results)
            let visible = results.first { $0.call.id == "read-one" }?.content ?? ""
            let refused = results.first { $0.call.id == "read-future" }?.failed == true
            let valid = visible.contains("lighthouse first clue.") && refused && !visible.contains("secret identity")
            let wrote = results.filter { ReaderTools.writing.contains($0.call.name) }
            let answer = writing ? (valid && wrote.count == 4 && wrote.allSatisfy { !$0.failed } ? "批注、笔记与梗概已保存。" : "保存结果不完整。") : (valid ? "已查到第一章，并拦住未读章节。" : "工具查询结果不完整。")
            append(answer, to: conversationID, messageID: responseID)
            return ChatToolRound(text: answer, calls: [], replay: Data("{}".utf8))
        }
        return try mockToolCalls(calls)
    }
    private func mockToolCalls(_ calls: [ChatToolCall]) throws -> ChatToolRound {
        let native: [String: Any] = ["role": "assistant", "content": "", "tool_calls": calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }]
        return ChatToolRound(text: "", calls: calls, replay: try JSONSerialization.data(withJSONObject: native))
    }
    #endif
}
