import Foundation

public enum ReadingWidget: String, CaseIterable, Sendable {
    case heatmap, calendar, trend, hours, timeline, books, tags, authors
    public var title: String {
        switch self { case .heatmap: "阅读热力"; case .calendar: "阅读月历"; case .trend: "阅读趋势"; case .hours: "阅读时间段"; case .timeline: "阅读时间线"; case .books: "阅读排行"; case .tags: "标签云"; case .authors: "作者云" }
    }
}
public struct StatisticsWidgets: Codable, Sendable {
    public var order: [String] = ReadingWidget.allCases.map(\.rawValue)
    public var hidden: Set<String> = []
    public init(data: Data = Data()) {
        if let value = try? JSONDecoder().decode(Self.self, from: data) { self = value }
        var seen: Set<String> = []
        order = (order + ReadingWidget.allCases.map(\.rawValue)).filter { ReadingWidget(rawValue: $0) != nil && seen.insert($0).inserted }
        hidden = hidden.intersection(order)
    }
    public var visible: [ReadingWidget] { order.filter { !hidden.contains($0) }.compactMap(ReadingWidget.init(rawValue:)) }
    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

public enum ReadingPeriod: String, CaseIterable, Sendable {
    case total, year, month, week, day
    public var label: String { switch self { case .total: "总"; case .year: "年"; case .month: "月"; case .week: "周"; case .day: "日" } }
    private var component: Calendar.Component { switch self { case .total, .year: .year; case .month: .month; case .week: .weekOfYear; case .day: .day } }
    public func interval(around date: Date, calendar: Calendar) -> DateInterval? {
        self == .total ? nil : calendar.dateInterval(of: component, for: date)
    }
    public func shifted(_ date: Date, by amount: Int, calendar: Calendar) -> Date {
        self == .total ? date : calendar.date(byAdding: component, value: amount, to: date) ?? date
    }
}

public enum ReadingCalendar {
    public static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = timeZone; value.firstWeekday = 2; value.minimumDaysInFirstWeek = 4
        return value
    }
    public static func key(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    public static func date(_ key: String, calendar: Calendar) -> Date? {
        let bytes = Array(key.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ [4, 7].contains($0.offset) || (48...57).contains($0.element) }) else { return nil }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]),
              let value = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)),
              self.key(value, calendar: calendar) == key else { return nil }
        return calendar.startOfDay(for: value)
    }
}

extension BookRecords {
    public mutating func recordReading(from start: Date, to end: Date, timeZone: TimeZone = .current) {
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, end.timeIntervalSince(start) >= 1 else { return }
        let calendar = ReadingCalendar.calendar(timeZone: timeZone)
        var cursor = start
        while cursor < end {
            guard let hour = calendar.dateInterval(of: .hour, for: cursor), hour.end > cursor else { break }
            let next = min(end, hour.end), seconds = next.timeIntervalSince(cursor)
            let day = ReadingCalendar.key(cursor, calendar: calendar), index = calendar.component(.hour, from: cursor)
            readingSeconds[day, default: 0] += seconds
            var hours = readingHours?[day] ?? Array(repeating: 0, count: 24)
            if hours.count != 24 { hours = Array(repeating: 0, count: 24) }
            hours[index] += seconds
            if readingHours == nil { readingHours = [:] }
            readingHours?[day] = hours
            cursor = next
        }
    }
}

public struct ReadingBookStat: Identifiable, Sendable {
    public var id: UUID { book.id }
    public let book: Book
    public let seconds: Double
}
public struct ReadingDayStat: Identifiable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let books: [ReadingBookStat]
    public var seconds: Double { books.reduce(0) { $0 + $1.seconds } }
    public init(date: Date, books: [ReadingBookStat]) { self.date = date; self.books = books }
}
public struct ReadingLabelStat: Identifiable, Sendable {
    public var id: String { label }
    public let label: String
    public let seconds: Double
    public let books: Int
}
public struct ReadingBar: Identifiable, Sendable {
    public var id: String { label }
    public let label: String
    public let seconds: Double
    public init(label: String, seconds: Double) { self.label = label; self.seconds = seconds }
}

public struct ReadingStatistics: Sendable {
    public let period: ReadingPeriod
    public let anchor: Date
    public let calendar: Calendar
    public let interval: DateInterval?
    public let canGoNext: Bool
    public let days: [ReadingDayStat]
    public let periodDays: [ReadingDayStat]
    public let monthDays: [ReadingDayStat]
    public let books: [ReadingBookStat]
    public let totalSeconds: Double
    public let previousSeconds: Double
    public let hourlySeconds: [Double]
    public var unassignedHourlySeconds: Double { max(0, totalSeconds - hourlySeconds.reduce(0, +)) }
    public let streak: Int
    public let longestStreak: Int
    public let finishedBooks: Int
    public let noteCount: Int
    public let tags: [ReadingLabelStat]
    public let authors: [ReadingLabelStat]
    public let trend: [ReadingBar]

    public init(books library: [Book], records: [UUID: BookRecords], organization: ShelfOrganization = .init(), period: ReadingPeriod = .month, anchor: Date = Date(), now: Date = Date(), timeZone: TimeZone = .current) {
        let calendar = ReadingCalendar.calendar(timeZone: timeZone)
        let anchor = min(anchor, now), interval = period.interval(around: anchor, calendar: calendar)
        func contains(_ range: DateInterval?, _ day: Date) -> Bool { range.map { day >= $0.start && day < $0.end } ?? true }
        func ranked(_ values: [ReadingBookStat]) -> [ReadingBookStat] {
            values.sorted { $0.seconds == $1.seconds ? $0.book.title < $1.book.title : $0.seconds > $1.seconds }
        }
        var byDay: [Date: [ReadingBookStat]] = [:], byBook: [UUID: Double] = [:], hourly = Array(repeating: 0.0, count: 24)
        var notes = 0
        for book in library {
            guard let value = records[book.id] else { continue }
            notes += value.annotations.count + (value.notes?.count ?? 0)
            for (key, seconds) in value.readingSeconds {
                // ponytail: discard per-book days above 48 hours; session timestamps can support wider cross-zone days later.
                guard seconds.isFinite, seconds > 0, seconds <= 172_800, let day = ReadingCalendar.date(key, calendar: calendar) else { continue }
                byDay[day, default: []].append(.init(book: book, seconds: seconds))
                if contains(interval, day) {
                    byBook[book.id, default: 0] += seconds
                    if let hours = value.readingHours?[key], hours.count == 24, hours.allSatisfy({ $0.isFinite && $0 >= 0 }), hours.reduce(0, +) <= seconds + 0.001 {
                        for index in 0..<24 { hourly[index] += hours[index] }
                    }
                }
            }
        }
        let days = byDay.map { ReadingDayStat(date: $0.key, books: ranked($0.value)) }.sorted { $0.date < $1.date }
        let selected = days.filter { contains(interval, $0.date) }
        let month = calendar.dateInterval(of: .month, for: anchor)
        let previous = interval.flatMap { period.interval(around: period.shifted($0.start, by: -1, calendar: calendar), calendar: calendar) }
        let periodBooks = ranked(library.compactMap { book in byBook[book.id].map { .init(book: book, seconds: $0) } })
        let dates = Set(days.map(\.date)), today = calendar.startOfDay(for: now)
        var cursor = dates.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!, streak = 0, longest = 0, run = 0, last: Date?
        while dates.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        for day in days {
            run = last.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } == day.date ? run + 1 : 1
            longest = max(longest, run); last = day.date
        }
        func cloud(_ labels: (Book) -> [String]) -> [ReadingLabelStat] {
            var values: [String: (Double, Int)] = [:]
            for row in periodBooks {
                for label in Set(labels(row.book).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }) {
                    let old = values[label] ?? (0, 0); values[label] = (old.0 + row.seconds, old.1 + 1)
                }
            }
            return values.map { ReadingLabelStat(label: $0.key, seconds: $0.value.0, books: $0.value.1) }.sorted { $0.seconds == $1.seconds ? $0.label < $1.label : $0.seconds > $1.seconds }
        }
        let names = Dictionary(organization.tags.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        self.period = period; self.anchor = anchor; self.calendar = calendar; self.interval = interval
        canGoNext = interval.map { $0.start < (period.interval(around: now, calendar: calendar)?.start ?? $0.start) } ?? false
        self.days = days; periodDays = selected; monthDays = days.filter { contains(month, $0.date) }; self.books = periodBooks
        totalSeconds = selected.reduce(0) { $0 + $1.seconds }; previousSeconds = previous.map { range in days.filter { contains(range, $0.date) }.reduce(0) { $0 + $1.seconds } } ?? 0
        hourlySeconds = hourly; self.streak = streak; longestStreak = longest; finishedBooks = library.filter { $0.state == "已读" }.count; noteCount = notes
        tags = cloud { book in
            let labels = (organization.bookTags[book.id] ?? []).compactMap { names[$0] }
            return labels.isEmpty ? book.tags : labels
        }
        authors = cloud { $0.author == "未知作者" ? [] : [$0.author] }
        switch period {
        case .day: trend = hourly.enumerated().map { .init(label: String($0.offset), seconds: $0.element) }
        case .total:
            trend = Dictionary(grouping: selected, by: { calendar.component(.year, from: $0.date) }).sorted { $0.key < $1.key }.map { .init(label: String($0.key), seconds: $0.value.reduce(0) { $0 + $1.seconds }) }
        case .year:
            let monthly = Dictionary(grouping: selected, by: { calendar.component(.month, from: $0.date) })
            trend = (1...12).map { month in .init(label: "\(month)月", seconds: monthly[month, default: []].reduce(0) { $0 + $1.seconds }) }
        case .month, .week:
            var result: [ReadingBar] = [], date = interval?.start ?? today
            let totals = Dictionary(uniqueKeysWithValues: selected.map { ($0.date, $0.seconds) })
            while let range = interval, date < range.end {
                let label = period == .week ? ["日", "一", "二", "三", "四", "五", "六"][calendar.component(.weekday, from: date) - 1] : String(calendar.component(.day, from: date))
                result.append(.init(label: label, seconds: totals[date, default: 0]))
                guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }; date = next
            }
            trend = result
        }
    }
}
