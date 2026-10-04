import XCTest

final class ReviewCardUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testLongCardKeepsTextExportAndCanHideThought() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--long-review-card"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        app.buttons["书架选项"].tap(); app.buttons["划线与笔记回顾"].tap()
        XCTAssertTrue(app.buttons["review-entry-长篇读书笔记"].waitForExistence(timeout: 10)); app.buttons["review-entry-长篇读书笔记"].tap()
        XCTAssertTrue(app.buttons["review-card-export"].waitForExistence(timeout: 10))
        app.buttons["review-card-export"].tap()
        XCTAssertTrue(app.staticTexts["这条内容较长，请使用文字分享以保留全文。"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["review-card-share"].exists)
        XCTAssertTrue(app.buttons["分享文字"].isEnabled)
        let thought = app.switches["review-card-thought"]
        if !thought.isHittable { app.swipeUp() }
        thought.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.swipeDown()
        XCTAssertTrue(app.images["review-card-preview"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["review-card-error"].exists)
        app.swipeUp(); app.swipeUp()
        XCTAssertTrue(app.buttons["review-card-share"].exists); XCTAssertTrue(app.buttons["分享文字"].exists)
    }
    func testPreviewTemplatesOptionsAndRestart() {
        executionTimeAllowance = 300
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        app.buttons["批注"].tap(); app.buttons["读书笔记与梗概"].tap(); app.buttons["新建笔记"].tap()
        app.textFields["reading-note-title"].tap(); app.textFields["reading-note-title"].typeText("A light in the rain")
        let content = app.textViews["reading-note-content"]
        content.tap(); content.typeText("The lighthouse reminds me of home.\nA quiet place to read, and a light to return to.\n")
        XCTAssertTrue((content.value as? String ?? "").contains("return to.")); app.buttons["保存"].tap()
        app.navigationBars["读书笔记与梗概"].buttons.firstMatch.tap(); app.buttons["划线与笔记回顾"].tap()
        XCTAssertTrue(app.buttons["review-entry-A light in the rain"].waitForExistence(timeout: 10)); app.buttons["review-entry-A light in the rain"].tap()
        func openExport() {
            XCTAssertTrue(app.buttons["导出卡片"].waitForExistence(timeout: 10)); app.buttons["导出卡片"].tap()
            XCTAssertTrue(app.images["review-card-preview"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["review-card-error"].exists)
        }
        openExport()
        let first = XCTAttachment(screenshot: app.screenshot()); first.name = "review-card-paper"; first.lifetime = .keepAlways; add(first)
        app.buttons["review-card-style"].tap(); app.buttons["暗夜"].tap()
        XCTAssertTrue(app.images["review-card-preview"].waitForExistence(timeout: 10))
        app.buttons["新建自定义模板"].tap()
        let name = app.textFields["review-card-template-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String ?? "").count) + "Night card")
        XCTAssertEqual(name.value as? String, "Night card")
        name.typeText("\n")
        let css = app.textViews["review-card-css"]
        for _ in 0..<10 { if css.exists && css.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(css.isHittable); css.tap(); css.typeText("padding: -1em;")
        app.buttons["review-card-template-save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "padding：")).firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["好"].tap()
        css.tap(); css.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (css.value as? String ?? "").count))
        let style = "color: #38444b; color: linear-gradient(to right, #dc7858, #6590c5); background: linear-gradient(135deg, #f7f5ef, #d7e6f2); border-width: 0.05em; border-radius: 1em; font-size: 1.2em; text-align: center;"
        css.typeText(style + "\n"); XCTAssertTrue((css.value as? String ?? "").contains("text-align: center;"))
        app.buttons["review-card-template-save"].tap()
        XCTAssertTrue(app.buttons["编辑模板"].waitForExistence(timeout: 10))
        let custom = XCTAttachment(screenshot: app.screenshot()); custom.name = "review-card-night-template"; custom.lifetime = .keepAlways; add(custom)
        app.swipeUp()
        let thought = app.switches["review-card-thought"]
        XCTAssertTrue(thought.waitForExistence(timeout: 5)); thought.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(thought.value as? String, "0")
        app.swipeUp()
        XCTAssertTrue(app.buttons["review-card-share"].waitForExistence(timeout: 10)); app.buttons["review-card-share"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10))
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.buttons["书架选项"].tap(); app.buttons["划线与笔记回顾"].tap()
        XCTAssertTrue(app.buttons["review-entry-A light in the rain"].waitForExistence(timeout: 10)); app.buttons["review-entry-A light in the rain"].tap(); openExport()
        app.buttons["review-card-style"].tap(); XCTAssertTrue(app.buttons["Night card"].waitForExistence(timeout: 5)); app.buttons["Night card"].tap()
        XCTAssertTrue(app.buttons["编辑模板"].waitForExistence(timeout: 5))
        app.buttons["编辑模板"].tap()
        for _ in 0..<10 { if css.exists && css.isHittable { break }; app.swipeUp() }
        XCTAssertTrue((css.value as? String ?? "").contains("linear-gradient(to right"))
        for _ in 0..<6 { if css.frame.maxY < app.frame.maxY - 40 { break }; app.swipeUp() }
        css.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        let clippedStyle = "\ncolor: #d3dee8; background: linear-gradient(to right, #dc7858, #6590c5); background-clip: text; -webkit-text-fill-color: transparent;\n"
        css.typeText(clippedStyle)
        XCTAssertTrue((css.value as? String ?? "").hasSuffix(clippedStyle))
        app.buttons["review-card-template-save"].tap()
        XCTAssertTrue(app.images["review-card-preview"].waitForExistence(timeout: 10))
        let clipped = XCTAttachment(screenshot: app.screenshot()); clipped.name = "review-card-gradient-text-mask"; clipped.lifetime = .keepAlways; add(clipped)
        app.buttons["删除模板"].tap(); app.sheets.buttons["删除模板"].tap()
        XCTAssertFalse(app.buttons["编辑模板"].exists)
        app.buttons["review-card-style"].tap(); XCTAssertFalse(app.buttons["Night card"].exists)
    }
}
