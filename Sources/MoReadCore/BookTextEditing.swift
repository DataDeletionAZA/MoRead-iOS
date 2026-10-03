import Foundation

public struct ChapterRecognitionPreview: Sendable {
    public let bookID: UUID
    public let sourceChapters: [ChapterInfo]
    public let chapters: [ChapterInfo]
    public let detachedAnnotations: Int
    let recordsDigest: String
    let spans: [TextChapterSpan]
    let oldBodyStarts: [Int]

    func global(_ position: ReadingPosition) -> Int {
        let index = min(max(0, position.chapter), sourceChapters.count - 1)
        return oldBodyStarts[index] + min(max(0, position.offset), sourceChapters[index].length)
    }
    func position(_ old: ReadingPosition) -> ReadingPosition {
        let offset = global(old)
        var low = 0, high = spans.count - 1
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(spans[middle].bodyRange) < offset { low = middle + 1 } else { high = middle }
        }
        let span = spans[low]
        return .init(chapter: low, offset: TextBoundary.floor(offset - span.bodyRange.location, in: span.chapter.text))
    }
    func passage(_ old: SourcePassage) -> SourcePassage? {
        guard old.bookID == bookID, sourceChapters.indices.contains(old.chapter), old.offset >= 0,
              old.revision == sourceChapters[old.chapter].revision, !old.text.isEmpty,
              old.offset <= sourceChapters[old.chapter].length,
              old.text.utf16.count <= sourceChapters[old.chapter].length - old.offset else { return nil }
        let start = oldBodyStarts[old.chapter] + old.offset
        let position = position(.init(chapter: old.chapter, offset: old.offset)), span = spans[position.chapter]
        guard start >= span.bodyRange.location, old.text.utf16.count <= NSMaxRange(span.bodyRange) - start else { return nil }
        var passage = SourcePassage(bookID: bookID, chapter: span.chapter, offset: start - span.bodyRange.location, text: old.text)
        passage.epubLocator = nil
        return passage.isValid(in: span.chapter, scope: .wholeBook) ? passage : nil
    }
}

extension LibraryStore {
    public func replaceSelectedText(_ passage: SourcePassage, with replacement: String) throws -> Book {
        let book = try editableTextBook(passage.bookID), source = try chapter(passage.chapter, in: book)
        guard passage.isValid(in: source, scope: .wholeBook) else { throw MoReadError.invalid("选中的原文已变化，请重新选择。") }
        guard replacement.utf16.count <= 20_000 else { throw MoReadError.invalid("替换文字最多 20000 字符。") }
        guard passage.text != replacement else { return book }
        let range = NSRange(location: passage.offset, length: passage.text.utf16.count)
        let text = (source.text as NSString).replacingCharacters(in: range, with: replacement)
        let result = TextCleanupResult(text: text, matches: 1, stages: [[.init(range: range, length: replacement.utf16.count)]], sourceLength: source.text.utf16.count)
        let records = try Data(contentsOf: directory(book.id).appendingPathComponent("records.json"))
        let chapters = try book.chapters.map { info -> Chapter in
            try Task.checkCancellation()
            if info.id == source.id { var updated = source; updated.text = text; return updated }
            return try chapter(info.id, in: book)
        }
        return try applyTextEdits(book: book, chapters: chapters, changes: [source.id: result], originalRecords: records)
    }

    public func previewChapterRecognition(bookID: UUID, customRule: String = "") throws -> ChapterRecognitionPreview {
        let book = try editableTextBook(bookID), source = NSMutableString(), records = try Data(contentsOf: directory(bookID).appendingPathComponent("records.json"))
        var starts: [Int] = []
        for info in book.chapters {
            try Task.checkCancellation()
            let chapter = try chapter(info.id, in: book)
            if info.id > 0 {
                if source.length > 0, source.character(at: source.length - 1) != 10 { source.append("\n") }
            }
            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let first = chapter.text.prefix(while: { !$0.isNewline }).trimmingCharacters(in: .whitespacesAndNewlines)
            if chapter.hasSourceHeading != false, !title.isEmpty, title != first { source.append(title + "\n") }
            starts.append(source.length); source.append(chapter.text)
            guard source.length <= TextImporter.maximumBytes else { throw MoReadError.invalid("正文过长，请拆分后再识别。") }
        }
        let rule = customRule.trimmingCharacters(in: .whitespacesAndNewlines)
        let spans = try TextImporter.chapterSpans(source as String, customRule: rule.isEmpty ? nil : rule)
        let chapters = spans.map { ChapterInfo($0.chapter) }
        let preview = ChapterRecognitionPreview(bookID: bookID, sourceChapters: book.chapters, chapters: chapters, detachedAnnotations: 0, recordsDigest: textRecordDigest(records), spans: spans, oldBodyStarts: starts)
        let saved = try JSONDecoder().decode(BookRecords.self, from: records)
        let detached = saved.annotations.filter { preview.passage($0.passage) == nil }.count
        guard try self.book(bookID).chapters == book.chapters else { throw MoReadError.invalid("正文已变化，请重新预览。") }
        return .init(bookID: bookID, sourceChapters: book.chapters, chapters: chapters, detachedAnnotations: detached, recordsDigest: preview.recordsDigest, spans: spans, oldBodyStarts: starts)
    }

    public func applyChapterRecognition(_ preview: ChapterRecognitionPreview) throws -> Book {
        let book = try editableTextBook(preview.bookID)
        guard book.chapters == preview.sourceChapters else { throw MoReadError.invalid("正文或目录已变化，请重新预览。") }
        for info in book.chapters { try Task.checkCancellation(); _ = try chapter(info.id, in: book) }
        let originalRecords = try Data(contentsOf: directory(book.id).appendingPathComponent("records.json"))
        guard textRecordDigest(originalRecords) == preview.recordsDigest else { throw MoReadError.invalid("阅读记录已变化，请重新预览。") }
        var records = try JSONDecoder().decode(BookRecords.self, from: originalRecords), updated = book
        updated.chapters = preview.chapters
        updated.position = preview.position(book.position); updated.readThrough = preview.position(book.readThrough)
        for index in records.bookmarks.indices {
            records.bookmarks[index].position = preview.position(records.bookmarks[index].position)
            records.bookmarks[index].locator = nil
        }
        for index in records.annotations.indices {
            if let mapped = preview.passage(records.annotations[index].passage) { records.annotations[index].passage = mapped }
            else if !records.annotations[index].passage.revision.hasPrefix("retired:") { records.annotations[index].passage.revision = "retired:" + records.annotations[index].passage.revision }
            if let end = records.annotations[index].sourceThrough { records.annotations[index].sourceThrough = preview.position(end) }
        }
        return try commitTextChapters(book: book, updated: updated, chapters: preview.spans.map(\.chapter), records: records, originalRecords: originalRecords)
    }
}
