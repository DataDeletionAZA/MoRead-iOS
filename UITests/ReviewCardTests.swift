import XCTest

final class ReviewCardUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    func testQuotationRulePreviewValidationAndPersistence() {
        executionTimeAllowance = 300
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        app.buttons["批注"].tap(); app.buttons["读书笔记与梗概"].tap(); app.buttons["新建笔记"].tap()
        let title = "Rain and 「a light in the window and a quiet place to read while the rain falls」 Home."
        app.textFields["reading-note-title"].tap(); app.textFields["reading-note-title"].typeText(title)
        app.textViews["reading-note-content"].tap(); app.textViews["reading-note-content"].typeText("A quiet place to return to.\n")
        app.buttons["保存"].tap(); app.navigationBars["读书笔记与梗概"].buttons.firstMatch.tap()
        app.buttons["划线与笔记回顾"].tap(); app.buttons["review-entry-" + title].tap(); app.buttons["review-card-export"].tap()
        XCTAssertTrue(app.images["review-card-preview"].waitForExistence(timeout: 10))
        app.buttons["新建自定义模板"].tap()
        let name = app.textFields["review-card-template-name"]; name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String ?? "").count) + "Quotation card\n")
        func openRules() {
            for _ in 0..<12 { if app.buttons["编辑文字规则"].isHittable { break }; app.swipeUp() }
            XCTAssertTrue(app.buttons["编辑文字规则"].isHittable)
            app.buttons["编辑文字规则"].tap()
        }
        for _ in 0..<12 { if app.switches["review-rules-enabled"].isHittable { break }; app.swipeUp() }
        let enabled = app.switches["review-rules-enabled"]
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(enabled.value as? String, "1"); openRules()
        app.buttons["添加文字规则"].tap()
        let ruleName = app.textFields["review-rule-name"]; ruleName.tap()
        ruleName.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (ruleName.value as? String ?? "").count) + "Window\n")
        app.buttons["检查当前摘录"].tap()
        XCTAssertEqual(app.staticTexts["review-rule-matches"].label, "找到 1 处匹配")
        let css = app.textViews["review-rule-css"]
        for _ in 0..<10 { if css.isHittable { break }; app.swipeUp() }
        css.tap(); css.typeText("padding: 1em;")
        app.buttons["review-rule-save"].tap()
        XCTAssertTrue(app.alerts["请检查文字规则"].waitForExistence(timeout: 5)); app.alerts.buttons["好"].tap()
        for _ in 0..<6 { if css.frame.maxY < app.frame.maxY - 100 { break }; app.swipeUp() }
        css.tap(); css.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (css.value as? String ?? "").count))
        css.typeText("color: linear-gradient(to right, #c64a26, #446bd0); font-weight: bold; text-decoration: underline;\n")
        app.buttons["review-rule-save"].tap()
        XCTAssertTrue(app.buttons["review-rule-Window"].waitForExistence(timeout: 5))
        app.navigationBars["文字着色规则"].buttons.firstMatch.tap(); app.buttons["review-card-template-save"].tap()
        XCTAssertTrue(app.images["review-card-preview"].waitForExistence(timeout: 10)); XCTAssertFalse(app.staticTexts["review-card-error"].exists)
        let rendered = XCTAttachment(screenshot: app.screenshot()); rendered.name = "review-card-quotation-gradient"; rendered.lifetime = .keepAlways; add(rendered)
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.buttons["书架选项"].tap(); app.buttons["划线与笔记回顾"].tap(); app.buttons["review-entry-" + title].tap(); app.buttons["review-card-export"].tap()
        app.buttons["review-card-style"].tap(); app.buttons["Quotation card"].tap(); app.buttons["编辑模板"].tap(); openRules()
        app.buttons["review-rule-Window"].tap()
        app.buttons["检查当前摘录"].tap(); XCTAssertEqual(app.staticTexts["review-rule-matches"].label, "找到 1 处匹配")
        for _ in 0..<10 { if css.isHittable { break }; app.swipeUp() }
        XCTAssertTrue((css.value as? String ?? "").contains("linear-gradient(to right"))
        app.buttons["取消"].tap(); app.navigationBars["文字着色规则"].buttons.firstMatch.tap(); app.buttons["取消"].tap()
        XCTAssertTrue(app.images["review-card-preview"].waitForExistence(timeout: 10))
    }
    func testReviewMotionPagingSourceAndPersistence() {
        executionTimeAllowance = 240
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--review-motion-sample"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        func openReview() {
            app.buttons["书架选项"].tap(); app.buttons["划线与笔记回顾"].tap()
            XCTAssertTrue(app.buttons["review-entry-书店随记"].waitForExistence(timeout: 10)); app.buttons["review-entry-书店随记"].tap()
        }
        func position(_ text: String) {
            XCTAssertTrue(app.staticTexts["reading-review-position"].waitForExistence(timeout: 5))
            XCTAssertTrue(NSPredicate(format: "label == %@", text).evaluate(with: app.staticTexts["reading-review-position"]))
        }
        openReview(); position("2 / 3")
        XCTAssertTrue(app.textViews.matching(identifier: "reading-review-body").matching(NSPredicate(format: "value CONTAINS %@", "窗外的雨停了")).firstMatch.isHittable)
        let initial = XCTAttachment(screenshot: app.screenshot()); initial.name = "review-initial-position"; initial.lifetime = .keepAlways; add(initial)
        app.buttons["下一篇"].tap(); position("3 / 3")
        let next = XCTAttachment(screenshot: app.screenshot()); next.name = "review-next-position"; next.lifetime = .keepAlways; add(next)
        app.buttons["上一篇"].tap(); position("2 / 3")
        let menu = app.buttons["review-motion-menu"]
        XCTAssertEqual(menu.label, "翻页动效，纸片")
        for mode in ["纸片", "立方体", "流动"] {
            menu.tap(); app.buttons[mode].tap(); XCTAssertEqual(menu.label, "翻页动效，" + mode)
            let body = app.textViews.matching(identifier: "reading-review-body").matching(NSPredicate(format: "value CONTAINS %@", "窗外的雨停了")).firstMatch
            XCTAssertTrue(body.waitForExistence(timeout: 5)); XCTAssertTrue(body.isHittable)
            body.swipeLeft(); position("3 / 3"); XCTAssertFalse(app.buttons["下一篇"].isEnabled)
            app.buttons["上一篇"].tap(); position("2 / 3")
            body.swipeRight(); position("1 / 3"); XCTAssertFalse(app.buttons["上一篇"].isEnabled)
            XCTAssertTrue(app.buttons["返回原文"].isHittable)
            let image = XCTAttachment(screenshot: app.screenshot()); image.name = "review-motion-" + mode; image.lifetime = .keepAlways; add(image)
            app.buttons["下一篇"].tap(); position("2 / 3")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        position("2 / 3")
        XCTAssertTrue(app.textViews.matching(identifier: "reading-review-body").matching(NSPredicate(format: "value CONTAINS %@", "窗外的雨停了")).firstMatch.isHittable)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)], timeout: 10), .completed)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "review-motion-landscape"; landscape.lifetime = .keepAlways; add(landscape)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width < app.frame.height }, object: nil)], timeout: 10), .completed)
        position("2 / 3")
        app.buttons["上一篇"].tap(); app.buttons["返回原文"].tap()
        XCTAssertTrue(app.buttons["排版"].waitForExistence(timeout: 15)); app.buttons["返回回顾"].tap(); position("1 / 3")
        app.buttons["review-card-export"].tap(); XCTAssertTrue(app.images["review-card-preview"].waitForExistence(timeout: 10))
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); openReview()
        position("2 / 3"); XCTAssertEqual(menu.label, "翻页动效，流动")
        XCTAssertTrue(app.textViews.matching(identifier: "reading-review-body").matching(NSPredicate(format: "value CONTAINS %@", "窗外的雨停了")).firstMatch.isHittable)
    }
    func testLongCardKeepsTextExportAndCanHideThought() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--long-review-card"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        app.buttons["书架选项"].tap(); app.buttons["划线与笔记回顾"].tap()
        XCTAssertTrue(app.buttons["review-entry-长篇读书笔记"].waitForExistence(timeout: 10)); app.buttons["review-entry-长篇读书笔记"].tap()
        app.buttons["review-motion-menu"].tap(); app.buttons["流动"].tap()
        let body = app.textViews["reading-review-body"].firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        XCTAssertEqual(body.value as? String, "灯塔与书店\n" + String(repeating: "灯塔在雨后的海边亮起，书店里有温暖的灯光。\n", count: 2000) + "长笔记的最后一行。")
        body.swipeUp()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "long-review-native-text"; shot.lifetime = .keepAlways; add(shot)
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
        for _ in 0..<6 { if css.frame.maxY < app.frame.maxY - 100 { break }; app.swipeUp() }
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
