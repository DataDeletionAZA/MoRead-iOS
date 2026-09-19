import XCTest
@testable import MoReadCore

final class ProactiveAnnotationTests: XCTestCase {
    func testLimitsRetriesAndLegacyRecords() throws {
        var policy = ProactiveSettings(); policy.maximumPerChapter = 100; policy.minimumPerChapter = 200; policy.dailyMaximum = -9
        let id = UUID(); policy.characterIDs = [id, id]
        let valid = policy.validated()
        XCTAssertEqual(valid.maximumPerChapter, 10); XCTAssertEqual(valid.minimumPerChapter, 10); XCTAssertEqual(valid.dailyMaximum, 1)
        XCTAssertEqual(valid.characterIDs, [id])
        policy.maximumPerChapter = -1; policy.dailyMaximum = -1
        XCTAssertEqual(policy.validated().maximumPerChapter, -1); XCTAssertEqual(policy.validated().dailyMaximum, -1)
        var attempt = ProactiveAttempt(); XCTAssertTrue(attempt.canStart())
        attempt.count = 1; attempt.updatedAt = Date()
        XCTAssertFalse(attempt.canStart(at: attempt.updatedAt.addingTimeInterval(599)))
        XCTAssertTrue(attempt.canStart(at: attempt.updatedAt.addingTimeInterval(601)))
        attempt.completed = true; XCTAssertFalse(attempt.canStart(at: attempt.updatedAt.addingTimeInterval(601)))
        attempt.completed = false; attempt.count = 2; XCTAssertFalse(attempt.canStart(at: attempt.updatedAt.addingTimeInterval(601)))
        attempt.count = -1; XCTAssertFalse(attempt.canStart(at: attempt.updatedAt.addingTimeInterval(601)))
        let old = try JSONDecoder().decode(BookRecords.self, from: Data(#"{"annotations":[],"bookmarks":[],"readingSeconds":{}}"#.utf8))
        XCTAssertNil(old.annotationAttempts)
    }

    func testParagraphsPreserveUnicodeOffsetsAndNeverSendFutureText() throws {
        let first = String(repeating: "她在灯下读着来信，窗外传来雨声。", count: 5)
        let long = String(repeating: "👩🏽‍🚀看着星空。", count: 400)
        let future = "后面的秘密绝不能提前出现在这一段评中。"
        let chapter = Chapter(id: 0, title: "雨后", text: "第一章 雨后\n  " + first + "  \n" + long + "\n" + future)
        let paragraphs = ProactiveAnnotations.paragraphs(in: chapter.text)
        XCTAssertEqual((chapter.text as NSString).substring(with: try XCTUnwrap(paragraphs.first).range), first)
        XCTAssertGreaterThan(paragraphs.count, 2)
        for paragraph in paragraphs {
            XCTAssertEqual(TextBoundary.floor(paragraph.start, in: chapter.text), paragraph.start)
            XCTAssertEqual(TextBoundary.floor(paragraph.end, in: chapter.text), paragraph.end)
            XCTAssertLessThanOrEqual(paragraph.end - paragraph.start, ProactiveAnnotations.targetLimit)
        }
        let selected = ProactiveAnnotations.candidates(in: chapter.text, limit: 3)
        XCTAssertEqual(Set(selected).count, 3)
        XCTAssertEqual(selected, selected.sorted { $0.end < $1.end })
        let messages = try ProactiveAnnotations.messages(chapter: chapter, target: paragraphs[0], card: CharacterCard(), user: "读者")
        XCTAssertTrue(messages.last?.content.hasSuffix(first) == true)
        XCTAssertFalse(messages.map(\.content).joined().contains(future))
        XCTAssertFalse(messages.map(\.content).joined().contains("👩🏽‍🚀"))
    }
    func testDraftQuoteMustMatchTargetAndRecordEditsDoNotLoseOtherWriters() throws {
        let text = String(repeating: "灯塔就在海边，读者打开了旧信。", count: 4)
        let chapter = Chapter(id: 0, title: "来信", text: text)
        let target = try XCTUnwrap(ProactiveAnnotations.paragraphs(in: text).first)
        let card = CharacterCard(name: "共读者")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root), book = try store.importBook(title: "测试书", chapters: [chapter])
        let raw = "```json\n{\"annotations\":[{\"quote\":\"灯塔就在海边\",\"note\":\"这处景物像在等一个人回来。\",\"style\":\"WAVY\"}]}\n```"
        let generated = try ProactiveAnnotations.annotation(from: raw, bookID: book.id, chapter: chapter, target: target, character: card)
        XCTAssertEqual(generated.characterID, card.id); XCTAssertEqual(generated.characterName, card.name)
        XCTAssertEqual(generated.style, "wave"); XCTAssertEqual(generated.sourceThrough?.offset, target.end)
        XCTAssertThrowsError(try ProactiveAnnotations.annotation(from: #"{"quote":"并不存在的未来剧情","note":"猜测"}"#, bookID: book.id, chapter: chapter, target: target, character: card))
        let old = try store.records(for: book)
        _ = try store.modifyRecords(for: book) { $0.annotations.append(generated) }
        let saved = try store.modifyRecords(for: book) { $0.bookmarks.append(Bookmark(position: .init(), label: "起点")) }
        XCTAssertTrue(try store.notesMarkdown(for: book).contains("共读者的段评"))
        XCTAssertTrue(old.annotations.isEmpty); XCTAssertEqual(saved.annotations, [generated]); XCTAssertEqual(saved.bookmarks.count, 1)
        XCTAssertThrowsError(try store.modifyRecords(for: book) { records in records.annotations = []; throw MoReadError.invalid("写入取消") })
        XCTAssertEqual(try store.records(for: book).annotations, [generated])
        XCTAssertEqual(try JSONDecoder().decode(BookRecords.self, from: JSONEncoder().encode(saved)).annotations, [generated])
    }
}
