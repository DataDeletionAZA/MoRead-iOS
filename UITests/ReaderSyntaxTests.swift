import XCTest

final class ReaderSyntaxUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testGradientRulesInScrollingAndPagingKeepBookmarksAfterRestart() {
        executionTimeAllowance = 300
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--syntax-reading-sample"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        book.tap()
        let text = app.textViews["reader-text"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10)); let original = text.value as? String
        app.buttons["排版"].tap(); app.buttons["字体与段落"].tap()
        let enabled = app.switches["reader-syntax-enabled"]
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["编辑文字规则"].tap(); app.buttons["添加文字规则"].tap()
        let name = app.textFields["review-rule-name"]; name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String ?? "").count) + "Dialogue\n")
        app.buttons["检查当前正文"].tap(); XCTAssertEqual(app.staticTexts["review-rule-matches"].label, "找到 1 处匹配")
        let css = app.textViews["review-rule-css"]
        for _ in 0..<12 { if css.isHittable && css.frame.maxY < app.frame.maxY - 60 { break }; app.swipeUp() }
        css.tap(); css.typeText("color: linear-gradient(to right, #c64a26, #446bd0); background: #fff2cc; text-decoration: underline; font-style: italic;\n")
        app.buttons["review-rule-save"].tap()
        XCTAssertTrue(app.buttons["review-rule-Dialogue"].waitForExistence(timeout: 5))
        app.navigationBars["文字着色规则"].buttons.firstMatch.tap(); app.navigationBars["字体与段落"].buttons.firstMatch.tap(); app.buttons["完成"].tap()
        XCTAssertEqual(text.value as? String, original)
        func shot(_ name: String) { let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot) }
        shot("syntax-scrolling-gradient-wave")
        app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons["无动画翻页"].tap(); app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["reader-next-page"].waitForExistence(timeout: 10)); shot("syntax-paged-gradient-wave")
        app.buttons["reader-next-page"].tap()
        let turned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "本章 2 /"), object: app.staticTexts["reader-page-number"])
        XCTAssertEqual(XCTWaiter.wait(for: [turned], timeout: 10), .completed)
        let saved = text.value as? String
        app.buttons["书签"].tap(); app.buttons["添加当前位置书签"].tap(); app.buttons["完成"].tap()
        app.buttons["reader-next-page"].tap(); app.buttons["书签"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmark-")).firstMatch.tap()
        XCTAssertEqual(text.value as? String, saved)
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); book.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 10)); XCTAssertEqual(text.value as? String, saved)
        app.buttons["排版"].tap(); app.buttons["字体与段落"].tap()
        XCTAssertEqual(enabled.value as? String, "1")
        app.buttons["编辑文字规则"].tap(); XCTAssertTrue(app.buttons["review-rule-Dialogue"].exists)
        app.buttons["review-rule-Dialogue"].tap()
        for _ in 0..<12 { if css.isHittable { break }; app.swipeUp() }
        XCTAssertTrue((css.value as? String ?? "").contains("linear-gradient"))
    }
}
