import XCTest

final class DictionaryTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil, subdirectory: "Dictionary"))
        return try Data(contentsOf: url).base64EncodedString()
    }
    private func lookup(_ app: XCUIApplication, _ word: String) {
        let field = app.textFields["dictionary-query"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
        if let value = field.value as? String, value != field.placeholderValue { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)) }
        field.typeText(word); app.buttons["dictionary-search"].tap()
    }
    private func manager(_ app: XCUIApplication) {
        app.tabBars.buttons["设置"].tap()
        let link = app.buttons["词典管理"]
        for _ in 0..<4 { if link.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(link.waitForExistence(timeout: 5)); link.tap()
    }
    func testLookupResourcesEntryLinksRestartAndReaderEntry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-dictionary"]
        app.launchEnvironment["MOREAD_TEST_MDX"] = try fixture("sample-classical.mdx")
        app.launchEnvironment["MOREAD_TEST_MDD"] = try fixture("sample.mdd")
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        manager(app)
        XCTAssertTrue(app.buttons["添加 MDD 资源（1）"].waitForExistence(timeout: 10))
        app.buttons["查字词"].tap(); lookup(app, "学而时习之")
        XCTAssertTrue(app.webViews.staticTexts["学习后按时温习。"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "dictionary-classical-stylesheet"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["dictionary-simple"].tap()
        XCTAssertTrue(app.staticTexts["dictionary-plain"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["dictionary-plain"].label.contains("学习后按时温习。"))
        app.buttons["dictionary-simple"].tap()
        app.webViews.links["故"].tap()
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "旧的，原来的。")).firstMatch.waitForExistence(timeout: 10))
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        app.buttons["目录"].tap(); app.buttons["查字词"].tap(); lookup(app, "故人")
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "老朋友。")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts["需要处理"].exists)
    }
    func testDisableDuplicateAndDelete() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-dictionary"]
        app.launchEnvironment["MOREAD_TEST_MDX"] = try fixture("sample-v2.mdx"); app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); manager(app)
        let toggle = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "dictionary-enabled-")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.terminate(); app.launchArguments = ["--ui-testing", "--import-test-dictionary"]; app.launch(); manager(app)
        XCTAssertEqual(app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "dictionary-enabled-")).count, 1)
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertTrue(app.staticTexts["dictionary-notice"].label.contains("1 个文件已存在"))
        app.buttons["查字词"].tap(); lookup(app, "apple")
        XCTAssertTrue(app.staticTexts["没有找到释义"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["查字词"].tap(); lookup(app, "apple")
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "苹果")).firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["删除词典"].tap(); app.sheets.buttons.matching(identifier: "dictionary-delete-confirm").firstMatch.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: toggle)], timeout: 10), .completed)
    }
    func testStaticDictionaryDisplayAndPlainTextFallback() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-dictionary"]
        app.launchEnvironment["MOREAD_TEST_MDX"] = try fixture("sample-display.mdx")
        app.launchEnvironment["MOREAD_TEST_MDD"] = try fixture("sample.mdd"); app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); manager(app)
        app.buttons["查字词"].tap(); lookup(app, "layout")
        XCTAssertTrue(app.webViews.staticTexts["这是本地释义。"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.images["词典图片"].exists)
        XCTAssertFalse(app.staticTexts["脚本已执行"].exists)
        let link = app.webViews.links["外部链接"], frame = link.frame
        XCTAssertTrue(app.webViews.firstMatch.frame.contains(frame))
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        XCTAssertTrue(app.webViews.staticTexts["这是本地释义。"].exists)
        lookup(app, "hidden"); app.buttons["dictionary-simple"].tap()
        let plain = app.staticTexts["dictionary-plain"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "简明释义仍可阅读。"), object: plain)], timeout: 10), .completed)
        XCTAssertFalse(plain.label.contains("display:none")); XCTAssertFalse(plain.label.contains("脚本内容"))
    }
    func testSelectionLookupInContinuousPagedAndEPUBReading() throws {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        for mode in ["上下滚动", "无动画翻页", "EPUB"] {
            app.launchArguments = ["--ui-testing", "--reset-test-library", "--translation-pages-sample"]; app.launch()
            let sample = app.buttons[mode == "EPUB" ? "add-epub-sample" : "add-sample"]
            XCTAssertTrue(sample.waitForExistence(timeout: 15)); sample.tap()
            let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
            XCTAssertTrue(book.waitForExistence(timeout: 20)); book.tap()
            XCTAssertTrue(app.buttons["排版"].waitForExistence(timeout: 15))
            if mode == "无动画翻页" { app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons[mode].tap(); app.buttons["完成"].tap() }
            if mode == "EPUB" {
                let web = app.webViews.firstMatch
                XCTAssertTrue(web.waitForExistence(timeout: 15))
                let text = try XCTUnwrap(web.staticTexts.allElementsBoundByIndex.first(where: { $0.isHittable && $0.frame.height > 15 }))
                let frame = text.frame
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + min(20, frame.width / 2), dy: frame.midY)).press(forDuration: 1.2)
            } else {
                app.textViews["reader-text"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.12)).press(forDuration: 1.2)
            }
            func action() -> XCUIElement? {
                if app.menuItems["查字词"].exists { return app.menuItems["查字词"] }
                let button = app.collectionViews.buttons["查字词"]; return button.exists ? button : nil
            }
            for _ in 0..<4 where action() == nil {
                let next = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next Page", "Forward"])).firstMatch
                if next.waitForExistence(timeout: 2) { next.tap() }
            }
            let menu = try XCTUnwrap(action()), frame = menu.frame
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            XCTAssertTrue(app.textFields["dictionary-query"].waitForExistence(timeout: 10))
            let word = try XCTUnwrap(app.textFields["dictionary-query"].value as? String)
            XCTAssertFalse(word.isEmpty); XCTAssertNotEqual(word, "字词或短语")
            app.buttons["完成"].tap(); XCTAssertTrue(app.buttons["排版"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

}
