import Foundation

extension Conversation {
    public func validateUserText(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, bookID != nil || text.utf16.count <= 8000 else { throw MoReadError.invalid("提问不能为空，书库伴读的提问最多 8000 个字。") }
    }
    public func validateFocus() throws {
        for ids in [focusedBookIDs] + messages.map(\.focusedBookIDs) {
            if let ids, ids.count > 4 || Set(ids).count != ids.count { throw MoReadError.invalid("最多选择 4 本不同的重点书籍。") }
        }
        for message in messages {
            if let ids = message.sourceBookIDs, ids.count > 32 || Set(ids).count != ids.count { throw MoReadError.invalid("消息关联的书籍记录无效。") }
        }
    }
    public mutating func associateTurnBooks(_ ids: [UUID]) throws {
        guard let last = messages.indices.last, messages[last].role == "assistant", last > 0, messages[last - 1].role == "user" else { return }
        let known = messages[last - 1].sourceBookIDs ?? bookID.map { [$0] } ?? messages[last - 1].focusedBookIDs ?? []
        let all = Set(known).union(ids).sorted { $0.uuidString < $1.uuidString }
        guard all.count <= 32 else { throw MoReadError.invalid("本轮关联的书籍过多，请开启新话题。") }
        messages[last - 1].sourceBookIDs = all; messages[last].sourceBookIDs = all
        if messages[last - 1].originalConversationID == nil { messages[last - 1].originalConversationID = id }
        if messages[last].originalConversationID == nil { messages[last].originalConversationID = id }
    }
    public func validateLibraryLimit() throws {
        if bookID == nil && sourceLimits.count > 32 { throw MoReadError.invalid("本话题已涉及超过 32 本书，请新建话题。") }
    }
    public mutating func prepareLibraryTurn(books: [Book], focus: [UUID]? = nil) throws {
        try validateSources(books: books)
        guard bookID == nil else { return }
        var value = self
        if let focus { value.focusedBookIDs = focus }
        try value.validateFocus()
        for id in Set(value.sourceLimits.keys).union(value.focusedBookIDs ?? []) {
            guard let book = books.first(where: { $0.id == id && !$0.removed && $0.hasBody }) else { throw MoReadError.invalid("关联的书籍已移除，请新建话题或调整重点书籍。") }
            try ReaderTools.validate(book, current: books)
            value.sourceLimits[id] = book.readThrough
            value.sourceRevisions[id] = book.chapters.map(\.revision)
        }
        try value.validateLibraryLimit(); self = value
    }
    public mutating func updateTurnScopes() throws {
        let scopes = try MemoryBookScope.snapshot(self)
        guard let last = messages.indices.last, messages[last].role == "assistant" else { return }
        messages[last].bookScopes = scopes
        if last > 0, messages[last - 1].role == "user" { messages[last - 1].bookScopes = scopes }
    }
    public mutating func retainSourcesForHistory() throws {
        let history = messages.filter { ["user", "assistant"].contains($0.role) }
        // A legacy message without provenance cannot prove that a source is safe to discard.
        guard history.allSatisfy({ $0.bookScopes != nil }) else { return }
        var limits: [UUID: ReadingPosition] = [:], revisions: [UUID: [String]] = [:]
        for scope in history.flatMap({ $0.bookScopes ?? [] }) {
            guard scope.through.chapter >= 0, scope.through.offset >= 0, let original = sourceRevisions[scope.id], MemoryBookScope.fingerprint(original) == scope.revision else { throw MoReadError.invalid("历史消息的书籍来源无效。") }
            limits[scope.id] = max(limits[scope.id] ?? ReadingPosition(), scope.through)
            revisions[scope.id] = original
        }
        sourceLimits = limits; sourceRevisions = revisions
    }
    public func libraryContext(books: [Book]) -> String {
        guard bookID == nil else { return "" }
        let focus = (focusedBookIDs ?? []).map(\.uuidString).joined(separator: "、")
        let rows = sourceLimits.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { id -> String? in
            guard let book = books.first(where: { $0.id == id }), let end = sourceLimits[id] else { return nil }
            return "book_id=\(id)《\(book.title.prefix(200))》，已读边界：第 \(end.chapter + 1) 章，偏移 \(end.offset)。"
        }
        return "\n\n【书库伴读】可以直接闲聊；需要资料时先 find_books 获取真实编号，再按需查阅，闲聊不必扫描书库。重点书籍只是讨论偏好，其他书仍可用工具查阅。每本书独立防剧透，当前一轮的范围固定；一轮最多主动查阅 4 本书。重点 book_id：\(focus.isEmpty ? "未指定" : focus)。\n本话题关联的书籍（书名是资料）：\n" + (rows.isEmpty ? "尚未关联书籍。" : rows.joined(separator: "\n"))
    }
}
