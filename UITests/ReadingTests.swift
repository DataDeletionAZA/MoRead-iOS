import XCTest

final class ReadingTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    func testSpeechPreferencesAndChapterSleepTimer() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        XCTAssertTrue(app.buttons["听书"].waitForExistence(timeout: 10)); app.buttons["听书"].tap()
        let rate = app.sliders["speech-rate"]
        XCTAssertTrue(rate.waitForExistence(timeout: 10)); rate.adjust(toNormalizedSliderPosition: 0.65)
        let savedRate = rate.value as? String; XCTAssertNotNil(savedRate)
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        app.buttons["听书"].tap()
        XCTAssertTrue(rate.waitForExistence(timeout: 10)); XCTAssertEqual(rate.value as? String, savedRate)
        app.buttons["speech-start"].tap()
        let playback = app.buttons["speech-play-pause"]
        XCTAssertTrue(playback.waitForExistence(timeout: 15))
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '暂停' AND enabled == true"), object: playback)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 15), .completed); playback.tap()
        XCTAssertEqual(playback.label, "继续")
        app.buttons["speech-timer"].tap(); app.buttons["15 分钟"].tap()
        XCTAssertTrue(app.buttons["speech-timer"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["speech-timer"].label.contains("15:00"))
        app.buttons["speech-timer"].tap(); app.buttons["按章节"].tap(); app.buttons["本章结束"].tap()
        XCTAssertTrue(app.buttons["speech-timer"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["speech-timer"].label.contains("还剩 1 章"))
        app.buttons["speech-next-chapter"].tap()
        XCTAssertTrue(app.buttons["speech-timer"].label.contains("还剩 1 章"))
        XCTAssertEqual(playback.label, "继续")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
        playback.tap()
        XCTAssertTrue(app.staticTexts["speech-stop-reason"].waitForExistence(timeout: 50))
        XCTAssertEqual(app.staticTexts["speech-stop-reason"].label, "定时结束")
        XCTAssertTrue(app.buttons["speech-start"].exists)
        XCTAssertFalse(app.alerts["需要处理"].exists)
    }
    func testVectorMemoryOptInAndModelSurviveRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        app.tabBars.buttons["设置"].tap(); app.buttons["向量记忆"].tap()
        let model = app.textFields["embedding-model"]
        XCTAssertTrue(model.waitForExistence(timeout: 10)); model.tap(); model.typeText("embedding-test\n")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        let enabled = app.switches["enable-book-memory"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 10)); XCTAssertEqual(enabled.value as? String, "0")
        XCTAssertTrue(enabled.isHittable)
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let toggled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: enabled)
        XCTAssertEqual(XCTWaiter.wait(for: [toggled], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["build-book-memory"].isEnabled)
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.tabBars.buttons["设置"].tap(); app.buttons["向量记忆"].tap()
        XCTAssertEqual(app.textFields["embedding-model"].value as? String, "embedding-test")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        XCTAssertEqual(app.switches["enable-book-memory"].value as? String, "1")
        XCTAssertEqual(app.staticTexts["book-memory-state"].label, "尚未整理原文")
        XCTAssertFalse(app.buttons["build-book-memory"].isEnabled)
    }
    func testLargeImportPreviewCanBeCancelled() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--preview-test-text", "--large-preview-test-text"]
        app.launch()
        let cancel = app.buttons["取消导入"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 20))
        XCTAssertTrue(cancel.isHittable); cancel.tap()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts["需要处理"].exists)
    }
    func testPreviewCustomRuleAndBatchImport() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--preview-test-text"]
        app.launch()
        XCTAssertTrue(app.staticTexts["import-preview"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["import-preview"].label.contains("她在第一页写下今天的日期"))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "章节规则")).firstMatch.tap()
        app.buttons["自定义规则"].tap()
        let rule = app.textFields["import-rule"]
        XCTAssertTrue(rule.waitForExistence(timeout: 10)); rule.tap(); rule.typeText("[")
        app.buttons["更新预览"].tap()
        XCTAssertTrue(app.staticTexts["import-error"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["confirm-text-import"].isEnabled)
        rule.tap()
        rule.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        rule.typeText(XCUIKeyboardKey.delete.rawValue)
        rule.typeText("^第[一二]章.*$")
        XCTAssertEqual(rule.value as? String, "^第[一二]章.*$")
        app.buttons["更新预览"].tap()
        XCTAssertTrue(app.staticTexts["import-preview"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["confirm-text-import"].tap()
        XCTAssertTrue(app.buttons["取消导入"].waitForExistence(timeout: 10)); app.buttons["取消导入"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        XCTAssertTrue(app.textViews["reader-text"].waitForExistence(timeout: 10))
        XCTAssertTrue((app.textViews["reader-text"].value as? String)?.contains("她在第一页写下今天的日期") == true)
        app.buttons["下一章"].tap()
        XCTAssertTrue(app.navigationBars["第二章 来信"].waitForExistence(timeout: 5))
    }
    func testClearBodyKeepsBookmarkAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library"]
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        XCTAssertTrue(app.textViews["reader-text"].waitForExistence(timeout: 10))
        app.buttons["书签"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["设置"].tap()
        app.buttons["存储与阅读记录"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        app.buttons["clear-book-body"].tap()
        app.alerts.buttons["清理正文"].tap()
        XCTAssertTrue(app.staticTexts["正文已清理，阅读记录保存在本机。"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["--ui-testing"]; app.launch()
        app.tabBars.buttons["设置"].tap()
        app.buttons["存储与阅读记录"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["正文已清理，阅读记录保存在本机。"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "第一章 雨后")).firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
    }

    func testShelfGroupAndAssignmentSurviveRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library"]
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15))
        app.buttons["add-sample"].tap()
        app.tabBars.buttons["设置"].tap()
        app.buttons["整理书架"].tap()
        app.buttons["new-shelf-group"].tap()
        app.textFields["group-name"].tap(); app.textFields["group-name"].typeText("旅行")
        app.buttons["保存"].tap()
        app.buttons["批量整理书籍"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["已选 1 本"].exists)
        XCTAssertTrue(app.buttons["分组"].isHittable)
        app.buttons["分组"].tap()
        app.buttons["旅行"].tap()
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["旅行"].waitForExistence(timeout: 10)); app.buttons["旅行"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.waitForExistence(timeout: 10))
    }

    func testCreateLocalBackupFromSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library"]
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15))
        app.buttons["add-sample"].tap()
        app.tabBars.buttons["设置"].tap()
        app.buttons["备份与恢复"].tap()
        app.buttons["create-backup"].tap()
        XCTAssertTrue(app.buttons["share-backup"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.alerts["需要处理"].exists)
    }

    func testEPUBContentsAndLocationSurviveRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library"]
        app.launch()
        XCTAssertTrue(app.buttons["add-epub-sample"].waitForExistence(timeout: 15))
        app.buttons["add-epub-sample"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店 · EPUB")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20)); book.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))
        app.buttons["目录"].tap()
        app.buttons["第二章 来信"].tap()
        let text = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "一封没有署名的信")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 20))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 20))
    }

    func testOpenBookAndKeepLibraryAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library"]
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15))
        app.buttons["add-sample"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        XCTAssertTrue(app.textViews["reader-text"].waitForExistence(timeout: 10))
        XCTAssertTrue((app.textViews["reader-text"].value as? String)?.contains("她在第一页写下今天的日期") == true)
        app.textViews["reader-text"].swipeUp()
        app.buttons["下一章"].tap()
        XCTAssertTrue(app.navigationBars["第二章 来信"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        XCTAssertTrue(app.navigationBars["第二章 来信"].waitForExistence(timeout: 10))
    }
}
