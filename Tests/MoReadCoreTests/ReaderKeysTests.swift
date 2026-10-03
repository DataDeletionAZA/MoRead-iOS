import XCTest
@testable import MoReadCore

final class ReaderKeysTests: XCTestCase {
    func testBindingConflictsModifiersPersistenceAndInvalidInput() throws {
        var keys = ReaderKeys(); let a = ReaderKey(code: 4, modifiers: 2)
        XCTAssertNil(keys.direction(for: a)); keys.enabled = true
        keys.bind(a, forward: true); XCTAssertEqual(keys.direction(for: a), true)
        XCTAssertNil(keys.direction(for: ReaderKey(code: 4)))
        keys.bind(a, forward: false)
        XCTAssertEqual(keys.bindings.filter { $0.key == a }.count, 1)
        XCTAssertEqual(ReaderKeys(data: keys.encoded()).direction(for: a), false)
        keys.bind(.init(code: 41), forward: true)
        XCTAssertFalse(keys.bindings.contains { $0.key.code == 41 })
        let duplicate = ReaderKeyBinding(key: a, forward: true)
        keys.bindings += [duplicate, .init(key: .init(code: 999), forward: false)]
        let decoded = ReaderKeys(data: keys.encoded())
        XCTAssertEqual(decoded.bindings.filter { $0.key == a }.count, 1)
        XCTAssertTrue(decoded.bindings.allSatisfy { $0.key.isValid })
        XCTAssertFalse(ReaderKeys(data: Data("invalid".utf8)).enabled)
        XCTAssertEqual(a.label, "⌃A")
        keys.bind(.init(code: 40), forward: true); XCTAssertEqual(keys.direction(for: .init(code: 40)), true)
        XCTAssertEqual(ReaderKey(code: 43, modifiers: 1).label, "⇧Tab")
    }
}
