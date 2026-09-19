import XCTest
@testable import MoReadCore

final class CoreTests: XCTestCase {
    func testImportDetectsHeadingsAndPreservesText() throws {
        let text = "前言\n第一章 雨\n甲😀乙\n第二章 风\n后文\n"
        let chapters = try TextImporter.chapters(text)
        XCTAssertEqual(chapters.map(\.title), ["序章", "第一章 雨", "第二章 风"])
        XCTAssertEqual(chapters[1].text, "甲😀乙\n")
        XCTAssertEqual(chapters[2].text, "后文\n")
        let long = String(repeating: "甲😀", count: 7000)
        XCTAssertEqual(try TextImporter.chapters(long).map(\.text).joined(), long)
        XCTAssertThrowsError(try TextImporter.chapters("\n  "))
        XCTAssertThrowsError(try TextImporter.chapters(text, customRule: "["))
    }

    func testEncodingAndCorruptInput() throws {
        XCTAssertEqual(try TextImporter.decode(Data([0xFF, 0xFE, 0x2D, 0x4E, 0x87, 0x65])), "中文")
        XCTAssertEqual(try TextImporter.decode(Data("\u{FEFF}雨\r\n风\r雪".utf8)), "雨\n风\n雪")
        XCTAssertThrowsError(try TextImporter.decode(Data([0, 0, 0]), encoding: .utf8))
    }

    func testSpoilerBoundaryCannotSplitUnicodeOrLeakFutureText() {
        let chapter = Chapter(id: 0, title: "一", text: "甲😀乙秘密")
        let scope = ReadingScope(through: .init(chapter: 0, offset: 2))
        XCTAssertEqual(scope.readableText(chapter), "甲")
        XCTAssertEqual(scope.readableText(.init(id: 1, title: "二", text: "未读")), "")
        XCTAssertTrue(BookSearch.find("秘密", in: chapter, bookID: UUID(), scope: scope).isEmpty)
        XCTAssertFalse(scope.allows(chapter: 0, range: NSRange(location: -1, length: 1)))
        XCTAssertFalse(scope.allows(chapter: 0, range: NSRange(location: Int.max, length: 2)))
        XCTAssertEqual(scope.intersect(.wholeBook), scope)
        XCTAssertEqual(scope.intersect(.init(through: .init())), .init(through: .init()))
    }

    func testCitationMustMatchRevisionAndReadableRange() {
        let id = UUID()
        let chapter = Chapter(id: 0, title: "一", text: "甲乙丙丁")
        let passage = SourcePassage(bookID: id, chapter: chapter, offset: 1, text: "乙丙")
        XCTAssertTrue(passage.isValid(in: chapter, scope: .wholeBook))
        XCTAssertFalse(passage.isValid(in: chapter, scope: .init(through: .init(chapter: 0, offset: 2))))
        XCTAssertFalse(passage.isValid(in: .init(id: 0, title: "一", text: "甲乙丙戊"), scope: .wholeBook))
    }

    func testAtomicImportPersistenceAndRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let chapters = [Chapter(id: 0, title: "一", text: "正文😀")]
        var book = try store.importBook(title: "测试", chapters: chapters)
        book.record(position: .init(chapter: 0, offset: 1), visibleEnd: .init(chapter: 0, offset: 4))
        book.record(position: .init(), visibleEnd: .init(chapter: 0, offset: 1))
        XCTAssertEqual(book.readThrough.offset, 4)
        try store.save(book)
        let fresh = try LibraryStore(root: root)
        XCTAssertEqual(try fresh.books().first, book)
        XCTAssertEqual(try fresh.chapter(0, in: book), chapters[0])
        XCTAssertThrowsError(try fresh.importBook(title: "失败", chapters: chapters, original: root.appendingPathComponent("missing.txt")))
        XCTAssertEqual(try fresh.books().count, 1)
        try fresh.remove(book, permanently: false)
        XCTAssertEqual(try fresh.books().first?.removed, true)
        XCTAssertEqual(try fresh.chapter(0, in: book), chapters[0])
        try fresh.remove(book, permanently: true)
        XCTAssertTrue(try fresh.books().isEmpty)
    }
}
