import XCTest
@testable import MoReadCore

final class BookTextEditingTests: XCTestCase {
    func testRecognitionRejectsChangedChapterFileBeforeWriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let book = try store.importBook(title: "版本变化", chapters: TextImporter.chapters("第一章 春\n春天来了。\n第二章 夏\n夏天来了。"))
        let preview = try store.previewChapterRecognition(bookID: book.id)
        var edited = try store.chapter(0, in: book); edited.text = "另一份正在修改的正文"
        let data = try JSONEncoder().encode(edited), file = store.directory(book.id).appendingPathComponent("chapter-0.json")
        try data.write(to: file, options: .atomic)
        XCTAssertThrowsError(try store.applyChapterRecognition(preview))
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(try store.book(book.id), book)
    }
    func testSelectedEditMapsUTF16RecordsAndRejectsStaleSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root), source = Chapter(id: 0, title: "雨后", text: "😀雨后的书店。雨后", hasSourceHeading: true)
        var book = try store.importBook(title: "修改", chapters: [source, .init(id: 1, title: "后文", text: "未读")])
        book.position.offset = 5; book.readThrough.offset = 8; try store.save(book)
        let passage = SourcePassage(bookID: book.id, chapter: source, offset: 2, text: "雨后")
        let unaffected = SourcePassage(bookID: book.id, chapter: source, offset: 5, text: "书店")
        var records = BookRecords(); records.bookmarks = [.init(position: .init(chapter: 0, offset: 5), label: "书店")]
        records.annotations = [.init(passage: passage, note: "保留旧引文笔记"), .init(passage: unaffected, note: "保留高亮")]
        records.readingSeconds = ["2026-10-03": 42]; try store.saveRecords(records, for: book)
        let changed = try store.replaceSelectedText(passage, with: "晴天以后")
        let chapter = try store.chapter(0, in: changed), saved = try store.records(for: changed)
        XCTAssertEqual(chapter.text, "😀晴天以后的书店。雨后"); XCTAssertEqual(chapter.hasSourceHeading, true)
        XCTAssertEqual(changed.position.offset, 7); XCTAssertEqual(changed.readThrough.offset, 10)
        XCTAssertEqual(saved.bookmarks[0].position.offset, 7)
        XCTAssertEqual(saved.annotations[0].note, "保留旧引文笔记"); XCTAssertFalse(saved.annotations[0].passage.isValid(in: chapter, scope: .wholeBook))
        XCTAssertTrue(saved.annotations[1].passage.isValid(in: chapter, scope: .wholeBook)); XCTAssertEqual(saved.readingSeconds, records.readingSeconds)
        XCTAssertThrowsError(try store.replaceSelectedText(passage, with: "旧选择"))
        let broken = SourcePassage(bookID: book.id, chapter: chapter, offset: 1, text: "😀")
        XCTAssertThrowsError(try store.replaceSelectedText(broken, with: "x"))
        XCTAssertThrowsError(try store.replaceSelectedText(saved.annotations[1].passage, with: String(repeating: "a", count: 20_001)))
        XCTAssertEqual(try store.chapter(0, in: changed), chapter)
        let deleted = try store.replaceSelectedText(saved.annotations[1].passage, with: "")
        XCTAssertEqual(try store.chapter(0, in: deleted).text, "😀晴天以后的。雨后")
    }

    func testRecognitionMapsPositionsQuotesAndIsRepeatable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let source = Chapter(id: 0, title: "正文", text: "导言😀\n第一章 雨后\n😀书店。\n第二章 灯塔\n灯光亮了。\n", hasSourceHeading: false)
        var book = try store.importBook(title: "分章", chapters: [source])
        let quote = (source.text as NSString).range(of: "😀书店")
        book.position.offset = quote.location; book.readThrough.offset = NSMaxRange(quote); try store.save(book)
        var records = BookRecords()
        records.bookmarks = [.init(position: .init(chapter: 0, offset: (source.text as NSString).range(of: "灯光").location), label: "灯光")]
        records.annotations = [.init(passage: .init(bookID: book.id, chapter: source, offset: quote.location, text: "😀书店"), note: "映射"), .init(passage: .init(bookID: book.id, chapter: source, offset: 0, text: "导言😀\n第一章 雨后"), note: "跨越新标题")]
        try store.saveRecords(records, for: book)
        let preview = try store.previewChapterRecognition(bookID: book.id)
        XCTAssertEqual(preview.chapters.map(\.title), ["序章", "第一章 雨后", "第二章 灯塔"])
        XCTAssertEqual(preview.detachedAnnotations, 1); XCTAssertEqual(try store.book(book.id), book)
        let changed = try store.applyChapterRecognition(preview), saved = try store.records(for: changed)
        XCTAssertEqual(changed.position, .init(chapter: 1, offset: 0)); XCTAssertEqual(changed.readThrough, .init(chapter: 1, offset: 4))
        XCTAssertFalse(ReadingScope(through: changed.readThrough).allows(chapter: 2, range: .init(location: 0, length: 1)))
        XCTAssertEqual(saved.bookmarks[0].position, .init(chapter: 2, offset: 0))
        XCTAssertTrue(saved.annotations[0].passage.isValid(in: try store.chapter(1, in: changed), scope: .wholeBook))
        XCTAssertEqual(saved.annotations[1].note, "跨越新标题"); XCTAssertTrue(saved.annotations[1].passage.revision.hasPrefix("retired:"))
        let repeated = try store.applyChapterRecognition(store.previewChapterRecognition(bookID: book.id))
        XCTAssertEqual(changed.chapters, repeated.chapters); XCTAssertEqual(changed.position, repeated.position)
        XCTAssertEqual(try store.records(for: repeated).annotations, saved.annotations)
        let archive = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        _ = try await BackupArchive.create(root: root, output: archive)
        let restored = try await BackupArchive.prepare(archive, beside: root)
        defer { try? FileManager.default.removeItem(at: restored.directory) }
        XCTAssertEqual(try LibraryStore(root: restored.directory).book(book.id).chapters, changed.chapters)
    }

    func testRecognitionInvalidRulesStaleRecordsCancellationAndChapterRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let book = try store.importBook(title: "合并", chapters: [.init(id: 0, title: "Part 1", text: "甲。\n", hasSourceHeading: true), .init(id: 1, title: "Part 2", text: "乙。\n", hasSourceHeading: true), .init(id: 2, title: "Part 3", text: "丙。\n", hasSourceHeading: true)])
        for rule in ["[", "^不存在$"] {
            XCTAssertThrowsError(try store.previewChapterRecognition(bookID: book.id, customRule: rule))
        }
        let preview = try store.previewChapterRecognition(bookID: book.id, customRule: "^Part 1$")
        XCTAssertEqual(preview.chapters.count, 1)
        var records = BookRecords(); records.bookmarks = [.init(position: .init(chapter: 2, offset: 1), label: "更新")]
        try store.saveRecords(records, for: book)
        XCTAssertThrowsError(try store.applyChapterRecognition(preview))
        XCTAssertEqual(try store.book(book.id), book)
        let fresh = try store.previewChapterRecognition(bookID: book.id, customRule: "^Part 1$")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try store.applyChapterRecognition(fresh)
        }
        do { _ = try await task.value; XCTFail("Cancelled operation wrote a book") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try store.book(book.id), book)
        let merged = try store.applyChapterRecognition(fresh)
        XCTAssertEqual(merged.chapters.count, 1)
        XCTAssertTrue(try store.chapter(0, in: merged).text.contains("Part 3\n丙。"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(book.id).appendingPathComponent("chapter-2.json").path))
        XCTAssertThrowsError(try store.applyChapterRecognition(fresh))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".text-edit-") })
    }
}
