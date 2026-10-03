import XCTest
@testable import MoReadCore

final class TextCleanupTests: XCTestCase {
    private func rule(_ pattern: String, _ replacement: String = "", regex: Bool = true, listen: Bool = false) -> TextReplacementRule {
        var rule = TextReplacementRule(); rule.pattern = pattern; rule.replacement = replacement; rule.isRegex = regex; rule.forListeningOnly = listen
        return rule
    }
    func testSequentialRulesLiteralsCapturesAndListeningIsolation() throws {
        let source = "广告：加群123\n雨停了😀。\nfooBAR"
        var replace = rule("(foo)(bar)", "$2/$1/$0/$12/\\$1/$9"); replace.ignoreCase = true
        let rules = [rule("^广告：.*\\n"), replace, rule("雨", "雪", regex: false, listen: true)]
        let result = try TextCleanup.apply(source, rules: rules)
        XCTAssertEqual(result.text, "雨停了😀。\nBAR/foo/fooBAR/foo2/$1/")
        XCTAssertEqual(result.matches, 2)
        XCTAssertEqual(try TextCleanup.apply(source, rules: rules, forListening: true).text, "广告：加群123\n雪停了😀。\nfooBAR")
        XCTAssertEqual(try TextCleanup.apply("[广告]", rules: [rule("[广告]", "$1\\end", regex: false)]).text, "$1\\end")
        var disabled = rule("雨", "雪"); disabled.enabled = false
        XCTAssertEqual(try TextCleanup.apply(source, rules: [disabled]).text, source)
    }
    func testPositionsUnchangedQuotesAndUTF16Boundaries() throws {
        let source = "广告\n😀雨后的书店。"
        let result = try TextCleanup.apply(source, rules: [rule("^广告\\n"), rule("雨后", "雨停以后", regex: false)])
        XCTAssertEqual(result.text, "😀雨停以后的书店。")
        XCTAssertEqual(result.mapPosition(0), 0)
        XCTAssertEqual(result.mapPosition(3), 0)
        XCTAssertEqual(result.mapPosition(4), 0)
        XCTAssertEqual(result.mapPosition(5), 2)
        XCTAssertEqual(result.mapPosition(Int.max), result.text.utf16.count)
        let quote = (source as NSString).range(of: "书店")
        let mapped = try XCTUnwrap(result.mapUnchangedRange(quote))
        XCTAssertEqual((result.text as NSString).substring(with: mapped), "书店")
        XCTAssertNil(result.mapUnchangedRange((source as NSString).range(of: "雨后")))
        XCTAssertNil(result.mapUnchangedRange(NSRange(location: Int.max - 1, length: 1)))
        let insertion = try TextCleanup.apply("雨后的书店", rules: [rule("(?=书店)", "旧"), rule("(?<=书店)", "！")])
        XCTAssertEqual(insertion.text, "雨后的旧书店！")
        XCTAssertEqual(insertion.mapPosition(3), 3)
        XCTAssertEqual(insertion.mapUnchangedRange(NSRange(location: 3, length: 2)), NSRange(location: 4, length: 2))
        XCTAssertNil(insertion.mapUnchangedRange(NSRange(location: 2, length: 3)))
    }
    func testBoundedRegexAndExpansionLeaveInputUntouched() throws {
        let source = String(repeating: "a", count: 5000) + "!"
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try TextCleanup.apply(source, rules: [rule("(a+)+$")]))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        XCTAssertThrowsError(try TextCleanup.apply(String(repeating: "x", count: 100_000), rules: [rule("(x+)", String(repeating: "$1", count: 1000))]))
        XCTAssertThrowsError(try TextCleanup.apply("正文", rules: [rule("[")]))
        XCTAssertEqual(source.count, 5001)
    }
    func testRulesPersistWithBackupAndRejectInvalidUpdates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("library")
        _ = try LibraryStore(root: root)
        let store = TextReplacementStore(root: root)
        let rules = [rule("广告"), rule("ABC", "字母", regex: false, listen: true)]
        try store.save(rules)
        XCTAssertEqual(try store.rules(), rules)
        XCTAssertThrowsError(try store.save([rules[0], rules[0]]))
        XCTAssertThrowsError(try store.save([rule("[")]))
        XCTAssertEqual(try store.rules(), rules)
        let archive = directory.appendingPathComponent("rules.zip")
        _ = try await BackupArchive.create(root: root, output: archive)
        try store.save([])
        let prepared = try await BackupArchive.prepare(archive, beside: root)
        try BackupArchive.activate(prepared, replacing: root)
        XCTAssertEqual(try store.rules(), rules)
    }
    func testBookCleanupPreservesRecordsAndRejectsStalePreviews() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let first = Chapter(id: 0, title: "第一章", text: "广告\n😀雨后的书店。")
        let second = Chapter(id: 1, title: "第二章", text: "广告\n街灯亮了。")
        var book = try store.importBook(title: "雨后", chapters: [first, second])
        let quote = (first.text as NSString).range(of: "书店")
        book.position = .init(chapter: 0, offset: quote.location)
        book.readThrough = .init(chapter: 1, offset: second.text.utf16.count)
        try store.save(book)
        var records = BookRecords()
        records.readingSeconds = ["2026-10-03": 123]
        records.bookmarks = [.init(position: book.position, label: "重读")]
        records.annotations = [Annotation(passage: .init(bookID: book.id, chapter: first, offset: quote.location, text: "书店"), note: "保留的想法"), Annotation(passage: .init(bookID: book.id, chapter: first, offset: 5, text: "雨后"), note: "旧引文")]
        try store.saveRecords(records, for: book)
        let original = store.directory(book.id).appendingPathComponent("original.txt")
        try Data("原始文件".utf8).write(to: original)
        let rules = [rule("^广告\\n"), rule("雨后", "雨停以后", regex: false)]
        let preview = try store.previewTextCleanup(bookID: book.id, rules: rules)
        XCTAssertEqual(preview.changedChapters, 2)
        XCTAssertEqual(preview.matches, 3)
        XCTAssertEqual(preview.detachedAnnotations, 1)
        XCTAssertEqual(try store.chapter(0, in: book).text, first.text)
        records.bookmarks.append(.init(position: .init(chapter: 1, offset: 3), label: "新书签"))
        try store.saveRecords(records, for: book)
        XCTAssertThrowsError(try store.applyTextCleanup(preview))
        XCTAssertEqual(try store.chapter(0, in: book).text, first.text)
        let refreshed = try store.previewTextCleanup(bookID: book.id, rules: rules)
        let updated = try store.applyTextCleanup(refreshed)
        let chapter = try store.chapter(0, in: updated), saved = try store.records(for: updated)
        XCTAssertEqual(chapter.text, "😀雨停以后的书店。")
        XCTAssertEqual(updated.position.offset, 7)
        XCTAssertEqual(updated.readThrough, .init(chapter: 1, offset: "街灯亮了。".utf16.count))
        XCTAssertEqual(saved.bookmarks.map(\.position.offset), [7, 0])
        XCTAssertTrue(saved.annotations[0].passage.isValid(in: chapter, scope: .wholeBook))
        XCTAssertFalse(saved.annotations[1].passage.isValid(in: chapter, scope: .wholeBook))
        XCTAssertEqual(saved.annotations.map(\.note), ["保留的想法", "旧引文"])
        XCTAssertEqual(saved.readingSeconds, records.readingSeconds)
        XCTAssertEqual(try Data(contentsOf: original), Data("原始文件".utf8))
        XCTAssertThrowsError(try store.applyTextCleanup(refreshed))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".text-edit-") })
        let archive = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        _ = try await BackupArchive.create(root: root, output: archive)
        let prepared = try await BackupArchive.prepare(archive, beside: root)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let restored = try LibraryStore(root: prepared.directory)
        XCTAssertEqual(try restored.chapter(0, in: restored.book(book.id)).text, chapter.text)
    }

    func testFailedOrCancelledBookOperationKeepsOriginalFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let book = try store.importBook(title: "失败保护", chapters: [Chapter(id: 0, title: "一", text: "广告正文"), Chapter(id: 1, title: "二", text: String(repeating: "a", count: 5000) + "!")])
        let directory = store.directory(book.id)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let before = try names.map { try Data(contentsOf: directory.appendingPathComponent($0)) }
        XCTAssertThrowsError(try store.previewTextCleanup(bookID: book.id, rules: [rule("广告"), rule("(a+)+$")]))
        let preview = try store.previewTextCleanup(bookID: book.id, rules: [rule("广告")])
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try LibraryStore(root: root).applyTextCleanup(preview)
        }
        do { _ = try await worker.value; XCTFail("Cancelled cleanup was applied") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try names.map { try Data(contentsOf: directory.appendingPathComponent($0)) }, before)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".text-edit-") })
    }

}
