import XCTest

final class AutoReadUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func status(_ app: XCUIApplication, _ text: String, timeout: Double = 10) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", text), object: app.staticTexts["auto-read-status"])], timeout: timeout), .completed)
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let value = XCTAttachment(screenshot: app.screenshot()); value.name = name; value.lifetime = .keepAlways; add(value)
    }
    private func open(_ app: XCUIApplication, title: String = "雨后的书店") {
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        XCTAssertTrue(app.buttons["auto-read-open"].waitForExistence(timeout: 15))
    }
    private func settings(_ app: XCUIApplication, mode: String, first: Bool = false) {
        app.buttons["auto-read-open"].tap()
        app.buttons["auto-read-mode"].tap(); app.buttons[mode].tap()
        if mode == "定时翻页", first {
            let decrement = app.steppers["auto-read-interval"].buttons.element(boundBy: 0)
            for _ in 0..<12 { decrement.tap() }
        }
        if mode == "匀速滚动" {
            app.sliders["滚动速度"].adjust(toNormalizedSliderPosition: 1)
            let guide = app.switches["导读线"]
            if guide.value as? String != "1" { guide.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        }
        app.buttons["auto-read-start"].tap()
        status(app, "自动阅读中")
    }
    func testTXTAutoReadModesPauseResumeCrossChapterAndRelaunch() {
        executionTimeAllowance = 360
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap(); open(app)
        for (index, mode) in ["无动画翻页", "滑动翻页", "覆盖翻页", "仿真翻页"].enumerated() {
            app.buttons["目录"].tap(); app.buttons["第一章 雨后"].tap()
            app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons[mode].tap(); app.buttons["完成"].tap()
            settings(app, mode: "定时翻页", first: index == 0)
            let page = app.staticTexts["reader-page-number"]
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH '本章 2 /'"), object: page)], timeout: 10), .completed)
            app.buttons["auto-read-toggle"].tap(); status(app, "已暂停")
            let paused = page.label
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", paused), object: page)], timeout: 4), .timedOut)
            app.buttons["auto-read-stop"].tap()
        }
        settings(app, mode: "定时翻页")
        app.buttons["目录"].tap(); app.buttons["完成"].tap(); status(app, "操作面板打开，已暂停")
        app.buttons["auto-read-toggle"].tap(); status(app, "自动阅读中")
        XCUIDevice.shared.press(.home); app.activate(); status(app, "离开阅读页后已暂停")
        app.buttons["auto-read-stop"].tap()
        app.buttons["目录"].tap(); app.buttons["第一章 雨后"].tap()
        settings(app, mode: "匀速滚动")
        shot(app, "auto-scroll-start")
        XCUIDevice.shared.orientation = .landscapeLeft
        status(app, "排版改变，已暂停")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["auto-read-toggle"].tap(); status(app, "自动阅读中")
        app.textViews["reader-text"].coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).tap()
        status(app, "触摸后已暂停")
        app.buttons["auto-read-toggle"].tap(); status(app, "自动阅读中")
        status(app, "已到全书末尾", timeout: 90)
        XCTAssertTrue(app.navigationBars["第二章 来信"].exists)
        shot(app, "auto-scroll-end")
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); open(app)
        XCTAssertFalse(app.staticTexts["auto-read-status"].exists)
        XCTAssertTrue(app.navigationBars["第二章 来信"].exists)
        app.buttons["auto-read-open"].tap()
        XCTAssertTrue(app.buttons["auto-read-mode"].label.contains("匀速滚动"))
        XCTAssertFalse(app.alerts["需要处理"].exists)
    }
    func testEPUBAutoReadScrollAndPages() throws {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        let url = try XCTUnwrap(Bundle(for: AutoReadUITests.self).url(forResource: "Bilingual", withExtension: "epub"))
        app.launchEnvironment["MOREAD_TEST_EPUB"] = try Data(contentsOf: url).base64EncodedString()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-epub"]; app.launch()
        open(app, title: "雨后的书店 · EPUB")
        settings(app, mode: "定时翻页", first: true)
        status(app, "已到全书末尾", timeout: 90)
        shot(app, "epub-auto-page-end")
        app.buttons["auto-read-stop"].tap()
        app.buttons["目录"].tap(); app.buttons["第一章 雨后"].tap()
        settings(app, mode: "匀速滚动")
        shot(app, "epub-auto-scroll-start")
        app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).tap()
        status(app, "触摸后已暂停")
        app.buttons["auto-read-toggle"].tap(); status(app, "自动阅读中")
        status(app, "已到全书末尾", timeout: 90)
        shot(app, "epub-auto-scroll-end")
        XCTAssertFalse(app.alerts["需要处理"].exists)
    }
}
