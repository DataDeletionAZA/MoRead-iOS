import XCTest
import SwiftSoup
@testable import MoReadCore

final class EPUBTextEditingTests: XCTestCase {
    private func anchor(_ offset: Int, _ selector: String, chapter: Int = 0) throws -> EPUBAnchor {
        let json: [String: Any] = ["href": "/OPS/page.xhtml", "type": "application/xhtml+xml", "locations": ["cssSelector": selector]]
        return .init(chapter: chapter, offset: offset, locator: String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self))
    }
    func testInlineUnicodeRepeatedBlocksAndMultilineReplacementPreserveAssets() throws {
        let html = """
        <?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>书</title><link rel="stylesheet" href="book.css"/></head><body><p id="p">😀雨后 <em>书店</em>。<br/>😀雨后 <b>书店</b>。</p><svg viewBox="0 0 10 10"><linearGradient id="g"/></svg><img src="cover.jpg" alt="封面"/><p id="q">结尾</p></body></html>
        """
        let text = "😀雨后 书店。\n😀雨后 书店。\n结尾\n", source = Chapter(id: 0, title: "书", text: text)
        let second = (text as NSString).range(of: "😀雨后 书店。", options: .backwards)
        let anchors = try [anchor(0, "#p"), anchor(second.location, "#p"), anchor((text as NSString).range(of: "结尾").location, "#q")]
        let range = NSRange(location: second.location, length: "😀雨后 书店".utf16.count)
        let changed = try EPUBTextEditing.replace(html: html, chapter: source, anchors: anchors, range: range, with: "<新> & 😀\n第二行")
        let document = try SwiftSoup.parse(changed)
        XCTAssertEqual(try document.select("em").text(), "书店")
        XCTAssertEqual(try document.select("#p").text(), "😀雨后 书店。<新> & 😀 第二行。")
        XCTAssertEqual(try document.select("#q").text(), "结尾")
        XCTAssertEqual(try document.select("img").attr("src"), "cover.jpg")
        XCTAssertEqual(try document.select("link").attr("href"), "book.css")
        XCTAssertTrue(changed.contains("viewBox=\"0 0 10 10\"")); XCTAssertTrue(changed.contains("linearGradient"))
        XCTAssertFalse(changed.contains("<新>")); XCTAssertEqual(try document.select("br").size(), 2)
        XCTAssertThrowsError(try EPUBTextEditing.replace(html: html, chapter: source, anchors: anchors, range: NSRange(location: 1, length: 1), with: "x"))
        XCTAssertThrowsError(try EPUBTextEditing.replace(html: html, chapter: source, anchors: anchors, range: range, with: String(repeating: "x", count: 20_001)))
        XCTAssertThrowsError(try EPUBTextEditing.replace(html: html, chapter: source, anchors: anchors, range: range, with: "\0"))
        XCTAssertThrowsError(try EPUBTextEditing.replace(html: html.replacingOccurrences(of: "书店", with: "其他"), chapter: source, anchors: anchors, range: range, with: "x"))
    }
    func testCrossParagraphDeletionKeepsNonTextElementsAndCancellation() async throws {
        let html = "<html><body><p id='a'>甲<strong>乙</strong>丙</p><img src='x'/><p id='b'>丁<i>戊</i>己</p></body></html>"
        let source = Chapter(id: 0, title: "跨段", text: "甲乙丙\n丁戊己\n")
        let anchors = try [anchor(0, "#a"), anchor(4, "#b")], range = NSRange(location: 1, length: 5)
        let output = try EPUBTextEditing.replace(html: html, chapter: source, anchors: anchors, range: range, with: "")
        let doc = try SwiftSoup.parse(output)
        XCTAssertEqual(try doc.select("#a").text(), "甲"); XCTAssertEqual(try doc.select("#b").text(), "己")
        XCTAssertEqual(try doc.select("img").attr("src"), "x"); XCTAssertEqual(try doc.select("strong").size(), 1)
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try EPUBTextEditing.replace(html: html, chapter: source, anchors: anchors, range: range, with: "新") }
        do { _ = try await task.value; XCTFail("Cancelled edit completed") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testRepeatedTextEditUsesSelectedOccurrenceForRecordOffsets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root), source = Chapter(id: 0, title: "重复", text: "甲甲甲\n")
        var book = try store.importBook(title: "重复", chapters: [source], format: "epub")
        book.position.offset = 1; book.readThrough.offset = 2; try store.save(book)
        let records = try Data(contentsOf: store.directory(book.id).appendingPathComponent("records.json"))
        let passage = SourcePassage(bookID: book.id, chapter: source, offset: 0, text: "甲")
        let updated = Chapter(id: 0, title: source.title, text: "甲甲甲甲\n")
        let changed = try store.commitEPUBEdit(book: book, passage: passage, chapters: [updated], anchors: [anchor(0, "#p")], overrides: ["/OPS/page.xhtml": "<p id='p'>甲甲甲甲</p>"], originalRecords: records, originalOverrides: [:])
        XCTAssertEqual(changed.position.offset, 2); XCTAssertEqual(changed.readThrough.offset, 3)
        let before = try store.epubOverrides(book.id)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let selection = SourcePassage(bookID: changed.id, chapter: updated, offset: 0, text: "甲")
            return try store.commitEPUBEdit(book: changed, passage: selection, chapters: [source], anchors: [self.anchor(0, "#p")], overrides: ["/OPS/page.xhtml": "<p id='p'>甲甲甲</p>"], originalRecords: Data(contentsOf: store.directory(book.id).appendingPathComponent("records.json")), originalOverrides: before)
        }
        do { _ = try await task.value; XCTFail("Cancelled commit wrote a book") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try store.book(book.id), changed); XCTAssertEqual(try store.epubOverrides(book.id), before)
        _ = try store.clearBody(changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(book.id).appendingPathComponent("epub-overrides.json").path))
    }
    func testAtomicEPUBCommitMapsRecordsRejectsStaleInputAndSurvivesBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root), source = Chapter(id: 0, title: "修订", text: "😀书店\n结尾\n")
        let original = root.appendingPathComponent("input.epub"); try Data("original epub".utf8).write(to: original)
        var book = try store.importBook(title: "EPUB修订", chapters: [source], original: original, format: "epub", readingMap: JSONEncoder().encode([anchor(0, "#p"), anchor(5, "#q")]))
        book.position.offset = 5; book.readThrough.offset = 7; try store.save(book)
        var records = BookRecords()
        records.bookmarks = [.init(position: .init(chapter: 0, offset: 5), label: "结尾", locator: Data("old".utf8))]
        records.annotations = [.init(passage: .init(bookID: book.id, chapter: source, offset: 2, text: "书店"), note: "旧文"), .init(passage: .init(bookID: book.id, chapter: source, offset: 5, text: "结尾"), note: "不变")]
        try store.saveRecords(records, for: book)
        let recordData = try Data(contentsOf: store.directory(book.id).appendingPathComponent("records.json"))
        let updated = Chapter(id: 0, title: source.title, text: "😀新的书屋\n结尾\n"), anchors = try [anchor(0, "#p"), anchor(7, "#q")]
        let overrides = ["/OPS/page.xhtml": "<html><body><p id='p'>😀新的书屋</p><p id='q'>结尾</p></body></html>"]
        let changed = try store.commitEPUBEdit(book: book, passage: records.annotations[0].passage, chapters: [updated], anchors: anchors, overrides: overrides, originalRecords: recordData, originalOverrides: [:])
        XCTAssertEqual(changed.position.offset, 7); XCTAssertEqual(changed.readThrough.offset, 9)
        let saved = try store.records(for: changed)
        XCTAssertEqual(saved.bookmarks[0].position.offset, 7); XCTAssertNotEqual(saved.bookmarks[0].locator, records.bookmarks[0].locator)
        XCTAssertFalse(saved.annotations[0].passage.isValid(in: updated, scope: .wholeBook))
        XCTAssertTrue(saved.annotations[1].passage.isValid(in: updated, scope: .wholeBook)); XCTAssertNotNil(saved.annotations[1].passage.epubLocator)
        XCTAssertEqual(try store.epubOverrides(book.id), overrides)
        XCTAssertEqual(try Data(contentsOf: store.directory(book.id).appendingPathComponent("original.epub")), Data("original epub".utf8))
        XCTAssertThrowsError(try store.commitEPUBEdit(book: book, passage: records.annotations[0].passage, chapters: [updated], anchors: anchors, overrides: overrides, originalRecords: recordData, originalOverrides: [:]))
        XCTAssertThrowsError(try LibraryStore.validateEPUBOverrides(["https://example.org/file": "x"]))
        let archive = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        _ = try await BackupArchive.create(root: root, output: archive)
        let restored = try await BackupArchive.prepare(archive, beside: root)
        defer { try? FileManager.default.removeItem(at: restored.directory) }
        let copy = try LibraryStore(root: restored.directory)
        XCTAssertEqual(try copy.epubOverrides(book.id), overrides); XCTAssertEqual(try copy.chapter(0, in: changed), updated)
    }
}
