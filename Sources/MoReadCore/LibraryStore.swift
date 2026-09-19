import Foundation

public struct Annotation: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var passage: SourcePassage
    public var note: String
    public var style: String
    public var createdAt = Date()
    public init(passage: SourcePassage, note: String = "", style: String = "highlight") {
        self.passage = passage; self.note = note; self.style = style
    }
}

public struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var position: ReadingPosition
    public var label: String
    public var locator: Data?
    public init(position: ReadingPosition, label: String, locator: Data? = nil) {
        self.position = position; self.label = label; self.locator = locator
    }
}

public struct BookRecords: Codable, Sendable {
    public var annotations: [Annotation] = []
    public var bookmarks: [Bookmark] = []
    public var readingSeconds: [String: Double] = [:]
    public init() {}
}

/// The app serializes calls on its main actor. Every replacement is atomic; book imports
/// become visible only after their original file and all chapters have been written.
public final class LibraryStore {
    public let root: URL
    private let manager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(root: URL) throws {
        self.root = root
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        encoder.outputFormatting = [.sortedKeys]
    }
    public func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func books() throws -> [Book] {
        try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map { try decoder.decode(Book.self, from: Data(contentsOf: $0.appendingPathComponent("book.json"))) }
            .sorted { ($0.lastOpened ?? $0.importedAt) > ($1.lastOpened ?? $1.importedAt) }
    }
    public func importBook(title: String, author: String = "", chapters: [Chapter], original: URL? = nil, format: String = "txt") throws -> Book {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !chapters.isEmpty,
              chapters.enumerated().allSatisfy({ $0.offset == $0.element.id }), ["txt", "epub"].contains(format) else {
            throw MoReadError.invalid("书籍标题或章节信息不完整。")
        }
        let book = Book(title: title, author: author, format: format, chapters: chapters)
        let temporary = root.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        for chapter in chapters { try encoder.encode(chapter).write(to: temporary.appendingPathComponent("chapter-\(chapter.id).json"), options: .atomic) }
        if let original { try manager.copyItem(at: original, to: temporary.appendingPathComponent("original.\(format)")) }
        try encoder.encode(book).write(to: temporary.appendingPathComponent("book.json"), options: .atomic)
        try encoder.encode(BookRecords()).write(to: temporary.appendingPathComponent("records.json"), options: .atomic)
        try manager.moveItem(at: temporary, to: directory(book.id))
        return book
    }
    public func save(_ book: Book) throws {
        try encoder.encode(book).write(to: directory(book.id).appendingPathComponent("book.json"), options: .atomic)
    }
    public func chapter(_ index: Int, in book: Book) throws -> Chapter {
        guard book.chapters.indices.contains(index) else { throw MoReadError.invalid("找不到这一章。") }
        let chapter = try decoder.decode(Chapter.self, from: Data(contentsOf: directory(book.id).appendingPathComponent("chapter-\(index).json")))
        guard chapter.id == index, chapter.revision == book.chapters[index].revision else { throw MoReadError.invalid("章节内容与索引不一致，请从备份恢复。") }
        return chapter
    }
    public func records(for book: Book) throws -> BookRecords {
        try decoder.decode(BookRecords.self, from: Data(contentsOf: directory(book.id).appendingPathComponent("records.json")))
    }
    public func saveRecords(_ records: BookRecords, for book: Book) throws {
        try encoder.encode(records).write(to: directory(book.id).appendingPathComponent("records.json"), options: .atomic)
    }
    public func remove(_ book: Book, permanently: Bool) throws {
        if permanently { try manager.removeItem(at: directory(book.id)) }
        else {
            var copy = book; copy.removed = true
            try save(copy)
        }
    }
    public func notesMarkdown(for book: Book) throws -> String {
        let records = try records(for: book)
        return "# \(book.title)\n\n" + records.annotations.map { annotation in
            let heading = book.chapters.first { $0.id == annotation.passage.chapter }?.title ?? ""
            return "## \(heading)\n\n> " + annotation.passage.text.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n\(annotation.note)\n"
        }.joined(separator: "\n")
    }
}
