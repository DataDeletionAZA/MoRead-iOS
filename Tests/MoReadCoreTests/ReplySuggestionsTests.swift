import XCTest
@testable import MoReadCore

final class ReplySuggestionsTests: XCTestCase {
    func testParsesBoundedPlainRepliesAndRejectsMalformedOutput() throws {
        XCTAssertEqual(ReplySuggestions.parse("```json\n[\"  接着说  \",\"接着说\",\"换个\\n话题\",\"我想想\",\"第四条\"]\n```"), ["接着说", "换个 话题", "我想想"])
        XCTAssertEqual(ReplySuggestions.parse(#"{"suggestions":[null,12,{},true,"好呀"]}"#), ["好呀"])
        XCTAssertEqual(ReplySuggestions.parse("这里是建议：[\"好呀\"]。"), ["好呀"])
        for raw in ["[]", "{}", "null", "not json", "[\"unfinished", #"["\u0000"]"#, String(repeating: " ", count: 16_385)] { XCTAssertTrue(ReplySuggestions.parse(raw).isEmpty, raw.prefix(40).description) }
        let prefix = String(repeating: "👩🏽‍💻", count: 40)
        let raw = String(decoding: try JSONEncoder().encode([prefix + "一", prefix + "二", "另一条"]), as: UTF8.self)
        XCTAssertEqual(ReplySuggestions.parse(raw), [prefix, "另一条"])
    }
    func testHistoryIdentityBudgetAndSpoilerBoundary() throws {
        let identity = ChatIdentity(name: "本人", mask: UserMask(name: "林遥", description: "书店访客"))
        let chapters = [Chapter(id: 0, title: "第一章", text: "已读文字。后续秘密。")]
        var book = Book(title: "书店", chapters: chapters); book.readThrough = .init(offset: 5)
        var conversation = Conversation(title: "伴读", bookID: book.id, characterID: UUID())
        conversation.sourceLimits = [book.id: book.readThrough]; conversation.sourceRevisions = [book.id: book.chapters.map(\.revision)]
        conversation.messages = (0..<10).map { index in
            var message = ChatMessage(role: index.isMultiple(of: 2) ? "user" : "assistant", content: "第\(index)轮" + String(repeating: "字", count: 1000))
            message.identity = identity; return message
        }
        let history = ReplySuggestions.history(conversation.messages)
        XCTAssertEqual(history.count, 8); XCTAssertEqual(history.first?.id, conversation.messages[2].id)
        let request = try XCTUnwrap(ReplySuggestions.messages(conversation: conversation, books: [book], personaName: "阿翎", identity: identity))
        XCTAssertEqual(request.map(\.role), ["system", "user"])
        XCTAssertTrue(request[0].content.contains("书店")); XCTAssertTrue(request[0].content.contains("扮演「林遥」"))
        XCTAssertTrue(request[1].content.contains("用户（扮演：林遥）")); XCTAssertFalse(request[1].content.contains("第0轮"))
        XCTAssertLessThan(request[1].content.count, 6050); XCTAssertFalse(request.map(\.content).joined().contains("后续秘密"))
        var invalid = conversation
        invalid.sourceLimits[book.id] = .init(offset: 10)
        XCTAssertThrowsError(try ReplySuggestions.messages(conversation: invalid, books: [book], personaName: "阿翎", identity: identity))
        XCTAssertNil(try ReplySuggestions.messages(conversation: invalid, books: [book], personaName: "阿翎", identity: identity, enabled: false))
        book.removed = true
        XCTAssertThrowsError(try ReplySuggestions.messages(conversation: conversation, books: [book], personaName: "阿翎", identity: identity))
        for status in ["receiving", "interrupted"] {
            conversation.messages[9].status = status
            XCTAssertTrue(ReplySuggestions.history(conversation.messages).isEmpty)
        }
        conversation.messages.removeLast(); XCTAssertTrue(ReplySuggestions.history(conversation.messages).isEmpty)
        conversation.messages = []; XCTAssertTrue(ReplySuggestions.history(conversation.messages).isEmpty)
        let legacy = try JSONDecoder().decode(CompanionSettings.self, from: Data(#"{"providers":[],"userName":"读者"}"#.utf8))
        XCTAssertNil(legacy.suggestionProvider); XCTAssertNil(legacy.suggestionRepliesEnabled)
    }
}
