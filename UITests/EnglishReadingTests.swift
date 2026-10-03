import XCTest

final class EnglishReadingTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    func testInlineAndPopupVocabularyPreserveReadingText() {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--translation-pages-sample", "--english-reading-sample"]
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        XCTAssertTrue(app.buttons["排版"].waitForExistence(timeout: 10))
        app.buttons["排版"].tap(); app.buttons["阅读辅助"].tap()
        for key in ["english-learning", "english-bionic"] {
            let toggle = app.switches[key]; XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        app.navigationBars["阅读辅助"].buttons.element(boundBy: 0).tap(); app.buttons["完成"].tap()
        let body = app.textViews["reader-text"].firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        XCTAssertTrue((body.value as? String ?? "").contains("After the rain"))
        XCTAssertFalse((body.value as? String ?? "").contains("书店"))
        func screenshot(_ name: String) { let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot) }
        screenshot("english-inline-continuous")
        app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons["无动画翻页"].tap(); app.buttons["完成"].tap()
        screenshot("english-inline-paged")
        app.buttons["reader-next-page"].tap()
        let saved = body.value as? String
        app.buttons["书签"].tap(); app.buttons["添加当前位置书签"].tap(); app.buttons["完成"].tap()
        app.buttons["reader-next-page"].tap(); app.buttons["书签"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmark-")).firstMatch.tap()
        XCTAssertEqual(body.value as? String, saved)
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        XCTAssertTrue(body.waitForExistence(timeout: 10)); XCTAssertEqual(body.value as? String, saved)
        app.buttons["排版"].tap(); app.buttons["阅读辅助"].tap()
        XCTAssertEqual(app.switches["english-learning"].value as? String, "1")
        XCTAssertEqual(app.switches["english-bionic"].value as? String, "1")
        app.buttons["english-annotation-mode"].tap(); app.buttons["划线弹窗"].tap()
        app.navigationBars["阅读辅助"].buttons.element(boundBy: 0).tap(); app.buttons["完成"].tap()
        screenshot("english-popup-paged")
        let paragraph = body.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "Paragraph 1.")).firstMatch
        XCTAssertTrue(paragraph.exists)
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.44, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).tap()
        XCTAssertTrue(app.textFields["dictionary-query"].waitForExistence(timeout: 10))
        XCTAssertEqual((app.textFields["dictionary-query"].value as? String)?.lowercased(), "after")
        XCTAssertTrue(app.staticTexts["生词本释义"].waitForExistence(timeout: 10))
        let learned = app.switches["dictionary-word-learned"]
        XCTAssertTrue(learned.waitForExistence(timeout: 10)); learned.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        screenshot("english-saved-definition")
        app.buttons["完成"].tap()
        screenshot("english-learned-word-unmarked")
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.44, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).tap()
        XCTAssertFalse(app.textFields["dictionary-query"].exists)
        XCTAssertFalse(app.buttons["排版"].exists)
    }

    func testPopupInEveryTextPageMode() {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--translation-pages-sample", "--english-reading-sample"]
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        XCTAssertTrue(app.buttons["排版"].waitForExistence(timeout: 10))
        app.buttons["排版"].tap(); app.buttons["阅读辅助"].tap()
        for key in ["english-learning", "english-bionic"] { app.switches[key].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        app.buttons["english-annotation-mode"].tap(); app.buttons["划线弹窗"].tap()
        app.navigationBars["阅读辅助"].buttons.element(boundBy: 0).tap(); app.buttons["完成"].tap()
        for mode in ["上下滚动", "无动画翻页", "覆盖翻页", "滑动翻页", "仿真翻页"] {
            app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons[mode].tap(); app.buttons["完成"].tap()
            let paragraph = app.textViews["reader-text"].firstMatch.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "Paragraph 1.")).firstMatch
            XCTAssertTrue(paragraph.waitForExistence(timeout: 10))
            paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.44, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).tap()
            XCTAssertTrue(app.textFields["dictionary-query"].waitForExistence(timeout: 10), mode)
            XCTAssertEqual((app.textFields["dictionary-query"].value as? String)?.lowercased(), "after", mode)
            XCTAssertTrue(app.staticTexts["生词本释义"].waitForExistence(timeout: 10))
            app.buttons["完成"].tap()
        }
    }

    func testEPUBEnglishDisplayAndBookmarkRestore() throws {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "EnglishReading", withExtension: "epub"))
        app.launchEnvironment["MOREAD_TEST_EPUB"] = try Data(contentsOf: url).base64EncodedString()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-epub", "--english-reading-sample", "--simulate-translations"]
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店 · EPUB")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20)); book.tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 20))
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Paragraph 01.")).firstMatch.waitForExistence(timeout: 15))
        app.buttons["排版"].tap(); app.buttons["阅读辅助"].tap()
        for key in ["english-learning", "english-bionic"] { app.switches[key].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        app.navigationBars["阅读辅助"].buttons.firstMatch.tap(); app.buttons["完成"].tap()
        func shot(_ name: String) { let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image) }
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Paragraph")).firstMatch.waitForExistence(timeout: 15))
        shot("epub-english-inline")
        web.swipeLeft()
        let baseline = web.screenshot().pngRepresentation
        app.buttons["书签"].tap(); app.buttons["添加当前位置书签"].tap(); app.buttons["完成"].tap()
        app.buttons["目录"].tap(); app.buttons["第二章 来信"].tap()
        app.buttons["书签"].tap(); app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmark-")).firstMatch.tap()
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Paragraph")).firstMatch.waitForExistence(timeout: 15))
        shot("epub-english-bookmark")
        XCTAssertEqual(web.screenshot().pngRepresentation, baseline)
        app.terminate(); app.launchArguments = ["--ui-testing", "--simulate-translations"]; app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Paragraph")).firstMatch.waitForExistence(timeout: 20))
        shot("epub-english-restart")
        XCTAssertEqual(web.screenshot().pngRepresentation, baseline)
        app.buttons["排版"].tap(); app.buttons["阅读辅助"].tap()
        app.buttons["english-annotation-mode"].tap(); app.buttons["划线弹窗"].tap()
        app.navigationBars["阅读辅助"].buttons.firstMatch.tap(); app.buttons["完成"].tap()
        shot("epub-english-popup")
        func tapWord(_ prefix: String, expected: String) throws {
            let word = try XCTUnwrap(web.staticTexts.matching(NSPredicate(format: "label IN %@", [prefix, expected, expected.capitalized])).allElementsBoundByIndex.first(where: { $0.isHittable }))
            word.tap()
            XCTAssertTrue(app.textFields["dictionary-query"].waitForExistence(timeout: 10))
            XCTAssertEqual((app.textFields["dictionary-query"].value as? String)?.lowercased(), expected)
            XCTAssertTrue(app.staticTexts["生词本释义"].waitForExistence(timeout: 10))
            app.buttons["完成"].tap()
        }
        try tapWord("Aft", expected: "after")
        try tapWord("shop", expected: "bookshop")
        app.buttons["排版"].tap(); app.buttons["epub-page-mode"].tap(); app.buttons["上下滚动"].tap(); app.buttons["完成"].tap()
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label IN %@", ["Aft", "After"])).firstMatch.waitForExistence(timeout: 15))
        shot("epub-english-popup-scroll")
        try tapWord("Aft", expected: "after")
        app.buttons["排版"].tap(); app.buttons["阅读辅助"].tap()
        app.buttons["english-annotation-mode"].tap(); app.buttons["直接显示"].tap()
        app.navigationBars["阅读辅助"].buttons.firstMatch.tap(); app.buttons["完成"].tap()
        app.buttons["目录"].tap(); app.buttons["中英对照"].tap(); app.buttons["translations-start"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "译文已保存"), object: app.staticTexts["translations-status"])], timeout: 20), .completed)
        app.navigationBars["中英对照"].buttons.firstMatch.tap(); app.buttons["完成"].tap()
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "本地译文：")).firstMatch.waitForExistence(timeout: 15))
        shot("epub-english-with-translations")
        app.buttons["排版"].tap(); app.buttons["阅读辅助"].tap()
        for key in ["english-learning", "english-bionic"] { app.switches[key].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        app.navigationBars["阅读辅助"].buttons.firstMatch.tap(); app.buttons["完成"].tap()
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "本地译文：")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(web.staticTexts["Aft"].waitForNonExistence(timeout: 10))
        shot("epub-english-disabled")
        let translated = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "本地译文：")).firstMatch
        let frame = translated.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + 12, dy: frame.minY + 12)).press(forDuration: 1.2)
        func selectionAction() -> XCUIElement? {
            if app.menuItems["批注"].exists { return app.menuItems["批注"] }
            let button = app.collectionViews.buttons["批注"]; return button.exists ? button : nil
        }
        for _ in 0..<3 where selectionAction() == nil {
            let next = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next Page", "Forward"])).firstMatch
            if next.waitForExistence(timeout: 2) { next.tap() }
        }
        let action = try XCTUnwrap(selectionAction()), actionFrame = action.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: actionFrame.midX, dy: actionFrame.midY)).tap()
        XCTAssertTrue(app.navigationBars["本段对照"].waitForExistence(timeout: 10))
        let original = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "translation-source-")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        XCTAssertTrue(original.label.contains("Paragraph 01. After the rain, Lin opened the bookshop door."))
    }
}
