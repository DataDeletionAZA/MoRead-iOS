import XCTest

final class ReaderLocationTests: XCTestCase {
    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
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
