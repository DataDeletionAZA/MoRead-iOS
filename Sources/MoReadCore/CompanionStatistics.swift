import Foundation

public enum CompanionStatsScope: String, CaseIterable, Sendable {
    case all, book, library
    public var label: String { switch self { case .all: "全部伴读"; case .book: "书内伴读"; case .library: "书库伴读" } }
    func includes(_ book: UUID?) -> Bool { self == .all || (self == .book ? book != nil : book == nil) }
}
public enum CompanionStatsPeriod: String, CaseIterable, Sendable {
    case week, month, all
    public var label: String { switch self { case .week: "近 7 天"; case .month: "近 30 天"; case .all: "全部" } }
    public var days: Int? { switch self { case .week: 7; case .month: 30; case .all: nil } }
}

public struct CompanionStatistics: Sendable {
    public let rounds: Int
    public let conversations: Int
    public let bookIDs: Set<UUID>
    public let roundsByDay: [Date: Int]
    public var activeDays: Int { roundsByDay.count }
    public let firstChatDate: Date?
    public let companionshipDays: Int?
    public let chatCharacters: Int
    public let readingSeconds: Double
    public let today: Date
    public let calendar: Calendar

    public init(conversations: [Conversation], books: [Book], records: [UUID: BookRecords] = [:], scope: CompanionStatsScope = .all, period: CompanionStatsPeriod = .all, now: Date = Date(), timeZone: TimeZone = .current) {
        let calendar = ReadingCalendar.calendar(timeZone: timeZone), today = calendar.startOfDay(for: now)
        let firstDay = period.days.flatMap { calendar.date(byAdding: .day, value: 1 - $0, to: today) }
        func day(_ date: Date) -> Date? { date.timeIntervalSince1970.isFinite ? calendar.startOfDay(for: date) : nil }
        func includes(_ date: Date) -> Bool { date <= today && (firstDay.map { date >= $0 } ?? true) }
        struct Round { let reply: UUID; let conversation: UUID; let book: UUID?; let date: Date; let books: [UUID]; let order: (Date, Int, String) }
        struct Words { let message: UUID; let book: UUID?; let date: Date; let count: Int; let order: (Date, Int, String) }
        var rounds: [Round] = [], words: [Words] = []
        for chat in conversations {
            var pending: ChatMessage?
            func order(_ message: ChatMessage) -> (Date, Int, String) {
                (message.createdAt, message.originalConversationID == nil || message.originalConversationID == chat.id ? 0 : 1, chat.id.uuidString)
            }
            for message in chat.messages {
                guard ["user", "assistant"].contains(message.role) else { continue }
                if let date = day(message.createdAt) {
                    let count = message.content.unicodeScalars.reduce(0) { $0 + ([9, 10, 13, 32].contains($1.value) ? 0 : 1) }
                    words.append(.init(message: message.id, book: chat.bookID, date: date, count: count, order: order(message)))
                }
                if message.role == "user" { pending = message; continue }
                guard let user = pending, message.status == "complete", !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let date = day(user.createdAt) else { continue }
                let legacy = user.bookScopes?.map(\.id) ?? message.bookScopes?.map(\.id) ?? Array(chat.sourceLimits.keys)
                let associated = user.sourceBookIDs ?? message.sourceBookIDs ?? legacy
                let ids = chat.bookID.map { [$0] } ?? associated
                rounds.append(.init(reply: message.id, conversation: chat.id, book: chat.bookID, date: date, books: ids, order: order(user)))
                pending = nil
            }
        }
        var seenReplies: Set<UUID> = [], seenMessages: Set<UUID> = []
        let unique = rounds.sorted { $0.order < $1.order }
            .filter { seenReplies.insert($0.reply).inserted }
        let selected = unique.filter { scope.includes($0.book) && includes($0.date) }
        let retained = Set(books.map(\.id)), ids = Set(selected.flatMap(\.books)).intersection(retained)
        self.rounds = selected.count; self.conversations = Set(selected.map(\.conversation)).count
        bookIDs = ids; roundsByDay = Dictionary(grouping: selected, by: \.date).mapValues(\.count)
        firstChatDate = unique.filter { scope.includes($0.book) && $0.date <= today }.map(\.date).min()
        companionshipDays = firstChatDate.flatMap { calendar.dateComponents([.day], from: $0, to: today).day }.map { $0 + 1 }
        chatCharacters = words.sorted { $0.order < $1.order }
            .filter { seenMessages.insert($0.message).inserted }.filter { scope.includes($0.book) && includes($0.date) }.reduce(0) { $0 + $1.count }
        readingSeconds = ids.reduce(0) { total, id in
            total + (records[id]?.readingSeconds ?? [:]).reduce(0) { subtotal, entry in
                guard entry.value.isFinite, entry.value > 0, entry.value <= 172_800,
                      let date = ReadingCalendar.date(entry.key, calendar: calendar), includes(date) else { return subtotal }
                return subtotal + entry.value
            }
        }
        self.today = today; self.calendar = calendar
    }
}
