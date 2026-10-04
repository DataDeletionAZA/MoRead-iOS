import Foundation

public struct ReadingReviewEntry: Identifiable, Hashable, Sendable {
    public enum Content: Hashable, Sendable { case annotation(Annotation), note(ReadingNote) }
    public let book: Book
    public let content: Content
    public init(book: Book, content: Content) { self.book = book; self.content = content }
    public var id: String {
        switch content {
        case .annotation(let value): return "\(book.id):annotation:\(value.id)"
        case .note(let value): return "\(book.id):note:\(value.id)"
        }
    }
    public var characterID: UUID? {
        switch content { case .annotation(let value): return value.characterID; case .note(let value): return value.characterID }
    }
    public var author: String {
        switch content {
        case .annotation(let value): return value.characterID == nil ? "我" : value.characterName ?? "已删除角色"
        case .note(let value): return value.characterID == nil ? "我" : value.characterName ?? "已删除角色"
        }
    }
    public var title: String {
        switch content { case .annotation: return "划线与批注"; case .note(let value): return value.title }
    }
    public var quote: String {
        switch content { case .annotation(let value): return value.passage.text; case .note: return "" }
    }
    public var body: String {
        switch content { case .annotation(let value): return value.note; case .note(let value): return value.content }
    }
    public var date: Date {
        switch content { case .annotation(let value): return value.createdAt; case .note(let value): return value.updatedAt }
    }
    public var passage: SourcePassage? {
        guard book.hasBody, !book.removed, case .annotation(let value) = content else { return nil }
        return value.passage
    }
    public var markdown: String {
        "## \(book.title) · \(title)\n\n" + (quote.isEmpty ? "" : "> " + quote.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n")
            + body + "\n\n— " + author + "\n"
    }
}

public struct ReadingReviewFilter: Equatable, Sendable {
    public enum Source: String, CaseIterable, Sendable {
        case all = "全部作者", mine = "我的", companion = "角色"
    }
    public enum Kind: String, CaseIterable, Sendable {
        case all = "全部内容", annotation = "划线与批注", note = "读书笔记"
    }
    public var bookIDs: Set<UUID> = []
    public var source: Source = .all
    public var characterID: UUID?
    public var kind: Kind = .all
    public var query = ""
    public var oldestFirst = false
    public init() {}
    public func apply(to entries: [ReadingReviewEntry]) -> [ReadingReviewEntry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.filter { entry in
            guard bookIDs.isEmpty || bookIDs.contains(entry.book.id) else { return false }
            if source == .mine && entry.characterID != nil { return false }
            if source == .companion && (entry.characterID == nil || (characterID != nil && characterID != entry.characterID)) { return false }
            switch (kind, entry.content) { case (.annotation, .note), (.note, .annotation): return false; default: break }
            let fields = [entry.book.title, entry.book.author, entry.author, entry.title, entry.quote, entry.body]
            return words.allSatisfy { word in fields.contains { $0.localizedCaseInsensitiveContains(word) } }
        }.sorted {
            if $0.date == $1.date { return $0.id < $1.id }
            return oldestFirst ? $0.date < $1.date : $0.date > $1.date
        }
    }
}

public enum ReadingReview {
    public static func entries(books: [Book], records: [UUID: BookRecords]) -> [ReadingReviewEntry] {
        books.flatMap { book -> [ReadingReviewEntry] in
            guard let saved = records[book.id] else { return [] }
            let scope = ReadingScope(through: book.readThrough)
            let annotations = saved.annotations.filter { value in
                let passage = value.passage
                guard passage.bookID == book.id else { return false }
                if value.characterID == nil { return true }
                guard let through = value.sourceThrough, through >= ReadingPosition(), through <= book.readThrough,
                      book.chapters.indices.contains(passage.chapter), book.chapters[passage.chapter].revision == passage.revision,
                      scope.allows(chapter: passage.chapter, range: NSRange(location: passage.offset, length: passage.text.utf16.count)),
                      passage.offset <= book.chapters[passage.chapter].length,
                      passage.text.utf16.count <= book.chapters[passage.chapter].length - passage.offset else { return false }
                return true
            }.map { ReadingReviewEntry(book: book, content: .annotation($0)) }
            let notes = (saved.notes ?? []).filter { $0.characterID == nil || $0.visible(in: book) }
                .map { ReadingReviewEntry(book: book, content: .note($0)) }
            return annotations + notes
        }
    }
    public static func markdown(_ entries: [ReadingReviewEntry]) -> String {
        "# 划线与笔记\n\n" + entries.map(\.markdown).joined(separator: "\n")
    }
}
