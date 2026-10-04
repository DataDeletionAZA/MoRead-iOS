import Foundation

struct CompanionStoryRound {
    let id: UUID
    let at: Date
    let characterID: UUID
    let library: Bool
    let bookIDs: Set<UUID>
}

public struct CompanionStoryEvent: Identifiable, Sendable {
    public enum Kind: Sendable { case firstWords, session, milestone(Int), memory(String) }
    public let id: String
    public let at: Date
    public let characterID: UUID?
    public let kind: Kind
    public var end: Date
    public var rounds: Int = 0
    public var bookIDs: Set<UUID> = []
    public var library = false
    public var firstMeeting = false
    var priority: Int { switch kind { case .firstWords: 0; case .session: 1; case .milestone: 2; case .memory: 3 } }
}

public struct CompanionStoryDay: Identifiable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let rounds: Int
    public let roundsByHour: [Int]
    public let readingSeconds: Double
    public let events: [CompanionStoryEvent]

    static func build(rounds: [CompanionStoryRound], memories: [PersonaMemory], conversations: [Conversation], books: [Book], records: [UUID: BookRecords], scope: CompanionStatsScope, firstDay: Date?, today: Date, calendar: Calendar) -> [Self] {
        var events: [CompanionStoryEvent] = [], session: CompanionStoryEvent?, seenBooks: Set<UUID> = []
        if let first = rounds.first { events.append(.init(id: "first", at: first.at, characterID: first.characterID, kind: .firstWords, end: first.at)) }
        for (index, round) in rounds.enumerated() {
            if [10, 50, 100, 200, 500, 1000, 2000, 5000].contains(index + 1) {
                events.append(.init(id: "milestone-\(index + 1)", at: round.at, characterID: nil, kind: .milestone(index + 1), end: round.at))
            }
            let firstMeeting = !round.bookIDs.subtracting(seenBooks).isEmpty
            seenBooks.formUnion(round.bookIDs)
            if var current = session, calendar.isDate(current.at, inSameDayAs: round.at), round.at.timeIntervalSince(current.end) <= 1800,
               current.characterID == round.characterID, current.library == round.library, round.library || current.bookIDs == round.bookIDs {
                current.end = round.at; current.rounds += 1; current.bookIDs.formUnion(round.bookIDs); current.firstMeeting = current.firstMeeting || firstMeeting
                session = current
            } else {
                if let session { events.append(session) }
                session = .init(id: "session-\(round.id)", at: round.at, characterID: round.characterID, kind: .session, end: round.at, rounds: 1, bookIDs: round.bookIDs, library: round.library, firstMeeting: firstMeeting)
            }
        }
        if let session { events.append(session) }
        let valid = MemoryOrigin.validated(memories.flatMap(\.origins), books: books, conversations: conversations)
        var seenMemories: Set<UUID> = []
        for memory in memories where seenMemories.insert(memory.id).inserted {
            guard memory.updatedAt.timeIntervalSince1970.isFinite, !memory.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  scope.includes(memory.bookID), memory.origins.allSatisfy({ valid.contains($0) }) else { continue }
            events.append(.init(id: "memory-\(memory.id)", at: memory.updatedAt, characterID: memory.characterID, kind: .memory(memory.text), end: memory.updatedAt))
        }
        let visible = events.filter {
            let day = calendar.startOfDay(for: $0.at)
            return day <= today && (firstDay.map { day >= $0 } ?? true)
        }.sorted { ($0.at, $0.priority, $0.id) < ($1.at, $1.priority, $1.id) }
        let dailyRounds = Dictionary(grouping: rounds, by: { calendar.startOfDay(for: $0.at) })
        return Dictionary(grouping: visible, by: { calendar.startOfDay(for: $0.at) }).map { date, events in
            let daily = dailyRounds[date] ?? []
            let ids = Set(events.flatMap(\.bookIDs))
            let seconds = ids.reduce(0.0) { total, id in
                let value = records[id]?.readingSeconds[ReadingCalendar.key(date, calendar: calendar)] ?? 0
                return total + (value.isFinite && value > 0 && value <= 172_800 ? value : 0)
            }
            return Self(date: date, rounds: daily.count, roundsByHour: (0..<24).map { hour in daily.filter { calendar.component(.hour, from: $0.at) == hour }.count }, readingSeconds: seconds, events: events)
        }.sorted { $0.date > $1.date }
    }
}
