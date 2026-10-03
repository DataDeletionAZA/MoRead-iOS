import Foundation
import CryptoKit

public struct BookTextCleanupPreview: Sendable {
    public struct Example: Sendable, Identifiable {
        public let id: Int
        public let title: String
        public let before: String
        public let after: String
    }
    public let bookID: UUID
    public let rules: [TextReplacementRule]
    public let sourceRevisions: [String]
    public let recordsDigest: String
    public let matches: Int
    public let changedChapters: Int
    public let detachedAnnotations: Int
    public let examples: [Example]
}

extension LibraryStore {
    public func previewTextCleanup(bookID: UUID, rules: [TextReplacementRule]) throws -> BookTextCleanupPreview {
        let book = try editableTextBook(bookID)
        let active = rules.filter { $0.enabled && !$0.forListeningOnly }
        guard !active.isEmpty else { throw MoReadError.invalid("请先启用至少一条正文规则。") }
        let recordsURL = directory(bookID).appendingPathComponent("records.json")
        let recordsData = try Data(contentsOf: recordsURL), records = try JSONDecoder().decode(BookRecords.self, from: recordsData)
        var count = 0, changed = 0, detached = 0, examples: [BookTextCleanupPreview.Example] = []
        for info in book.chapters {
            try Task.checkCancellation()
            let source = try chapter(info.id, in: book), result = try TextCleanup.apply(source.text, rules: active)
            count += result.matches
            guard source.text != result.text else { continue }
            changed += 1
            detached += records.annotations.filter { annotation in
                annotation.passage.bookID == book.id && annotation.passage.chapter == info.id && annotation.passage.isValid(in: source, scope: .wholeBook) && result.mapUnchangedRange(NSRange(location: annotation.passage.offset, length: annotation.passage.text.utf16.count)) == nil
            }.count
            if examples.count < 12 {
                let old = source.text as NSString, new = result.text as NSString
                var first = 0
                while first < min(old.length, new.length), old.character(at: first) == new.character(at: first) { first += 1 }
                func excerpt(_ text: String) -> String {
                    let start = TextBoundary.floor(max(0, first - 80), in: text), end = TextBoundary.floor(start + 700, in: text)
                    return (text as NSString).substring(with: NSRange(location: start, length: end - start))
                }
                examples.append(.init(id: info.id, title: info.title, before: excerpt(source.text), after: excerpt(result.text)))
            }
        }
        return .init(bookID: bookID, rules: active, sourceRevisions: book.chapters.map(\.revision), recordsDigest: textRecordDigest(recordsData), matches: count, changedChapters: changed, detachedAnnotations: detached, examples: examples)
    }
    /// Application writers stay paused until the chapter index and records are swapped together.
    public func applyTextCleanup(_ preview: BookTextCleanupPreview) throws -> Book {
        let book = try editableTextBook(preview.bookID)
        guard book.chapters.map(\.revision) == preview.sourceRevisions else { throw MoReadError.invalid("正文已变化，请重新预览后应用。") }
        let original = directory(book.id), recordsURL = original.appendingPathComponent("records.json")
        let originalRecords = try Data(contentsOf: recordsURL)
        guard textRecordDigest(originalRecords) == preview.recordsDigest else { throw MoReadError.invalid("阅读记录已变化，请重新预览后应用。") }
        var chapters: [Chapter] = [], changes: [Int: TextCleanupResult] = [:]
        for info in book.chapters {
            try Task.checkCancellation()
            var chapter = try chapter(info.id, in: book)
            let result = try TextCleanup.apply(chapter.text, rules: preview.rules)
            if result.text != chapter.text { changes[info.id] = result; chapter.text = result.text }
            chapters.append(chapter)
        }
        return try applyTextEdits(book: book, chapters: chapters, changes: changes, originalRecords: originalRecords)
    }
    func applyTextEdits(book: Book, chapters: [Chapter], changes: [Int: TextCleanupResult], originalRecords: Data) throws -> Book {
        guard !changes.isEmpty else { return book }
        var updated = book; updated.chapters = chapters.map(ChapterInfo.init)
        func position(_ value: ReadingPosition) -> ReadingPosition {
            guard let change = changes[value.chapter] else { return value }
            return .init(chapter: value.chapter, offset: change.mapPosition(value.offset))
        }
        updated.position = position(book.position); updated.readThrough = position(book.readThrough)
        var records = try JSONDecoder().decode(BookRecords.self, from: originalRecords)
        for index in records.bookmarks.indices {
            records.bookmarks[index].position = position(records.bookmarks[index].position)
        }
        for index in records.annotations.indices {
            var annotation = records.annotations[index]
            let passage = annotation.passage
            if let sourceThrough = annotation.sourceThrough { annotation.sourceThrough = position(sourceThrough) }
            if let result = changes[passage.chapter], passage.bookID == book.id,
               passage.revision == book.chapters[passage.chapter].revision,
               let mapped = result.mapUnchangedRange(NSRange(location: passage.offset, length: passage.text.utf16.count)),
               (result.text as NSString).substring(with: mapped) == passage.text {
                annotation.passage.offset = mapped.location; annotation.passage.revision = chapters[passage.chapter].revision
            }
            records.annotations[index] = annotation
        }
        return try commitTextChapters(book: book, updated: updated, chapters: chapters, records: records, originalRecords: originalRecords)
    }
    func commitTextChapters(book: Book, updated: Book, chapters: [Chapter], records: BookRecords, originalRecords: Data) throws -> Book {
        let original = directory(book.id), recordsURL = original.appendingPathComponent("records.json")
        let manager = FileManager.default, staging = root.appendingPathComponent(".text-edit-" + UUID().uuidString, isDirectory: true)
        try Task.checkCancellation()
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: original, to: staging)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for chapter in chapters {
            try Task.checkCancellation()
            try encoder.encode(chapter).write(to: staging.appendingPathComponent("chapter-\(chapter.id).json"), options: .atomic)
        }
        try encoder.encode(records).write(to: staging.appendingPathComponent("records.json"), options: .atomic)
        try encoder.encode(updated).write(to: staging.appendingPathComponent("book.json"), options: .atomic)
        for old in book.chapters where old.id >= chapters.count {
            try manager.removeItem(at: staging.appendingPathComponent("chapter-\(old.id).json"))
        }
        for info in updated.chapters {
            let chapter = try JSONDecoder().decode(Chapter.self, from: Data(contentsOf: staging.appendingPathComponent("chapter-\(info.id).json")))
            guard ChapterInfo(chapter) == info else { throw MoReadError.invalid("新正文未通过校验，原书籍已保留。") }
        }
        guard try self.book(book.id) == book, try Data(contentsOf: recordsURL) == originalRecords else { throw MoReadError.invalid("书籍或阅读记录已变化，请重新预览后应用。") }
        try Task.checkCancellation()
        try Self.swapDirectories(original, staging)
        return updated
    }
    func editableTextBook(_ id: UUID) throws -> Book {
        let book = try book(id)
        guard book.format == "txt", book.hasBody, !book.removed, !book.chapters.isEmpty else { throw MoReadError.invalid("请选择有正文的 TXT 书籍。") }
        return book
    }
    func textRecordDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
