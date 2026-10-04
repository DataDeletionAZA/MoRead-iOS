import XCTest

final class ChapterRuleAssistantUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    private func open(_ app: XCUIApplication, flags: [String] = []) {
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--preview-test-text", "--simulate-chapter-rule"] + flags
        app.launch()
        let open = app.buttons["import-ai-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 20)); XCTAssertTrue(open.isEnabled); open.tap()
        XCTAssertTrue(app.buttons["chapter-ai-start"].waitForExistence(timeout: 5))
    }
    func testProposalCanBeReviewedThenAppliedAndImported() {
        let app = XCUIApplication(); open(app)
        app.buttons["chapter-ai-start"].tap()
        XCTAssertTrue(app.staticTexts["chapter-ai-result"].waitForExistence(timeout: 15))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "chapter-rule-proposal"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["chapter-ai-close"].tap()
        XCTAssertFalse(app.buttons["import-ai-edit"].exists)
        app.buttons["import-ai-open"].tap(); app.buttons["chapter-ai-start"].tap()
        XCTAssertTrue(app.buttons["chapter-ai-apply"].waitForExistence(timeout: 15)); app.buttons["chapter-ai-apply"].tap()
        XCTAssertTrue(app.staticTexts["import-preview"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["import-ai-edit"].exists)
        XCTAssertTrue(app.staticTexts["import-preview"].label.contains("她在第一页写下今天的日期"))
        app.buttons["import-ai-edit"].tap()
        let rule = app.descendants(matching: .any).matching(identifier: "import-rule").firstMatch
        XCTAssertEqual(rule.value as? String, "^第[一二三四五六七八九十0-9]+章.*$")
        app.buttons["更新预览"].tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["import-preview"].waitForExistence(timeout: 10))
        app.buttons["confirm-text-import"].tap()
        XCTAssertTrue(app.buttons["取消导入"].waitForExistence(timeout: 10)); app.buttons["取消导入"].tap()
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        XCTAssertTrue(app.textViews["reader-text"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["下一章"].tap(); XCTAssertTrue(app.navigationBars["第二章 来信"].waitForExistence(timeout: 5))
    }
    func testFailureStopAndClosePreserveImport() {
        let app = XCUIApplication(); open(app, flags: ["--chapter-rule-fail"])
        app.buttons["chapter-ai-start"].tap()
        let message = app.staticTexts["chapter-ai-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10)); XCTAssertTrue(message.label.contains("服务暂不可用")); XCTAssertFalse(app.buttons["chapter-ai-apply"].exists)
        app.buttons["chapter-ai-close"].tap(); XCTAssertTrue(app.buttons["confirm-text-import"].isEnabled)
        app.terminate(); open(app, flags: ["--chapter-rule-slow"])
        app.buttons["chapter-ai-start"].tap(); XCTAssertTrue(app.buttons["chapter-ai-stop"].waitForExistence(timeout: 10)); app.buttons["chapter-ai-stop"].tap()
        XCTAssertTrue(app.buttons["chapter-ai-start"].waitForExistence(timeout: 5)); XCTAssertTrue(message.label.contains("已停止")); XCTAssertFalse(app.buttons["chapter-ai-apply"].exists)
        app.buttons["chapter-ai-start"].tap(); app.buttons["chapter-ai-close"].tap()
        XCTAssertTrue(app.buttons["confirm-text-import"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["confirm-text-import"].isEnabled)
        XCTAssertTrue(app.staticTexts["import-preview"].label.contains("她在第一页写下今天的日期"))
    }
}
