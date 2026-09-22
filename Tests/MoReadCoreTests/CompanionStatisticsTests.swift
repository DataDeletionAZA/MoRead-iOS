import XCTest
@testable import MoReadCore

final class CompanionStatisticsTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/New_York")!
    private let now = ISO8601DateFormatter().date(from: "2026-09-22T16:00:00Z")!
    private func pair(daysAgo: Int, books: [UUID]? = nil) -> [ChatMessage] {
        let date = ReadingCalendar.calendar(timeZone: zone).date(byAdding: .day, value: -daysAgo, to: now)!
        var user = ChatMessage(role: "user", content: "问 题😀"), reply = ChatMessage(role: "assistant", content: "回\n答")
        user.createdAt = date; reply.createdAt = date.addingTimeInterval(10)
        user.sourceBookIDs = books; reply.sourceBookIDs = books
        return [user, reply]
    }
    func testBranchesDeduplicateBeforeDateFilteringAndPartialRepliesDoNotCountAsRounds() {
        let book = Book(title: "书店", chapters: [.init(id: 0, title: "一", text: "正文")])
        var chat = Conversation(title: "伴读", bookID: book.id, characterID: UUID())
        chat.messages = pair(daysAgo: 15) + pair(daysAgo: 6) + pair(daysAgo: 7) + pair(daysAgo: -1)
        var partial = pair(daysAgo: 0); partial[0].content = "未"; partial[1].content = "部分"; partial[1].status = "interrupted"
        chat.messages += partial
        var branch = chat; branch.id = UUID(); branch.messages = Array(chat.messages.prefix(2))
        for index in branch.messages.indices { branch.messages[index].createdAt = now }
        let week = CompanionStatistics(conversations: [branch, chat], books: [book], period: .week, now: now, timeZone: zone)
        XCTAssertEqual(week.rounds, 1); XCTAssertEqual(week.conversations, 1); XCTAssertEqual(week.activeDays, 1)
        XCTAssertEqual(week.chatCharacters, 8); XCTAssertEqual(week.companionshipDays, 16)
        XCTAssertEqual(week.bookIDs, [book.id])
        let all = CompanionStatistics(conversations: [chat, branch], books: [book], now: now, timeZone: zone)
        XCTAssertEqual(all.rounds, 3); XCTAssertEqual(all.chatCharacters, 18); XCTAssertEqual(all.activeDays, 3)
        branch.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        branch.messages = Array(chat.messages.prefix(2))
        for index in branch.messages.indices { branch.messages[index].originalConversationID = chat.id }
        let copied = CompanionStatistics(conversations: [branch, chat], books: [book], now: now, timeZone: zone)
        XCTAssertEqual(copied.conversations, 1); XCTAssertEqual(copied.rounds, 3); XCTAssertEqual(copied.chatCharacters, 18)
        branch.messages += pair(daysAgo: 0)
        let continued = CompanionStatistics(conversations: [branch, chat], books: [book], now: now, timeZone: zone)
        XCTAssertEqual(continued.conversations, 2); XCTAssertEqual(continued.rounds, 4)
        let originalDeleted = CompanionStatistics(conversations: [branch], books: [book], now: now, timeZone: zone)
        XCTAssertEqual(originalDeleted.conversations, 1); XCTAssertEqual(originalDeleted.rounds, 2)
        let library = CompanionStatistics(conversations: [chat, branch], books: [book], scope: .library, now: now, timeZone: zone)
        XCTAssertEqual(library.rounds, 0); XCTAssertNil(library.firstChatDate); XCTAssertEqual(library.chatCharacters, 0)
    }
    func testPerTurnAssociationsEmptyHistoryRetainedBooksAndReadingDates() {
        let first = Book(title: "海岸", chapters: [.init(id: 0, title: "一", text: "正文")])
        var second = Book(title: "森林", chapters: [.init(id: 0, title: "一", text: "正文")]); second.removed = true; second.bodyCleared = true
        var chat = Conversation(title: "书库", bookID: nil, characterID: UUID())
        chat.sourceLimits[second.id] = .init(offset: 2)
        chat.messages = pair(daysAgo: 0, books: [])
        XCTAssertEqual(CompanionStatistics(conversations: [chat], books: [first, second], now: now).bookIDs.count, 0)
        chat.messages = pair(daysAgo: 0)
        XCTAssertEqual(CompanionStatistics(conversations: [chat], books: [first, second], now: now).bookIDs, [second.id])
        chat.messages[0].bookScopes = []
        XCTAssertEqual(CompanionStatistics(conversations: [chat], books: [first, second], now: now).bookIDs.count, 0)
        chat.messages = pair(daysAgo: 0, books: [first.id, second.id])
        var one = BookRecords(), two = BookRecords()
        one.readingSeconds = ["2026-09-22": 3600, "2026-09-16": 600, "2026-09-15": 1200, "2026-09-23": 9000, "bad": 1, "2026-09-20": -1]
        two.readingSeconds = ["2026-09-22": 120]
        let week = CompanionStatistics(conversations: [chat], books: [first, second], records: [first.id: one, second.id: two], scope: .library, period: .week, now: now, timeZone: zone)
        XCTAssertEqual(week.bookIDs.count, 2); XCTAssertEqual(week.readingSeconds, 4320); XCTAssertEqual(week.rounds, 1)
        let month = CompanionStatistics(conversations: [chat], books: [first, second], records: [first.id: one, second.id: two], period: .month, now: now, timeZone: zone)
        XCTAssertEqual(month.readingSeconds, 5520)
        let deleted = CompanionStatistics(conversations: [chat], books: [first], records: [first.id: one, second.id: two], period: .week, now: now, timeZone: zone)
        XCTAssertEqual(deleted.bookIDs, [first.id]); XCTAssertEqual(deleted.readingSeconds, 4200); XCTAssertEqual(deleted.rounds, 1)
        XCTAssertEqual(CompanionStatistics(conversations: [chat], books: [first, second], scope: .book, now: now).rounds, 0)
    }
    func testTurnAssociationDoesNotExpandReadingBoundariesAndSurvivesStorage() throws {
        let first = UUID(), second = UUID()
        var chat = Conversation(title: "书库", bookID: nil, characterID: UUID())
        chat.messages = pair(daysAgo: 0); chat.messages[0].focusedBookIDs = [first]
        chat.sourceLimits[first] = .init(offset: 2); chat.sourceRevisions[first] = ["revision"]
        try chat.updateTurnScopes()
        let scopes = chat.messages[0].bookScopes
        try chat.associateTurnBooks([])
        XCTAssertEqual(chat.messages[0].sourceBookIDs, [first])
        XCTAssertEqual(chat.messages[0].originalConversationID, chat.id)
        XCTAssertEqual(chat.messages[1].originalConversationID, chat.id)
        try chat.associateTurnBooks([second, second])
        XCTAssertEqual(Set(chat.messages[0].sourceBookIDs ?? []), [first, second])
        XCTAssertEqual(chat.messages[1].sourceBookIDs, chat.messages[0].sourceBookIDs)
        XCTAssertEqual(chat.messages[0].bookScopes, scopes); XCTAssertEqual(chat.sourceLimits, [first: .init(offset: 2)])
        let before = chat
        XCTAssertThrowsError(try chat.associateTurnBooks((0..<33).map { _ in UUID() })); XCTAssertEqual(chat, before)
        var invalid = chat; invalid.messages[0].sourceBookIDs = [first, first]
        XCTAssertThrowsError(try invalid.validateFocus())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CompanionStore(root: root); try store.save(chat)
        XCTAssertEqual(try store.conversations(), [chat])
        var legacy = chat; legacy.messages[0].sourceBookIDs = nil; legacy.messages[1].sourceBookIDs = nil
        let decoded = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.messages[0].sourceBookIDs)
    }
}
