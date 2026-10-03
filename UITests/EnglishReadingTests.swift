import XCTest

final class EnglishReadingTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    func testInlineAndPopupVocabularyPreserveReadingText() {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--translation-pages-sample", "--english-reading-sample"]
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        XCTAssertTrue(app.buttons["排版"].waitForExistence(timeout: 10))
        app.buttons["排版"].tap(); app.buttons["阅读辅助"].tap()
        for key in ["english-learning", "english-bionic"] {
            let toggle = app.switches[key]; XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        app.navigationBars["阅读辅助"].buttons.element(boundBy: 0).tap(); app.buttons["完成"].tap()
        let body = app.textViews["reader-text"].firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        XCTAssertTrue((body.value as? String ?? "").contains("After the rain"))
        XCTAssertFalse((body.value as? String ?? "").contains("书店"))
        func screenshot(_ name: String) { let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot) }
        screenshot("english-inline-continuous")
        app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons["无动画翻页"].tap(); app.buttons["完成"].tap()
        screenshot("english-inline-paged")
        app.buttons["reader-next-page"].tap()
        let saved = body.value as? String
        app.buttons["书签"].tap(); app.buttons["添加当前位置书签"].tap(); app.buttons["完成"].tap()
        app.buttons["reader-next-page"].tap(); app.buttons["书签"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmark-")).firstMatch.tap()
        XCTAssertEqual(body.value as? String, saved)
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        XCTAssertTrue(body.waitForExistence(timeout: 10)); XCTAssertEqual(body.value as? String, saved)
        app.buttons["排版"].tap(); app.buttons["阅读辅助"].tap()
        XCTAssertEqual(app.switches["english-learning"].value as? String, "1")
        XCTAssertEqual(app.switches["english-bionic"].value as? String, "1")
        app.buttons["english-annotation-mode"].tap(); app.buttons["划线弹窗"].tap()
        app.navigationBars["阅读辅助"].buttons.element(boundBy: 0).tap(); app.buttons["完成"].tap()
        screenshot("english-popup-paged")
        let paragraph = body.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "Paragraph 1.")).firstMatch
        XCTAssertTrue(paragraph.exists)
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.44, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).tap()
        XCTAssertTrue(app.textFields["dictionary-query"].waitForExistence(timeout: 10))
        XCTAssertEqual((app.textFields["dictionary-query"].value as? String)?.lowercased(), "after")
        XCTAssertTrue(app.staticTexts["生词本释义"].waitForExistence(timeout: 10))
        let learned = app.switches["dictionary-word-learned"]
        XCTAssertTrue(learned.waitForExistence(timeout: 10)); learned.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        screenshot("english-saved-definition")
        app.buttons["完成"].tap()
        screenshot("english-learned-word-unmarked")
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.44, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).tap()
        XCTAssertFalse(app.textFields["dictionary-query"].exists)
        XCTAssertFalse(app.buttons["排版"].exists)
    }

    func testPopupInEveryTextPageMode() {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--translation-pages-sample", "--english-reading-sample"]
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        XCTAssertTrue(app.buttons["排版"].waitForExistence(timeout: 10))
        app.buttons["排版"].tap(); app.buttons["阅读辅助"].tap()
        for key in ["english-learning", "english-bionic"] { app.switches[key].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        app.buttons["english-annotation-mode"].tap(); app.buttons["划线弹窗"].tap()
        app.navigationBars["阅读辅助"].buttons.element(boundBy: 0).tap(); app.buttons["完成"].tap()
        for mode in ["上下滚动", "无动画翻页", "覆盖翻页", "滑动翻页", "仿真翻页"] {
            app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons[mode].tap(); app.buttons["完成"].tap()
            let paragraph = app.textViews["reader-text"].firstMatch.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "Paragraph 1.")).firstMatch
            XCTAssertTrue(paragraph.waitForExistence(timeout: 10))
            paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.44, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).tap()
            XCTAssertTrue(app.textFields["dictionary-query"].waitForExistence(timeout: 10), mode)
            XCTAssertEqual((app.textFields["dictionary-query"].value as? String)?.lowercased(), "after", mode)
            XCTAssertTrue(app.staticTexts["生词本释义"].waitForExistence(timeout: 10))
            app.buttons["完成"].tap()
        }
    }
}
