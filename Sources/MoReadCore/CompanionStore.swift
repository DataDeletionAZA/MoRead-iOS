import Foundation
import NaturalLanguage

public struct CompanionSettings: Codable {
    public var providers: [AIProvider] = []
    public var selectedProvider: UUID?
    public var selectedCharacter: UUID?
    public var userName = "读者"
    public init() {}
}

public struct Conversation: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var title: String
    public var bookID: UUID?
    public var characterID: UUID
    public var messages: [ChatMessage] = []
    public var sourceLimits: [UUID: ReadingPosition] = [:]
    public var sourceRevisions: [UUID: [String]] = [:]
    public var updatedAt = Date()
    public init(title: String, bookID: UUID?, characterID: UUID) {
        self.title = title; self.bookID = bookID; self.characterID = characterID
    }
    public func validateSources(books: [Book]) throws {
        for (id, end) in sourceLimits {
            guard let book = books.first(where: { $0.id == id }), !book.removed,
                  book.readThrough >= end, sourceRevisions[id] == book.chapters.map(\.revision) else {
                throw MoReadError.invalid("这个话题引用的书籍或已读范围发生了变化，请新建话题后继续。")
            }
        }
    }
}

public final class CompanionStore {
    private let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let manager = FileManager.default
    public init(root: URL) throws {
        self.root = root.appendingPathComponent("companion", isDirectory: true)
        try manager.createDirectory(at: self.root.appendingPathComponent("characters"), withIntermediateDirectories: true)
        try manager.createDirectory(at: self.root.appendingPathComponent("conversations"), withIntermediateDirectories: true)
    }
    public func settings() throws -> CompanionSettings {
        let url = root.appendingPathComponent("settings.json")
        return manager.fileExists(atPath: url.path) ? try decoder.decode(CompanionSettings.self, from: Data(contentsOf: url)) : CompanionSettings()
    }
    public func save(_ settings: CompanionSettings) throws { try encoder.encode(settings).write(to: root.appendingPathComponent("settings.json"), options: .atomic) }
    public func characters() throws -> [CharacterCard] {
        try manager.contentsOfDirectory(at: root.appendingPathComponent("characters"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try decoder.decode(CharacterCard.self, from: Data(contentsOf: $0)) }.sorted { $0.name < $1.name }
    }
    public func save(_ card: CharacterCard) throws {
        try encoder.encode(card).write(to: root.appendingPathComponent("characters/\(card.id.uuidString).json"), options: .atomic)
    }
    public func conversations() throws -> [Conversation] {
        // ponytail: history loads one JSON per conversation; add a lightweight index if history opening becomes slow.
        try manager.contentsOfDirectory(at: root.appendingPathComponent("conversations"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try decoder.decode(Conversation.self, from: Data(contentsOf: $0)) }.sorted { $0.updatedAt > $1.updatedAt }
    }
    public func save(_ conversation: Conversation) throws {
        try encoder.encode(conversation).write(to: root.appendingPathComponent("conversations/\(conversation.id.uuidString).json"), options: .atomic)
    }
    public func deleteConversation(_ id: UUID) throws { try manager.removeItem(at: root.appendingPathComponent("conversations/\(id.uuidString).json")) }
}

public struct CompanionContext: Sendable {
    public var text: String
    public var passages: [SourcePassage]
    public var limits: [UUID: ReadingPosition]
    public var revisions: [UUID: [String]]
}

public enum CompanionContextBuilder {
    public static func build(query: String, books: [Book], currentBook: UUID?, store: LibraryStore, selection: SourcePassage? = nil) throws -> CompanionContext {
        let targets = books.filter { !$0.removed && (currentBook == nil || $0.id == currentBook) }
        var passages: [SourcePassage] = []
        var limits: [UUID: ReadingPosition] = [:]
        var revisions: [UUID: [String]] = [:]
        var budget = 12_000
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = query
        var words: [String] = []
        tokenizer.enumerateTokens(in: query.startIndex..<query.endIndex) { range, _ in
            let value = String(query[range])
            if value.count >= 2, !words.contains(value) { words.append(value) }
            return words.count < 12
        }
        func append(_ passage: SourcePassage, book: Book) {
            guard passages.count < 24, passage.text.utf16.count <= budget, !passages.contains(where: { $0.id == passage.id }) else { return }
            passages.append(passage); budget -= passage.text.utf16.count
            limits[book.id] = book.readThrough; revisions[book.id] = book.chapters.map(\.revision)
        }
        for book in targets {
            try Task.checkCancellation()
            let scope = ReadingScope(through: book.readThrough)
            if let selection, selection.bookID == book.id,
               selection.isValid(in: try store.chapter(selection.chapter, in: book), scope: scope) { append(selection, book: book) }
            if currentBook == book.id, book.chapters.indices.contains(book.position.chapter) {
                let chapter = try store.chapter(book.position.chapter, in: book)
                let readable = scope.readableText(chapter)
                let end = min(readable.utf16.count, book.position.offset + 2000)
                let start = TextBoundary.floor(max(0, end - 4000), in: readable)
                let safeEnd = TextBoundary.floor(end, in: readable)
                if safeEnd > start { append(SourcePassage(bookID: book.id, chapter: chapter, offset: start, text: (readable as NSString).substring(with: NSRange(location: start, length: safeEnd - start))), book: book) }
            }
            for info in book.chapters where info.id <= scope.end.chapter && budget > 300 && passages.count < 24 {
                try Task.checkCancellation()
                let chapter = try store.chapter(info.id, in: book)
                for word in words {
                    for passage in BookSearch.find(word, in: chapter, bookID: book.id, scope: scope, limit: 2) { append(passage, book: book) }
                    if passages.count >= 24 || budget <= 300 { break }
                }
            }
        }
        let text = passages.enumerated().map { index, passage in
            let book = targets.first { $0.id == passage.bookID }
            let title = book?.chapters.first { $0.id == passage.chapter }?.title ?? ""
            return "【来源 \(index + 1)】《\(book?.title ?? "")》\(title)\n\(passage.text)"
        }.joined(separator: "\n\n")
        return CompanionContext(text: text, passages: passages, limits: limits, revisions: revisions)
    }
}
