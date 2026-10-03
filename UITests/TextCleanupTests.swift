import XCTest

final class TextCleanupTests: XCTestCase {
    func testPreviewConfirmAndPersistEditedText() {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--translation-sample"]
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        func openBook() {
            let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
            XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        }
        func openCleanup() {
            app.buttons["目录"].tap()
            let button = app.buttons["cleanup-open"]
            for _ in 0..<3 where !button.isHittable { app.swipeUp() }
            button.tap(); XCTAssertTrue(app.buttons["cleanup-add"].waitForExistence(timeout: 10))
        }
        openBook(); openCleanup()
        app.buttons["cleanup-add"].tap()
        let pattern = app.descendants(matching: .any)["cleanup-pattern"]
        XCTAssertTrue(pattern.waitForExistence(timeout: 5)); pattern.tap(); pattern.typeText("rain")
        let replacement = app.descendants(matching: .any)["cleanup-replacement"]
        replacement.tap(); replacement.typeText("sunrise")
        app.buttons["cleanup-save-rule"].tap()
        app.buttons["cleanup-preview"].tap()
        let summary = app.staticTexts["cleanup-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 15)); XCTAssertEqual(summary.label, "匹配 1 处 · 改动 1 章")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "text-cleanup-preview"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["cleanup-apply"].tap(); app.alerts.buttons["取消"].tap()
        XCTAssertTrue(summary.exists)
        app.buttons["cleanup-apply"].tap(); app.alerts.buttons["确认应用"].tap()
        XCTAssertTrue(app.staticTexts["正文已更新。"].waitForExistence(timeout: 15))
        app.navigationBars["正文清理"].buttons.firstMatch.tap(); app.buttons["完成"].tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "After the sunrise")).firstMatch.waitForExistence(timeout: 10))
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); openBook()
        let source = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "After the sunrise")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        let reader = XCTAttachment(screenshot: app.screenshot()); reader.name = "text-cleanup-updated-reader"; reader.lifetime = .keepAlways; add(reader)
        openCleanup(); app.buttons["cleanup-preview"].tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 15)); XCTAssertEqual(summary.label, "匹配 0 处 · 改动 0 章")
        XCTAssertFalse(app.buttons["cleanup-apply"].isEnabled)
    }
}
