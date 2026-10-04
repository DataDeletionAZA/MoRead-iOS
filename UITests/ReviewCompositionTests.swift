import XCTest

final class ReviewCompositionUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testPreviewEditSaveRestartStopAndFailureKeepOriginalNotes() {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-review-composition"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        app.buttons["批注"].tap(); app.buttons["读书笔记与梗概"].tap(); app.buttons["新建笔记"].tap()
        app.textFields["reading-note-title"].tap(); app.textFields["reading-note-title"].typeText("My original note")
        app.textViews["reading-note-content"].tap(); app.textViews["reading-note-content"].typeText("The light reminds me of home.")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.buttons["reading-note-My original note"].waitForExistence(timeout: 5))
        app.navigationBars["读书笔记与梗概"].buttons.firstMatch.tap(); app.buttons["划线与笔记回顾"].tap()
        func invite(_ mode: String, requirement: String = "") {
            let visibleInvite = NSPredicate { _, _ in app.buttons.matching(identifier: "邀请角色").allElementsBoundByIndex.contains { $0.isHittable } }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visibleInvite, object: nil)], timeout: 10), .completed)
            let inviteButton = app.buttons.matching(identifier: "邀请角色").allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(inviteButton); inviteButton?.tap(); app.buttons[mode].tap()
            XCTAssertTrue(app.buttons["review-compose-generate"].waitForExistence(timeout: 5))
            if !requirement.isEmpty {
                app.descendants(matching: .any)["review-compose-instruction"].tap(); app.descendants(matching: .any)["review-compose-instruction"].typeText(requirement)
            }
        }
        func generate() {
            XCTAssertTrue(app.buttons["review-compose-generate"].isEnabled)
            app.buttons["review-compose-generate"].tap()
            XCTAssertTrue(app.alerts.buttons["确认生成"].waitForExistence(timeout: 5)); app.alerts.buttons["确认生成"].tap()
        }
        invite("共创笔记")
        XCTAssertTrue(app.staticTexts["The light reminds me of home."].exists)
        app.buttons["review-compose-generate"].tap(); app.alerts.buttons["取消"].tap()
        XCTAssertFalse(app.textViews["review-draft-content"].exists)
        generate()
        XCTAssertTrue(app.buttons["review-compose-save"].waitForExistence(timeout: 10))
        let draft = app.textViews["review-draft-content"]
        XCTAssertTrue((draft.value as? String ?? "").contains("素材 [1]"))
        draft.tap(); draft.typeText("Personal thought. ")
        XCTAssertTrue((draft.value as? String ?? "").contains("Personal thought."))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "review-editable-composition"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["review-compose-save"].tap()
        XCTAssertTrue(app.buttons["review-entry-My original note"].waitForExistence(timeout: 10))
        let savedTitle = "《雨后的书店》读书笔记"
        XCTAssertTrue(app.buttons["review-entry-" + savedTitle].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = ["--ui-testing", "--simulate-review-composition"]; app.launch()
        app.buttons["书架选项"].tap(); app.buttons["划线与笔记回顾"].tap()
        XCTAssertTrue(app.buttons["review-entry-My original note"].waitForExistence(timeout: 10))
        app.buttons["review-entry-" + savedTitle].tap()
        XCTAssertTrue(app.textViews["reading-review-body"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue((app.textViews["reading-review-body"].firstMatch.value as? String ?? "").contains("Personal thought."))
        XCTAssertTrue((app.textViews["reading-review-body"].firstMatch.value as? String ?? "").contains("素材出处"))
        invite("角色点评", requirement: "slow"); generate()
        XCTAssertTrue(app.buttons["review-compose-stop"].waitForExistence(timeout: 5)); app.buttons["review-compose-stop"].tap()
        XCTAssertTrue(app.staticTexts["review-compose-error"].waitForExistence(timeout: 5))
        XCTAssertTrue((draft.value as? String ?? "").contains("这是角色补充的观点"))
        XCTAssertTrue(app.buttons["review-compose-save"].exists)
        app.buttons["关闭"].tap(); app.buttons["放弃并关闭"].tap()
        invite("角色点评", requirement: "fail"); generate()
        XCTAssertTrue(app.staticTexts["点评服务暂不可用。"].waitForExistence(timeout: 10))
        XCTAssertTrue((draft.value as? String ?? "").contains("这是角色补充的观点"))
        app.buttons["关闭"].tap(); app.buttons["放弃并关闭"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.buttons["完成"].isHittable }, object: nil)], timeout: 10), .completed)
        app.buttons["完成"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "review-entry-" + savedTitle).count, 1)
        app.buttons["review-entry-My original note"].tap()
        XCTAssertTrue(app.textViews["reading-review-body"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews["reading-review-body"].firstMatch.value as? String, "The light reminds me of home.")
        XCTAssertTrue(app.staticTexts["reading-review-position"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reading-review-position"].label, "2 / 2")
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.buttons["书架选项"].tap(); app.buttons["划线与笔记回顾"].tap()
        XCTAssertTrue(app.buttons["review-entry-My original note"].waitForExistence(timeout: 10)); app.buttons["review-entry-My original note"].tap()
        invite("角色点评")
        let material = app.switches["review-material-My original note"]
        XCTAssertTrue(material.waitForExistence(timeout: 5))
        material.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertFalse(app.buttons["review-compose-generate"].isEnabled)
        material.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        generate()
        XCTAssertTrue(app.staticTexts["请先在设置中添加并选择 AI 模型。"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["review-compose-save"].isEnabled)
    }
}
