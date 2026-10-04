import XCTest
@testable import MoReadCore

final class ReaderLocationHintTests: XCTestCase {
    func testVisibilityIdentityRevisionAndUTF16Boundaries() {
        let chapter = Chapter(id: 2, title: "灯塔", text: "😀雨停了。灯塔亮起了。")
        let book = UUID(), source = SourcePassage(bookID: UUID(), chapter: chapter, offset: 6, text: "灯塔")
        var passage = source; passage.bookID = book
        var hint = ReaderLocationHint(passage: passage)
        var visible = SourcePassage(bookID: book, chapter: chapter, offset: 0, text: "😀雨停了。")
        hint.observe(nil); XCTAssertFalse(hint.seen)
        hint.observe(visible); XCTAssertFalse(hint.seen)
        visible.offset = 7; visible.text = "塔亮起了。"
        for invalid in 0..<4 {
            var value = visible
            switch invalid { case 0: value.bookID = UUID(); case 1: value.chapter = 1; case 2: value.revision = "old"; default: value.offset = Int.max }
            hint.observe(value); XCTAssertFalse(hint.seen)
        }
        hint.observe(visible); XCTAssertTrue(hint.seen)
        hint.observe(nil); XCTAssertTrue(hint.seen)
        XCTAssertNotEqual(hint.id, ReaderLocationHint(passage: passage).id)
        var empty = ReaderLocationHint(passage: .init(bookID: book, chapter: chapter, offset: 7, text: ""))
        empty.observe(visible); XCTAssertFalse(empty.seen)
    }
}
