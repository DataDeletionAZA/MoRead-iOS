import XCTest
@testable import MoReadCore

final class CoreTests: XCTestCase {
    func testReaderTypographyRoundTripAndBounds() throws {
        var value = ReaderTypography()
        value.font = .serif; value.weight = 650; value.firstLineIndent = 2
        value.marginLeft = 800; value.marginTop = -.infinity
        value.letterSpacing = .nan; value.paragraphSpacing = -12
        value.publisherStyles = false; value.justified = true
        let restored = ReaderTypography(data: value.encoded())
        XCTAssertEqual(restored.font, .serif); XCTAssertEqual(restored.weight, 600)
        XCTAssertEqual(restored.firstLineIndent, 2); XCTAssertEqual(restored.marginLeft, 64)
        XCTAssertEqual(restored.marginTop, 24); XCTAssertEqual(restored.letterSpacing, 0)
        XCTAssertEqual(restored.paragraphSpacing, 0); XCTAssertTrue(restored.justified)
        XCTAssertFalse(restored.publisherStyles)
        XCTAssertEqual(ReaderTypography(data: Data("invalid".utf8)), ReaderTypography())
    }
    func testManualEncodingAndChapterRulesProduceReviewableText() throws {
        let metadata = TextImporter.metadata(fileName: "《旧标题》作者：旧作者著.txt", text: "书名：灯塔\n作者：林遥\n第一章\n正文")
        XCTAssertEqual(metadata.title, "灯塔"); XCTAssertEqual(metadata.author, "林遥")
        XCTAssertEqual(TextImporter.metadata(fileName: "【林遥】灯塔.txt", text: "正文").author, "林遥")
        XCTAssertEqual(TextImporter.metadata(fileName: "灯塔 by 林遥.txt", text: "正文").title, "灯塔")
        XCTAssertEqual(TextImporter.metadata(fileName: "《灯塔》完结.txt", text: "正文").author, "")
        let decoded = try TextImporter.decoded(Data([0xA4, 0xA4, 0xA4, 0xE5]), encoding: TextEncoding.big5.encoding)
        XCTAssertEqual(decoded.text, "中文"); XCTAssertEqual(decoded.encoding, TextEncoding.big5.encoding)
        XCTAssertEqual(try TextImporter.decode(Data([0xD6, 0xD0, 0xCE, 0xC4]), encoding: TextEncoding.gb18030.encoding), "中文")
        let chapters = try TextImporter.chapters("开场\n第一幕 灯塔\n正文😀\n第二幕 海边\n结尾", customRule: "^第[一二]幕.*$")
        XCTAssertEqual(chapters.map(\.title), ["序章", "第一幕 灯塔", "第二幕 海边"])
        XCTAssertEqual(chapters.map(\.text), ["开场\n", "正文😀\n", "结尾"])
        XCTAssertEqual(try TextImporter.chapters("唯一标题\n正文", customRule: "^唯一标题$").first?.text, "正文")
        XCTAssertThrowsError(try TextImporter.chapters("正文", customRule: "^章节$"))
        XCTAssertThrowsError(try TextImporter.chapters("正文", customRule: "^"))
        let started = Date()
        XCTAssertThrowsError(try TextImporter.chapters(String(repeating: "a", count: 70) + "!", customRule: "^(a+)+$"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
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

    func testChapterWordsInsideProseDoNotBecomeHeadings() throws {
        let body = String(repeating: "雨停后，她在第一页写下了自己的名字。\n", count: 12)
        let chapters = try TextImporter.chapters("　第一章 书店\n" + body + "  第二章 来信\n一封信。\n")
        XCTAssertEqual(chapters.map(\.title), ["第一章 书店", "第二章 来信"])
        XCTAssertEqual(chapters.map(\.text), [body, "一封信。\n"])
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
