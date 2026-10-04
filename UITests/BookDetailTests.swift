import XCTest

final class BookDetailTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    func testBookDetailEPUBCoverResetAndReading() {
        executionTimeAllowance = 180
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-cover"]; app.launch()
        XCTAssertTrue(app.buttons["add-epub-sample"].waitForExistence(timeout: 15)); app.buttons["add-epub-sample"].tap()
        let detail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "book-details-")).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 15)); detail.tap()
        XCTAssertTrue(app.buttons["book-detail-cover"].waitForExistence(timeout: 5)); app.buttons["book-detail-cover"].tap()
        func tap(_ label: String) {
            let button = app.buttons[label]
            for _ in 0..<5 { if button.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(button.isHittable); button.tap()
        }
        tap("选择测试封面"); tap("save-book-cover")
        XCTAssertTrue(app.images["saved-book-cover"].waitForExistence(timeout: 5)); app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["book-detail-read"].waitForExistence(timeout: 5))
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "book-detail-epub-cover"; image.lifetime = .keepAlways; add(image)
        app.buttons["book-detail-cover"].tap(); tap("恢复文字封面"); app.sheets.buttons["恢复文字封面"].tap()
        XCTAssertTrue(app.staticTexts["文字封面"].waitForExistence(timeout: 5)); app.navigationBars.buttons.element(boundBy: 0).tap()
        let fallback = XCTAttachment(screenshot: app.screenshot()); fallback.name = "book-detail-epub-text-cover"; fallback.lifetime = .keepAlways; add(fallback)
        app.buttons["book-detail-read"].tap(); XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["排版"].exists)
    }
    func testBookDetailCoverMetadataRecordsAndReaderEntrypoints() {
        executionTimeAllowance = 360
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-cover"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        func openDetail() {
            let detail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "book-details-")).firstMatch
            XCTAssertTrue(detail.waitForExistence(timeout: 10)); detail.tap()
            XCTAssertTrue(app.buttons["book-detail-read"].waitForExistence(timeout: 5))
        }
        func tap(_ id: String) {
            let button = app.buttons[id]
            for _ in 0..<5 { if button.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(button.isHittable); button.tap()
        }
        func back() { app.navigationBars.buttons.element(boundBy: 0).tap() }
        func top() { for _ in 0..<5 { if app.buttons["book-detail-cover"].isHittable { break }; app.swipeDown() } }
        openDetail()
        let plain = XCTAttachment(screenshot: app.screenshot()); plain.name = "book-detail-text-cover"; plain.lifetime = .keepAlways; add(plain)
        app.buttons["book-detail-cover"].tap(); tap("选择测试封面"); tap("save-book-cover")
        XCTAssertTrue(app.images["saved-book-cover"].waitForExistence(timeout: 5)); back()
        XCTAssertTrue(app.buttons["book-detail-read"].waitForExistence(timeout: 5))
        let art = XCTAttachment(screenshot: app.screenshot()); art.name = "book-detail-cover-atmosphere"; art.lifetime = .keepAlways; add(art)
        app.buttons["book-detail-edit"].tap(); app.buttons["编辑资料"].tap()
        let title = app.textFields["book-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText(" · 藏书")
        app.buttons["保存"].tap(); XCTAssertTrue(app.staticTexts["雨后的书店 · 藏书"].waitForExistence(timeout: 5))
        tap("book-detail-notes"); app.buttons["新建笔记"].tap()
        let noteTitle = app.textFields["reading-note-title"]
        XCTAssertTrue(noteTitle.waitForExistence(timeout: 5)); noteTitle.tap(); noteTitle.typeText("书店随记")
        app.textViews["reading-note-content"].tap(); app.textViews["reading-note-content"].typeText("雨后再翻开这本书。")
        app.buttons["保存"].tap(); XCTAssertTrue(app.buttons["reading-note-书店随记"].waitForExistence(timeout: 5)); back()
        tap("book-detail-annotations")
        XCTAssertTrue(app.buttons["review-kind"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["review-kind"].label.contains("划线与批注")); back()
        top(); tap("book-detail-listen")
        XCTAssertTrue(app.navigationBars["听书"].waitForExistence(timeout: 10)); app.buttons["完成"].tap(); back()
        tap("book-detail-read")
        XCTAssertTrue(app.buttons["书签"].waitForExistence(timeout: 10)); app.buttons["书签"].tap()
        app.buttons["添加当前位置书签"].tap(); app.buttons["完成"].tap(); back()
        tap("book-detail-bookmarks")
        XCTAssertTrue(app.navigationBars["书签"].waitForExistence(timeout: 10)); app.buttons["完成"].tap(); back()
        top(); app.buttons["book-detail-state"].tap(); app.buttons["已读"].tap()
        app.terminate(); app.launchArguments = ["--ui-testing", "--simulate-cover"]; app.launch(); openDetail()
        XCTAssertTrue(app.staticTexts["雨后的书店 · 藏书"].exists); XCTAssertTrue(app.buttons["book-detail-state"].label.contains("已读"))
        tap("book-detail-notes"); XCTAssertTrue(app.buttons["reading-note-书店随记"].waitForExistence(timeout: 5))
    }
}
