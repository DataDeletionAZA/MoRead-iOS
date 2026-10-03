import XCTest
@testable import MoReadCore

final class ChineseConversionTests: XCTestCase {
    // Oracle outputs: OpenccJava v1.4.2, the conversion library used by Android MoRead.
    func testMatchesAndroidConverterForRegionalPhrasesAndUnicode() throws {
        struct Example: Decodable { let source: String; let s2twp: String; let tw2sp: String }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ChineseConversion", withExtension: "json"))
        let rows = try JSONDecoder().decode([Example].self, from: Data(contentsOf: url))
        XCTAssertEqual(rows.count, 277)
        for row in rows {
            for (mode, expected) in [(ChineseConversionMode.s2twp, row.s2twp), (.tw2sp, row.tw2sp)] {
                let value = try ChineseTextConversion(row.source, mode: mode)
                XCTAssertEqual(value.text, expected, "\(mode): \(row.source)")
                XCTAssertEqual(value.source, row.source)
                XCTAssertEqual(value.displayOffset(forSource: row.source.utf16.count), expected.utf16.count)
                XCTAssertEqual(value.sourceOffset(forDisplay: expected.utf16.count), row.source.utf16.count)
                XCTAssertEqual(value.sourceRange(forDisplay: NSRange(location: 0, length: expected.utf16.count)), NSRange(location: 0, length: row.source.utf16.count))
            }
        }
    }
    func testSourceMappingKeepsFullChangedPhrasesAndRepeatedOccurrences() throws {
        let source = "😀主機板。主機板x", value = try ChineseTextConversion(source, mode: .tw2sp)
        XCTAssertEqual(value.text, "😀主板。主板x")
        XCTAssertEqual(value.sourceRange(forDisplay: NSRange(location: 2, length: 1)), NSRange(location: 2, length: 3))
        XCTAssertEqual(value.sourceRange(forDisplay: NSRange(location: 5, length: 2)), NSRange(location: 6, length: 3))
        XCTAssertEqual(value.displayOffset(forSource: 6), 5)
        XCTAssertEqual(value.displayOffset(forSource: 7), 5)
        XCTAssertEqual(value.displayOffset(forSource: 7, trailing: true), 7)
        XCTAssertEqual(value.sourceOffset(forDisplay: 1), 0)
        XCTAssertNil(value.sourceRange(forDisplay: NSRange(location: 0, length: 999)))
        let off = try ChineseTextConversion(source, mode: .off)
        XCTAssertEqual(off.text, source); XCTAssertEqual(off.displayOffset(forSource: 6), 6)
    }
    func testConvertedPresentationMapsTranslationsHighlightsAndRestoresOriginal() throws {
        let source = "😀主機板 x\nA computer waits.\n主機板。"
        let paragraph = try XCTUnwrap(EnglishParagraph.paragraphs(in: source).first { $0.text == "A computer waits." })
        let row = ParagraphTranslation(paragraph: paragraph, chinese: "滑鼠和主機板。")
        let original = TranslatedText(source: source, translations: [row])
        let displayed = try original.converted(.tw2sp)
        XCTAssertEqual(displayed.text, "😀主板 x\nA computer waits.\n鼠标和主板。\n主板。")
        XCTAssertEqual(displayed.source, source)
        let translated = try XCTUnwrap(displayed.insertions.first)
        XCTAssertEqual((displayed.text as NSString).substring(with: translated.textRange), "鼠标和主板。")
        XCTAssertTrue(displayed.containsTranslation(in: translated.textRange))
        XCTAssertEqual(displayed.sourceRange(forDisplay: translated.textRange), NSRange(location: paragraph.start, length: paragraph.text.utf16.count))
        let last = (source as NSString).range(of: "主機板", options: .backwards)
        let highlights = displayed.displayRanges(forSource: last)
        XCTAssertEqual(highlights.count, 1); XCTAssertEqual((displayed.text as NSString).substring(with: highlights[0]), "主板")
        XCTAssertEqual(displayed.sourceRange(forDisplay: highlights[0]), last)
        XCTAssertEqual(displayed.displayOffset(forSource: last.location), highlights[0].location)
        XCTAssertEqual(try displayed.converted(.off).text, original.text)
        XCTAssertEqual(try displayed.converted(.off).insertions, original.insertions)
    }
    func testPerBookSettingAndSourceRecordsSurviveBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root), chapter = Chapter(id: 0, title: "資料庫", text: "😀主機板和滑鼠。")
        var book = try store.importBook(title: "转换", chapters: [chapter])
        let other = try store.importBook(title: "原文", chapters: [chapter])
        let sourceData = try Data(contentsOf: store.directory(book.id).appendingPathComponent("chapter-0.json"))
        book.chineseConversion = .tw2sp; book.position.offset = 5; book.readThrough.offset = 8; try store.save(book)
        XCTAssertNil(try store.book(other.id).chineseConversion)
        XCTAssertEqual(try Data(contentsOf: store.directory(book.id).appendingPathComponent("chapter-0.json")), sourceData)
        let archive = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        _ = try await BackupArchive.create(root: root, output: archive)
        let prepared = try await BackupArchive.prepare(archive, beside: root)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let restored = try LibraryStore(root: prepared.directory).book(book.id)
        XCTAssertEqual(restored, book); XCTAssertEqual(restored.chapters[0].revision, chapter.revision)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
        json.removeValue(forKey: "chineseConversion")
        XCTAssertNil(try JSONDecoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: json)).chineseConversion)
    }
    func testSearchMatchesDisplayedVocabularyAndKeepsSourceScope() throws {
        let chapter = Chapter(id: 0, title: "原文", text: "😀主機板和滑鼠。\n後文的主機板。"), id = UUID()
        let scope = ReadingScope(through: .init(chapter: 0, offset: 10))
        let found = try BookSearch.find("主板", in: chapter, bookID: id, scope: scope, conversion: .tw2sp)
        XCTAssertEqual(found.count, 1); XCTAssertEqual(found[0].text, "😀主機板和滑鼠。\n")
        XCTAssertTrue(found[0].isValid(in: chapter, scope: scope)); XCTAssertFalse(found[0].text.contains("後文"))
        XCTAssertEqual(try BookSearch.find("主機板", in: chapter, bookID: id, scope: scope, conversion: .tw2sp), found)
        XCTAssertEqual(try BookSearch.find("主板", in: chapter, bookID: id, scope: scope, conversion: .off), [])
    }
    func testCancellationAndLargeChapter() async throws {
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try ChineseTextConversion("主機板", mode: .tw2sp) }
        do { _ = try await task.value; XCTFail("Cancelled conversion completed") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let source = String(repeating: "主機板😀滑鼠。", count: 10_000)
        let value = try ChineseTextConversion(source, mode: .tw2sp)
        XCTAssertEqual(value.text, String(repeating: "主板😀鼠标。", count: 10_000))
        XCTAssertEqual(value.sourceOffset(forDisplay: value.text.utf16.count), source.utf16.count)
    }
}
