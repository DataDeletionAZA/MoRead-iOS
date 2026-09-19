import XCTest

final class ReadingTests: XCTestCase {
    func testOpenBookAndKeepLibraryAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library"]
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15))
        app.buttons["add-sample"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        XCTAssertTrue(app.textViews["reader-text"].waitForExistence(timeout: 10))
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
