import Foundation
import Darwin

public struct Annotation: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var passage: SourcePassage
    public var generationKey: String?
    public var characterID: UUID?
    public var characterName: String?
    public var sourceThrough: ReadingPosition?
    public var note: String
    public var style: String
    public var createdAt = Date()
    public var authorLabel: String { (characterName ?? "我") + (generationKey?.hasPrefix("tool:") == true || characterID == nil ? "的批注" : "的段评") }
    public init(passage: SourcePassage, note: String = "", style: String = "highlight") {
        self.passage = passage; self.note = note; self.style = style
    }
}

public struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var createdAt: Date? = Date()
    public var position: ReadingPosition
    public var label: String
    public var locator: Data?
    public init(position: ReadingPosition, label: String, locator: Data? = nil) {
        self.position = position; self.label = label; self.locator = locator
    }
}

public struct BookRecords: Codable, Sendable {
    public var chapterKnowledge: [ChapterKnowledgeEntry]?
    public var notes: [ReadingNote]?
    public var annotationAttempts: [String: ProactiveAttempt]?
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
    public func organization() throws -> ShelfOrganization {
        let url = root.appendingPathComponent("organization.json")
        let value = manager.fileExists(atPath: url.path) ? try decoder.decode(ShelfOrganization.self, from: Data(contentsOf: url)) : ShelfOrganization()
        try value.validate(); return value
    }
    public func saveOrganization(_ value: ShelfOrganization) throws {
        try value.validate()
        try encoder.encode(value).write(to: root.appendingPathComponent("organization.json"), options: .atomic)
    }
    public func books() throws -> [Book] {
        try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map { directory in
                let book = try decoder.decode(Book.self, from: Data(contentsOf: directory.appendingPathComponent("book.json")))
                guard book.id == UUID(uuidString: directory.lastPathComponent) else { throw MoReadError.invalid("书籍标识与存储目录不一致。") }
                return book
            }
            .sorted { ($0.lastOpened ?? $0.importedAt) > ($1.lastOpened ?? $1.importedAt) }
    }
    public func book(_ id: UUID) throws -> Book {
        let book = try decoder.decode(Book.self, from: Data(contentsOf: directory(id).appendingPathComponent("book.json")))
        guard book.id == id else { throw MoReadError.invalid("书籍标识与存储目录不一致。") }
        return book
    }
    public func importBook(title: String, author: String = "", chapters: [Chapter], original: URL? = nil, format: String = "txt", readingMap: Data? = nil) throws -> Book {
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
        if let readingMap { try readingMap.write(to: temporary.appendingPathComponent("epub-map.json"), options: .atomic) }
        try encoder.encode(book).write(to: temporary.appendingPathComponent("book.json"), options: .atomic)
        try encoder.encode(BookRecords()).write(to: temporary.appendingPathComponent("records.json"), options: .atomic)
        try manager.moveItem(at: temporary, to: directory(book.id))
        return book
    }
    public func save(_ book: Book) throws {
        guard book.hasBody || book.removed else { throw MoReadError.invalid("正文已清理，请重新导入书籍后阅读。") }
        try encoder.encode(book).write(to: directory(book.id).appendingPathComponent("book.json"), options: .atomic)
    }
    public func chapter(_ index: Int, in book: Book) throws -> Chapter {
        guard book.hasBody else { throw MoReadError.invalid("正文已清理，阅读记录仍保留。") }
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
    @discardableResult public func modifyRecords(for book: Book, _ update: (inout BookRecords) throws -> Void) throws -> BookRecords {
        var current = try records(for: book)
        try update(&current)
        try saveRecords(current, for: book)
        return current
    }
    public func remove(_ book: Book, permanently: Bool) throws {
        if permanently { try manager.removeItem(at: directory(book.id)) }
        else {
            var copy = book; copy.removed = true
            try save(copy)
        }
    }
    public func storageBytes(for book: Book) throws -> Int64 {
        let files = try manager.contentsOfDirectory(at: directory(book.id), includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        return try files.reduce(0) { sum, url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return sum + (values.isRegularFile == true ? Int64(values.fileSize ?? 0) : 0)
        }
    }
    public func clearBody(_ book: Book) throws -> Book {
        let original = directory(book.id)
        let staging = root.appendingPathComponent(".clear-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        let contentNames = Set(book.chapters.map { "chapter-\($0.id).json" } + ["original.txt", "original.epub", "epub-map.json", "vectors.sqlite", "vectors.sqlite-journal"])
        for url in try manager.contentsOfDirectory(at: original, includingPropertiesForKeys: nil) where !contentNames.contains(url.lastPathComponent) && !(url.lastPathComponent.hasPrefix("speech-") && url.pathExtension == "mp3") {
            try manager.copyItem(at: url, to: staging.appendingPathComponent(url.lastPathComponent))
        }
        var cleared = book; cleared.removed = true; cleared.bodyCleared = true
        try encoder.encode(cleared).write(to: staging.appendingPathComponent("book.json"), options: .atomic)
        _ = try decoder.decode(BookRecords.self, from: Data(contentsOf: staging.appendingPathComponent("records.json")))
        try Self.swapDirectories(original, staging)
        try manager.removeItem(at: staging)
        return cleared
    }
    static func swapDirectories(_ first: URL, _ second: URL) throws {
        guard renameatx_np(AT_FDCWD, first.path, AT_FDCWD, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    public func notesMarkdown(for book: Book) throws -> String {
        let records = try records(for: book)
        let annotations = records.annotations.map { annotation in
            let heading = book.chapters.first { $0.id == annotation.passage.chapter }?.title ?? ""
            let author = annotation.characterName == nil ? "" : "\n\n" + annotation.authorLabel
            return "## \(heading)\(author)\n\n> " + annotation.passage.text.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n\(annotation.note)\n"
        }.joined(separator: "\n")
        let notes = (records.notes ?? []).map { "## \($0.title)\n\n\($0.authorLabel) · \($0.kind == "plot_summary" ? "剧情梗概" : "读书笔记")\n\n\($0.content)\n" }.joined(separator: "\n")
        return "# \(book.title)\n\n" + annotations + "\n" + notes
    }
}
