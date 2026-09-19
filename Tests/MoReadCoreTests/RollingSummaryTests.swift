import XCTest
@testable import MoReadCore

final class RollingSummaryTests: XCTestCase {
    func testRollingSummaryPreservesWatermarksAndRejectsChangedSources() throws {
        var messages = (0..<26).map { ChatMessage(role: $0.isMultiple(of: 2) ? "user" : "assistant", content: "第\($0)条对话") }
        XCTAssertNil(RollingSummary.plan(messages: Array(messages.prefix(25)), summary: nil))
        let work = try XCTUnwrap(RollingSummary.plan(messages: messages, summary: nil))
        XCTAssertEqual(work.throughMessageID, messages[5].id)
        XCTAssertFalse(work.transcript.contains("第6条"))
        let summary = ConversationSummary(text: "用户喜欢雨后的书店。", work: work)
        XCTAssertTrue(summary.matches(messages))
        XCTAssertNil(RollingSummary.plan(messages: messages, summary: summary))
        messages += (26..<32).map { ChatMessage(role: "user", content: "第\($0)条对话") }
        let next = try XCTUnwrap(RollingSummary.plan(messages: messages, summary: summary))
        XCTAssertEqual(next.previous, summary.text)
        XCTAssertEqual(next.throughMessageID, messages[11].id)
        XCTAssertTrue(next.transcript.contains("第6条"))
        XCTAssertFalse(next.transcript.contains("第5条"))
        XCTAssertTrue(summary.matches(Array(messages.prefix(6))))
        XCTAssertFalse(summary.matches(Array(messages.prefix(5))))
        messages[0].content = "已修改"
        XCTAssertFalse(summary.matches(messages))
        XCTAssertEqual(RollingSummary.block(summary: summary, messages: messages), "")
        XCTAssertEqual(RollingSummary.plan(messages: messages, summary: summary)?.previous, "")
        messages[0].content = "第0条对话"; messages[0].status = "interrupted"
        XCTAssertFalse(summary.matches(messages))
    }

    func testBoundedTranscriptOnlyAdvancesThroughIncludedMessagesAndPersists() throws {
        let messages = (0..<60).map { ChatMessage(role: "user", content: "第\($0)条" + String(repeating: "👩🏽‍🚀", count: 300)) }
        let work = try XCTUnwrap(RollingSummary.plan(messages: messages, summary: nil))
        XCTAssertLessThanOrEqual(work.transcript.utf16.count, 12_000)
        let end = try XCTUnwrap(messages.firstIndex { $0.id == work.throughMessageID })
        XCTAssertLessThan(end, 39)
        XCTAssertTrue(work.transcript.contains("第\(end)条"))
        XCTAssertFalse(work.transcript.contains("第\(end + 1)条"))
        let summary = ConversationSummary(text: String(repeating: "👩🏽‍🚀", count: 800), work: work)
        XCTAssertEqual(summary.text.count, 600)
        XCTAssertEqual(summary.text.last, "👩🏽‍🚀")
        let next = try XCTUnwrap(RollingSummary.plan(messages: messages, summary: summary))
        XCTAssertTrue(next.transcript.hasPrefix("用户：第\(end + 1)条"))
        var interrupted = messages; for index in interrupted.indices { interrupted[index].status = "interrupted" }
        XCTAssertNil(RollingSummary.plan(messages: interrupted, summary: nil))
        XCTAssertNil(RollingSummary.plan(messages: (0..<40).map { ChatMessage(role: "tool", content: "\($0)") }, summary: nil))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CompanionStore(root: root)
        var conversation = Conversation(title: "提要测试", bookID: nil, characterID: UUID()); conversation.messages = messages
        try store.save(conversation)
        XCTAssertNil(try CompanionStore(root: root).conversations().first?.summary)
        conversation.summary = summary; try store.save(conversation)
        let restored = try XCTUnwrap(CompanionStore(root: root).conversations().first)
        XCTAssertTrue(try XCTUnwrap(restored.summary).matches(restored.messages))
        try store.save(CompanionSettings())
        XCTAssertNil(try store.settings().summarySettings)
    }
}
