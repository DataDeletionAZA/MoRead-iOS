import XCTest
@testable import MoReadCore

final class UserMaskTests: XCTestCase {
    func testIdentitySnapshotsSurviveSelectionEditsDeletionAndStorage() throws {
        var settings = CompanionSettings(); settings.userName = "读者"
        var masks = UserMaskSettings(), mask = UserMask(name: "  林遥  ", description: "书店的常客")
        try masks.save(mask); settings.userMasks = masks
        XCTAssertEqual(settings.currentIdentity, ChatIdentity(name: "读者"))
        masks.enabled = true; settings.userMasks = masks
        let identity = settings.currentIdentity
        XCTAssertEqual(identity.name, "林遥"); XCTAssertEqual(identity.maskID, mask.id)
        var message = ChatMessage(role: "user", content: "我经营这家书店。")
        message.identity = identity
        XCTAssertTrue(message.withIdentityLabel.content.contains("扮演：林遥"))
        XCTAssertTrue(message.withIdentityLabel.content.hasSuffix(message.content))
        var card = CharacterCard(); card.description = "你好，{{user}}。"
        XCTAssertTrue(card.prompt(user: identity.name, conversation: "").contains("你好，林遥。"))
        let chapter = Chapter(id: 0, title: "书店", text: String(repeating: "雨停了，书店的窗户敞开着。", count: 6))
        let target = try XCTUnwrap(ProactiveAnnotations.paragraphs(in: chapter.text).first)
        let annotation = try ProactiveAnnotations.messages(chapter: chapter, target: target, card: card, user: identity.name, identity: identity)
        XCTAssertTrue(annotation.first?.content.contains("用户当前扮演「林遥」") == true)
        XCTAssertTrue(annotation.first?.content.contains("书店的常客") == true)
        let messages = (0..<26).map { _ -> ChatMessage in var value = message; value.id = UUID(); return value }
        let work = try XCTUnwrap(RollingSummary.plan(messages: messages, summary: nil))
        XCTAssertTrue(work.transcript.contains("用户（扮演：林遥）"))
        var uniqueMessages = messages
        let uniqueWork = try XCTUnwrap(RollingSummary.plan(messages: uniqueMessages, summary: nil))
        let summary = ConversationSummary(text: "用户扮演林遥。", work: uniqueWork)
        XCTAssertTrue(summary.matches(uniqueMessages))
        uniqueMessages[0].identity = ChatIdentity(name: "本人")
        XCTAssertFalse(summary.matches(uniqueMessages))
        mask.name = "改名之后"; mask.description = "新的身份设定"; try masks.save(mask)
        masks.remove([mask.id]); settings.userMasks = masks
        XCTAssertFalse(masks.enabled); XCTAssertNil(settings.currentIdentity.maskID)
        XCTAssertEqual(message.identity, identity)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CompanionStore(root: root)
        var conversation = Conversation(title: "身份测试", bookID: nil, characterID: card.id); conversation.messages = [message]
        try store.save(conversation); try store.save(settings)
        let restored = try CompanionStore(root: root)
        XCTAssertEqual(try restored.conversations().first?.messages.first?.identity, identity)
        XCTAssertNil(try restored.settings().currentIdentity.maskID)
        let legacy = try JSONDecoder().decode(ChatMessage.self, from: Data("{\"id\":\"\(UUID().uuidString)\",\"role\":\"user\",\"content\":\"旧消息\",\"createdAt\":0,\"status\":\"complete\",\"sources\":[]}".utf8))
        XCTAssertNil(legacy.identity); XCTAssertEqual(legacy.withIdentityLabel.content, "旧消息")
        let long = try UserMask(name: String(repeating: "👩🏽‍🚀", count: 30), description: String(repeating: "界", count: 4100)).validated()
        XCTAssertEqual(long.name.count, 24); XCTAssertEqual(long.description.count, 4000)
        XCTAssertThrowsError(try UserMask(name: " \n").validated())
    }
}
