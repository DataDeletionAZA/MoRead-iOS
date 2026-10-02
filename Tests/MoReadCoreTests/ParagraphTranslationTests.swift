import XCTest
@testable import MoReadCore

final class ParagraphTranslationTests: XCTestCase {
    func testParagraphSelectionAndUnicodeChunks() throws {
        let text = "中文\r\n😀 Hello, reader!\r\n\nAnother paragraph.\u{2028}末尾"
        let paragraphs = try EnglishParagraph.paragraphs(in: text)
        XCTAssertEqual(paragraphs.map(\.text), ["😀 Hello, reader!", "Another paragraph."])
        XCTAssertEqual(paragraphs[0].start, 4)
        XCTAssertEqual(try EnglishParagraph.paragraphs(in: text, intersecting: NSRange(location: 7, length: 2)), [paragraphs[0]])
        XCTAssertThrowsError(try EnglishParagraph.paragraphs(in: text, intersecting: NSRange(location: Int.max, length: 1)))
        XCTAssertThrowsError(try EnglishParagraph.paragraphs(in: text, intersecting: NSRange(location: 0, length: Int.max)))
        let long = String(repeating: "a", count: 5999) + "😀" + String(repeating: "b", count: 6001)
        let parts = try XCTUnwrap(EnglishParagraph.paragraphs(in: long).first).parts()
        XCTAssertEqual(parts.joined(), long); XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { $0.utf16.count <= 6000 && !$0.contains("�") })
    }

    @MainActor func testReuseRetranslateHideDeleteFailureAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root), source = Chapter(id: 0, title: "Chapter", text: "Hello reader.\nA letter arrived.")
        let book = try library.importBook(title: "Book", chapters: [source, .init(id: 1, title: "Next", text: "Private future text.")])
        let store = ParagraphTranslationStore(library: library, bookID: book.id), first = NSRange(location: 0, length: 1)
        let replies = TranslationReplies(["你好，读者。", "一封信到了。"])
        var rows = try await store.generate(source: source, range: first, complete: { try await replies.complete($0) })
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].chinese, "你好，读者。")
        try store.setHidden(true, translation: rows[0], chapter: 0)
        XCTAssertTrue(try store.load(chapter: 0)[0].hidden)
        rows = try await store.generate(source: source, complete: { try await replies.complete($0) })
        XCTAssertEqual(rows.count, 2); XCTAssertFalse(rows[0].hidden)
        let requests = await replies.calls
        XCTAssertEqual(requests.map { $0.last!.content }, ["Hello reader.", "A letter arrived."])
        XCTAssertTrue(requests.allSatisfy { $0.count == 2 && $0[0].role == "system" && $0[1].role == "user" })
        XCTAssertEqual(try library.book(book.id).readThrough, book.readThrough)
        XCTAssertEqual(try ParagraphTranslationStore(library: LibraryStore(root: root), bookID: book.id).load(chapter: 0), rows)
        let old = rows[0]
        do {
            _ = try await store.generate(source: source, range: first, replaceCached: true, complete: { _ in "  " })
            XCTFail("An empty response must not replace a saved translation")
        } catch { XCTAssertEqual(try store.load(chapter: 0), rows) }
        rows = try await store.generate(source: source, range: first, replaceCached: true, complete: { _ in "读者，你好。" })
        XCTAssertEqual(rows[0].chinese, "读者，你好。")
        XCTAssertThrowsError(try store.delete(old, chapter: 0))
        try store.delete(rows[0], chapter: 0)
        XCTAssertEqual(try store.load(chapter: 0), [rows[1]])
    }

    @MainActor func testCancellationAndSourceChangesPreserveCompletedWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try LibraryStore(root: root), source = Chapter(id: 0, title: "Chapter", text: "First paragraph.\nSecond paragraph.")
        let book = try library.importBook(title: "Book", chapters: [source])
        let store = ParagraphTranslationStore(library: library, bookID: book.id)
        let replies = TranslationReplies(["第一段。"])
        do { _ = try await store.generate(source: source, complete: { try await replies.complete($0) }); XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try store.load(chapter: 0).map(\.chinese), ["第一段。"])
        let chapterFile = library.directory(book.id).appendingPathComponent("chapter-0.json")
        let bookFile = library.directory(book.id).appendingPathComponent("book.json")
        let changed = Chapter(id: 0, title: source.title, text: "First paragraph.\nEdited paragraph.")
        do {
            _ = try await store.generate(source: source, complete: { _ in
                try JSONEncoder().encode(changed).write(to: chapterFile, options: .atomic)
                var edited = book; edited.chapters[0] = ChapterInfo(changed)
                try JSONEncoder().encode(edited).write(to: bookFile, options: .atomic)
                return "不应保存。"
            }); XCTFail("Changed source must invalidate the response")
        } catch { XCTAssertEqual(try store.load(chapter: 0).map(\.chinese), ["第一段。"]) }
        let allChanged = Chapter(id: 0, title: source.title, text: "Other paragraph.\nEdited paragraph.")
        try JSONEncoder().encode(allChanged).write(to: chapterFile, options: .atomic)
        var edited = book; edited.chapters[0] = ChapterInfo(allChanged); try library.save(edited)
        XCTAssertTrue(try store.load(chapter: 0).isEmpty)
        let rows = try await store.generate(source: allChanged, complete: { _ in "新译文。" })
        XCTAssertEqual(rows.count, 2)
    }

    @MainActor func testConcurrentMutationAndBackupValidation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), root = folder.appendingPathComponent("library")
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try LibraryStore(root: root), source = Chapter(id: 0, title: "Chapter", text: "A quiet bookshop.")
        let book = try library.importBook(title: "Book", chapters: [source])
        let store = ParagraphTranslationStore(library: library, bookID: book.id)
        var rows = try await store.generate(source: source, complete: { _ in "一家安静的书店。" })
        let expected = rows[0]
        rows = try await store.generate(source: source, replaceCached: true, complete: { _ in
            try await MainActor.run { XCTAssertThrowsError(try store.delete(expected, chapter: 0)) }
            return "静谧的书店。"
        })
        try store.setHidden(true, translation: rows[0], chapter: 0)
        let archive = folder.appendingPathComponent("translations.zip")
        var records = try library.records(for: book); records.translationsVisible = false; try library.saveRecords(records, for: book)
        _ = try await BackupArchive.create(root: root, output: archive)
        let prepared = try await BackupArchive.prepare(archive, beside: root)
        try BackupArchive.activate(prepared, replacing: root)
        let restored = try ParagraphTranslationStore(library: LibraryStore(root: root), bookID: book.id).load(chapter: 0)
        XCTAssertEqual(restored[0].chinese, "静谧的书店。"); XCTAssertTrue(restored[0].hidden)
        XCTAssertEqual(try LibraryStore(root: root).records(for: book).translationsVisible, false)
        let cache = store.directory.appendingPathComponent("0.json")
        var malformed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
        malformed["bookID"] = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: malformed)
        try data.write(to: cache, options: .atomic)
        XCTAssertThrowsError(try store.load(chapter: 0)); XCTAssertThrowsError(try store.validateBackup())
        do { _ = try await store.generate(source: source, complete: { _ in "替换。" }); XCTFail("Corrupt caches must not be overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: cache), data)
    }
}

private actor TranslationReplies {
    private var replies: [String]
    private(set) var calls: [[ChatMessage]] = []
    init(_ replies: [String]) { self.replies = replies }
    func complete(_ messages: [ChatMessage]) throws -> String {
        calls.append(messages)
        guard !replies.isEmpty else { throw CancellationError() }
        return replies.removeFirst()
    }
}
