import XCTest
@testable import MoReadCore

final class BookDescriptionTests: XCTestCase {
    func testPreferredInlineFallbackAndUnicodeLimit() {
        let first = Chapter(id: 0, title: "开篇", text: "作者：某人\n书名：一本书\n第一段。")
        XCTAssertEqual(BookDescription.extract([first]), "第一段。")
        XCTAssertEqual(BookDescription.extract([first, Chapter(id: 1, title: "内容简介", text: "简介正文。")]), "简介正文。")
        XCTAssertEqual(BookDescription.extract([Chapter(id: 0, title: "开篇", text: "作者：某人\n简介：一间书店。\n雨后开门。\n正文\n后续章节。")]), "一间书店。\n\n雨后开门。")
        XCTAssertEqual(BookDescription.extract([first, Chapter(id: 1, title: "前言", text: "前言文字。")]), "前言文字。")
        XCTAssertEqual(BookDescription.extract([Chapter(id: 0, title: "", text: String(repeating: "👩🏽‍💻", count: 10))], maximum: 2), "👩🏽‍💻👩🏽‍💻…")
        XCTAssertEqual(BookDescription.extract([]), "")
        XCTAssertEqual(BookDescription.extract([first], maximum: 0), "")
    }
}
