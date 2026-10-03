import XCTest

final class ChineseConversionTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    func testAllTXTPageModesOriginalSelectionBookmarksAndRestart() throws {
        executionTimeAllowance = 600
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--chinese-conversion-sample"]
        app.launch(); XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        let body = app.textViews["reader-text"].firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10)); let original = try XCTUnwrap(body.value as? String)
        func mode(_ label: String, page: String? = nil) {
            app.buttons["排版"].tap()
            if let page { app.buttons["reader-page-mode"].tap(); app.buttons[page].tap() }
            let picker = app.buttons["reader-chinese-conversion"]
            for _ in 0..<3 where !picker.isHittable { app.swipeUp() }
            picker.tap(); app.buttons[label].tap(); app.buttons["完成"].tap()
            XCTAssertTrue(body.waitForExistence(timeout: 10))
        }
        for page in ["上下滚动", "滑动翻页", "仿真翻页", "覆盖翻页", "无动画翻页"] {
            mode("简体（大陆用语）", page: page)
            XCTAssertTrue((body.value as? String ?? "").contains("鼠标放在主板旁"))
            XCTAssertFalse((body.value as? String ?? "").contains("主機板"))
            mode("繁体（台湾用语）")
            XCTAssertTrue((body.value as? String ?? "").contains("滑鼠放在主機板旁"))
            mode("显示原文"); XCTAssertEqual(body.value as? String, original)
        }
        mode("简体（大陆用语）")
        app.buttons["书签"].tap(); app.buttons["添加当前位置书签"].tap(); app.buttons["完成"].tap()
        app.buttons["下一章"].tap(); app.buttons["书签"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmark-")).firstMatch.tap()
        XCTAssertTrue((body.value as? String ?? "").contains("鼠标放在主板旁"))
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.12)).press(forDuration: 1.2)
        func editAction() -> XCUIElement? {
            if app.menuItems["编辑原文"].exists { return app.menuItems["编辑原文"] }
            let button = app.collectionViews.buttons["编辑原文"]; return button.exists ? button : nil
        }
        for _ in 0..<6 where editAction() == nil {
            let next = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next Page", "Forward"])).firstMatch
            if next.waitForExistence(timeout: 2) { next.tap() }
        }
        try XCTUnwrap(editAction()).tap()
        let editor = app.textViews["source-edit-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let selected = try XCTUnwrap(editor.value as? String)
        XCTAssertFalse(selected.isEmpty); XCTAssertTrue(original.contains(selected))
        app.buttons["取消"].tap()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "chinese-conversion-all-page-modes"; shot.lifetime = .keepAlways; add(shot)
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        XCTAssertTrue(body.waitForExistence(timeout: 10)); XCTAssertTrue((body.value as? String ?? "").contains("鼠标放在主板旁"))
        app.buttons["搜索"].tap()
        let field = app.searchFields.firstMatch; XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("鼠标")
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "鼠标放在主板旁")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10)); result.tap()
        XCTAssertTrue((body.value as? String ?? "").contains("鼠标放在主板旁"))
        mode("显示原文"); XCTAssertEqual(body.value as? String, original)
    }
}

extension ChineseConversionTests {
    func testEPUBConversionSelectionOriginalEditBookmarksSearchAndRestart() throws {
        executionTimeAllowance = 480
        let app = XCUIApplication(), url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ChineseReading", withExtension: "epub"))
        app.launchEnvironment["MOREAD_TEST_EPUB"] = try Data(contentsOf: url).base64EncodedString()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-epub"]
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店 · EPUB")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20)); book.tap()
        let web = app.webViews.firstMatch
        func text(_ value: String) -> XCUIElement { web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch }
        XCTAssertTrue(text("滑鼠在主機板旁").waitForExistence(timeout: 20))
        func mode(_ name: String) {
            app.buttons["排版"].tap()
            let picker = app.buttons["reader-chinese-conversion"]
            for _ in 0..<3 where !picker.isHittable { app.swipeUp() }
            picker.tap(); app.buttons[name].tap(); app.buttons["完成"].tap()
        }
        mode("简体（大陆用语）")
        XCTAssertTrue(text("鼠标在主板旁").waitForExistence(timeout: 20))
        app.buttons["书签"].tap(); app.buttons["添加当前位置书签"].tap(); app.buttons["完成"].tap()
        let board = web.staticTexts.matching(NSPredicate(format: "label == %@", "主板")).firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 10)); board.press(forDuration: 1.2)
        func editMenu() -> XCUIElement? {
            if app.menuItems["编辑原文"].exists { return app.menuItems["编辑原文"] }
            return app.collectionViews.buttons["编辑原文"].exists ? app.collectionViews.buttons["编辑原文"] : nil
        }
        let menuNext = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next Page", "Forward"])).firstMatch
        if editMenu() == nil, !menuNext.exists { board.tap() }
        for _ in 0..<6 where editMenu() == nil {
            let next = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next Page", "Forward"])).firstMatch
            if next.waitForExistence(timeout: 2) { next.tap() }
        }
        try XCTUnwrap(editMenu()).tap()
        XCTAssertTrue(app.textViews["source-edit-text"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textViews["source-edit-text"].value as? String, "主機板")
        app.buttons["取消"].tap()
        let first = text("鼠标在主板旁"); let frame = first.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + 12, dy: frame.minY + 12)).press(forDuration: 1.2)
        func action() -> XCUIElement? {
            if app.menuItems["编辑原文"].exists { return app.menuItems["编辑原文"] }
            return app.collectionViews.buttons["编辑原文"].exists ? app.collectionViews.buttons["编辑原文"] : nil
        }
        if action() == nil, !menuNext.exists {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + 12, dy: frame.minY + 12)).tap()
        }
        for _ in 0..<6 where action() == nil {
            let next = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next Page", "Forward"])).firstMatch
            if next.waitForExistence(timeout: 2) { next.tap() }
        }
        try XCTUnwrap(action()).tap()
        let editor = app.textViews["source-edit-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); XCTAssertEqual(editor.value as? String, "滑鼠")
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0)).withOffset(CGVector(dx: 0, dy: 20)).tap()
        editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "新的滑鼠")
        app.buttons["source-edit-save"].tap()
        XCTAssertTrue(text("新的鼠标在主板旁").waitForExistence(timeout: 30))
        mode("繁体（台湾用语）")
        XCTAssertTrue(text("新的滑鼠在主機板旁").waitForExistence(timeout: 20))
        app.buttons["目录"].tap(); app.buttons["第二章 來信"].tap()
        app.buttons["书签"].tap(); app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmark-")).firstMatch.tap()
        XCTAssertTrue(text("新的滑鼠在主機板旁").waitForExistence(timeout: 15))
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        XCTAssertTrue(text("新的滑鼠在主機板旁").waitForExistence(timeout: 20))
        mode("简体（大陆用语）")
        app.buttons["搜索"].tap(); let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("鼠标")
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "新的鼠标在主板旁")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10)); result.tap()
        XCTAssertTrue(text("新的鼠标在主板旁").waitForExistence(timeout: 15))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "epub-chinese-conversion"; shot.lifetime = .keepAlways; add(shot)
        mode("显示原文")
        XCTAssertTrue(text("新的滑鼠在主機板旁").waitForExistence(timeout: 20))
        XCTAssertFalse(app.alerts["需要处理"].exists)
    }
}
