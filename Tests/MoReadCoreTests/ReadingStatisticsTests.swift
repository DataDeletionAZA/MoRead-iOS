import XCTest
@testable import MoReadCore

final class ReadingStatisticsTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/New_York")!
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testReadingSplitsMidnightAndDaylightSavingHoursWithoutInventingHistory() throws {
        var value = try JSONDecoder().decode(BookRecords.self, from: Data("{\"annotations\":[],\"bookmarks\":[],\"readingSeconds\":{\"2026-03-07\":60}}".utf8))
        XCTAssertNil(value.readingHours)
        value.recordReading(from: date("2026-03-08T04:30:00Z"), to: date("2026-03-08T08:30:00Z"), timeZone: zone)
        XCTAssertEqual(value.readingSeconds["2026-03-07"], 1860)
        XCTAssertEqual(value.readingSeconds["2026-03-08"], 12600)
        XCTAssertEqual(value.readingHours?["2026-03-07"]?[23], 1800)
        XCTAssertEqual(value.readingHours?["2026-03-08"]?[2], 0)
        XCTAssertEqual(value.readingHours?["2026-03-08"]?.reduce(0, +), 12600)
        var fall = BookRecords()
        fall.recordReading(from: date("2026-11-01T04:30:00Z"), to: date("2026-11-01T08:30:00Z"), timeZone: zone)
        XCTAssertEqual(fall.readingSeconds["2026-11-01"], 14400)
        XCTAssertEqual(fall.readingHours?["2026-11-01"]?[1], 7200)
        let encoded = try JSONEncoder().encode(fall)
        XCTAssertEqual(try JSONDecoder().decode(BookRecords.self, from: encoded).readingHours, fall.readingHours)
        fall.recordReading(from: date("2026-11-02T00:00:00Z"), to: date("2026-11-01T00:00:00Z"), timeZone: zone)
        XCTAssertEqual(fall.readingSeconds.count, 1)
        var glance = BookRecords()
        let start = date("2026-09-22T12:00:00Z")
        glance.recordReading(from: start, to: start.addingTimeInterval(0.5), timeZone: zone)
        XCTAssertTrue(glance.readingSeconds.isEmpty)
    }

    func testPeriodsCalendarStreaksRankingTagsAndInvalidRecords() throws {
        var first = Book(title: "甲", author: "作者", chapters: [.init(id: 0, title: "开篇", text: "正文")])
        first.tags = ["旧标签"]; first.state = "已读"
        var second = Book(title: "乙", author: "作者", chapters: first.chapters.map { .init(id: $0.id, title: $0.title, text: "正文") })
        second.removed = true; second.bodyCleared = true
        var one = BookRecords(), two = BookRecords()
        one.readingSeconds = ["2026-08-30": 300, "2026-08-31": 60, "2026-09-01": 120, "2026-09-02": 180, "2026-09-20": 900, "2026-09-21": 300, "bad": 30, "2026-02-30": 999, "2026-09-22": -.infinity]
        two.readingSeconds = ["2026-09-20": 60, "2026-09-21": 1200]
        one.readingHours = ["2026-09-20": Array(repeating: 0, count: 9) + [900] + Array(repeating: 0, count: 14)]
        two.readingHours = ["2026-09-20": [60], "2026-09-21": Array(repeating: 100, count: 24)]
        var organization = ShelfOrganization(); let tag = ShelfTag(name: "文学")
        organization.tags = [tag]; organization.bookTags[first.id] = [tag.id]
        let now = date("2026-09-22T16:00:00Z")
        let stats = ReadingStatistics(books: [first, second], records: [first.id: one, second.id: two], organization: organization, anchor: now, now: now, timeZone: zone)
        XCTAssertEqual(stats.totalSeconds, 2760); XCTAssertEqual(stats.previousSeconds, 360)
        XCTAssertEqual(stats.periodDays.count, 4); XCTAssertEqual(stats.monthDays.count, 4)
        XCTAssertEqual(stats.streak, 2); XCTAssertEqual(stats.longestStreak, 4)
        XCTAssertEqual(stats.books.map(\.id), [first.id, second.id]); XCTAssertEqual(stats.finishedBooks, 1)
        XCTAssertEqual(stats.tags.first?.label, "文学"); XCTAssertEqual(stats.tags.first?.seconds, 1500)
        XCTAssertEqual(stats.authors.first?.books, 2); XCTAssertEqual(stats.authors.first?.seconds, 2760)
        XCTAssertEqual(stats.hourlySeconds[9], 900); XCTAssertEqual(stats.unassignedHourlySeconds, 1860)
        XCTAssertEqual(stats.trend.count, 30); XCTAssertFalse(stats.canGoNext)
        let old = ReadingStatistics(books: [first, second], records: [first.id: one, second.id: two], period: .week, anchor: date("2026-08-31T16:00:00Z"), now: now, timeZone: zone)
        XCTAssertTrue(old.canGoNext); XCTAssertEqual(old.totalSeconds, 360); XCTAssertEqual(old.streak, 2)
        XCTAssertEqual(old.trend.map(\.label), ["一", "二", "三", "四", "五", "六", "日"])
        XCTAssertEqual(old.monthDays.count, 2)
        let total = ReadingStatistics(books: [first, second], records: [first.id: one, second.id: two], period: .total, now: now, timeZone: zone)
        XCTAssertEqual(total.totalSeconds, 3120); XCTAssertEqual(total.trend.first?.label, "2026"); XCTAssertFalse(total.canGoNext)
        let year = ReadingStatistics(books: [first, second], records: [first.id: one, second.id: two], period: .year, anchor: now, now: now, timeZone: zone)
        XCTAssertEqual(year.trend.count, 12); XCTAssertEqual(year.trend[7].seconds, 360); XCTAssertEqual(year.trend[8].seconds, 2760)
        let day = ReadingStatistics(books: [first, second], records: [first.id: one, second.id: two], period: .day, anchor: date("2026-09-20T16:00:00Z"), now: now, timeZone: zone)
        XCTAssertEqual(day.totalSeconds, 960); XCTAssertEqual(day.trend.count, 24); XCTAssertEqual(day.trend[9].seconds, 900)
    }

    func testGregorianKeysLeapYearsAndWeekBoundaries() {
        let calendar = ReadingCalendar.calendar(timeZone: zone)
        XCTAssertNil(ReadingCalendar.date("2026-02-29", calendar: calendar))
        XCTAssertNil(ReadingCalendar.date("2026-2-03", calendar: calendar))
        XCTAssertNil(ReadingCalendar.date("0000-01-01", calendar: calendar))
        XCTAssertNotNil(ReadingCalendar.date("2024-02-29", calendar: calendar))
        let january = date("2026-01-31T17:00:00Z")
        XCTAssertEqual(ReadingCalendar.key(ReadingPeriod.month.shifted(january, by: 1, calendar: calendar), calendar: calendar), "2026-02-28")
        let week = ReadingPeriod.week.interval(around: date("2026-01-01T17:00:00Z"), calendar: calendar)!
        XCTAssertEqual(ReadingCalendar.key(week.start, calendar: calendar), "2025-12-29")
        XCTAssertEqual(ReadingCalendar.key(week.end, calendar: calendar), "2026-01-05")
        let widgets = StatisticsWidgets(data: Data("{\"order\":[\"hours\",\"hours\",\"unknown\"],\"hidden\":[\"books\",\"unknown\"]}".utf8))
        XCTAssertEqual(widgets.order.first, "hours"); XCTAssertEqual(widgets.order.count, 8)
        XCTAssertEqual(widgets.hidden, ["books"]); XCTAssertEqual(StatisticsWidgets(data: widgets.encoded()).visible.count, 7)
    }
}
