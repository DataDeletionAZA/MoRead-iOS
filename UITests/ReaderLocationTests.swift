import XCTest

final class ReaderLocationTests: XCTestCase {
    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    func testTextAnnotationTapAllModesWithOverlaps() throws { try annotationTap(epub: false) }
    func testEPUBAnnotationTapBothModesWithOverlaps() throws { try annotationTap(epub: true) }
    private func annotationTap(epub: Bool) throws {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--english-reading-sample", "--annotation-discussion-sample"]
        if epub {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "EnglishReading", withExtension: "epub"))
            app.launchEnvironment["MOREAD_TEST_EPUB"] = try Data(contentsOf: url).base64EncodedString()
            app.launchArguments.append("--import-test-epub")
        } else { app.launchArguments.append("--translation-pages-sample") }
        app.launch()
        if !epub { XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap() }
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", epub ? "雨后的书店 · EPUB" : "雨后的书店")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20)); book.tap()
        XCTAssertTrue(app.buttons["排版"].waitForExistence(timeout: 15)); app.buttons["排版"].tap(); app.buttons["阅读辅助"].tap()
        for key in ["english-learning", "english-bionic"] { app.switches[key].coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap() }
        app.buttons["english-annotation-mode"].tap(); app.buttons["划线弹窗"].tap()
        app.navigationBars["阅读辅助"].buttons.firstMatch.tap(); app.buttons["完成"].tap()
        func tapWord() {
            if epub {
                let word = app.webViews.staticTexts.matching(NSPredicate(format: "label IN %@", ["Aft", "After"])).firstMatch
                XCTAssertTrue(word.waitForExistence(timeout: 15)); word.tap()
            } else {
                let text = app.textViews["reader-text"].firstMatch
                XCTAssertTrue(text.waitForExistence(timeout: 10))
                text.coordinate(withNormalizedOffset: .init(dx: 0.44, dy: 0)).withOffset(.init(dx: 0, dy: 36)).tap()
            }
        }
        let modes = epub ? ["左右翻页", "上下滚动"] : ["上下滚动", "仿真翻页", "覆盖翻页", "滑动翻页", "无动画翻页"]
        for mode in modes {
            app.buttons["排版"].tap(); app.buttons[epub ? "epub-page-mode" : "reader-page-mode"].tap(); app.buttons[mode].tap(); app.buttons["完成"].tap()
            tapWord()
            let choices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'discussion-choice-'"))
            XCTAssertTrue(choices.firstMatch.waitForExistence(timeout: 10), mode); XCTAssertEqual(choices.count, 2)
            choices.matching(NSPredicate(format: "label CONTAINS %@", "A warm opening.")).firstMatch.tap()
            XCTAssertEqual(app.staticTexts["discussion-opening"].label, "A warm opening.")
            XCTAssertTrue(app.navigationBars["批注讨论"].buttons["BackButton"].waitForExistence(timeout: 5))
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "tap-discussion-" + (epub ? "epub-" : "txt-") + mode; shot.lifetime = .keepAlways; add(shot)
            app.navigationBars["批注讨论"].buttons["BackButton"].tap()
            app.buttons["完成"].tap(); XCTAssertTrue(app.buttons["排版"].waitForExistence(timeout: 10))
        }
        func remove(_ note: String) {
            app.buttons["批注"].tap()
            let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", note)).firstMatch
            XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.swipeLeft(); app.buttons.matching(NSPredicate(format: "label IN %@", ["删除", "Delete"])).firstMatch.tap()
            app.buttons["完成"].tap()
        }
        remove("A warm opening."); tapWord()
        XCTAssertTrue(app.staticTexts["discussion-opening"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["discussion-opening"].label, "What changed after the rain?")
        app.buttons["完成"].tap()
        remove("What changed after the rain?"); tapWord()
        XCTAssertTrue(app.textFields["dictionary-query"].waitForExistence(timeout: 10))
        XCTAssertEqual((app.textFields["dictionary-query"].value as? String)?.lowercased(), "after")
    }
    func testTextSourceHighlightAllModesAndExpiry() { check(epub: false) }
    func testEPUBSourceHighlightBothModesAndExpiry() { check(epub: true) }
    private func check(epub: Bool) {
        executionTimeAllowance = 300
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--location-annotation-sample"]; app.launch()
        let sample = app.buttons[epub ? "add-epub-sample" : "add-sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 15)); sample.tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20)); book.tap()
        let modes = epub ? ["左右翻页", "上下滚动"] : ["上下滚动", "仿真翻页", "覆盖翻页", "滑动翻页", "无动画翻页"]
        for mode in modes {
            XCTAssertTrue(app.buttons["排版"].waitForExistence(timeout: 15)); app.buttons["排版"].tap()
            app.buttons[epub ? "epub-page-mode" : "reader-page-mode"].tap(); app.buttons[mode].tap(); app.buttons["完成"].tap()
            app.buttons["搜索"].tap()
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (search.value as? String ?? "").count) + "没有署名")
            let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "一封没有署名的信")).firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 10)); result.tap()
            let hint = app.staticTexts["reader-location-hint"]
            XCTAssertTrue(hint.waitForExistence(timeout: 10), mode)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "located-" + (epub ? "epub-" : "text-") + mode; shot.lifetime = .keepAlways; add(shot)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: hint)], timeout: 6), .completed)
            let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); after.name = "location-expired-" + mode; after.lifetime = .keepAlways; add(after)
        }
    }
}
