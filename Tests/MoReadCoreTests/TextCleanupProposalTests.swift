import XCTest
@testable import MoReadCore

final class TextCleanupProposalTests: XCTestCase {
    func testScopeSamplingVersionsAndNoWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        var book = try store.importBook(title: "取样", chapters: [.init(id: 0, title: "开篇", text: "😀雨后。秘密"), .init(id: 1, title: "未读标题", text: "隐藏结局")])
        XCTAssertThrowsError(try store.textCleanupSample(bookID: book.id, wholeBook: false))
        book.readThrough = .init(chapter: 0, offset: 1); try store.save(book)
        XCTAssertThrowsError(try store.textCleanupSample(bookID: book.id, wholeBook: false))
        book.readThrough.offset = 5; try store.save(book)
        let sample = try store.textCleanupSample(bookID: book.id, wholeBook: false)
        XCTAssertTrue(sample.text.contains("😀雨后。")); XCTAssertFalse(sample.text.contains("秘密")); XCTAssertFalse(sample.text.contains("未读标题"))
        XCTAssertEqual(sample.sampledChapters, 1)
        let full = try store.textCleanupSample(bookID: book.id, wholeBook: true)
        XCTAssertTrue(full.text.contains("隐藏结局")); XCTAssertEqual(full.sampledChapters, 2)
        XCTAssertEqual(try store.book(book.id), book)
        XCTAssertEqual(try TextReplacementStore(root: root).rules(), [])
        var changed = book; changed.readThrough.offset = 0
        XCTAssertThrowsError(try sample.validate(in: changed)); XCTAssertNoThrow(try full.validate(in: changed))
        changed = book; changed.chapters[0].revision = "changed"
        XCTAssertThrowsError(try full.validate(in: changed))
        changed = book; changed.bodyCleared = true
        XCTAssertThrowsError(try full.validate(in: changed))
    }
    func testBoundedEvenSamplingAndProtocolRequests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let chapters = (0..<620).map { Chapter(id: $0, title: String(repeating: "标题", count: 100), text: "头\($0)" + String(repeating: "😀", count: 150) + "尾\($0)") }
        let book = try store.importBook(title: "长书", chapters: chapters)
        let sample = try store.textCleanupSample(bookID: book.id, wholeBook: true)
        XCTAssertLessThanOrEqual(sample.text.utf16.count, 72_000)
        XCTAssertEqual(sample.sampledChapters, 600); XCTAssertEqual(sample.eligibleChapters, 620)
        XCTAssertTrue(sample.text.contains("头0")); XCTAssertTrue(sample.text.contains("尾619"))
        XCTAssertFalse(sample.text.contains("�"))
        let messages = try sample.messages(requirement: "删除广告", listeningOnly: true)
        XCTAssertTrue(messages[0].content.contains("each spoken sentence"))
        let data = try XCTUnwrap(messages.last?.content.data(using: .utf8))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(body["bookExcerpts"], sample.text)
        XCTAssertThrowsError(try sample.messages(requirement: " ", listeningOnly: false))
        XCTAssertThrowsError(try sample.messages(requirement: String(repeating: "x", count: 4001), listeningOnly: false))
        for dialect in AIProtocol.allCases {
            var provider = AIProvider(); provider.model = "fixture"; provider.dialect = dialect
            let request = try ChatRequest.make(provider: provider, key: "fixture-key", messages: messages)
            XCTAssertEqual(request.httpMethod, "POST")
            let encoded = try XCTUnwrap(request.httpBody)
            XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("requirement"))
        }
    }
    func testDraftValidationPreservesMeaningAndScope() throws {
        let raw = "```json\n{\"name\":\"  广告  \",\"pattern\":\"^广告：.*\\n\",\"ignoreCase\":true,\"forListeningOnly\":false}\n```"
        let draft = try TextCleanupProposal.parse(raw, listeningOnly: true)
        XCTAssertEqual(draft.name, "广告"); XCTAssertEqual(draft.pattern, "^广告：.*\n")
        XCTAssertTrue(draft.forListeningOnly); XCTAssertTrue(draft.isRegex); XCTAssertTrue(draft.ignoreCase)
        XCTAssertEqual(try TextCleanup.apply("广告：加群\n😀正文", rules: [draft], forListening: true).text, "😀正文")
        for raw in ["no JSON", "{}", "{\"pattern\":\"[\"}", "{\"pattern\":3}", "{\"pattern\":\"x\",\"ignoreCase\":\"false\"}", "{\"pattern\":\" \"}", String(repeating: "x", count: 64_001)] {
            XCTAssertThrowsError(try TextCleanupProposal.parse(raw, listeningOnly: false))
        }
        let long = try JSONSerialization.data(withJSONObject: ["pattern": "x", "replacement": String(repeating: "x", count: 4001)])
        XCTAssertThrowsError(try TextCleanupProposal.parse(String(decoding: long, as: UTF8.self), listeningOnly: false))
    }
}
