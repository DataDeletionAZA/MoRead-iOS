import XCTest
@testable import MoReadCore

final class AutoReadTests: XCTestCase {
    func testReadinessResumeAndStallsDoNotSkipTextOrCatchUpPages() throws {
        var settings = AutoReadSettings()
        var clock = AutoReadClock()
        XCTAssertEqual(clock.step(at: 1, settings: settings), 0)
        XCTAssertEqual(clock.step(at: 1.05, settings: settings), 1.2, accuracy: 0.001)
        XCTAssertEqual(clock.step(at: 50, settings: settings), 2.4, accuracy: 0.001)
        clock.reset()
        XCTAssertEqual(clock.step(at: 100, settings: settings), 0)
        settings.mode = .page; settings.interval = 3; clock.reset()
        XCTAssertEqual(clock.step(at: 100, settings: settings), 0)
        XCTAssertEqual(clock.step(at: 102.9, settings: settings), 0)
        XCTAssertEqual(clock.step(at: 140, settings: settings), 1)
        clock.pageCommitted(at: 145)
        XCTAssertEqual(clock.step(at: 145.1, settings: settings), 0)
        clock.reset()
        XCTAssertEqual(clock.step(at: 200, settings: settings), 0)
        settings.speed = .nan; settings.interval = .infinity
        XCTAssertEqual(settings.validated().speed, 24)
        XCTAssertEqual(settings.validated().interval, 15)
        settings.speed = -1; settings.interval = 1000
        XCTAssertEqual(AutoReadSettings(data: settings.encoded()).speed, 8)
        XCTAssertEqual(AutoReadSettings(data: settings.encoded()).interval, 120)
        XCTAssertEqual(AutoReadSettings(data: Data("{}".utf8)), AutoReadSettings())
    }
}
