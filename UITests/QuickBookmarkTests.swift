import XCTest

final class QuickBookmarkTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    private func pull(_ app: XCUIApplication, distance: CGFloat = 190) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: .slow, thenHoldForDuration: 0.4)
    }
    private func message(_ app: XCUIApplication, _ value: String) {
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@", "bookmark-pull-status", value)).firstMatch.waitForExistence(timeout: 5))
    }
    private func bookmarks(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmark-"))
    }
    func testImmersivePullKeepsControlsHidden() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons["无动画翻页"].tap()
        app.buttons["enter-immersive"].tap()
        XCTAssertFalse(app.buttons["排版"].exists)
        pull(app); message(app, "书签已保存")
        XCTAssertFalse(app.buttons["排版"].exists)
        XCTAssertTrue(app.statusBars.allElementsBoundByIndex.allSatisfy { !$0.isHittable })
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "TXT-immersive-quick-bookmark"; shot.lifetime = .keepAlways; add(shot)
        app.textViews["reader-text"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["书签"].waitForExistence(timeout: 5)); app.buttons["书签"].tap()
        XCTAssertEqual(bookmarks(app).count, 1)
    }
    func testTXTPullBookmarksAcrossPageModesCancelDuplicateRestoreAndRestart() {
        executionTimeAllowance = 300
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        book.tap()
        for (index, mode) in ["无动画翻页", "覆盖翻页", "滑动翻页", "仿真翻页"].enumerated() {
            app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons[mode].tap(); app.buttons["完成"].tap()
            XCTAssertTrue(app.staticTexts["reader-page-number"].waitForExistence(timeout: 10))
            if index == 0 {
                pull(app, distance: 45)
                XCTAssertFalse(app.staticTexts["bookmark-pull-status"].exists)
                app.buttons["书签"].tap(); XCTAssertEqual(bookmarks(app).count, 0); app.buttons["完成"].tap()
                app.buttons["reader-next-page"].tap()
            }
            let page = app.staticTexts["reader-page-number"].label
            let text = app.textViews["reader-text"].firstMatch.value as? String
            pull(app); message(app, index == 0 ? "书签已保存" : "这里已经有书签了")
            XCTAssertEqual(app.staticTexts["reader-page-number"].label, page)
            pull(app); message(app, "这里已经有书签了")
            app.buttons["书签"].tap(); XCTAssertEqual(bookmarks(app).count, 1); app.buttons["完成"].tap()
            app.textViews["reader-text"].firstMatch.swipeLeft()
            XCTAssertNotEqual(app.staticTexts["reader-page-number"].label, page)
            app.buttons["书签"].tap(); bookmarks(app).firstMatch.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", page), object: app.staticTexts["reader-page-number"])], timeout: 5), .completed)
            XCTAssertEqual(app.textViews["reader-text"].firstMatch.value as? String, text)
        }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "TXT-quick-bookmark-restored"; shot.lifetime = .keepAlways; add(shot)
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); book.tap()
        app.buttons["书签"].tap(); XCTAssertEqual(bookmarks(app).count, 1); app.buttons["完成"].tap()
        app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons["上下滚动"].tap(); app.buttons["完成"].tap()
        pull(app); XCTAssertFalse(app.staticTexts["bookmark-pull-status"].exists)
        app.buttons["书签"].tap(); XCTAssertEqual(bookmarks(app).count, 1)
    }
    func testEPUBPullBookmarkDuplicateNavigationAndScrollMode() throws {
        executionTimeAllowance = 180
        let app = XCUIApplication()
        let url = try XCTUnwrap(Bundle(for: QuickBookmarkTests.self).url(forResource: "Bilingual", withExtension: "epub"))
        app.launchEnvironment["MOREAD_TEST_EPUB"] = try Data(contentsOf: url).base64EncodedString()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-epub"]; app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店 · EPUB")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        let web = app.webViews.firstMatch
        let original = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "The same letter arrived twice.")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 15))
        pull(app, distance: 45); XCTAssertFalse(app.staticTexts["bookmark-pull-status"].exists)
        pull(app); message(app, "书签已保存")
        pull(app); message(app, "这里已经有书签了")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "EPUB-quick-bookmark-existing"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["书签"].tap(); XCTAssertEqual(bookmarks(app).count, 1)
        app.buttons["添加当前位置书签"].tap(); XCTAssertTrue(app.staticTexts["这里已经有书签了"].exists)
        XCTAssertEqual(bookmarks(app).count, 1); app.buttons["完成"].tap()
        web.swipeLeft(); app.buttons["书签"].tap(); bookmarks(app).firstMatch.tap()
        XCTAssertTrue(original.waitForExistence(timeout: 10)); XCTAssertTrue(original.isHittable)
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); book.tap()
        XCTAssertTrue(original.waitForExistence(timeout: 15))
        app.buttons["书签"].tap(); XCTAssertEqual(bookmarks(app).count, 1); app.buttons["完成"].tap()
        app.buttons["排版"].tap(); app.buttons["epub-page-mode"].tap(); app.buttons["上下滚动"].tap(); app.buttons["完成"].tap()
        XCTAssertTrue(web.waitForExistence(timeout: 15)); pull(app)
        XCTAssertFalse(app.staticTexts["bookmark-pull-status"].exists)
        app.buttons["书签"].tap(); XCTAssertEqual(bookmarks(app).count, 1)
    }
}
