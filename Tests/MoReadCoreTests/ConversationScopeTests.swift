import XCTest
@testable import MoReadCore

final class ConversationScopeTests: XCTestCase {
    func testFocusRefreshIndependentBoundariesAndEarlierBranchSources() throws {
        var a = Book(title: "海岸", chapters: [.init(id: 0, title: "一", text: "0123456789")]), b = Book(title: "森林", chapters: [.init(id: 0, title: "一", text: "abcdefghij")])
        a.readThrough = .init(offset: 3); b.readThrough = .init(offset: 7)
        var chat = Conversation(title: "书库", bookID: nil, characterID: UUID()); chat.focusedBookIDs = [a.id]
        try chat.prepareLibraryTurn(books: [a, b])
        var user = ChatMessage(role: "user", content: "海岸"); user.focusedBookIDs = chat.focusedBookIDs
        chat.messages = [user, .init(role: "assistant", content: "已读部分")]; try chat.updateTurnScopes()
        XCTAssertEqual(chat.sourceLimits, [a.id: .init(offset: 3)])
        a.readThrough.offset = 5
        try chat.prepareLibraryTurn(books: [a, b], focus: [b.id])
        XCTAssertEqual(chat.sourceLimits[a.id], .init(offset: 5)); XCTAssertEqual(chat.sourceLimits[b.id], .init(offset: 7))
        user = ChatMessage(role: "user", content: "森林"); user.focusedBookIDs = chat.focusedBookIDs
        chat.messages += [user, .init(role: "assistant", content: "已读部分")]; try chat.updateTurnScopes()
        XCTAssertEqual(chat.messages[0].focusedBookIDs, [a.id]); XCTAssertEqual(chat.messages[2].focusedBookIDs, [b.id])
        XCTAssertTrue(chat.libraryContext(books: [a, b]).contains("偏移 5")); XCTAssertTrue(chat.libraryContext(books: [a, b]).contains("偏移 7"))
        var branch = chat; branch.messages = Array(chat.messages.prefix(2)); try branch.retainSourcesForHistory()
        XCTAssertEqual(branch.sourceLimits, [a.id: .init(offset: 3)]); XCTAssertEqual(Set(branch.sourceRevisions.keys), [a.id])
        XCTAssertNoThrow(try branch.validateSources(books: [a])); XCTAssertThrowsError(try chat.validateSources(books: [a]))
        var legacy = chat; legacy.messages = Array(chat.messages.prefix(2)); legacy.messages[0].bookScopes = nil
        try legacy.retainSourcesForHistory(); XCTAssertEqual(legacy.sourceLimits, chat.sourceLimits)
        XCTAssertThrowsError(try legacy.validateSources(books: [a]))
        a.readThrough.offset = 1
        let before = chat
        XCTAssertThrowsError(try chat.prepareLibraryTurn(books: [a, b])); XCTAssertEqual(chat, before)
        var corrupt = branch; corrupt.sourceLimits[a.id] = .init(chapter: Int.max, offset: 0)
        XCTAssertThrowsError(try corrupt.validateSources(books: [a]))
    }
    func testLimitsStorageAndMalformedHistoryFailWithoutDroppingSources() throws {
        let books = (0..<33).map { Book(title: "Book \($0)", chapters: [.init(id: 0, title: "一", text: "body")]) }
        var chat = Conversation(title: "书库", bookID: nil, characterID: UUID())
        XCTAssertThrowsError(try chat.validateUserText(" \n "))
        XCTAssertThrowsError(try chat.validateUserText(String(repeating: "字", count: 8001)))
        XCTAssertNoThrow(try chat.validateUserText(String(repeating: "字", count: 8000)))
        XCTAssertThrowsError(try chat.prepareLibraryTurn(books: books, focus: books.prefix(5).map(\.id)))
        XCTAssertThrowsError(try chat.prepareLibraryTurn(books: books, focus: [books[0].id, books[0].id]))
        XCTAssertThrowsError(try chat.prepareLibraryTurn(books: books, focus: [UUID()]))
        XCTAssertTrue(chat.sourceLimits.isEmpty)
        for start in stride(from: 0, to: 32, by: 4) { try chat.prepareLibraryTurn(books: books, focus: books[start..<(start + 4)].map(\.id)) }
        let snapshot = chat
        XCTAssertThrowsError(try chat.prepareLibraryTurn(books: books, focus: [books[32].id])); XCTAssertEqual(chat, snapshot)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CompanionStore(root: root)
        var user = ChatMessage(role: "user", content: "聊聊"); user.focusedBookIDs = chat.focusedBookIDs
        chat.messages = [user, .init(role: "assistant", content: "好的")]; try chat.updateTurnScopes()
        try store.save(chat); XCTAssertEqual(try store.conversations(), [chat])
        chat.messages[0].bookScopes = [.init(id: books[0].id, through: .init(), revision: "wrong")]
        let corrupt = chat
        XCTAssertThrowsError(try chat.retainSourcesForHistory()); XCTAssertEqual(chat, corrupt)
    }
}
