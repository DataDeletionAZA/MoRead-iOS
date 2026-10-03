import XCTest

final class ReaderTapZonesTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    private func configure(_ app: XCUIApplication) {
        app.buttons["排版"].tap(); app.buttons["操作区域"].tap()
        let enabled = app.switches["tap-zones-enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 10))
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        assign(app, index: 3, title: "正文左侧", action: "nextPage")
        assign(app, index: 5, title: "正文右侧", action: "previousPage")
        assign(app, index: 10, title: "页眉右侧", action: "toggleBookmark")
        assign(app, index: 11, title: "页脚左侧", action: "bookmarks")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "custom-tap-zones"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["tap-zones-save"].tap(); app.buttons["完成"].tap()
    }
    private func assign(_ app: XCUIApplication, index: Int, title: String, action: String) {
        let zone = app.buttons["tap-zone-\(index)"]
        for _ in 0..<3 where !zone.isHittable { app.swipeUp() }
        XCTAssertTrue(zone.isHittable); zone.tap()
        let choice = app.buttons["tap-action-" + action]
        for _ in 0..<3 where !choice.isHittable { app.swipeUp() }
        XCTAssertTrue(choice.isHittable); choice.tap()
        app.navigationBars[title].buttons.firstMatch.tap()
    }
    private func tap(_ surface: XCUIElement, _ x: CGFloat, _ y: CGFloat) {
        surface.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
    }
    private func bookmark(_ app: XCUIApplication, surface: XCUIElement) {
        tap(surface, 0.75, 0.04)
        XCTAssertTrue(app.staticTexts["书签已保存"].waitForExistence(timeout: 10))
        tap(surface, 0.75, 0.04)
        XCTAssertTrue(app.staticTexts["书签已移除"].waitForExistence(timeout: 10))
        tap(surface, 0.25, 0.96)
        XCTAssertTrue(app.buttons["添加当前位置书签"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmark-")).firstMatch.exists)
        app.buttons["完成"].tap()
    }
    func testTextCustomTapsEveryPageModeAndPersistence() throws {
        executionTimeAllowance = 420
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--translation-pages-sample", "--english-reading-sample"]
        app.launch(); XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap(); configure(app)
        let continuous = app.tables["continuous-reader"]
        XCTAssertTrue(continuous.waitForExistence(timeout: 10))
        let before = continuous.screenshot().pngRepresentation
        tap(continuous, 0.15, 0.5)
        XCTAssertNotEqual(continuous.screenshot().pngRepresentation, before)
        tap(continuous, 0.85, 0.5)
        bookmark(app, surface: continuous)
        for mode in ["无动画翻页", "滑动翻页", "覆盖翻页", "仿真翻页"] {
            app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons[mode].tap(); app.buttons["完成"].tap()
            let surface = app.textViews["reader-text"].firstMatch
            XCTAssertTrue(surface.waitForExistence(timeout: 10))
            let count = app.staticTexts["reader-page-number"]
            let baseline = count.label
            tap(surface, 0.15, 0.5)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", baseline), object: count)], timeout: 10), .completed, mode)
            tap(surface, 0.85, 0.5)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", baseline), object: count)], timeout: 10), .completed, mode)
        }
        let surface = app.textViews["reader-text"].firstMatch
        bookmark(app, surface: surface)
        tap(surface, 0.5, 0.5); XCTAssertTrue(app.buttons["排版"].waitForNonExistence(timeout: 10))
        tap(surface, 0.5, 0.5); XCTAssertTrue(app.buttons["排版"].waitForExistence(timeout: 10))
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        app.buttons["排版"].tap(); app.buttons["操作区域"].tap()
        XCTAssertEqual(app.switches["tap-zones-enabled"].value as? String, "1")
        XCTAssertTrue(app.buttons["tap-zone-3"].label.contains("下一页"))
        assign(app, index: 1, title: "正文上方", action: "none")
        assign(app, index: 4, title: "正文中央", action: "none")
        assign(app, index: 7, title: "正文下方", action: "none")
        XCTAssertFalse(app.buttons["tap-zones-save"].isEnabled)
        XCTAssertTrue(app.staticTexts["tap-zones-invalid"].exists)
        app.navigationBars["操作区域"].buttons.firstMatch.tap(); app.buttons["完成"].tap()
        tap(surface, 0.5, 0.5); XCTAssertTrue(app.buttons["排版"].waitForNonExistence(timeout: 10))
        tap(surface, 0.5, 0.5); XCTAssertTrue(app.buttons["排版"].waitForExistence(timeout: 10))
    }
    func testEPUBCustomTapsInPagesAndScroll() throws {
        executionTimeAllowance = 600
        let app = XCUIApplication()
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "EnglishReading", withExtension: "epub"))
        app.launchEnvironment["MOREAD_TEST_EPUB"] = try Data(contentsOf: url).base64EncodedString()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-epub", "--english-reading-sample"]
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店 · EPUB")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20)); book.tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 20)); configure(app)
        let before = web.screenshot().pngRepresentation
        func shot(_ name: String) { let image = XCTAttachment(screenshot: web.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image) }
        shot("tap-epub-before")
        tap(web, 0.15, 0.5); XCTAssertNotEqual(web.screenshot().pngRepresentation, before)
        tap(web, 0.85, 0.5)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in web.screenshot().pngRepresentation == before }, object: nil)], timeout: 10), .completed)
        shot("tap-epub-after")
        bookmark(app, surface: web)
        app.buttons["排版"].tap(); app.buttons["epub-page-mode"].tap(); app.buttons["上下滚动"].tap(); app.buttons["完成"].tap()
        XCTAssertTrue(web.waitForExistence(timeout: 15))
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Paragraph 01.")).firstMatch.waitForExistence(timeout: 10))
        let top = web.screenshot().pngRepresentation
        shot("tap-epub-scroll-before")
        tap(web, 0.15, 0.5); XCTAssertNotEqual(web.screenshot().pngRepresentation, top)
        tap(web, 0.85, 0.5)
        let restored = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in web.screenshot().pngRepresentation == top }, object: nil)], timeout: 10)
        shot("tap-epub-scroll-after")
        let tree = XCTAttachment(string: web.debugDescription); tree.name = "tap-epub-scroll-tree"; tree.lifetime = .keepAlways; add(tree)
        XCTAssertEqual(restored, .completed)
        bookmark(app, surface: web)
        app.buttons["排版"].tap(); app.buttons["阅读辅助"].tap()
        app.switches["english-learning"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["english-annotation-mode"].tap(); app.buttons["划线弹窗"].tap()
        app.navigationBars["阅读辅助"].buttons.firstMatch.tap(); app.buttons["完成"].tap()
        let word = try XCTUnwrap(web.staticTexts.matching(NSPredicate(format: "label == %@", "After")).allElementsBoundByIndex.first(where: { $0.isHittable }))
        word.tap(); XCTAssertTrue(app.textFields["dictionary-query"].waitForExistence(timeout: 10))
        XCTAssertEqual((app.textFields["dictionary-query"].value as? String)?.lowercased(), "after")
        app.buttons["完成"].tap()
    }
}

extension ReaderTapZonesTests {
    func testKeyboardRecordingPagingInputIsolationAndRestart() throws {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--translation-pages-sample"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons["无动画翻页"].tap()
        app.buttons["按键翻页"].tap()
        let enabled = app.switches["reader-keys-enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 10)); XCTAssertEqual(enabled.value as? String, "0"); enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["record-next-key"].tap()
        XCTAssertTrue(app.staticTexts["recorded-key"].waitForExistence(timeout: 10))
        app.typeKey("j", modifierFlags: [])
        XCTAssertEqual(app.staticTexts["recorded-key"].label, "J")
        XCTAssertTrue(app.buttons["record-key-save"].isEnabled); app.buttons["record-key-save"].tap()
        let keyShot = XCTAttachment(screenshot: app.screenshot()); keyShot.name = "reader-key-bindings"; keyShot.lifetime = .keepAlways; add(keyShot)
        app.buttons["reader-keys-save"].tap(); app.buttons["完成"].tap()
        let page = app.staticTexts["reader-page-number"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        func pageIs(_ number: Int) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "本章 \(number) /"), object: page)], timeout: 10), .completed)
        }
        pageIs(1); app.typeKey("j", modifierFlags: []); pageIs(2)
        app.typeKey(.leftArrow, modifierFlags: []); pageIs(1)
        app.buttons["搜索"].tap(); let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("j")
        XCTAssertEqual(search.value as? String, "j")
        app.typeKey("j", modifierFlags: []); XCTAssertNotEqual(search.value as? String, "j")
        if app.buttons["close"].exists { app.buttons["close"].tap() }
        app.buttons["完成"].tap(); pageIs(1)
        app.typeKey("j", modifierFlags: []); pageIs(2)
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap(); pageIs(2)
        app.typeKey(.leftArrow, modifierFlags: []); pageIs(1)
        for mode in ["滑动翻页", "覆盖翻页", "仿真翻页"] {
            app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons[mode].tap(); app.buttons["完成"].tap()
            pageIs(1); app.typeKey("j", modifierFlags: []); pageIs(2)
            app.typeKey(.leftArrow, modifierFlags: []); pageIs(1)
        }
        app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons["上下滚动"].tap(); app.buttons["完成"].tap()
        let table = app.tables["continuous-reader"]
        XCTAssertTrue(table.waitForExistence(timeout: 10)); let before = table.screenshot().pngRepresentation
        app.typeKey("j", modifierFlags: []); XCTAssertNotEqual(table.screenshot().pngRepresentation, before)
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in table.screenshot().pngRepresentation == before }, object: nil)], timeout: 10), .completed)
        XCTAssertFalse(app.alerts["需要处理"].exists)
    }
}

extension ReaderTapZonesTests {
    func testEPUBKeyboardPagesScrollAndDisable() throws {
        executionTimeAllowance = 180
        let app = XCUIApplication(), url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "EnglishReading", withExtension: "epub"))
        app.launchEnvironment["MOREAD_TEST_EPUB"] = try Data(contentsOf: url).base64EncodedString()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-epub"]; app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店 · EPUB")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20)); book.tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 20))
        app.buttons["排版"].tap(); app.buttons["按键翻页"].tap()
        let enabled = app.switches["reader-keys-enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 10)); XCTAssertEqual(enabled.value as? String, "0"); enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["reader-keys-save"].tap(); app.buttons["完成"].tap()
        for scrolling in [false, true] {
            if scrolling {
                app.buttons["排版"].tap(); app.buttons["epub-page-mode"].tap(); app.buttons["上下滚动"].tap(); app.buttons["完成"].tap()
            }
            XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Paragraph 01.")).firstMatch.waitForExistence(timeout: 15))
            let before = web.screenshot().pngRepresentation
            app.typeKey(.rightArrow, modifierFlags: [])
            XCTAssertNotEqual(web.screenshot().pngRepresentation, before)
            app.typeKey(.leftArrow, modifierFlags: [])
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in web.screenshot().pngRepresentation == before }, object: nil)], timeout: 10), .completed)
        }
        app.buttons["排版"].tap(); app.buttons["按键翻页"].tap()
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["reader-keys-save"].tap(); app.buttons["完成"].tap()
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        app.buttons["排版"].tap(); app.buttons["按键翻页"].tap()
        XCTAssertEqual(enabled.value as? String, "0")
    }
}
