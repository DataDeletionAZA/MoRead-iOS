import XCTest

final class ReadingTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    func testShelfGroupAndAssignmentSurviveRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library"]
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15))
        app.buttons["add-sample"].tap()
        app.tabBars.buttons["设置"].tap()
        app.buttons["整理书架"].tap()
        app.buttons["new-shelf-group"].tap()
        app.textFields["group-name"].tap(); app.textFields["group-name"].typeText("旅行")
        app.buttons["保存"].tap()
        app.buttons["批量整理书籍"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["已选 1 本"].exists)
        XCTAssertTrue(app.buttons["分组"].isHittable)
        app.buttons["分组"].tap()
        app.buttons["旅行"].tap()
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["旅行"].waitForExistence(timeout: 10)); app.buttons["旅行"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.waitForExistence(timeout: 10))
    }

    func testCreateLocalBackupFromSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library"]
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15))
        app.buttons["add-sample"].tap()
        app.tabBars.buttons["设置"].tap()
        app.buttons["备份与恢复"].tap()
        app.buttons["create-backup"].tap()
        XCTAssertTrue(app.buttons["share-backup"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.alerts["需要处理"].exists)
    }

    func testEPUBContentsAndLocationSurviveRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library"]
        app.launch()
        XCTAssertTrue(app.buttons["add-epub-sample"].waitForExistence(timeout: 15))
        app.buttons["add-epub-sample"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店 · EPUB")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20)); book.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))
        app.buttons["目录"].tap()
        app.buttons["第二章 来信"].tap()
        let text = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "一封没有署名的信")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 20))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 20))
    }

    func testOpenBookAndKeepLibraryAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library"]
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15))
        app.buttons["add-sample"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        XCTAssertTrue(app.textViews["reader-text"].waitForExistence(timeout: 10))
        XCTAssertTrue((app.textViews["reader-text"].value as? String)?.contains("她在第一页写下今天的日期") == true)
        app.textViews["reader-text"].swipeUp()
        app.buttons["下一章"].tap()
        XCTAssertTrue(app.navigationBars["第二章 来信"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        XCTAssertTrue(app.navigationBars["第二章 来信"].waitForExistence(timeout: 10))
    }
}
