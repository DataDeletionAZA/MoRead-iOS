import XCTest
@testable import MoReadCore

final class ReaderTapZonesTests: XCTestCase {
    func testRegionsPersistenceAndMenuSafety() throws {
        for (width, height) in [(390.0, 700.0), (800.0, 350.0)] {
            for row in 0..<3 { for column in 0..<3 {
                XCTAssertEqual(ReaderTapZones.index(x: (Double(column) + 0.5) / 3 * width, y: (0.08 + (Double(row) + 0.5) * 0.28) * height, width: width, height: height), row * 3 + column)
            } }
            for (x, y, expected) in [(0.1, 0.04, 9), (0.9, 0.04, 10), (0.1, 0.96, 11), (0.9, 0.96, 12)] {
                XCTAssertEqual(ReaderTapZones.index(x: x * width, y: y * height, width: width, height: height), expected)
            }
        }
        XCTAssertEqual(ReaderTapZones.index(x: -1, y: -1, width: 100, height: 100), 9)
        XCTAssertEqual(ReaderTapZones.index(x: 100, y: 100, width: 100, height: 100), 12)
        XCTAssertEqual(ReaderTapZones.index(x: .nan, y: 0, width: 100, height: 100), 4)
        var zones = ReaderTapZones()
        for action in ReaderTapAction.allCases {
            zones.actions[0] = action
            XCTAssertEqual(ReaderTapZones(data: zones.encoded()), zones)
            XCTAssertEqual(zones.action(x: 10, y: 20, width: 100, height: 100), action)
        }
        zones.actions = Array(repeating: .none, count: 13)
        XCTAssertFalse(zones.isValid); XCTAssertNil(ReaderTapZones(data: try JSONEncoder().encode(zones)))
        zones.actions = [.menu]
        XCTAssertFalse(zones.isValid); XCTAssertNil(ReaderTapZones(data: try JSONEncoder().encode(zones)))
        XCTAssertNil(ReaderTapZones(data: Data()))
        XCTAssertNil(ReaderTapZones(data: Data("{\"actions\":[\"unknown\"]}".utf8)))
    }
}
