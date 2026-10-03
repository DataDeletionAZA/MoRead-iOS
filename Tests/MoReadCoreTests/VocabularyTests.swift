import XCTest
@testable import MoReadCore

final class VocabularyTests: XCTestCase {
    func testSaveReplaceEditRestartBackupAndInvalidRecords() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("library")
        _ = try LibraryStore(root: root)
        let store = VocabularyStore(root: root)
        XCTAssertTrue(try store.words().isEmpty)
        let chapter = Chapter(id: 0, title: "Example", text: "He doesn’t know.")
        let source = SourcePassage(bookID: UUID(), chapter: chapter, offset: 3, text: "doesn’t")
        let first = try store.saveDefinition(word: "  DOESN’T  ", definition: " 不 ", source: source, context: chapter.text, gloss: "不", phonetic: "/dʌznt/")
        XCTAssertEqual(first.word, "doesn't"); XCTAssertEqual(first.definition, "不")
        var learned = first; learned.learned = true
        try store.update(learned, replacing: first)
        XCTAssertThrowsError(try store.update(first, replacing: first))
        let updated = try store.saveDefinition(word: "doesn't", definition: "并不")
        XCTAssertTrue(updated.learned); XCTAssertEqual(updated.source, source); XCTAssertEqual(updated.createdAt, first.createdAt); XCTAssertEqual(updated.context, chapter.text)
        XCTAssertEqual(updated.gloss, ""); XCTAssertEqual(updated.phonetic, "")
        XCTAssertEqual(try store.words().count, 1)
        var edited = updated; edited.definition = "不；并不"; edited.gloss = "并不"; edited.phonetic = "/dʌznt/"
        try store.update(edited, replacing: updated)
        XCTAssertEqual(try VocabularyStore(root: root).words(), [edited])
        XCTAssertTrue(try XCTUnwrap(edited.source).isValid(in: chapter, scope: .wholeBook))
        XCTAssertFalse(try XCTUnwrap(edited.source).isValid(in: Chapter(id: 0, title: "Changed", text: "Other text"), scope: .wholeBook))
        for word in ["", "\n", "--", "bad\u{0}word", String(repeating: "x", count: 81)] {
            XCTAssertThrowsError(try store.saveDefinition(word: word, definition: "meaning"))
        }
        XCTAssertThrowsError(try store.saveDefinition(word: "valid", definition: "  "))
        var tooLong = edited; tooLong.gloss = String(repeating: "字", count: 25)
        XCTAssertThrowsError(try store.update(tooLong, replacing: edited))
        XCTAssertEqual(try store.words(), [edited])
        let archive = temporary.appendingPathComponent("vocabulary.zip")
        _ = try await BackupArchive.create(root: root, output: archive)
        try store.remove(edited); XCTAssertTrue(try store.words().isEmpty)
        let prepared = try await BackupArchive.prepare(archive, beside: root)
        try BackupArchive.activate(prepared, replacing: root)
        XCTAssertEqual(try VocabularyStore(root: root).words(), [edited])
        try JSONEncoder().encode([edited, edited]).write(to: root.appendingPathComponent("vocabulary.json"))
        XCTAssertThrowsError(try store.words())
        let corrupt = temporary.appendingPathComponent("corrupt.zip")
        _ = try await BackupArchive.create(root: root, output: corrupt)
        do { _ = try await BackupArchive.prepare(corrupt, beside: root); XCTFail("Duplicate vocabulary restored") } catch { }
    }
}
