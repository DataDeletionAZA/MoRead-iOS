import XCTest

final class BookTextEditingTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    private func openBook(_ app: XCUIApplication) {
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        XCTAssertTrue(app.textViews["reader-text"].firstMatch.waitForExistence(timeout: 10))
    }
    private func start(_ app: XCUIApplication) {
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--translation-sample"]
        app.launch(); XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap(); openBook(app)
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testSelectionEditCancelAllPageModesAndRestart() throws {
        executionTimeAllowance = 600
        let app = XCUIApplication(); start(app)
        let body = app.textViews["reader-text"].firstMatch
        func editor() throws -> XCUIElement {
            body.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.12)).press(forDuration: 1.2)
            func action() -> XCUIElement? {
                let menu = app.menuItems["编辑原文"]
                if menu.exists && menu.isHittable { return menu }
                let button = app.collectionViews.buttons["编辑原文"]
                return button.exists && button.isHittable ? button : nil
            }
            for _ in 0..<5 where action() == nil {
                let next = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next Page", "Forward"])).firstMatch
                if next.waitForExistence(timeout: 2) { next.tap() }
            }
            try XCTUnwrap(action()).tap()
            let edit = app.textViews["source-edit-text"]
            XCTAssertTrue(edit.waitForExistence(timeout: 10)); return edit
        }
        for (index, mode) in ["上下滚动", "滑动翻页", "仿真翻页", "覆盖翻页", "无动画翻页"].enumerated() {
            app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons[mode].tap(); app.buttons["完成"].tap()
            XCTAssertTrue(body.waitForExistence(timeout: 10))
            let before = body.value as? String
            var edit = try editor()
            if index == 0 {
                edit.tap(); edit.typeText("CANCELLED")
                app.buttons["取消"].tap(); XCTAssertEqual(body.value as? String, before)
                edit = try editor()
            }
            let original = try XCTUnwrap(edit.value as? String)
            XCTAssertFalse(original.isEmpty)
            edit.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0)).withOffset(CGVector(dx: 0, dy: 20)).tap()
            edit.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count) + "EDITED\(index)")
            XCTAssertEqual(edit.value as? String, "EDITED\(index)")
            app.buttons["source-edit-save"].tap()
            XCTAssertTrue(edit.waitForNonExistence(timeout: 15))
            XCTAssertTrue((body.value as? String ?? "").contains("EDITED\(index)"))
        }
        screenshot(app, "edited-source-all-page-modes")
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); openBook(app)
        XCTAssertTrue((body.value as? String ?? "").contains("EDITED4"))
    }
    func testEPUBSelectionEditPersistsInRendererSearchAndBookmarks() throws {
        executionTimeAllowance = 360
        let app = XCUIApplication(), url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "EnglishReading", withExtension: "epub"))
        app.launchEnvironment["MOREAD_TEST_EPUB"] = try Data(contentsOf: url).base64EncodedString()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-epub"]
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店 · EPUB")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20)); book.tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 20))
        let paragraph = web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Paragraph 01.")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 15))
        app.buttons["书签"].tap(); app.buttons["添加当前位置书签"].tap(); app.buttons["完成"].tap()
        var selectedWord = "book"
        func editor() throws -> XCUIElement {
            let word = web.staticTexts.matching(NSPredicate(format: "label == %@", selectedWord)).firstMatch
            if word.exists, word.isHittable {
                word.press(forDuration: 1.2)
            } else {
                let line = web.staticTexts.allElementsBoundByIndex.first { $0.isHittable && $0.label.contains("After the rain") }
                let frame = try XCTUnwrap(line).frame
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + min(80, frame.width / 2), dy: frame.minY + 12)).press(forDuration: 1.2)
            }
            screenshot(app, "epub-source-selection")
            func action() -> XCUIElement? {
                if app.menuItems["编辑原文"].exists { return app.menuItems["编辑原文"] }
                let button = app.collectionViews.buttons["编辑原文"]; return button.exists ? button : nil
            }
            for _ in 0..<6 where action() == nil {
                let next = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next Page", "Forward"])).firstMatch
                if next.waitForExistence(timeout: 2) { next.tap() }
            }
            try XCTUnwrap(action()).tap()
            let edit = app.textViews["source-edit-text"]
            XCTAssertTrue(edit.waitForExistence(timeout: 10))
            XCTAssertFalse((edit.value as? String ?? "").isEmpty)
            return edit
        }
        var edit = try editor(), before = try XCTUnwrap(edit.value as? String)
        edit.tap(); edit.typeText("CANCELLED")
        app.buttons["取消"].tap(); XCTAssertFalse(web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "CANCELLED")).firstMatch.exists)
        for marker in ["REVISED", "UPDATED\nNEXTLINE"] {
            edit = try editor(); before = try XCTUnwrap(edit.value as? String)
            edit.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0)).withOffset(CGVector(dx: 0, dy: 20)).tap()
            edit.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: before.count) + marker)
            XCTAssertEqual(edit.value as? String, marker)
            app.buttons["source-edit-save"].tap()
            XCTAssertTrue(edit.waitForNonExistence(timeout: 30))
            XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", String(marker.prefix(7)))).firstMatch.waitForExistence(timeout: 20))
            selectedWord = marker
        }
        screenshot(app, "epub-edited-source")
        app.buttons["目录"].tap(); app.buttons["第二章 来信"].tap()
        app.buttons["书签"].tap(); app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmark-")).firstMatch.tap()
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "UPDATED")).firstMatch.waitForExistence(timeout: 15))
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "UPDATED")).firstMatch.waitForExistence(timeout: 15))
        screenshot(app, "epub-edited-source-restarted")
        app.buttons["搜索"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("NEXTLINE")
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "NEXTLINE")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10)); result.tap()
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "NEXTLINE")).firstMatch.waitForExistence(timeout: 10))
        screenshot(app, "epub-edited-source-search")
    }
    func testChapterRecognitionPreviewCancelMergeSplitAndBookmarks() {
        executionTimeAllowance = 360
        let app = XCUIApplication(); start(app)
        app.buttons["下一章"].tap()
        app.buttons["书签"].tap(); app.buttons["添加当前位置书签"].tap(); app.buttons["完成"].tap()
        func openRecognition() {
            app.buttons["目录"].tap()
            let button = app.buttons["chapter-recognition-open"]
            for _ in 0..<3 where !button.isHittable { app.swipeUp() }
            button.tap(); XCTAssertTrue(app.buttons["chapter-recognition-preview"].waitForExistence(timeout: 10))
        }
        func finish() {
            app.navigationBars["重新识别章节"].buttons.firstMatch.tap(); app.buttons["完成"].tap()
        }
        openRecognition()
        let rule = app.descendants(matching: .any)["chapter-recognition-rule"]
        rule.tap(); rule.typeText("["); app.buttons["chapter-recognition-preview"].tap()
        XCTAssertTrue(app.staticTexts["chapter-recognition-error"].waitForExistence(timeout: 10))
        rule.tap(); rule.typeText(XCUIKeyboardKey.delete.rawValue + "^第一章.*$")
        app.buttons["chapter-recognition-preview"].tap()
        let summary = app.staticTexts["chapter-recognition-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10)); XCTAssertEqual(summary.label, "原目录 2 章 → 新目录 1 章")
        screenshot(app, "chapter-recognition-preview")
        app.buttons["chapter-recognition-apply"].tap(); app.alerts.buttons["取消"].tap()
        XCTAssertTrue(summary.exists)
        app.buttons["chapter-recognition-apply"].tap(); app.alerts.buttons["确认应用"].tap()
        XCTAssertTrue(app.staticTexts["目录已更新。"].waitForExistence(timeout: 15)); finish()
        XCTAssertTrue(app.staticTexts["1 / 1"].waitForExistence(timeout: 10))
        app.buttons["书签"].tap()
        let bookmark = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmark-")).firstMatch
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5)); bookmark.tap()
        XCTAssertTrue((app.textViews["reader-text"].firstMatch.value as? String ?? "").contains("一封没有署名的信"))
        screenshot(app, "chapter-recognition-mapped-bookmark")
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); openBook(app)
        XCTAssertTrue(app.staticTexts["1 / 1"].waitForExistence(timeout: 10)); openRecognition()
        app.buttons["chapter-recognition-preview"].tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 10)); XCTAssertEqual(summary.label, "原目录 1 章 → 新目录 2 章")
        app.buttons["chapter-recognition-apply"].tap(); app.alerts.buttons["确认应用"].tap()
        XCTAssertTrue(app.staticTexts["目录已更新。"].waitForExistence(timeout: 15)); finish()
        XCTAssertTrue(app.staticTexts["1 / 2"].waitForExistence(timeout: 10))
        app.buttons["书签"].tap()
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5)); bookmark.tap()
        XCTAssertTrue(app.staticTexts["2 / 2"].waitForExistence(timeout: 10))
        screenshot(app, "chapter-recognition-restored-bookmark")
    }
}
