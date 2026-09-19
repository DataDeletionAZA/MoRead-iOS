import XCTest
@testable import MoReadCore

final class CompanionTests: XCTestCase {
    func testRetrievedEvidenceAndOldConversationsRespectSourceChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        var book = try store.importBook(title: "测试小说", chapters: [Chapter(id: 0, title: "一", text: "灯塔在海边。秘密是第二天发生的。"), Chapter(id: 1, title: "二", text: "凶手是未读人物。")])
        book.readThrough = ReadingPosition(chapter: 0, offset: 6)
        let context = try CompanionContextBuilder.build(query: "灯塔", books: [book], currentBook: book.id, store: store)
        XCTAssertTrue(context.text.contains("灯塔"))
        XCTAssertFalse(context.text.contains("秘密")); XCTAssertFalse(context.text.contains("凶手"))
        for passage in context.passages { XCTAssertTrue(passage.isValid(in: try store.chapter(passage.chapter, in: book), scope: ReadingScope(through: book.readThrough))) }
        var conversation = Conversation(title: "对话", bookID: book.id, characterID: UUID())
        conversation.sourceLimits = context.limits; conversation.sourceRevisions = context.revisions
        XCTAssertNoThrow(try conversation.validateSources(books: [book]))
        book.readThrough = .init()
        XCTAssertThrowsError(try conversation.validateSources(books: [book]))
        XCTAssertThrowsError(try conversation.validateSources(books: []))
        let companion = try CompanionStore(root: root)
        try companion.save(conversation)
        XCTAssertEqual(try companion.conversations().first, conversation)
        XCTAssertEqual(try store.books().count, 1)
    }
}
