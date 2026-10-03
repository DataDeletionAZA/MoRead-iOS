import XCTest

final class TextCleanupProposalTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    func testDraftCancelErrorsSaveAndApply() {
        executionTimeAllowance = 360
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--translation-sample", "--simulate-cleanup-rule"]
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        func openCleanup() {
            let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
            XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
            app.buttons["目录"].tap()
            let open = app.buttons["cleanup-open"]
            for _ in 0..<3 where !open.isHittable { app.swipeUp() }
            open.tap(); XCTAssertTrue(app.buttons["cleanup-ai-open"].waitForExistence(timeout: 10))
        }
        openCleanup(); app.buttons["cleanup-ai-open"].tap()
        let requirement = app.descendants(matching: .any)["cleanup-ai-requirement"]
        XCTAssertTrue(requirement.waitForExistence(timeout: 5))
        requirement.tap(); requirement.typeText("invalid")
        app.segmentedControls["cleanup-ai-scope"].buttons["全书"].tap()
        app.buttons["cleanup-ai-preview"].tap()
        XCTAssertTrue(app.staticTexts["cleanup-ai-summary"].waitForExistence(timeout: 10))
        let generate = app.buttons["cleanup-ai-generate"]
        func revealGenerate() {
            for _ in 0..<3 where !generate.isHittable { app.swipeUp() }
            XCTAssertTrue(generate.isHittable)
        }
        revealGenerate(); generate.tap(); app.alerts.buttons["取消"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["cleanup-pattern"].exists)
        generate.tap(); app.alerts.buttons["确认生成"].tap()
        XCTAssertTrue(app.staticTexts["cleanup-ai-error"].waitForExistence(timeout: 10))
        func changeRequirement(_ text: String) {
            for _ in 0..<3 where !requirement.isHittable { app.swipeDown() }
            requirement.tap()
            let old = requirement.value as? String ?? ""
            requirement.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + text)
            revealGenerate()
        }
        changeRequirement("fail"); generate.tap(); app.alerts.buttons["确认生成"].tap()
        XCTAssertTrue(app.staticTexts["清理规则服务暂不可用。"].waitForExistence(timeout: 10))
        changeRequirement("slow"); generate.tap(); app.alerts.buttons["确认生成"].tap()
        XCTAssertTrue(app.buttons["cleanup-ai-stop"].waitForExistence(timeout: 5)); app.buttons["cleanup-ai-stop"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["cleanup-pattern"].exists)
        changeRequirement("replace rain"); generate.tap(); app.alerts.buttons["确认生成"].tap()
        let pattern = app.descendants(matching: .any)["cleanup-pattern"]
        XCTAssertTrue(pattern.waitForExistence(timeout: 10)); XCTAssertEqual(pattern.value as? String, "rain")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "ai-cleanup-editable-draft"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["取消"].tap()
        app.buttons["关闭"].tap()
        XCTAssertFalse(app.switches.matching(NSPredicate(format: "label CONTAINS %@", "AI 清理规则")).firstMatch.exists)
        app.buttons["cleanup-ai-open"].tap()
        XCTAssertTrue(requirement.waitForExistence(timeout: 5)); requirement.tap(); requirement.typeText("replace rain")
        app.buttons["cleanup-ai-preview"].tap()
        XCTAssertTrue(app.staticTexts["cleanup-ai-summary"].waitForExistence(timeout: 10))
        revealGenerate(); generate.tap(); app.alerts.buttons["确认生成"].tap()
        XCTAssertTrue(pattern.waitForExistence(timeout: 10))
        let replacement = app.descendants(matching: .any)["cleanup-replacement"]
        replacement.tap(); replacement.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "sunlight")
        app.buttons["cleanup-save-rule"].tap()
        XCTAssertTrue(app.buttons["cleanup-preview"].waitForExistence(timeout: 10))
        app.buttons["cleanup-preview"].tap()
        XCTAssertTrue(app.staticTexts["cleanup-summary"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["cleanup-summary"].label, "匹配 1 处 · 改动 1 章")
        app.buttons["cleanup-apply"].tap(); app.alerts.buttons["确认应用"].tap()
        XCTAssertTrue(app.staticTexts["正文已更新。"].waitForExistence(timeout: 15))
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); openCleanup()
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label CONTAINS %@", "AI 清理规则")).firstMatch.exists)
        app.navigationBars["正文清理"].buttons.firstMatch.tap(); app.buttons["完成"].tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "After the sunlight")).firstMatch.waitForExistence(timeout: 10))
    }
}
