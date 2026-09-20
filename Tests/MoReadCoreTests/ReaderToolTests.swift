import XCTest
@testable import MoReadCore

final class ReaderToolTests: XCTestCase {
    func testReadToolsRespectFrozenScopeNotesAndOtherBooks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let chapters = [Chapter(id: 0, title: "开头", text: "灯塔在海边。"), Chapter(id: 1, title: "相遇", text: "主角走过。秘密尚未发生。"), Chapter(id: 2, title: "未读秘密标题", text: "幕后真相")]
        var book = try store.importBook(title: "灯塔", chapters: chapters); book.readThrough = .init(chapter: 1, offset: 5); try store.save(book)
        let other = try store.importBook(title: "另一本书", chapters: [.init(id: 0, title: "一", text: "另一段正文")])
        func run(_ name: String, _ args: String = "{}") throws -> ReaderToolOutput { try ReaderTools.execute(.init(id: UUID().uuidString, name: name, arguments: args), currentBook: book.id, books: [book, other], store: store) }
        let toc = try run("list_chapters").text
        XCTAssertTrue(toc.contains("相遇")); XCTAssertFalse(toc.contains("未读秘密标题"))
        let read = try run("read_book_section", #"{"from_chapter":1,"to_chapter":2}"#)
        XCTAssertEqual(read.passages.count, 2); XCTAssertEqual(read.passages.last?.text, "主角走过。")
        XCTAssertFalse(read.passages.contains { $0.text.contains("秘密") })
        XCTAssertThrowsError(try run("read_book_section", #"{"from_chapter":3}"#))
        XCTAssertThrowsError(try run("read_book_section", #"{"from_chapter":true}"#))
        XCTAssertThrowsError(try run("read_book_section", #"{"from_chapter":1,"start_char":999999}"#))
        XCTAssertThrowsError(try run("get_reading_progress", "{\"book_id\":\"\(other.id)\"}"))
        XCTAssertTrue(try run("grep_book", #"{"query":"秘密"}"#).passages.isEmpty)
        XCTAssertEqual(try run("grep_book", #"{"query":"灯塔"}"#).passages.first?.text, "灯塔在海边。")
        var records = BookRecords()
        records.annotations = [.init(passage: .init(bookID: book.id, chapter: chapters[0], offset: 0, text: "灯塔"), note: "想再看看海边"), .init(passage: .init(bookID: book.id, chapter: chapters[2], offset: 0, text: "幕后真相"), note: "不能泄漏的笔记")]
        try store.saveRecords(records, for: book)
        XCTAssertTrue(try run("list_annotations").text.contains("想再看看海边")); XCTAssertFalse(try run("list_annotations").text.contains("不能泄漏"))
        let original = book; book.readThrough = .init(chapter: 0, offset: 1); try store.save(book)
        XCTAssertThrowsError(try ReaderTools.execute(.init(id: "stale", name: "list_chapters", arguments: "{}"), currentBook: original.id, books: [original], store: store))
    }
    func testLongSectionContinuationAndToolSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root), chapter = Chapter(id: 0, title: "长章节", text: "a" + String(repeating: "🌙", count: 1000))
        var book = try store.importBook(title: "长书", chapters: [chapter]); book.readThrough = .init(chapter: 0, offset: chapter.text.utf16.count); try store.save(book)
        let first = try ReaderTools.execute(.init(id: "first", name: "read_book_section", arguments: #"{"from_chapter":1,"max_chars":1000}"#), currentBook: book.id, books: [book], store: store)
        XCTAssertEqual(first.passages[0].text.utf16.count, 999); XCTAssertTrue(first.text.contains("start_char=999"))
        let next = try ReaderTools.execute(.init(id: "next", name: "read_book_section", arguments: #"{"from_chapter":1,"max_chars":1000,"start_char":999}"#), currentBook: book.id, books: [book], store: store)
        XCTAssertEqual(next.passages[0].offset, 999); XCTAssertFalse(next.passages[0].text.contains("�"))
        XCTAssertEqual(try ReaderTools.specs(currentBook: book.id, memory: false, enabled: ["read_book_section", "recall_memory", "find_books"]).map(\.name), ["read_book_section"])
        XCTAssertTrue(try ReaderTools.specs(currentBook: nil, memory: true).contains { $0.name == "find_books" })
        XCTAssertTrue(try ReaderTools.specs(currentBook: book.id, memory: true, enabled: []).isEmpty)
        let global = try ReaderTools.specs(currentBook: nil, memory: false).first { $0.name == "read_book_section" }!
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: global.parameters) as? [String: Any])
        XCTAssertTrue((schema["required"] as? [String] ?? []).contains("book_id"))
    }
}
