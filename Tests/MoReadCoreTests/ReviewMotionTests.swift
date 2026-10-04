import XCTest
@testable import MoReadCore

final class ReviewMotionTests: XCTestCase {
    func testModesEdgesFiniteValuesReducedMotionAndTilt() {
        XCTAssertEqual(ReviewFocusMotion(saved: "unknown"), .paper)
        XCTAssertEqual(ReviewFocusMotion(saved: "FLOW"), .flow)
        let identity = ReviewFocusMotion.paper.frame(position: 0)
        for mode in ReviewFocusMotion.allCases {
            for offset in [-100.0, -1, -0.5, 0, 0.5, 1, 100, .infinity, .nan] {
                let value = mode.frame(position: offset, tiltX: .infinity, tiltY: .nan)
                XCTAssertTrue((0...1).contains(value.alpha)); XCTAssertTrue((0.8...1).contains(value.scale))
                XCTAssertTrue(value.rotationX.isFinite && value.rotationY.isFinite && value.translationX.isFinite)
                XCTAssertEqual(mode.frame(position: offset, tiltX: 8, tiltY: -8, reduceMotion: true), identity)
            }
        }
        XCTAssertEqual(ReviewFocusMotion.paper.frame(position: 1).rotationZ, 2.5)
        XCTAssertEqual(ReviewFocusMotion.cube.frame(position: -0.5).pivotX, 1)
        XCTAssertEqual(ReviewFocusMotion.cube.frame(position: 0.5).rotationY, 45)
        XCTAssertEqual(ReviewFocusMotion.cube.frame(position: 1).alpha, 0)
        XCTAssertEqual(ReviewFocusMotion.flow.frame(position: 1).rotationY, -52)
        XCTAssertEqual(ReviewFocusMotion.flow.frame(position: 2).alpha, 0)
        var tilt = ReviewTiltState(); tilt.update(gravityX: 0, gravityY: 5)
        XCTAssertEqual(tilt.x, 0); XCTAssertEqual(tilt.y, 0)
        for _ in 0..<100 { tilt.update(gravityX: 20, gravityY: 20) }
        XCTAssertTrue((0...8).contains(tilt.x)); XCTAssertTrue((-8...0).contains(tilt.y))
        let saved = tilt; tilt.update(gravityX: .nan, gravityY: .infinity)
        XCTAssertEqual(tilt.x, saved.x); XCTAssertEqual(tilt.y, saved.y)
    }
}
