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
    func testDateGroupsTrimmedSearchPreviewAndContext() throws {
        let zone = TimeZone(identifier: "Asia/Shanghai")!, formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-09-27T09:00:00+08:00")!
        func word(_ name: String, _ date: String, learned: Bool = false) throws -> VocabularyWord {
            var value = VocabularyWord(word: name, definition: "释义", gloss: name == "early" ? "意外之喜" : "")
            value.learned = learned
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            object["createdAt"] = try XCTUnwrap(formatter.date(from: date)).timeIntervalSinceReferenceDate
            return try JSONDecoder().decode(VocabularyWord.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let words = try [word("august", "2026-08-30T12:00:00+08:00"), word("late", "2026-09-26T23:59:00+08:00", learned: true), word("early", "2026-09-27T00:01:00+08:00"), word("week", "2026-09-21T10:00:00+08:00"), word("september", "2026-09-20T08:00:00+08:00"), word("lastyear", "2025-12-31T20:00:00+08:00"), word("future", "2026-09-28T08:00:00+08:00")]
        let groups = VocabularyGroup.groups(words, query: "", filter: .all, now: now, timeZone: zone)
        XCTAssertEqual(groups.map(\.period), [.today, .yesterday, .week, .month(2026, 9), .month(2026, 8), .month(2025, 12)])
        XCTAssertEqual(groups.first?.words.map(\.word), ["future", "early"])
        XCTAssertEqual(VocabularyGroup.groups(words, query: "  之喜  ", filter: .learning, now: now, timeZone: zone).flatMap(\.words).map(\.word), ["early"])
        XCTAssertEqual(VocabularyGroup.groups(words, query: "LATE", filter: .learned, now: now, timeZone: zone).flatMap(\.words).map(\.word), ["late"])
        XCTAssertTrue(VocabularyGroup.groups(words, query: "LATE", filter: .learning, now: now, timeZone: zone).isEmpty)
        let sample = VocabularyWord(word: "serendipity", definition: "## Serendipity\n\n**n.** 不期而遇的美好\n- 意外发现珍贵事物的机缘\n> `a happy accident`", gloss: "意外之喜")
        XCTAssertEqual(sample.preview, "n. 不期而遇的美好 意外发现珍贵事物的机缘 a happy accident")
        XCTAssertEqual(VocabularyWord(word: "故", definition: "旧的", gloss: "旧的").preview, "")
        XCTAssertEqual(VocabularyWord(word: "x", definition: String(repeating: "👩🏽‍💻", count: 250)).preview.count, 200)
        let context = "A Serendipity by serendipity"
        XCTAssertEqual(String(context[try XCTUnwrap(sample.contextMatch(in: context))]), "Serendipity")
        let apostrophe = VocabularyWord(word: "doesn't", definition: "不"), quote = "He doesn’t know."
        XCTAssertEqual(String(quote[try XCTUnwrap(apostrophe.contextMatch(in: quote))]), "doesn’t")
        XCTAssertNil(sample.contextMatch(in: "nothing here"))
    }
    func testUndoPreservesOriginalMetadataAndRejectsLaterWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try LibraryStore(root: root)
        let store = VocabularyStore(root: root)
        let original = try store.saveDefinition(word: "word", definition: "释义", context: "A word.", gloss: "词", phonetic: "/wɜːd/")
        var learned = original; learned.learned = true
        try store.update(learned, replacing: original); try store.undo(original, after: learned)
        XCTAssertEqual(try store.words(), [original])
        var edited = original; edited.gloss = "单词"
        try store.update(edited, replacing: original)
        _ = try store.saveDefinition(word: "another", definition: "另一个词")
        try store.undo(original, after: edited)
        XCTAssertEqual(try store.words().first { $0.word == "word" }, original)
        try store.remove(original); try store.undo(original, after: nil)
        XCTAssertEqual(try VocabularyStore(root: root).words().first { $0.word == "word" }, original)
        try store.update(learned, replacing: original)
        let latest = try store.saveDefinition(word: "word", definition: "后来更新的释义")
        XCTAssertThrowsError(try store.undo(original, after: learned))
        XCTAssertEqual(try store.words().first { $0.word == "word" }, latest)
        try store.remove(latest)
        let replaced = try store.saveDefinition(word: "word", definition: "重新收藏")
        XCTAssertThrowsError(try store.undo(latest, after: nil))
        XCTAssertEqual(try store.words().first { $0.word == "word" }, replaced)
        XCTAssertEqual(try store.words().count, 2)
    }

}
