import XCTest

final class ReadingTests: XCTestCase {
    func testChapterTranslationsReuseHideDeleteStopAndRestart() {
        executionTimeAllowance = 420
        let app = XCUIApplication()
        func launch(_ extra: [String] = []) {
            app.launchArguments = ["--ui-testing", "--simulate-translations", "--simulate-model-roles", "--translation-sample"] + extra
            app.launch()
        }
        func tap(_ id: String) {
            let button = app.buttons[id]
            if !button.exists || !button.isHittable { revealListElement(button, in: app) }
            button.tap()
        }
        func open() {
            let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
            XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
            app.buttons["目录"].tap(); tap("中英对照")
            XCTAssertTrue(app.buttons["translations-start"].waitForExistence(timeout: 10))
        }
        func status(_ text: String) {
            let row = app.staticTexts["translations-status"]
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: row)], timeout: 15), .completed)
        }
        func replace() { tap("translations-replace"); app.buttons["重新翻译"].tap() }
        launch(["--reset-test-library"])
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap(); open()
        tap("model-role-translation"); app.buttons["批量测试 · batch-fixture"].tap()
        tap("translations-start"); status("译文已保存")
        let first = app.staticTexts["translation-text-0"]
        revealListElement(first, in: app); XCTAssertTrue(first.label.contains("本地译文：After the rain"))
        tap("translation-toggle-0"); XCTAssertFalse(first.exists)
        tap("translation-toggle-0"); XCTAssertTrue(first.exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "paragraph-translation"; shot.lifetime = .keepAlways; add(shot)
        tap("translation-delete-0"); XCTAssertFalse(first.exists)
        tap("translations-start"); status("译文已保存")
        app.terminate(); launch(["--translations-fail"]); open()
        XCTAssertTrue(app.staticTexts["model-effective-translation"].label.contains("batch-fixture"))
        tap("translations-start"); status("译文已保存")
        replace(); status("翻译服务暂不可用")
        revealListElement(first, in: app); XCTAssertTrue(first.label.contains("本地译文：After the rain"))
        let visible = app.switches["translations-visible"]
        revealListElement(visible, in: app); visible.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(visible.value as? String, "0")
        app.terminate(); launch(["--translations-slow"]); open()
        XCTAssertEqual(visible.value as? String, "0")
        replace(); XCTAssertTrue(app.buttons["translations-stop"].waitForExistence(timeout: 5)); tap("translations-stop"); status("已停止")
        tap("translation-toggle-0"); XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["需要处理"].exists)
    }
    func testInlineTranslationsCurrentPageModesAndBookmarks() {
        executionTimeAllowance = 420
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-translations", "--translation-pages-sample"]
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        func text() -> String { app.textViews["reader-text"].firstMatch.value as? String ?? "" }
        func mode(_ name: String) {
            app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons[name].tap(); app.buttons["完成"].tap()
            XCTAssertTrue(app.textViews["reader-text"].firstMatch.waitForExistence(timeout: 10))
        }
        func number(_ prefix: String) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", prefix), object: app.staticTexts["reader-page-number"])], timeout: 10), .completed)
        }
        func closeComparison(_ title: String) {
            app.navigationBars[title].buttons.element(boundBy: 0).tap()
            app.buttons["完成"].tap()
        }
        func showTranslations(_ visible: Bool) {
            app.buttons["目录"].tap(); app.buttons["中英对照"].tap()
            let toggle = app.switches["translations-visible"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            if (toggle.value as? String == "1") != visible { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
            closeComparison("中英对照")
        }
        mode("无动画翻页"); number("本章 1 /")
        let original = text(); XCTAssertTrue(original.hasPrefix("Paragraph 1.")); XCTAssertFalse(original.contains("Paragraph 24."))
        app.buttons["目录"].tap(); app.buttons["翻译当前页"].tap()
        XCTAssertTrue(app.navigationBars["当前页对照"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Paragraph 24.")).firstMatch.exists)
        app.buttons["translations-start"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "译文已保存"), object: app.staticTexts["translations-status"])], timeout: 15), .completed)
        closeComparison("当前页对照"); number("本章 1 /")
        XCTAssertTrue(text().contains("本地译文：Paragraph 1."))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "inline-translation-page"; shot.lifetime = .keepAlways; add(shot)
        app.textViews["reader-text"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4)).press(forDuration: 1.2)
        let translationMenu = app.descendants(matching: .any).matching(identifier: "本段译文").firstMatch
        for _ in 0..<3 where !translationMenu.exists {
            let next = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next Page", "Forward"])).firstMatch
            if next.waitForExistence(timeout: 2) { next.tap() }
        }
        XCTAssertTrue(translationMenu.waitForExistence(timeout: 5)); translationMenu.tap()
        XCTAssertTrue(app.navigationBars["本段对照"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["translation-source-0"].label.hasPrefix("Paragraph 1."))
        app.buttons["完成"].tap()
        for name in ["滑动翻页", "覆盖翻页", "仿真翻页"] {
            mode(name); number("本章 1 /"); XCTAssertTrue(text().contains("本地译文：Paragraph 1."))
        }
        mode("无动画翻页")
        showTranslations(false); number("本章 1 /"); XCTAssertEqual(text(), original)
        showTranslations(true); number("本章 1 /"); XCTAssertTrue(text().contains("本地译文：Paragraph 1."))
        let total = Int(app.staticTexts["reader-page-number"].label.components(separatedBy: "/").last!.replacingOccurrences(of: "页", with: "").trimmingCharacters(in: .whitespaces))!
        XCTAssertGreaterThan(total, 4)
        for page in 2..<total { app.buttons["reader-next-page"].tap(); number("本章 \(page) /") }
        let bookmarked = text()
        XCTAssertFalse(bookmarked.contains("本地译文"))
        app.buttons["书签"].tap(); app.buttons["添加当前位置书签"].tap()
        XCTAssertTrue(app.staticTexts["书签已保存"].exists); app.buttons["完成"].tap()
        app.buttons["reader-next-page"].tap(); number("本章 \(total) /")
        app.buttons["书签"].tap(); app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmark-")).firstMatch.tap()
        number("本章 \(total - 1) /"); XCTAssertEqual(text(), bookmarked)
        app.terminate(); app.launchArguments = ["--ui-testing", "--simulate-translations", "--translations-fail"]; app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        XCTAssertTrue(app.textViews["reader-text"].firstMatch.waitForExistence(timeout: 10))
        number("本章 \(total - 1) /"); XCTAssertEqual(text(), bookmarked)
        app.buttons["目录"].tap(); app.buttons["第一章 雨后"].tap(); number("本章 1 /")
        XCTAssertTrue(text().contains("本地译文：Paragraph 1."))
        mode("上下滚动"); XCTAssertTrue(text().contains("本地译文：Paragraph 1."))
        XCTAssertFalse(text().contains("本地译文：Paragraph 24."))
        XCTAssertFalse(app.alerts["需要处理"].exists)
    }

    func testSettingsRemainNavigableWhileCredentialsLoad() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-slow-credentials"]; app.launch()
        app.tabBars.buttons["设置"].tap(); app.buttons["AI 绘图"].tap()
        XCTAssertTrue(app.navigationBars["AI 绘图"].waitForExistence(timeout: 5))
        app.buttons["image-service"].tap(); app.buttons["聊天接口出图"].tap()
        app.buttons["save-image-settings"].tap()
        XCTAssertTrue(app.staticTexts["image-settings-status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["image-settings-status"].label, "绘图设置已保存。")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["image-key-status"].label.contains("正在读取"))
        XCTAssertFalse(app.secureTextFields["输入新的 API Key"].isEnabled)
        app.navigationBars["AI 绘图"].buttons.element(boundBy: 0).tap()
        tapSettingsRow("AI 服务商", in: app); app.buttons["添加服务商"].tap()
        XCTAssertTrue(app.navigationBars["连接 AI"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["API 密钥"].isEnabled); XCTAssertFalse(app.buttons["保存"].isEnabled)
        app.buttons["取消"].tap(); app.navigationBars["AI 服务商"].buttons.element(boundBy: 0).tap()
        tapSettingsRow("联网搜索", in: app)
        app.buttons["web-provider"].tap(); app.buttons["Tavily"].tap(); app.swipeUp()
        XCTAssertTrue(app.switches["web-advanced-search"].waitForExistence(timeout: 5))
        app.navigationBars["联网搜索"].buttons.element(boundBy: 0).tap()
        tapSettingsRow("云端声音与缓存", in: app)
        XCTAssertTrue(app.navigationBars["云端声音与缓存"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["cloud-speech-service"].isEnabled)
        app.navigationBars["云端声音与缓存"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
    }

    func testCompanionStatisticsScopesPeriodsBranchDeduplicationDeletionAndRestart() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-companion-statistics"]; app.launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "月下书店")).firstMatch.waitForExistence(timeout: 15))
        func openStats() { app.tabBars.buttons["伴读"].tap(); app.buttons["陪伴足迹"].tap() }
        func value(_ name: String, _ text: String) {
            let row = app.descendants(matching: .any).matching(identifier: "companion-stats-" + name).firstMatch
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: row)], timeout: 10), .completed, name)
        }
        func period(_ title: String) { app.segmentedControls["companion-stats-period"].buttons[title].tap() }
        func scope(_ title: String) { app.segmentedControls["companion-stats-scope"].buttons[title].tap() }
        openStats()
        value("days", "46"); value("books", "2 本书"); value("reading", "3 小时 30 分钟"); value("words", "30 字")
        let overview = XCTAttachment(screenshot: app.screenshot()); overview.name = "Companion-statistics-all"; overview.lifetime = .keepAlways; add(overview)
        period("近 7 天"); value("books", "1 本书"); value("reading", "1 小时 0 分钟"); value("words", "12 字"); value("days", "46")
        value("rounds", "2 轮"); value("active", "1 天"); value("conversations", "2 个")
        period("近 30 天"); value("books", "2 本书"); value("reading", "1 小时 30 分钟"); value("words", "24 字")
        scope("书库伴读"); value("days", "9"); value("books", "1 本书"); value("words", "12 字")
        period("近 7 天"); value("books", "0 本书"); value("reading", "0 分钟"); value("words", "6 字"); value("rounds", "1 轮")
        scope("书内伴读"); period("全部"); value("books", "1 本书"); value("words", "18 字"); value("reading", "3 小时 0 分钟")
        app.buttons["统计说明"].tap(); XCTAssertTrue(app.alerts["统计说明"].waitForExistence(timeout: 5)); app.buttons["知道了"].tap()
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); openStats()
        value("books", "2 本书"); value("words", "30 字")
        app.navigationBars["陪伴足迹"].buttons.element(boundBy: 0).tap()
        let chat = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "书库闲聊")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 5)); chat.swipeLeft(); app.buttons["删除"].tap()
        app.buttons["陪伴足迹"].tap(); scope("书库伴读")
        value("books", "0 本书"); value("words", "0 字")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["这个范围还没有完整的交流记录。"].exists)
        let empty = XCTAttachment(screenshot: app.screenshot()); empty.name = "Companion-statistics-empty"; empty.lifetime = .keepAlways; add(empty)
    }

    func testStatisticsPeriodsCalendarWidgetsAndRestart() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-statistics"]; app.launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "月下书店")).firstMatch.waitForExistence(timeout: 15))
        app.tabBars.buttons["足迹"].tap()
        func total(_ text: String) {
            let row = app.descendants(matching: .any).matching(identifier: "stats-total").firstMatch
            XCTAssertTrue(NSPredicate(format: "label CONTAINS %@", text).evaluate(with: row) || XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: row)], timeout: 10) == .completed)
        }
        func reveal(_ element: XCUIElement) { revealListElement(element, in: app) }
        func shot(_ name: String) { let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image) }
        total("1 小时 30 分钟"); XCTAssertFalse(app.buttons["stats-next"].isEnabled)
        app.buttons["stats-previous"].tap(); total("2 小时 0 分钟")
        XCTAssertTrue(app.buttons["stats-next"].isEnabled); app.buttons["stats-next"].tap(); total("1 小时 30 分钟")
        app.segmentedControls["stats-period"].buttons["总"].tap(); total("3 小时 30 分钟")
        XCTAssertFalse(app.buttons["stats-next"].isEnabled); XCTAssertFalse(app.buttons["stats-previous"].isEnabled)
        app.segmentedControls["stats-period"].buttons["日"].tap(); total("1 小时 30 分钟")
        app.segmentedControls["stats-period"].buttons["月"].tap(); total("1 小时 30 分钟"); shot("statistics-overview")
        let calendar = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "stats-calendar-day-", "2 本书")).firstMatch
        reveal(calendar)
        XCTAssertFalse(app.buttons["stats-calendar-next"].isEnabled)
        app.buttons["stats-calendar-previous"].tap()
        XCTAssertTrue(app.buttons["stats-calendar-next"].isEnabled)
        let emptyDay = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND enabled == true", "stats-calendar-day-", "0 本书")).firstMatch
        XCTAssertTrue(emptyDay.waitForExistence(timeout: 5)); emptyDay.tap()
        XCTAssertTrue(app.staticTexts["这一天还没有阅读记录。"].waitForExistence(timeout: 5)); app.buttons["完成"].tap()
        app.buttons["stats-calendar-next"].tap()
        reveal(calendar); shot("statistics-calendar"); calendar.tap()
        XCTAssertTrue(app.navigationBars["1 小时 30 分钟"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "月下书店")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "山间来信")).firstMatch.exists)
        shot("statistics-day-details"); app.buttons["完成"].tap()
        for title in ["阅读趋势", "阅读时间段", "阅读时间线", "阅读排行", "标签云", "作者云"] {
            reveal(app.staticTexts[title].firstMatch)
            if title == "阅读时间段" {
                let band = app.descendants(matching: .any).matching(identifier: "stats-hour-band-0").firstMatch
                reveal(band)
                XCTAssertTrue(band.label.contains("凌晨 00–06")); XCTAssertTrue(band.label.contains("1 小时 30 分钟"))
                shot("statistics-hours")
            }
        }
        shot("statistics-clouds")
        app.buttons["调整统计组件"].tap()
        let toggle = app.switches["stats-visible-calendar"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap(); XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["完成"].tap(); app.terminate()
        app.launchArguments = ["--ui-testing"]; app.launch(); app.tabBars.buttons["足迹"].tap(); total("1 小时 30 分钟")
        app.buttons["调整统计组件"].tap(); XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["恢复默认组件"].tap(); XCTAssertEqual(toggle.value as? String, "1"); app.buttons["完成"].tap()
    }

    func testEPUBEmbeddedCoverAndDamagedCoverPreserveReadableBook() throws {
        executionTimeAllowance = 600
        let app = XCUIApplication()
        for name in ["Cover", "BrokenCover"] {
            let url = try XCTUnwrap(Bundle(for: ReadingTests.self).url(forResource: name, withExtension: "epub"))
            app.launchEnvironment["MOREAD_TEST_EPUB"] = try Data(contentsOf: url).base64EncodedString()
            app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-epub"]; app.launch()
            func openCover() {
                let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店 · EPUB")).firstMatch
                XCTAssertTrue(book.waitForExistence(timeout: 20)); book.tap()
                XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))
                app.buttons["目录"].tap(); app.buttons["书籍封面"].tap()
                XCTAssertTrue(app.navigationBars["书籍封面"].waitForExistence(timeout: 5))
            }
            openCover()
            if name == "Cover" { XCTAssertTrue(app.images["saved-book-cover"].waitForExistence(timeout: 5)) }
            else { XCTAssertTrue(app.staticTexts["文字封面"].waitForExistence(timeout: 5)); XCTAssertFalse(app.images["saved-book-cover"].exists) }
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "EPUB-" + name; shot.lifetime = .keepAlways; add(shot)
            app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); openCover()
            if name == "Cover" { XCTAssertTrue(app.images["saved-book-cover"].waitForExistence(timeout: 5)) }
            else { XCTAssertTrue(app.staticTexts["文字封面"].waitForExistence(timeout: 5)) }
            app.navigationBars["书籍封面"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
            app.buttons["完成"].tap()
            XCTAssertFalse(app.navigationBars["目录"].exists)
            XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))
            XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "雨停后")).firstMatch.waitForExistence(timeout: 20))
            app.terminate()
        }
    }
    func testAICoverPreviewCancelFailureStopSaveAndRelaunch() {
        executionTimeAllowance = 600
        let app = XCUIApplication()
        func launch(_ reset: Bool = false) { app.launchArguments = ["--ui-testing", "--simulate-images", "--simulate-cover"] + (reset ? ["--reset-test-library"] : []); app.launch() }
        func tap(_ name: String) {
            let button = app.buttons[name]
            for _ in 0..<6 { if button.exists && button.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(button.exists && button.isHittable, name); button.tap()
        }
        func openCover() {
            let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
            XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap(); tap("目录"); tap("书籍封面")
        }
        func generate(_ direction: String = "") {
            tap("AI 生成封面"); XCTAssertTrue(app.navigationBars["AI 生成封面"].waitForExistence(timeout: 5))
            if !direction.isEmpty { let field = app.textViews["illustration-prompt"]; field.tap(); field.typeText(direction) }
            tap("generate-illustration")
        }
        launch(true); XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        app.tabBars.buttons["设置"].tap(); tapSettingsRow("AI 绘图", in: app); tap("save-image-settings")
        XCTAssertTrue(app.staticTexts["绘图设置已保存。"].waitForExistence(timeout: 5))
        app.tabBars.buttons["书架"].tap(); openCover(); tap("选择测试封面"); tap("save-book-cover")
        XCTAssertTrue(app.images["saved-book-cover"].waitForExistence(timeout: 5))
        generate(); XCTAssertTrue(app.images["generated-illustration"].waitForExistence(timeout: 10)); tap("preview-generated-cover")
        XCTAssertTrue(app.images["draft-book-cover"].waitForExistence(timeout: 5)); tap("取消裁剪")
        XCTAssertTrue(app.images["saved-book-cover"].waitForExistence(timeout: 5))
        generate("fail"); XCTAssertTrue(app.staticTexts["本地绘图服务暂不可用。"].waitForExistence(timeout: 10)); tap("关闭")
        XCTAssertTrue(app.images["saved-book-cover"].waitForExistence(timeout: 5))
        generate("slow"); tap("停止生成"); XCTAssertTrue(app.staticTexts["已停止。"].waitForExistence(timeout: 5)); tap("关闭")
        XCTAssertTrue(app.images["saved-book-cover"].waitForExistence(timeout: 5))
        generate("A quiet blue bookshop"); XCTAssertTrue(app.images["generated-illustration"].waitForExistence(timeout: 10)); tap("preview-generated-cover")
        XCTAssertTrue(app.images["draft-book-cover"].waitForExistence(timeout: 5)); app.sliders["cover-focus-y"].adjust(toNormalizedSliderPosition: 0.85)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "AI-cover-crop"; shot.lifetime = .keepAlways; add(shot)
        tap("save-book-cover"); XCTAssertTrue(app.images["saved-book-cover"].waitForExistence(timeout: 5))
        app.terminate(); launch(); openCover(); XCTAssertTrue(app.images["saved-book-cover"].waitForExistence(timeout: 5))
    }
    func testIllustrationsOpenTheirSourceInTextAndEPUB() {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-illustration-locations"]
        app.launch()
        func frontButton(_ name: String) -> XCUIElement {
            let matches = app.buttons.matching(identifier: name)
            return matches.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? matches.firstMatch
        }
        func tap(_ name: String) {
            var button = frontButton(name)
            for _ in 0..<6 { if button.exists && button.isHittable { break }; app.swipeUp(); button = frontButton(name) }
            XCTAssertTrue(button.exists && button.isHittable, name); button.tap()
        }
        func open(_ epub: Bool) {
            let books = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店"))
            let book = books.matching(NSPredicate(format: epub ? "label CONTAINS %@" : "NOT (label CONTAINS %@)", "EPUB")).firstMatch
            XCTAssertTrue(book.waitForExistence(timeout: 20)); book.tap()
            if epub { XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20)) }
            else { XCTAssertTrue(app.textViews["reader-text"].waitForExistence(timeout: 10)) }
            tap("目录"); tap("插图廊")
            let picture = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "illustration-row-")).firstMatch
            XCTAssertTrue(picture.waitForExistence(timeout: 10)); picture.tap(); tap("illustration-read-source")
        }
        open(false)
        XCTAssertTrue(app.navigationBars["第二章 来信"].waitForExistence(timeout: 10))
        let selectedText = app.textViews.matching(identifier: "reader-text").matching(NSPredicate(format: "value CONTAINS %@", "一封没有署名的信")).firstMatch
        XCTAssertTrue(selectedText.exists && selectedText.isHittable)
        tap("排版"); tap("reader-page-mode"); tap("滑动翻页"); tap("完成")
        XCTAssertTrue(app.buttons["reader-next-page"].waitForExistence(timeout: 10))
        XCTAssertTrue(selectedText.exists && selectedText.isHittable)
        app.navigationBars["第二章 来信"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["插图"].waitForExistence(timeout: 5)); tap("illustration-read-source")
        XCTAssertTrue(app.navigationBars["第二章 来信"].waitForExistence(timeout: 10))
        let textShot = XCTAttachment(screenshot: app.screenshot()); textShot.name = "Illustration-text-source"; textShot.lifetime = .keepAlways; add(textShot)
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        open(true)
        let source = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "一封没有署名的信")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 20)); XCTAssertTrue(source.isHittable)
        let epubShot = XCTAttachment(screenshot: app.screenshot()); epubShot.name = "Illustration-epub-source"; epubShot.lifetime = .keepAlways; add(epubShot)
        app.terminate(); app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店 · EPUB")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap(); XCTAssertTrue(source.waitForExistence(timeout: 20))
    }
    func testChatIllustrationsSaveRestoreRefuseFutureFailAndStop() {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        func launch(_ reset: Bool = false) { app.launchArguments = ["--ui-testing", "--simulate-tools", "--simulate-images", "--simulate-tool-images"] + (reset ? ["--reset-test-library"] : []); app.launch() }
        func tap(_ name: String) {
            let button = app.buttons[name]
            for _ in 0..<6 { if button.exists && button.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(button.exists && button.isHittable, name); button.tap()
        }
        func openChat() { app.tabBars.buttons["伴读"].tap(); app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "工具查询")).firstMatch.tap() }
        func send(_ text: String) {
            let input = app.descendants(matching: .any).matching(identifier: "chat-input").firstMatch
            input.tap(); input.typeText(text); app.buttons["发送"].tap()
        }
        func imageSetting() {
            app.tabBars.buttons["设置"].tap()
            if !app.navigationBars["AI 绘图"].exists { tapSettingsRow("AI 绘图", in: app) }
            let toggle = app.switches["image-companion-enabled"]
            for _ in 0..<6 { if toggle.exists && toggle.isHittable { break }; app.swipeUp() }
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap(); tap("save-image-settings")
            XCTAssertTrue(app.staticTexts["绘图设置已保存。"].waitForExistence(timeout: 5))
        }
        launch(true); imageSetting(); openChat(); send("Draw the lighthouse.")
        XCTAssertTrue(app.staticTexts["插图已生成并保存。"].waitForExistence(timeout: 15))
        let pictures = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-illustration-"))
        XCTAssertTrue(pictures.firstMatch.waitForExistence(timeout: 5)); pictures.firstMatch.tap()
        XCTAssertTrue(app.images["illustration-detail-image"].waitForExistence(timeout: 5))
        for _ in 0..<6 { if app.staticTexts["lighthouse first clue."].exists { break }; app.swipeUp() }
        XCTAssertTrue(app.staticTexts["lighthouse first clue."].exists); tap("illustration-read-source")
        XCTAssertTrue(app.navigationBars["First"].waitForExistence(timeout: 10))
        XCTAssertTrue((app.textViews["reader-text"].value as? String ?? "").contains("lighthouse first clue."))
        app.navigationBars["First"].buttons.element(boundBy: 0).tap(); tap("完成")
        app.terminate(); launch(); openChat()
        XCTAssertTrue(pictures.firstMatch.waitForExistence(timeout: 5)); XCTAssertEqual(pictures.count, 1)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Chat-illustration"; shot.lifetime = .keepAlways; add(shot)
        send("Draw many.")
        XCTAssertTrue(app.staticTexts["本轮已保存 4 张插图。"].waitForExistence(timeout: 15))
        send("Draw future.")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "插图未生成：")).firstMatch.waitForExistence(timeout: 10))
        send("Draw fail.")
        XCTAssertTrue(app.staticTexts["插图未生成：本地绘图服务暂不可用。"].waitForExistence(timeout: 10))
        send("Draw slow.")
        let generating = app.activityIndicators["正在生成插图…"]
        XCTAssertTrue(generating.waitForExistence(timeout: 10))
        let generatingShot = XCTAttachment(screenshot: app.screenshot()); generatingShot.name = "Chat-generating-visible"; generatingShot.lifetime = .keepAlways; add(generatingShot)
        XCTAssertTrue(generating.isHittable)
        tap("停止回复")
        XCTAssertTrue(app.staticTexts["回复已中断，可重试"].waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["停止回复"])], timeout: 5), .completed)
        tap("返回"); imageSetting(); openChat(); send("Draw again.")
        XCTAssertTrue(app.staticTexts["伴读绘图已关闭。"].waitForExistence(timeout: 10))
        tap("返回"); app.tabBars.buttons["书架"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "查询测试")).firstMatch.tap()
        tap("目录"); tap("插图廊")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "illustration-row-")).count, 5)
    }
    func testImageModelRoleRoutingAndSettingsPersist() {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        func launch(_ reset: Bool = false) { app.launchArguments = ["--ui-testing", "--simulate-images", "--simulate-model-roles"] + (reset ? ["--reset-test-library"] : []); app.launch() }
        func tap(_ name: String) {
            let button = app.buttons[name]
            for _ in 0..<6 { if button.exists && button.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(button.exists && button.isHittable, name); button.tap()
        }
        func gallery() {
            app.tabBars.buttons["书架"].tap()
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
            tap("目录"); tap("插图廊")
        }
        func describe(_ text: String) {
            let field = app.textViews["illustration-prompt"]
            for _ in 0..<6 { if field.isHittable { break }; app.swipeDown() }
            field.tap(); field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.85)).tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + text)
            XCTAssertEqual(field.value as? String, text)
        }
        func select(_ model: String) {
            tap("model-role-image"); tap(model); tap("save-image-settings")
            XCTAssertTrue(app.staticTexts["绘图设置已保存。"].waitForExistence(timeout: 5))
            app.navigationBars["AI 绘图"].buttons.element(boundBy: 0).tap()
        }
        launch(true); XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 10)); app.buttons["add-sample"].tap()
        gallery(); tap("生成新插图")
        XCTAssertEqual(app.staticTexts["illustration-model"].label, "请先配置绘图模型与密钥。")
        XCTAssertFalse(app.buttons["generate-illustration"].isEnabled)
        tap("绘图设置")
        app.switches["image-use-assigned"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        select("批量测试 · batch-fixture")
        XCTAssertEqual(app.staticTexts["illustration-model"].label, "批量测试 · batch-fixture")
        describe("A shop"); tap("generate-illustration")
        XCTAssertTrue(app.images["generated-illustration"].waitForExistence(timeout: 10))
        describe("slow"); tap("generate-illustration"); tap("绘图设置")
        select("主对话测试 · chat-fixture")
        XCTAssertEqual(app.staticTexts["illustration-model"].label, "主对话测试 · chat-fixture")
        describe("A garden"); tap("generate-illustration")
        XCTAssertTrue(app.staticTexts["已保存到插图廊。"].waitForExistence(timeout: 10))
        app.terminate(); launch(); gallery()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "illustration-row-"))
        XCTAssertEqual(rows.count, 2)
        rows.element(boundBy: 0).tap()
        let model = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "chat-fixture ·" )).firstMatch
        for _ in 0..<6 { if model.exists { break }; app.swipeUp() }
        XCTAssertTrue(model.exists)
        tap("修改描述并重新生成")
        XCTAssertEqual(app.staticTexts["illustration-model"].label, "主对话测试 · chat-fixture")
        tap("绘图设置")
        XCTAssertEqual(app.switches["image-use-assigned"].value as? String, "1")
        XCTAssertTrue(app.staticTexts["model-effective-image"].label.contains("chat-fixture"))
    }
    func testIllustrationsGenerateRerollFailCancelCategorizeCoverAndRelaunch() {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        func launch(_ reset: Bool = false) { app.launchArguments = ["--ui-testing", "--simulate-images"] + (reset ? ["--reset-test-library"] : []); app.launch() }
        func tap(_ name: String) {
            let button = app.buttons[name]
            for _ in 0..<6 { if button.exists && button.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(button.exists && button.isHittable, name); button.tap()
        }
        func gallery() {
            app.tabBars.buttons["书架"].tap()
            let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
            XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap(); tap("目录"); tap("插图廊")
        }
        let prompt = app.textViews["illustration-prompt"]
        func describe(_ text: String) {
            for _ in 0..<6 { if prompt.isHittable { break }; app.swipeDown() }
            prompt.tap(); prompt.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.85)).tap()
            let old = prompt.value as? String ?? ""
            prompt.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + text)
            XCTAssertEqual(prompt.value as? String, text)
        }
        launch(true); XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 10)); app.buttons["add-sample"].tap()
        app.tabBars.buttons["设置"].tap(); tapSettingsRow("AI 绘图", in: app); tap("save-image-settings")
        XCTAssertTrue(app.staticTexts["绘图设置已保存。"].waitForExistence(timeout: 5))
        gallery(); tap("生成新插图"); describe("A quiet shop"); tap("generate-illustration")
        XCTAssertTrue(app.images["generated-illustration"].waitForExistence(timeout: 10))
        describe("A green shop"); tap("generate-illustration")
        XCTAssertTrue(app.staticTexts["已保存到插图廊。"].waitForExistence(timeout: 10))
        describe("fail"); tap("generate-illustration")
        XCTAssertTrue(app.staticTexts["本地绘图服务暂不可用。"].waitForExistence(timeout: 10)); XCTAssertTrue(app.images["generated-illustration"].exists)
        describe("slow"); tap("generate-illustration"); tap("停止生成")
        XCTAssertTrue(app.staticTexts["已停止。"].waitForExistence(timeout: 5))
        tap("查看与导出"); XCTAssertTrue(app.images["illustration-detail-image"].waitForExistence(timeout: 5))
        tap("分享或存储到文件")
        let share = app.otherElements["ActivityListView"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        let closeShare = app.buttons.matching(NSPredicate(format: "label IN %@", ["关闭", "Close"])).firstMatch
        if closeShare.exists { closeShare.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: share)], timeout: 5), .completed)
        let category = app.textFields["illustration-category"]
        category.tap(); category.typeText("Scene"); tap("保存分类")
        XCTAssertTrue(app.staticTexts["分类已保存。"].waitForExistence(timeout: 5))
        tap("用作书籍封面"); XCTAssertTrue(app.images["draft-book-cover"].waitForExistence(timeout: 5)); tap("save-book-cover")
        XCTAssertTrue(app.images["saved-book-cover"].waitForExistence(timeout: 5))
        app.navigationBars["书籍封面"].buttons.element(boundBy: 0).tap()
        for _ in 0..<6 { if category.exists && category.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(category.value as? String, "Scene")
        app.terminate(); launch(); gallery()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "illustration-row-"))
        XCTAssertEqual(rows.count, 2)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Illustration-gallery"; shot.lifetime = .keepAlways; add(shot)
        rows.element(boundBy: 0).tap(); XCTAssertTrue(app.images["illustration-detail-image"].waitForExistence(timeout: 5))
        for _ in 0..<6 { if category.exists && category.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(app.textFields["illustration-category"].value as? String, "Scene")
        tap("删除这张插图"); app.alerts.buttons["删除"].tap()
        XCTAssertTrue(app.navigationBars["插图廊"].waitForExistence(timeout: 5)); XCTAssertEqual(rows.count, 1)
    }
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func revealListElement(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<35 {
            let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY + 8 : app.frame.minY + 60
            let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY - 8 : app.frame.maxY - 40
            let frame = element.exists ? element.frame : .zero
            if !frame.isEmpty && frame.minY >= top && frame.maxY <= bottom && element.isHittable { return }
            let dy: CGFloat = !frame.isEmpty && frame.minY < top ? 0.16 : -0.16
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5 + dy)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
        XCTFail("List element not visible: \(element)")
    }
    private func tapSettingsRow(_ title: String, in app: XCUIApplication) {
        let row = app.buttons[title]
        for _ in 0..<6 { if row.exists && row.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(row.exists && row.isHittable); row.tap()
    }
    func testReplySuggestionsSendPreserveDraftDismissCancelAndSettingsPersist() {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        func launch(_ reset: Bool = false) { app.launchArguments = ["--ui-testing", "--simulate-suggestions", "--simulate-model-roles"] + (reset ? ["--reset-test-library"] : []); app.launch() }
        func newChat() { app.tabBars.buttons["伴读"].tap(); app.buttons["开启新话题"].tap() }
        let input = app.descendants(matching: .any).matching(identifier: "chat-input").firstMatch
        let first = app.buttons["reply-suggestion-0"], model = app.buttons["reply-suggestion-1"]
        func send(_ text: String) { input.tap(); input.typeText(text); app.buttons["发送"].tap(); XCTAssertTrue(app.staticTexts["本地伴读：" + text].waitForExistence(timeout: 10)) }
        func settings() { app.tabBars.buttons["设置"].tap(); if !app.navigationBars["建议回复"].exists { tapSettingsRow("建议回复", in: app) } }
        func toggle() { app.switches["suggestions-enabled"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        func absent(_ seconds: TimeInterval = 2) {
            let unexpected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: first); unexpected.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [unexpected], timeout: seconds), .completed)
        }
        launch(true); newChat(); send("Hello.")
        XCTAssertTrue(first.waitForExistence(timeout: 10)); XCTAssertEqual(model.label, "聊聊 chat-fixture")
        input.tap(); input.typeText("My draft")
        first.tap(); XCTAssertTrue(app.staticTexts["本地伴读：想听你接着说"].waitForExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, "My draft")
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Reply-suggestions"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["dismiss-suggestions"].tap(); absent()
        app.buttons["返回"].tap(); settings()
        XCTAssertEqual(app.switches["suggestions-enabled"].value as? String, "1")
        app.buttons["model-role-suggestion"].tap(); app.buttons["批量测试 · batch-fixture"].tap()
        toggle(); XCTAssertEqual(app.switches["suggestions-enabled"].value as? String, "0")
        app.terminate(); launch(); settings()
        XCTAssertEqual(app.switches["suggestions-enabled"].value as? String, "0")
        XCTAssertTrue(app.staticTexts["model-effective-suggestion"].label.contains("batch-fixture"))
        newChat(); send("Disabled."); absent()
        app.buttons["返回"].tap(); settings(); toggle(); newChat(); send("Enabled.")
        XCTAssertTrue(first.waitForExistence(timeout: 10)); XCTAssertEqual(model.label, "聊聊 batch-fixture")
        app.buttons["返回"].tap(); newChat(); send("slow")
        app.buttons["返回"].tap(); newChat(); absent(6)
        send("fail"); absent(); XCTAssertFalse(app.alerts["需要处理"].exists)
        app.buttons["返回"].tap(); newChat(); send("Recovered.")
        XCTAssertTrue(first.waitForExistence(timeout: 10)); XCTAssertEqual(model.label, "聊聊 batch-fixture")
    }
    func testModelAssignmentsRouteKnowledgePreserveChatAndCancelChangedJobs() {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        var chat = "主对话测试 · chat-fixture"
        let batch = "批量测试 · batch-fixture"
        func launch(_ extra: [String] = []) { app.launchArguments = ["--ui-testing", "--simulate-model-roles", "--simulate-knowledge"] + extra; app.launch() }
        func tap(_ id: String) {
            let button = app.buttons[id]
            let navigation = app.navigationBars.buttons[id].firstMatch, toolbar = app.toolbars.buttons[id].firstMatch
            if !(navigation.exists && navigation.isHittable) && !(toolbar.exists && toolbar.isHittable) { revealListElement(button, in: app) }
            XCTAssertTrue(button.exists && button.isHittable, id); button.tap()
        }
        func models() { app.tabBars.buttons["设置"].tap(); if !app.navigationBars["模型分工"].exists { tap("模型分工") }; app.swipeDown(); app.swipeDown() }
        func select(_ task: String, _ option: String) { tap("model-role-" + task); app.buttons[option].tap() }
        func saveProvider() {
            app.buttons["保存"].tap()
            let later = app.buttons.matching(NSPredicate(format: "label IN %@", ["稍後再說", "稍后再说", "Not Now"])).firstMatch
            if later.waitForExistence(timeout: 3) {
                later.tap()
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: later)], timeout: 5), .completed)
            }
            let back = app.navigationBars["AI 服务商"].buttons.element(boundBy: 0)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in back.isHittable }, object: nil)], timeout: 5), .completed)
            back.tap()
            XCTAssertTrue(app.navigationBars["模型分工"].waitForExistence(timeout: 5))
        }
        func openKnowledge() {
            app.tabBars.buttons["书架"].tap()
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
            XCTAssertTrue(app.textViews["reader-text"].waitForExistence(timeout: 10)); tap("目录"); tap("章节提纲")
        }
        func closeKnowledge() { app.navigationBars["章节提纲"].buttons.element(boundBy: 0).tap(); tap("完成"); app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap() }
        func preview(_ model: String) {
            tap("knowledge-generate-0"); XCTAssertTrue(app.navigationBars["确认章节整理"].waitForExistence(timeout: 5))
            let label = app.descendants(matching: .any).matching(identifier: "knowledge-preview-model").firstMatch
            XCTAssertTrue((label.label + (label.value as? String ?? "")).contains(model))
        }
        launch(["--reset-test-library"]); XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 10)); app.buttons["add-sample"].tap()
        models(); select("batch", batch)
        XCTAssertTrue(app.staticTexts["model-effective-chat"].label.contains(chat))
        XCTAssertTrue(app.staticTexts["model-effective-knowledge"].label.contains(batch))
        select("knowledge", chat)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Model-assignments"; shot.lifetime = .keepAlways; add(shot)
        openKnowledge(); preview(chat); tap("取消")
        select("knowledge", "使用默认模型"); preview(batch); tap("knowledge-confirm")
        XCTAssertTrue(app.staticTexts["knowledge-outline-0"].waitForExistence(timeout: 15)); XCTAssertTrue(app.staticTexts[batch].exists)
        closeKnowledge(); models(); tap("管理 AI 服务商")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "批量测试")).firstMatch.tap()
        saveProvider()
        app.swipeDown(); app.swipeDown(); XCTAssertTrue(app.staticTexts["model-effective-chat"].label.contains(chat))
        app.terminate(); launch(["--knowledge-slow"]); models()
        XCTAssertTrue(app.staticTexts["model-effective-batch"].label.contains(batch)); XCTAssertTrue(app.staticTexts["model-effective-chat"].label.contains(chat))
        openKnowledge(); preview(batch); tap("knowledge-confirm"); closeKnowledge(); models(); select("batch", chat)
        openKnowledge()
        XCTAssertTrue(app.staticTexts["已停止，可重新生成。"].waitForExistence(timeout: 10)); XCTAssertTrue(app.staticTexts[batch].exists)
        preview(chat); tap("knowledge-confirm"); closeKnowledge(); models(); tap("管理 AI 服务商")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "主对话测试")).firstMatch.tap()
        let model = app.textFields["模型名称"]; model.tap(); model.typeText("-v2")
        let changed = model.value as? String ?? ""; XCTAssertNotEqual(changed, "chat-fixture"); chat = "主对话测试 · " + changed
        saveProvider()
        openKnowledge(); XCTAssertTrue(app.staticTexts["已停止，可重新生成。"].waitForExistence(timeout: 10)); XCTAssertTrue(app.staticTexts[batch].exists)
        app.terminate(); launch(); openKnowledge()
        preview(chat); tap("knowledge-confirm")
        XCTAssertTrue(app.staticTexts[chat].waitForExistence(timeout: 20)); XCTAssertTrue(app.staticTexts["knowledge-outline-0"].exists)
        app.terminate(); launch(); models()
        XCTAssertTrue(app.staticTexts["model-effective-batch"].label.contains(chat)); XCTAssertTrue(app.staticTexts["model-effective-knowledge"].label.contains(chat))
    }
    func testGlobalPresetsEditToggleRequestCopiesRetryDeleteAndRelaunch() {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        func launch(_ reset: Bool = false) { app.launchArguments = ["--ui-testing", "--simulate-tools", "--simulate-presets"] + (reset ? ["--reset-test-library"] : []); app.launch() }
        func reveal(_ element: XCUIElement) {
            for _ in 0..<6 { if element.exists && element.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(element.exists && element.isHittable)
        }
        func tap(_ id: String) { let button = app.buttons[id]; reveal(button); button.tap() }
        func toggle(_ name: String) { let control = app.switches["preset-toggle-" + name]; reveal(control); control.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        func settings() {
            app.tabBars.buttons["设置"].tap()
            if !app.navigationBars["全局提示词预设"].exists { tap("全局提示词预设") }
            app.swipeDown(); app.swipeDown()
        }
        func openChat() { app.tabBars.buttons["伴读"].tap(); app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "工具查询")).firstMatch.tap() }
        func send(_ text: String) { let input = app.descendants(matching: .any).matching(identifier: "chat-input").firstMatch; input.tap(); input.typeText(text); app.buttons["发送"].tap() }
        func reply(_ system: String, _ user: String) -> XCUIElement { app.staticTexts["本地请求核对：系统=\(system)；用户=\(user)；工具续接=1"] }
        launch(true); settings()
        XCTAssertEqual(app.switches["preset-toggle-自然表达"].value as? String, "0")
        tap("preset-edit-自然表达"); app.buttons["preset-position"].tap(); app.buttons["系统提示词之前"].tap(); app.buttons["保存"].tap()
        toggle("自然表达"); toggle("沉浸式角色扮演"); toggle("简洁回答")
        tap("添加自定义预设")
        XCTAssertFalse(app.buttons["保存"].isEnabled)
        app.textFields["preset-name"].tap(); app.textFields["preset-name"].typeText("Discarded")
        app.buttons["取消"].tap(); XCTAssertFalse(app.buttons["preset-edit-Discarded"].exists)
        tap("添加自定义预设")
        app.textFields["preset-name"].tap(); app.textFields["preset-name"].typeText("Ending")
        app.buttons["preset-position"].tap(); app.buttons["最近一条用户消息之后"].tap()
        app.textViews["preset-content"].tap(); app.textViews["preset-content"].typeText("End with a question.")
        app.buttons["保存"].tap()
        let ending = app.switches["preset-toggle-Ending"]; reveal(ending); XCTAssertEqual(ending.value as? String, "1")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Global-prompt-presets"; shot.lifetime = .keepAlways; add(shot)
        openChat(); send("Keep my words.")
        XCTAssertTrue(reply("自然表达、沉浸式角色扮演", "简洁回答、Ending").waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Keep my words."].exists)
        app.buttons["返回"].tap(); settings(); toggle("简洁回答")
        let edit = app.buttons["preset-edit-Ending"]; reveal(edit)
        app.cells.containing(.button, identifier: "preset-edit-Ending").firstMatch.swipeLeft()
        let delete = app.buttons.matching(NSPredicate(format: "label IN %@", ["删除", "Delete"])).firstMatch
        if delete.waitForExistence(timeout: 2) { delete.tap() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: edit)], timeout: 5), .completed)
        openChat(); app.buttons["重新生成"].tap()
        XCTAssertTrue(reply("自然表达、沉浸式角色扮演", "无").waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Keep my words."].exists)
        app.terminate(); launch(); settings()
        XCTAssertEqual(app.switches["preset-toggle-自然表达"].value as? String, "1")
        XCTAssertEqual(app.switches["preset-toggle-沉浸式角色扮演"].value as? String, "1")
        tap("preset-edit-自然表达"); XCTAssertTrue(app.buttons["preset-position"].label.contains("系统提示词之前")); app.buttons["取消"].tap()
        toggle("自然表达"); toggle("沉浸式角色扮演")
        reveal(app.switches["preset-toggle-简洁回答"]); XCTAssertEqual(app.switches["preset-toggle-简洁回答"].value as? String, "0")
        XCTAssertFalse(app.buttons["preset-edit-Ending"].exists)
        openChat(); XCTAssertTrue(app.staticTexts["Keep my words."].waitForExistence(timeout: 5)); send("Next words.")
        XCTAssertTrue(reply("无", "无").waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Next words."].exists)
    }
    func testStructuredCharacterAttributesAliasesRelationsAndRestart() {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        func tap(_ id: String) {
            let button = app.buttons[id]
            if !button.exists || !button.isHittable { revealListElement(button, in: app) }
            XCTAssertTrue(button.isHittable); button.tap()
        }
        func openBook() {
            let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
            XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        }
        func openPeople() { tap("目录"); tap("书中人物") }
        func search(_ text: String) {
            let field = app.textFields["characters-search"]; revealListElement(field, in: app)
            field.tap(); field.typeText(text + "\n")
        }
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-characters", "--characters-profile"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap(); openBook(); openPeople()
        tap("characters-generate"); tap("characters-confirm")
        XCTAssertTrue(app.staticTexts["已保存 2 位人物。"].waitForExistence(timeout: 15))
        search("小遥")
        let age = app.buttons["characters-attribute-林遥-AGE-1"]
        revealListElement(age, in: app); XCTAssertTrue(age.label.contains("二十岁"))
        XCTAssertFalse(app.buttons["characters-edit-小遥"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Character-attributes-and-alias"; shot.lifetime = .keepAlways; add(shot)
        age.tap(); XCTAssertTrue(app.textViews["reader-text"].waitForExistence(timeout: 5))
        XCTAssertTrue((app.textViews["reader-text"].value as? String ?? "").contains("二十岁"))
        openPeople(); tap("全书"); tap("characters-generate"); tap("characters-confirm")
        XCTAssertTrue(app.staticTexts["已保存 2 位人物。"].waitForExistence(timeout: 15))
        search("江舟"); tap("characters-relation-江舟-0")
        XCTAssertTrue(app.textViews["reader-text"].waitForExistence(timeout: 5))
        XCTAssertTrue((app.textViews["reader-text"].value as? String ?? "").contains("江舟是林遥的老师。"))
        app.terminate(); app.launchArguments = ["--ui-testing", "--simulate-characters", "--characters-profile"]; app.launch(); openBook(); openPeople()
        search("小遥"); tap("characters-card-林遥")
        let description = app.textViews["extracted-card-description"]
        XCTAssertTrue(description.waitForExistence(timeout: 5))
        let text = description.value as? String ?? ""
        for expected in ["别名：小遥", "年龄：二十岁", "性别：女", "身份：店主", "外貌：蓝衣", "第 2 章依据："] { XCTAssertTrue(text.contains(expected), expected) }
    }
    func testManualCharacterProfilesEditRegenerateAndRestart() {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        func tap(_ id: String) {
            let button = app.buttons[id]
            if !button.exists || !button.isHittable { revealListElement(button, in: app) }
            XCTAssertTrue(button.isHittable); button.tap()
        }
        func openPeople() {
            let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
            XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
            XCTAssertTrue(app.buttons["目录"].waitForExistence(timeout: 5)); app.buttons["目录"].tap(); tap("书中人物")
        }
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-characters"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap(); openPeople()
        tap("characters-add")
        let name = app.textFields["character-profile-name"], description = app.textViews["character-profile-description"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["character-profile-save"].isEnabled)
        name.tap(); name.typeText("取消的人物"); app.buttons["取消"].tap()
        XCTAssertFalse(app.staticTexts["characters-summary"].exists)
        tap("characters-add"); XCTAssertEqual(name.value as? String, "姓名")
        name.tap(); name.typeText("林遥"); app.buttons["完成"].tap()
        description.tap(); description.typeText("喜欢雨声。"); app.buttons["完成"].tap(); app.buttons["character-profile-save"].tap()
        XCTAssertTrue(app.staticTexts["characters-summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["characters-summary"].label.contains("手动整理"))
        tap("characters-generate"); tap("characters-confirm")
        XCTAssertTrue(app.staticTexts["已保存 1 位人物。"].waitForExistence(timeout: 15))
        tap("characters-edit-林遥"); XCTAssertEqual(name.value as? String, "林遥")
        XCTAssertEqual(description.value as? String, "喜欢雨声。")
        name.tap(); name.typeText("同伴"); app.buttons["完成"].tap()
        description.tap(); description.typeText("轻声说话。")
        let editedDescription = description.value as? String ?? ""
        XCTAssertTrue(editedDescription.contains("喜欢雨声。")); XCTAssertTrue(editedDescription.contains("轻声说话。"))
        app.buttons["完成"].tap(); app.buttons["character-profile-save"].tap()
        tap("characters-generate"); tap("characters-confirm")
        XCTAssertTrue(app.staticTexts["已保存 1 位人物。"].waitForExistence(timeout: 15))
        tap("characters-card-林遥同伴")
        XCTAssertEqual(app.textFields["extracted-card-name"].value as? String, "林遥同伴")
        XCTAssertEqual(app.textViews["extracted-card-description"].value as? String, editedDescription)
        app.buttons["关闭"].tap()
        app.terminate(); app.launchArguments = ["--ui-testing", "--simulate-characters"]; app.launch(); openPeople()
        let search = app.textFields["characters-search"]; revealListElement(search, in: app); search.tap(); search.typeText("林遥\n")
        tap("characters-edit-林遥")
        XCTAssertEqual(name.value as? String, "林遥同伴"); XCTAssertEqual(description.value as? String, editedDescription)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Manual-character-profile"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["取消"].tap(); tap("展开资料与原文依据"); tap("characters-locate-林遥同伴-0")
        XCTAssertTrue(app.textViews["reader-text"].waitForExistence(timeout: 5))
    }
    func testExtractedCharacterCardEditingExportCancelSaveAndRestart() {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-characters"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        app.buttons["目录"].tap(); app.buttons["书中人物"].tap()
        app.buttons["characters-generate"].tap(); app.buttons["characters-confirm"].tap()
        XCTAssertTrue(app.staticTexts["已保存 1 位人物。"].waitForExistence(timeout: 15))
        let extract = app.buttons["characters-card-林遥"]
        revealListElement(extract, in: app); extract.tap()
        let name = app.textFields["extracted-card-name"], description = app.textViews["extracted-card-description"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); XCTAssertEqual(name.value as? String, "林遥")
        XCTAssertTrue((description.value as? String ?? "").contains("第 1 章依据："))
        XCTAssertFalse((description.value as? String ?? "").contains("江舟"))
        name.tap(); name.typeText("草稿"); app.buttons["关闭"].tap()
        revealListElement(extract, in: app); extract.tap()
        XCTAssertEqual(name.value as? String, "林遥")
        name.tap(); name.typeText("同伴"); app.buttons["完成"].tap()
        description.tap(); description.typeText("\n轻声说话。"); app.buttons["完成"].tap()
        let export = app.buttons["extracted-card-export"]; revealListElement(export, in: app); export.tap()
        let picker = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        let exportSave = picker.buttons.matching(NSPredicate(format: "identifier == %@ OR label IN %@", "DOCPicker.actionButton", ["Move", "Save", "移动", "移動", "保存", "存储", "儲存"])).firstMatch
        let localFiles = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["我的iPhone", "我的 iPhone", "On My iPhone"])).firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (exportSave.exists && exportSave.isEnabled) || localFiles.exists }, object: nil)], timeout: 40), .completed)
        if !exportSave.exists || !exportSave.isEnabled { localFiles.tap() }
        XCTAssertTrue(exportSave.waitForExistence(timeout: 10)); exportSave.tap()
        let replacement = NSPredicate(format: "label IN %@", ["取代", "替换", "Replace"])
        let replace = app.buttons.matching(replacement).firstMatch
        let systemReplace = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons.matching(replacement).firstMatch
        let exported = app.staticTexts["extracted-card-status"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in exported.exists || replace.exists || systemReplace.exists }, object: nil)], timeout: 30), .completed)
        if replace.exists { replace.tap() } else if systemReplace.exists { systemReplace.tap() }
        XCTAssertTrue(app.staticTexts["extracted-card-status"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["extracted-card-status"].label.contains("已导出"))
        revealListElement(export, in: app); export.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        if !cancel.exists { picker.buttons.matching(NSPredicate(format: "identifier == %@ OR label IN %@", "BackButton", ["Browse", "瀏覽", "浏览"])).firstMatch.tap() }
        XCTAssertTrue(cancel.waitForExistence(timeout: 10)); cancel.tap()
        XCTAssertTrue(app.navigationBars["提取角色卡"].waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "林遥同伴")
        let save = app.buttons["extracted-card-save"]; revealListElement(save, in: app)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Extracted-character-card"; shot.lifetime = .keepAlways; add(shot)
        save.tap()
        XCTAssertTrue(app.navigationBars["书中人物"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.tabBars.buttons["伴读"].tap()
        let selected = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "林遥同伴", "角色与世界书")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 10)); selected.tap()
        let rows = app.cells.containing(.staticText, identifier: "林遥同伴").containing(.button, identifier: "编辑")
        XCTAssertEqual(rows.count, 1); rows.firstMatch.buttons["编辑"].tap()
        XCTAssertEqual(app.textFields["名字"].value as? String, "林遥同伴")
        let savedDescription = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "第 1 章依据：")).firstMatch
        XCTAssertTrue(savedDescription.waitForExistence(timeout: 5)); XCTAssertTrue((savedDescription.value as? String ?? "").contains("轻声说话。"))
    }
    func testBookCharactersScopePreviewResumeSearchCacheAndStop() {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        func launch(_ extra: [String] = []) { app.launchArguments = ["--ui-testing", "--simulate-characters"] + extra; app.launch() }
        func tap(_ id: String) {
            let button = app.buttons[id]
            let visible = app.frame.insetBy(dx: 0, dy: id.hasPrefix("characters-locate-") ? 60 : 0)
            for _ in 0..<6 { if button.exists && button.isHittable && visible.contains(button.frame) { break }; app.swipeUp() }
            XCTAssertTrue(button.exists && button.isHittable && visible.contains(button.frame), id); button.tap()
        }
        func openBook() {
            let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
            XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
            XCTAssertTrue(app.textViews["reader-text"].waitForExistence(timeout: 10))
        }
        func openPeople() { tap("目录"); tap("书中人物"); XCTAssertTrue(app.navigationBars["书中人物"].waitForExistence(timeout: 5)) }
        func generate() { tap("characters-generate"); XCTAssertTrue(app.navigationBars["确认人物提取"].waitForExistence(timeout: 5)); tap("characters-confirm") }
        launch(["--reset-test-library"])
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 10)); app.buttons["add-sample"].tap()
        openBook(); openPeople()
        XCTAssertEqual(app.segmentedControls["characters-scope"].buttons["读到此处"].isSelected, true)
        tap("characters-generate"); XCTAssertTrue(app.navigationBars["确认人物提取"].waitForExistence(timeout: 5)); tap("取消")
        XCTAssertFalse(app.staticTexts["characters-summary"].exists)
        generate(); XCTAssertTrue(app.staticTexts["已保存 1 位人物。"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["江舟"].exists)
        tap("characters-locate-林遥-0")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["书中人物"])], timeout: 5), .completed)
        XCTAssertTrue(app.textViews["reader-text"].waitForExistence(timeout: 5))
        openPeople(); tap("全书"); tap("characters-generate")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "包括尚未读到的章节")).firstMatch.waitForExistence(timeout: 5))
        tap("取消"); XCTAssertTrue(app.staticTexts["characters-summary"].label.contains("已读"))
        app.terminate(); launch(["--characters-fail"]); openBook(); openPeople(); tap("全书"); generate()
        XCTAssertTrue(app.staticTexts["人物整理服务暂不可用。"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["characters-summary"].label.contains("1 位人物"))
        app.terminate(); launch(); openBook(); openPeople(); tap("全书"); generate()
        XCTAssertTrue(app.staticTexts["已保存 2 位人物。"].waitForExistence(timeout: 15))
        let field = app.textFields["characters-search"]
        for _ in 0..<6 { if field.exists && field.isHittable { break }; app.swipeUp() }
        field.tap(); field.typeText("不存在\n")
        XCTAssertTrue(app.staticTexts["没有找到这个人物"].waitForExistence(timeout: 5))
        tap("清除搜索"); field.tap(); field.typeText("江舟\n")
        XCTAssertTrue(app.staticTexts["江舟"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Book-characters-search"; shot.lifetime = .keepAlways; add(shot)
        tap("characters-locate-江舟-0")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["书中人物"])], timeout: 5), .completed)
        XCTAssertTrue(app.textViews["reader-text"].waitForExistence(timeout: 5))
        XCTAssertTrue((app.textViews["reader-text"].value as? String ?? "").contains("江舟送来了灯塔地图"))
        app.terminate(); launch(["--characters-fail"]); openBook(); openPeople(); generate()
        XCTAssertTrue(app.staticTexts["已保存 2 位人物。"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["人物整理服务暂不可用。"].exists)
        app.terminate(); launch(["--characters-slow", "--characters-new-model"]); openBook(); openPeople(); generate()
        tap("characters-stop")
        XCTAssertTrue(app.staticTexts["已停止，已核对的分段会保留。"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["characters-summary"].label.contains("2 位人物"))
        tap("characters-delete"); app.alerts["删除人物资料？"].buttons["删除"].tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["characters-summary"])
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        app.terminate(); launch(); openBook(); openPeople()
        XCTAssertFalse(app.staticTexts["characters-summary"].exists)
        XCTAssertTrue(app.buttons["characters-generate"].label.contains("提取读过的人物"))
    }
    func testChapterKnowledgePreviewSaveEvidenceFailureStopAndRelaunch() {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        func launch(_ extra: [String] = []) { app.launchArguments = ["--ui-testing", "--simulate-knowledge"] + extra; app.launch() }
        func tap(_ id: String) {
            let button = app.buttons[id]
            for _ in 0..<6 { if button.exists && button.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(button.exists && button.isHittable, id); button.tap()
        }
        func openBook() {
            let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
            XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
            XCTAssertTrue(app.textViews["reader-text"].waitForExistence(timeout: 10))
        }
        func openKnowledge() { tap("目录"); tap("章节提纲"); XCTAssertTrue(app.navigationBars["章节提纲"].waitForExistence(timeout: 5)) }
        func generate() { tap("knowledge-generate-0"); XCTAssertTrue(app.navigationBars["确认章节整理"].waitForExistence(timeout: 5)); tap("knowledge-confirm") }
        launch(["--reset-test-library"])
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 10)); app.buttons["add-sample"].tap()
        openBook(); openKnowledge()
        XCTAssertFalse(app.staticTexts["第二章 来信"].exists)
        XCTAssertTrue(app.staticTexts["尚未生成"].exists)
        tap("knowledge-generate-0")
        XCTAssertTrue(app.navigationBars["确认章节整理"].waitForExistence(timeout: 5)); tap("取消")
        XCTAssertTrue(app.staticTexts["尚未生成"].exists)
        generate()
        app.navigationBars["章节提纲"].buttons.element(boundBy: 0).tap(); tap("完成")
        openKnowledge()
        let outline = app.staticTexts["knowledge-outline-0"]
        XCTAssertTrue(outline.waitForExistence(timeout: 15))
        XCTAssertEqual(outline.label, "林遥推开书店的大门，开始了这一天的阅读。")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Chapter-outline"; shot.lifetime = .keepAlways; add(shot)
        tap("原文依据（1）"); tap("knowledge-locate-0-0")
        XCTAssertTrue(app.textViews["reader-text"].waitForExistence(timeout: 5))
        tap("书签"); tap("添加当前位置书签"); tap("完成")
        app.terminate(); launch(["--knowledge-fail"]); openBook(); openKnowledge()
        XCTAssertTrue(outline.waitForExistence(timeout: 5)); generate()
        XCTAssertTrue(app.staticTexts["整理服务暂不可用。"].waitForExistence(timeout: 15)); XCTAssertTrue(outline.exists)
        app.terminate(); launch(["--knowledge-slow"]); openBook(); openKnowledge(); generate()
        tap("knowledge-stop-0")
        XCTAssertTrue(app.staticTexts["已停止，可重新生成。"].waitForExistence(timeout: 10)); XCTAssertTrue(outline.exists)
        tap("knowledge-delete-0"); app.alerts["删除本章提纲？"].buttons["删除"].tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: outline)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        app.terminate(); launch(); openBook(); openKnowledge()
        XCTAssertTrue(app.staticTexts["尚未生成"].exists); XCTAssertFalse(outline.exists)
    }
    func testOnlineCoverSearchSelectCancelFailuresAndStop() {
        executionTimeAllowance = 360
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-cover-search"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.press(forDuration: 1)
        app.buttons["更换封面"].tap()
        func tap(_ name: String) {
            let button = app.buttons[name]
            for _ in 0..<5 { if button.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(button.isHittable); button.tap()
        }
        func openSearch(_ suffix: String = "") {
            tap("网络搜索封面")
            XCTAssertTrue(app.navigationBars["网络封面"].waitForExistence(timeout: 5))
            if !suffix.isEmpty { let title = app.textFields["cover-search-title"]; title.tap(); title.typeText(suffix) }
            tap("搜索封面")
        }
        let select = "select-cover-https://example.invalid/cover.jpg"
        openSearch(); XCTAssertTrue(app.buttons[select].waitForExistence(timeout: 5))
        let result = XCTAttachment(screenshot: app.screenshot()); result.name = "Online-cover-results"; result.lifetime = .keepAlways; add(result)
        tap(select); XCTAssertEqual(app.state, .runningForeground); XCTAssertTrue(app.images["draft-book-cover"].waitForExistence(timeout: 5))
        tap("取消裁剪"); XCTAssertTrue(app.staticTexts["文字封面"].waitForExistence(timeout: 5))
        openSearch(" unavailable"); XCTAssertTrue(app.staticTexts["封面服务暂不可用。"].waitForExistence(timeout: 5)); app.buttons["关闭"].tap()
        openSearch(" empty"); XCTAssertTrue(app.staticTexts["没有找到可用封面，可以调整书名或作者再试。"].waitForExistence(timeout: 5)); app.buttons["关闭"].tap()
        openSearch(" slow"); tap("停止"); XCTAssertTrue(app.staticTexts["已停止。"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons[select].exists); app.buttons["关闭"].tap()
        openSearch(); XCTAssertTrue(app.buttons[select].waitForExistence(timeout: 5)); tap(select); XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.images["draft-book-cover"].waitForExistence(timeout: 5)); tap("save-book-cover")
        XCTAssertTrue(app.images["saved-book-cover"].waitForExistence(timeout: 5)); app.buttons["完成"].tap()
    }
    func testBookCoverCropCancelSaveResetAndRelaunch() {
        executionTimeAllowance = 600
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-cover"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        func openCover() {
            let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
            XCTAssertTrue(book.waitForExistence(timeout: 10)); book.press(forDuration: 1)
            app.buttons["更换封面"].tap()
            XCTAssertTrue(app.navigationBars["书籍封面"].waitForExistence(timeout: 5))
        }
        func tap(_ name: String) {
            let button = app.buttons[name]
            for _ in 0..<4 { if button.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(button.isHittable); button.tap()
        }
        openCover(); tap("选择测试封面")
        XCTAssertTrue(app.images["draft-book-cover"].waitForExistence(timeout: 5))
        tap("取消裁剪"); XCTAssertTrue(app.staticTexts["文字封面"].waitForExistence(timeout: 5))
        tap("选择测试封面"); app.sliders["cover-focus-y"].adjust(toNormalizedSliderPosition: 0.9)
        let crop = XCTAttachment(screenshot: app.screenshot()); crop.name = "Cover-crop"; crop.lifetime = .keepAlways; add(crop)
        tap("save-book-cover"); XCTAssertTrue(app.images["saved-book-cover"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        let shelf = XCTAttachment(screenshot: app.screenshot()); shelf.name = "Cover-bookshelf"; shelf.lifetime = .keepAlways; add(shelf)
        app.terminate(); app.launchArguments = ["--ui-testing", "--simulate-cover"]; app.launch(); openCover()
        XCTAssertTrue(app.images["saved-book-cover"].waitForExistence(timeout: 5))
        tap("选择测试封面"); tap("取消裁剪"); XCTAssertTrue(app.images["saved-book-cover"].waitForExistence(timeout: 5))
        tap("恢复文字封面"); app.sheets.buttons["恢复文字封面"].tap()
        XCTAssertTrue(app.staticTexts["文字封面"].waitForExistence(timeout: 5))
        app.terminate(); app.launch(); openCover()
        XCTAssertTrue(app.staticTexts["文字封面"].waitForExistence(timeout: 5)); XCTAssertFalse(app.images["saved-book-cover"].exists)
        app.buttons["完成"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.press(forDuration: 1)
        app.buttons["编辑资料"].tap()
        let title = app.textFields["book-title"]; title.tap(); title.typeText("海岸")
        let draftTitle = title.value as? String
        app.buttons["书籍封面"].tap(); app.navigationBars["书籍封面"].buttons.element(boundBy: 0).tap()
        XCTAssertEqual(title.value as? String, draftTitle)
        app.buttons["取消"].tap()
    }
    func testWebSearchOptInSourcesFailuresAndSettingsPersist() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-tools", "--simulate-web"]; app.launch()
        func openChat() { app.tabBars.buttons["伴读"].tap(); app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "工具查询")).firstMatch.tap() }
        func send(_ text: String) { let input = app.descendants(matching: .any).matching(identifier: "chat-input").firstMatch; input.tap(); input.typeText(text); app.buttons["发送"].tap() }
        openChat(); send("Tell me about lighthouses.")
        XCTAssertTrue(app.staticTexts["联网已关闭，本轮未请求网页。"].waitForExistence(timeout: 15)); XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "web-source-https://example.invalid/lighthouse").firstMatch.exists)
        app.buttons["返回"].tap(); app.tabBars.buttons["设置"].tap(); tapSettingsRow("联网搜索", in: app)
        app.switches["web-enabled"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["web-provider"].tap(); app.buttons["Tavily"].tap()
        for _ in 0..<4 { if app.switches["web-advanced-search"].isHittable { break }; app.swipeUp() }
        app.switches["web-advanced-search"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.terminate(); app.launchArguments = ["--ui-testing", "--simulate-tools", "--simulate-web"]; app.launch()
        app.tabBars.buttons["设置"].tap(); tapSettingsRow("联网搜索", in: app)
        XCTAssertEqual(app.switches["web-enabled"].value as? String, "1")
        XCTAssertEqual(app.textFields["web-search-endpoint"].value as? String, "https://api.tavily.com/search")
        for _ in 0..<4 { if app.switches["web-advanced-search"].isHittable { break }; app.swipeUp() }
        XCTAssertEqual(app.switches["web-advanced-search"].value as? String, "1")
        app.navigationBars["联网搜索"].buttons.element(boundBy: 0).tap(); openChat(); send("Find lighthouse history.")
        XCTAssertTrue(app.staticTexts["已核对网页资料，并保留来源链接。"].waitForExistence(timeout: 15))
        let trace = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "查询过程（2 步）")).firstMatch
        trace.tap(); XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "web-source-https://example.invalid/lighthouse").firstMatch.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Web-search-sources"; shot.lifetime = .keepAlways; add(shot)
        app.terminate(); app.launch(); openChat(); trace.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "web-source-https://example.invalid/lighthouse").firstMatch.waitForExistence(timeout: 5))
        send("Search unavailable."); XCTAssertTrue(app.staticTexts["搜索暂不可用，未编造网页内容。"].waitForExistence(timeout: 15))
        app.buttons["返回"].tap(); app.tabBars.buttons["设置"].tap(); tapSettingsRow("联网搜索", in: app)
        app.switches["web-enabled"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.terminate(); app.launch(); app.tabBars.buttons["设置"].tap(); tapSettingsRow("联网搜索", in: app)
        XCTAssertEqual(app.switches["web-enabled"].value as? String, "0")
        app.navigationBars["联网搜索"].buttons.element(boundBy: 0).tap(); openChat(); send("Please search again.")
        XCTAssertTrue(app.staticTexts["联网已关闭，这次也未请求网页。"].waitForExistence(timeout: 15))
    }
    func testGlobalFocusOnDemandSourcesAndRetryUseOriginalBooks() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-tools", "--simulate-scope"]; app.launch()
        func openChat() { app.tabBars.buttons["伴读"].tap(); app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "多书范围")).firstMatch.tap() }
        func toggle(_ title: String) { app.switches["focus-book-" + title].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        func send(_ text: String) { let input = app.descendants(matching: .any).matching(identifier: "chat-input").firstMatch; input.tap(); input.typeText(text); app.buttons["发送"].tap() }
        openChat(); app.buttons["重点书籍"].tap(); toggle("森林"); app.buttons["保存"].tap()
        send("Just chat.")
        XCTAssertTrue(app.staticTexts["本轮未发送书籍原文。"].waitForExistence(timeout: 15)); XCTAssertFalse(app.buttons["来源 1"].exists)
        app.terminate(); app.launchArguments = ["--ui-testing", "--simulate-tools", "--simulate-scope"]; app.launch(); openChat()
        app.buttons["重点书籍"].tap(); XCTAssertEqual(app.switches["focus-book-森林"].value as? String, "1"); app.buttons["保存"].tap()
        send("Read both books.")
        let reply = app.scrollViews["chat-messages"].staticTexts.matching(identifier: "重点：森林；已核对两本书的已读原文。").firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15))
        app.buttons["来源 1"].tap(); XCTAssertTrue(app.staticTexts["Forest visible."].waitForExistence(timeout: 5)); app.buttons["完成"].tap()
        app.buttons["来源 2"].tap(); XCTAssertTrue(app.staticTexts["Harbor."].waitForExistence(timeout: 5)); app.buttons["完成"].tap()
        app.buttons["重点书籍"].tap(); toggle("森林"); toggle("海岸"); app.buttons["保存"].tap()
        app.buttons["重新生成"].tap(); XCTAssertTrue(reply.waitForExistence(timeout: 15))
        app.buttons["重点书籍"].tap(); XCTAssertEqual(app.switches["focus-book-森林"].value as? String, "1"); XCTAssertEqual(app.switches["focus-book-海岸"].value as? String, "0")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Per-book-reading-scopes"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["保存"].tap()
        reply.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["从此处分支"].waitForExistence(timeout: 5)); app.buttons["从此处分支"].tap()
        app.buttons["返回"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "多书范围 · 分支")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["陪伴足迹"].tap()
        app.segmentedControls["companion-stats-period"].buttons["近 7 天"].tap()
        for (name, expected) in [("books", "2 本书"), ("rounds", "2 轮"), ("conversations", "1 个")] {
            let row = app.descendants(matching: .any).matching(identifier: "companion-stats-" + name).firstMatch
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", expected), object: row)], timeout: 10), .completed, name)
        }
    }
    func testLibraryOrganizationPreviewConfirmationCancellationAndRelaunch() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-tools", "--simulate-organization"]; app.launch()
        func openChat() { app.tabBars.buttons["伴读"].tap(); app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "工具查询")).firstMatch.tap() }
        func send(_ text: String) {
            let input = app.descendants(matching: .any).matching(identifier: "chat-input").firstMatch
            input.tap(); input.typeText(text); app.buttons["发送"].tap()
            XCTAssertTrue(app.staticTexts["整理预览已准备好，等待你确认。"].waitForExistence(timeout: 15))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["重新生成"])], timeout: 5), .completed)
        }
        func shows(_ text: String) -> Bool { app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch.waitForExistence(timeout: 5) }
        openChat(); send("Organize my books.")
        let pending = app.buttons["organization-plan-pending"]
        XCTAssertTrue(pending.waitForExistence(timeout: 15)); pending.tap()
        XCTAssertTrue(shows("海岸故事")); XCTAssertTrue(shows("旅途书单"))
        let preview = XCTAttachment(screenshot: app.screenshot()); preview.name = "Library-organization-preview"; preview.lifetime = .keepAlways; add(preview)
        app.buttons["完成"].tap(); app.buttons["返回"].tap(); app.tabBars.buttons["书架"].tap()
        XCTAssertFalse(app.buttons["旅途书单"].exists)
        app.terminate(); app.launchArguments = ["--ui-testing", "--simulate-tools", "--simulate-organization"]; app.launch()
        openChat(); pending.tap(); app.buttons["apply-organization"].tap()
        XCTAssertTrue(app.staticTexts["已应用到书架"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["apply-organization"].exists)
        app.buttons["完成"].tap(); app.buttons["返回"].tap(); app.tabBars.buttons["书架"].tap()
        XCTAssertTrue(app.buttons["旅途书单"].waitForExistence(timeout: 5)); app.buttons["旅途书单"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "查询测试")).firstMatch.exists)
        app.terminate(); app.launch(); openChat()
        XCTAssertTrue(app.buttons["organization-plan-applied"].exists)
        send("Cancel this second proposal."); XCTAssertTrue(pending.waitForExistence(timeout: 15)); pending.tap()
        XCTAssertTrue(shows("待考虑")); app.buttons["cancel-organization"].tap()
        XCTAssertTrue(app.staticTexts["已取消，书架未改变"].waitForExistence(timeout: 5))
        app.terminate(); app.launch(); openChat()
        XCTAssertTrue(app.buttons["organization-plan-cancelled"].exists)
        app.buttons["organization-plan-cancelled"].tap(); XCTAssertFalse(app.buttons["apply-organization"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Library-organization-cancelled"; shot.lifetime = .keepAlways; add(shot)
    }
    func testHybridRetrievalAndVectorFailureKeepReadableEvidence() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-hybrid"]; app.launch()
        app.tabBars.buttons["伴读"].tap(); app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "检索测试")).firstMatch.tap()
        let input = app.descendants(matching: .any).matching(identifier: "chat-input").firstMatch
        func send(_ text: String) { input.tap(); input.typeText(text); app.buttons["发送"].tap() }
        let reply = app.staticTexts["混合检索结果：At the harbor, the lighthouse beacon shone."]
        send("lighthouse harbor")
        XCTAssertTrue(reply.waitForExistence(timeout: 15))
        app.buttons["来源 1"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["At the harbor, the lighthouse beacon shone."].waitForExistence(timeout: 5)); app.buttons["完成"].tap()
        send("lighthouse harbor fallback")
        XCTAssertTrue(app.staticTexts["向量检索暂不可用，已使用本机关键词检索。"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.scrollViews["chat-messages"].staticTexts.matching(identifier: "混合检索结果：At the harbor, the lighthouse beacon shone.").count, 2)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Future secret")).firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Hybrid-retrieval-fallback"; shot.lifetime = .keepAlways; add(shot)
    }
    func testToolWritesNotesSummaryAndAnnotationWithProtectedUserEdits() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-tools", "--simulate-writing"]; app.launch()
        func openChat() { app.tabBars.buttons["伴读"].tap(); app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "工具查询")).firstMatch.tap() }
        func send(_ text: String) {
            let input = app.descendants(matching: .any).matching(identifier: "chat-input").firstMatch
            input.tap(); input.typeText(text); app.buttons["发送"].tap()
        }
        func openNotes() {
            app.tabBars.buttons["书架"].tap(); app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "查询测试")).firstMatch.tap()
            app.buttons["批注"].tap()
            XCTAssertTrue(app.staticTexts["Watch the lighthouse."].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["阿翎的批注"].exists)
            app.buttons["读书笔记与梗概"].tap()
        }
        openChat(); send("Please save a note, a recap, and an annotation.")
        XCTAssertTrue(app.staticTexts["批注、笔记与梗概已保存。"].waitForExistence(timeout: 20))
        app.navigationBars["工具查询"].buttons["返回"].tap(); openNotes()
        let note = app.buttons["reading-note-Lighthouse notes"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "reading-note-Plot recap").count, 1)
        app.buttons["reading-note-Plot recap"].tap()
        XCTAssertTrue(app.staticTexts["Reached the lighthouse and saw its light."].waitForExistence(timeout: 5))
        app.navigationBars["Plot recap"].buttons.element(boundBy: 0).tap(); note.tap(); app.buttons["编辑"].tap()
        let editor = app.textViews["reading-note-content"]; editor.tap(); editor.typeText("My own interpretation. ")
        let editedText = (editor.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(editedText.contains("My own interpretation."))
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts[editedText].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = ["--ui-testing", "--simulate-tools", "--simulate-writing"]; app.launch()
        openChat(); send("Update my edited note.")
        XCTAssertTrue(app.staticTexts["已保留你编辑的笔记。"].waitForExistence(timeout: 20))
        app.navigationBars["工具查询"].buttons["返回"].tap(); openNotes(); note.tap()
        XCTAssertTrue(app.staticTexts[editedText].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Overwritten by AI"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Protected-reading-note"; shot.lifetime = .keepAlways; add(shot)
    }
    func testToolQueriesKeepCitationsAndRefuseUnreadChapters() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-tools"]; app.launch()
        func openChat() { app.tabBars.buttons["伴读"].tap(); app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "工具查询")).firstMatch.tap() }
        openChat()
        let input = app.descendants(matching: .any).matching(identifier: "chat-input").firstMatch
        input.tap(); input.typeText("Please check chapter one."); app.buttons["发送"].tap()
        XCTAssertTrue(app.staticTexts["已查到第一章，并拦住未读章节。"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["来源 1"].exists)
        app.buttons["来源 1"].tap(); XCTAssertTrue(app.staticTexts["lighthouse first clue."].waitForExistence(timeout: 5)); app.buttons["完成"].tap()
        app.terminate(); app.launchArguments = ["--ui-testing", "--simulate-tools"]; app.launch(); openChat()
        XCTAssertTrue(app.staticTexts["已查到第一章，并拦住未读章节。"].waitForExistence(timeout: 10))
        let trace = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "查询过程（3 步）")).firstMatch
        XCTAssertTrue(trace.waitForExistence(timeout: 5)); trace.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "查看已读目录 · 完成")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Future secret")).firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Reading-tool-trace"; shot.lifetime = .keepAlways; add(shot)
    }
    func testRerankOrderCitationsFallbackAndSettingsPersist() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-rerank"]; app.launch()
        func openChat() { app.tabBars.buttons["伴读"].tap(); app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "寻找灯塔")).firstMatch.tap() }
        openChat()
        let input = app.descendants(matching: .any).matching(identifier: "chat-input").firstMatch
        input.tap(); input.typeText("lighthouse"); app.buttons["发送"].tap()
        XCTAssertTrue(app.staticTexts["本地排序结果：lighthouse second clue."].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["已按问题的相关性排列原文。"].exists)
        app.buttons["来源 1"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["lighthouse second clue."].waitForExistence(timeout: 5)); app.buttons["完成"].tap()
        input.tap(); input.typeText("lighthouse unavailable"); app.buttons["发送"].tap()
        XCTAssertTrue(app.staticTexts["本地排序结果：lighthouse first clue."].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["相关性排序暂不可用，已使用原来的原文检索顺序。"].exists)
        XCTAssertFalse(app.staticTexts["lighthouse secret identity."].exists)
        app.terminate(); app.launchArguments = ["--ui-testing", "--simulate-rerank"]; app.launch()
        app.tabBars.buttons["设置"].tap(); app.buttons["原文相关性排序"].tap()
        XCTAssertEqual(app.textFields["rerank-model"].value as? String, "fixture-rerank")
        app.switches["rerank-enabled"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(app.switches["rerank-enabled"].value as? String, "0")
        app.terminate(); app.launch(); app.tabBars.buttons["设置"].tap(); app.buttons["原文相关性排序"].tap()
        XCTAssertEqual(app.switches["rerank-enabled"].value as? String, "0")
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Rerank-settings"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.navigationBars["原文相关性排序"].buttons.element(boundBy: 0).tap(); app.tabBars.buttons["伴读"].tap(); app.buttons["开启新话题"].tap()
        input.tap(); input.typeText("lighthouse"); app.buttons["发送"].tap()
        XCTAssertTrue(app.staticTexts["本地排序结果：lighthouse first clue."].firstMatch.waitForExistence(timeout: 10))
    }
    func testPersonaMemoryConsolidationEditRecallAndForgettingPersist() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-memory"]; app.launch()
        func openChat() {
            app.tabBars.buttons["伴读"].tap()
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "书店的记忆")).firstMatch.tap()
        }
        func openMemory() { app.buttons["前情提要"].tap(); app.buttons["角色长期记忆"].tap() }
        func closeMemory() { app.navigationBars["角色记忆"].buttons.element(boundBy: 0).tap(); app.buttons["完成"].tap() }
        openChat(); openMemory(); app.buttons["整理本次对话"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "memory-entry-")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["memory-profile"].label.contains("安静的阅读环境"))
        entry.tap()
        let editor = app.textViews["memory-text-editor"]; editor.tap(); editor.typeText("Prefers quiet libraries.")
        let editedMemory = editor.value as? String ?? ""; XCTAssertTrue(editedMemory.contains("Prefers quiet libraries."))
        app.buttons["保存"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Prefers quiet libraries.")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["memory-profile"].label, "还没有用户画像。")
        closeMemory()
        let input = app.descendants(matching: .any).matching(identifier: "chat-input").firstMatch
        input.tap(); input.typeText("What do I like?"); app.buttons["发送"].tap()
        XCTAssertTrue(app.staticTexts["本地模拟：已收到修改后的长期记忆。"].waitForExistence(timeout: 10))
        app.terminate(); app.launchArguments = ["--ui-testing", "--simulate-memory"]; app.launch(); openChat(); openMemory()
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); XCTAssertTrue(entry.label.contains(editedMemory))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Persistent-persona-memory"; shot.lifetime = .keepAlways; add(shot)
        entry.swipeLeft(); app.buttons["遗忘"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: entry)], timeout: 5), .completed); closeMemory()
        input.tap(); input.typeText("What do you remember?"); app.buttons["发送"].tap()
        XCTAssertTrue(app.staticTexts["本地模拟：没有这条长期记忆。"].waitForExistence(timeout: 10))
        app.terminate(); app.launch(); openChat(); openMemory()
        XCTAssertFalse(entry.exists); XCTAssertEqual(app.staticTexts["memory-profile"].label, "还没有用户画像。")
    }
    func testUserIdentitySwitchRetryAndHistorySurviveRelaunch() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-identities"]; app.launch()
        app.tabBars.buttons["设置"].tap(); app.buttons["我的身份"].tap(); app.buttons["新建身份"].tap()
        app.textFields["mask-name"].tap(); app.textFields["mask-name"].typeText("Linyao")
        app.textViews["mask-description"].tap(); app.textViews["mask-description"].typeText("A bookshop guest.")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.buttons["select-mask-Linyao"].waitForExistence(timeout: 5)); app.buttons["select-mask-Linyao"].tap()
        app.tabBars.buttons["伴读"].tap(); app.buttons["开启新话题"].tap()
        XCTAssertTrue(app.buttons["chat-identity"].label.contains("扮演：Linyao"))
        let input = app.descendants(matching: .any).matching(identifier: "chat-input").firstMatch
        input.tap(); input.typeText("Hello."); app.buttons["发送"].tap()
        let maskedReply = app.staticTexts["本地模拟回复：【用户（扮演：Linyao）】"]
        XCTAssertTrue(maskedReply.waitForExistence(timeout: 10))
        app.buttons["chat-identity"].tap()
        app.switches["mask-enabled"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["chat-identity"].label.contains("本人：读者"))
        app.buttons["重新生成"].tap()
        XCTAssertTrue(maskedReply.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["扮演：Linyao"].exists)
        input.tap(); input.typeText("Now I am myself."); app.buttons["发送"].tap()
        XCTAssertTrue(app.staticTexts["本地模拟回复：【用户（本人：读者）】"].waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
        app.terminate(); app.launchArguments = ["--ui-testing", "--simulate-identities"]; app.launch()
        app.tabBars.buttons["伴读"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "与阿翎聊聊")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["扮演：Linyao"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["本人：读者"].exists)
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.staticTexts["扮演：Linyao"].isHittable && app.staticTexts["本人：读者"].isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        let restoredShot = XCTAttachment(screenshot: app.screenshot()); restoredShot.name = "Identity-history-after-relaunch"; restoredShot.lifetime = .keepAlways; add(restoredShot)
        app.buttons["chat-identity"].tap()
        XCTAssertEqual(app.switches["mask-enabled"].value as? String, "0")
        app.buttons["select-mask-Linyao"].swipeLeft(); app.buttons.matching(NSPredicate(format: "label IN %@", ["删除", "Delete"])).firstMatch.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["select-mask-Linyao"])], timeout: 5), .completed)
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["扮演：Linyao"].exists)
    }
    func testConversationSummaryGenerationSettingsAndDeletionPersist() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-summary"]; app.launch()
        func openSummary() {
            app.tabBars.buttons["伴读"].tap()
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "书店里的对话")).firstMatch.tap()
            app.buttons["前情提要"].tap()
        }
        openSummary(); app.buttons["现在整理"].tap()
        let summary = app.staticTexts["conversation-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertEqual(summary.label, "用户喜欢雨后的书店，希望我陪着慢慢读。")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); openSummary()
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        app.buttons["对话记忆设置"].tap()
        XCTAssertTrue(app.buttons["summary-provider"].label.contains("本地提要测试"))
        app.switches["summary-enabled"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.navigationBars["对话记忆"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["清除提要"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["现在整理"].isEnabled)
        app.buttons["清除提要"].tap(); XCTAssertFalse(summary.exists)
        app.terminate(); app.launch(); openSummary()
        XCTAssertFalse(summary.exists)
        app.buttons["对话记忆设置"].tap()
        XCTAssertEqual(app.switches["summary-enabled"].value as? String, "0")
    }
    func testGeneratedAnnotationsSurviveBookmarkWritesAndRelaunch() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-annotations"]; app.launch()
        app.buttons["add-sample"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        book.tap()
        for _ in 0..<6 { app.textViews["reader-text"].swipeUp() }
        app.buttons["批注"].tap()
        let generated = app.staticTexts.matching(NSPredicate(format: "label == %@", "这是一条本地模拟的随读段评。"))
        XCTAssertTrue(generated.firstMatch.waitForExistence(timeout: 15))
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in generated.count == 2 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 10), .completed)
        XCTAssertTrue(app.staticTexts["阿翎的段评"].firstMatch.exists)
        app.buttons["完成"].tap(); app.buttons["书签"].tap(); app.buttons["添加当前位置书签"].tap()
        XCTAssertTrue(app.staticTexts["书签已保存"].exists); app.buttons["完成"].tap()
        app.terminate(); app.launchArguments = ["--ui-testing", "--simulate-annotations"]; app.launch(); book.tap()
        app.buttons["批注"].tap()
        XCTAssertTrue(generated.firstMatch.waitForExistence(timeout: 10)); XCTAssertEqual(generated.count, 2)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
        app.buttons["完成"].tap(); app.buttons["书签"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmark-")).firstMatch.exists)
    }
    func testProactiveSettingsPersistAndMissingConnectionIsExplained() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library"]; app.launch()
        app.tabBars.buttons["设置"].tap(); app.buttons["随读段评"].tap()
        app.switches["proactive-enabled"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        for _ in 0..<3 { if app.steppers["proactive-chapter-limit"].isHittable { break }; app.swipeUp() }
        app.steppers["proactive-chapter-limit"].buttons.matching(NSPredicate(format: "label ENDSWITH %@", "Increment")).firstMatch.tap()
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.tabBars.buttons["设置"].tap(); app.buttons["随读段评"].tap()
        XCTAssertEqual(app.switches["proactive-enabled"].value as? String, "1")
        for _ in 0..<3 { if app.steppers["proactive-chapter-limit"].isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.steppers["proactive-chapter-limit"].label.contains("3"))
        app.terminate(); app.launch()
        app.buttons["add-sample"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        app.buttons["下一章"].tap(); app.buttons["批注"].tap()
        XCTAssertTrue(app.staticTexts["请先为随读段评选择 AI 服务商。"].waitForExistence(timeout: 10))
    }
    func testBackgroundImagePersistsAcrossTextAndEPUB() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-background"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        book.tap()
        XCTAssertTrue(app.textViews["reader-text"].waitForExistence(timeout: 10))
        func screenshot(_ name: String) { let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot) }
        screenshot("Background-TXT-scroll")
        app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons["无动画翻页"].tap(); app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["reader-page-number"].waitForExistence(timeout: 10)); screenshot("Background-TXT-page")
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); book.tap()
        app.buttons["排版"].tap()
        for _ in 0..<3 { if app.buttons["阅读背景图片"].isHittable { break }; app.swipeUp() }
        app.buttons["阅读背景图片"].tap()
        XCTAssertTrue(app.images["阅读背景预览"].exists)
        app.terminate(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-background"]; app.launch()
        app.buttons["add-epub-sample"].tap()
        let epub = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店 · EPUB")).firstMatch
        XCTAssertTrue(epub.waitForExistence(timeout: 20)); epub.tap()
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "林遥")).firstMatch.waitForExistence(timeout: 20))
        screenshot("Background-EPUB")
        app.buttons["排版"].tap(); app.buttons["epub-page-mode"].tap(); app.buttons["上下滚动"].tap(); app.buttons["完成"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10)); screenshot("Background-EPUB-scroll")
    }
    func testImmersiveReadingHidesControlsAndReturnsToPosition() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library"]; app.launch()
        app.buttons["add-sample"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons["无动画翻页"].tap(); app.buttons["完成"].tap()
        let page = app.staticTexts["reader-page-number"]
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        app.buttons["reader-next-page"].tap()
        let anchorText = app.textViews["reader-text"].firstMatch.value as? String
        app.buttons["排版"].tap(); app.buttons["enter-immersive"].tap()
        XCTAssertFalse(app.buttons["排版"].exists); XCTAssertFalse(app.buttons["下一章"].exists)
        XCTAssertFalse(app.buttons["reader-next-page"].isHittable)
        XCTAssertTrue(app.statusBars.allElementsBoundByIndex.allSatisfy { !$0.isHittable })
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
        app.textViews["reader-text"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["排版"].waitForExistence(timeout: 10))
        XCTAssertTrue(page.label.hasPrefix("本章 2 /"))
        XCTAssertEqual(app.textViews["reader-text"].firstMatch.value as? String, anchorText)
    }
    func testWorldBookEditingPersistsWithAvatarPickerAvailable() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library"]; app.launch()
        func openEditor() {
            app.tabBars.buttons["伴读"].tap()
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "角色与世界书")).firstMatch.tap()
            app.buttons["编辑"].firstMatch.tap()
            XCTAssertTrue(app.buttons["更换头像"].exists)
            app.buttons["edit-world-book"].tap()
        }
        openEditor()
        XCTAssertTrue(app.buttons["导入世界书 JSON"].exists)
        app.buttons["新建设定"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "新设定")).firstMatch.tap()
        app.textViews["lore-content"].tap(); app.textViews["lore-content"].typeText("The lighthouse is beside the sea.")
        app.navigationBars["世界书设定"].buttons.firstMatch.tap()
        app.navigationBars["世界书"].buttons.firstMatch.tap()
        app.buttons["保存"].tap(); app.buttons["完成"].tap()
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        openEditor()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "The lighthouse is beside the sea.")).firstMatch.exists)
    }
    func testImportedFontLibrarySurvivesRelaunchAndDeletion() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-font"]; app.launch()
        app.tabBars.buttons["设置"].tap(); tapSettingsRow("字体库", in: app)
        let rename = app.buttons["重命名"]
        XCTAssertTrue(rename.waitForExistence(timeout: 20)); rename.tap()
        let field = app.alerts["重命名字体"].textFields.firstMatch; XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        let previousName = field.value as? String
        field.typeText("My Reading Font")
        let renamedFont = field.value as? String ?? ""
        XCTAssertTrue(renamedFont.contains("My Reading Font")); XCTAssertNotEqual(renamedFont, previousName)
        let save = app.alerts.buttons["保存"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts[renamedFont].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.buttons["add-sample"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        XCTAssertTrue(app.textViews["reader-text"].waitForExistence(timeout: 10))
        app.buttons["排版"].tap(); app.buttons["字体与段落"].tap()
        XCTAssertTrue(app.buttons["reader-custom-font"].label.contains(renamedFont))
        app.buttons["管理与导入字体"].tap()
        app.buttons["删除字体"].tap()
        app.sheets.buttons["删除字体"].tap()
        let deleted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts[renamedFont])
        XCTAssertEqual(XCTWaiter.wait(for: [deleted], timeout: 5), .completed)
        app.navigationBars["字体库"].buttons.firstMatch.tap()
        XCTAssertFalse(app.buttons["reader-custom-font"].exists)
        app.navigationBars["字体与段落"].buttons.firstMatch.tap(); app.buttons["完成"].tap()
        XCTAssertTrue(app.textViews["reader-text"].waitForExistence(timeout: 10))
    }
    func testTypographyPreservesAnchorAndSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons["无动画翻页"].tap(); app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["reader-next-page"].waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: app.buttons["reader-next-page"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        app.buttons["reader-next-page"].tap()
        let turned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "本章 2 /"), object: app.staticTexts["reader-page-number"])
        XCTAssertEqual(XCTWaiter.wait(for: [turned], timeout: 10), .completed)
        let original = app.textViews["reader-text"].firstMatch.value as? String
        func openTypography() { app.buttons["排版"].tap(); app.buttons["字体与段落"].tap() }
        func closeTypography() { app.navigationBars["字体与段落"].buttons.firstMatch.tap(); app.buttons["完成"].tap() }
        openTypography()
        app.buttons["reader-font-family"].tap(); app.buttons["衬线字体"].tap()
        func increment(_ id: String, count: Int) {
            for _ in 0..<count { app.steppers[id].buttons.matching(NSPredicate(format: "label ENDSWITH %@", "Increment")).firstMatch.tap() }
        }
        increment("reader-font-weight", count: 2); increment("reader-first-line-indent", count: 4)
        app.switches["reader-justified"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(app.switches["reader-justified"].value as? String, "1")
        closeTypography()
        XCTAssertNotEqual(app.textViews["reader-text"].firstMatch.value as? String, original)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        openTypography()
        XCTAssertTrue(app.buttons["reader-font-family"].label.contains("衬线字体"))
        XCTAssertTrue(app.steppers["reader-font-weight"].label.contains("600"))
        XCTAssertTrue(app.steppers["reader-first-line-indent"].label.contains("2"))
        XCTAssertEqual(app.switches["reader-justified"].value as? String, "1")
        for _ in 0..<4 { if app.buttons["reader-typography-reset"].isHittable { break }; app.swipeUp() }
        app.buttons["reader-typography-reset"].tap(); closeTypography()
        XCTAssertTrue(app.staticTexts["reader-page-number"].label.hasPrefix("本章 2 /"))
        XCTAssertEqual(app.textViews["reader-text"].firstMatch.value as? String, original)
    }
    func testPaginatedReadingModesPreservePositionAndBookmarks() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        func mode(_ name: String) {
            app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons[name].tap(); app.buttons["完成"].tap()
            XCTAssertTrue(app.staticTexts["reader-page-number"].waitForExistence(timeout: 10))
        }
        mode("滑动翻页")
        let number = app.staticTexts["reader-page-number"]
        XCTAssertTrue(number.label.hasPrefix("本章 1 /"))
        XCTAssertFalse(app.buttons["reader-previous-page"].isEnabled)
        app.buttons["reader-next-page"].tap()
        let second = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "本章 2 /"), object: number)
        XCTAssertEqual(XCTWaiter.wait(for: [second], timeout: 10), .completed)
        let text = app.textViews["reader-text"].firstMatch.value as? String
        XCTAssertFalse(text?.isEmpty ?? true)
        app.buttons["书签"].tap(); app.buttons["添加当前位置书签"].tap()
        XCTAssertTrue(app.staticTexts["书签已保存"].exists); app.buttons["完成"].tap()
        mode("覆盖翻页"); XCTAssertTrue(number.label.hasPrefix("本章 2 /"))
        app.textViews["reader-text"].firstMatch.swipeLeft()
        let third = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "本章 3 /"), object: number)
        XCTAssertEqual(XCTWaiter.wait(for: [third], timeout: 10), .completed)
        mode("仿真翻页"); XCTAssertTrue(number.label.hasPrefix("本章 3 /"))
        app.buttons["reader-previous-page"].tap()
        let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "本章 2 /"), object: number)
        XCTAssertEqual(XCTWaiter.wait(for: [back], timeout: 10), .completed)
        mode("无动画翻页"); XCTAssertTrue(number.label.hasPrefix("本章 2 /"))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 10), .completed)
        XCUIDevice.shared.orientation = .portrait
        let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width < app.frame.height }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 10), .completed)
        XCTAssertTrue(number.label.hasPrefix("本章 2 /"))
        for direction in ["Increment", "Decrement"] {
            app.buttons["排版"].tap()
            for _ in 0..<3 { app.buttons["reader-font-size-stepper-" + direction].tap() }
            app.buttons["完成"].tap()
        }
        XCTAssertTrue(number.label.hasPrefix("本章 2 /"))
        XCTAssertEqual(app.textViews["reader-text"].firstMatch.value as? String, text)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        XCTAssertTrue(number.waitForExistence(timeout: 10)); XCTAssertTrue(number.label.hasPrefix("本章 2 /"))
        app.buttons["下一章"].tap()
        XCTAssertTrue(number.label.hasPrefix("本章 1 /"))
        app.buttons["reader-previous-page"].tap()
        XCTAssertTrue(app.navigationBars["第一章 雨后"].waitForExistence(timeout: 10))
        XCTAssertTrue(number.label.contains("/")); XCTAssertFalse(app.alerts["需要处理"].exists)
        app.buttons["书签"].tap()
        let marks = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookmark-"))
        XCTAssertEqual(marks.count, 1); marks.firstMatch.tap()
        XCTAssertTrue(number.label.hasPrefix("本章 2 /"))
        XCTAssertEqual(app.textViews["reader-text"].firstMatch.value as? String, text)
    }
    func testCachedCloudAudioPauseSeekAndChapterTimer() {
        var wave = Data()
        func word<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wave.append(contentsOf: $0) } }
        let samples = 24000
        wave.append(Data("RIFF".utf8)); word(UInt32(36 + samples * 2)); wave.append(Data("WAVEfmt ".utf8)); word(UInt32(16))
        word(UInt16(1)); word(UInt16(1)); word(UInt32(8000)); word(UInt32(16000)); word(UInt16(2)); word(UInt16(16))
        wave.append(Data("data".utf8)); word(UInt32(samples * 2))
        for index in 0..<samples { word(Int16(sin(Double(index) * 2 * .pi * 220 / 8000) * 100)) }
        for service in ["openAI", "gemini"] {
        let app = XCUIApplication()
        app.launchEnvironment["MOREAD_TEST_SPEECH_SERVICE"] = service
        app.launchArguments = ["--ui-testing", "--reset-test-library"]
        app.launchEnvironment["MOREAD_TEST_SPEECH_AUDIO"] = wave.base64EncodedString()
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        app.buttons["听书"].tap(); app.buttons["speech-start"].tap()
        let playback = app.buttons["speech-play-pause"]
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let current = app.buttons["speech-play-pause"]
            return current.exists && current.label == "暂停" && current.isEnabled
        }, object: nil)
        let started = XCTWaiter.wait(for: [playing], timeout: 20)
        if started != .completed {
            let state = XCTAttachment(string: app.debugDescription); state.name = "Speech-start-state"; state.lifetime = .keepAlways; add(state)
        }
        XCTAssertEqual(started, .completed)
        playback.tap(); XCTAssertEqual(playback.label, "继续")
        app.buttons["speech-timer"].tap(); app.buttons["按章节"].tap(); app.buttons["本章结束"].tap()
        app.buttons["speech-next-chapter"].tap()
        XCTAssertTrue(app.buttons["speech-timer"].label.contains("还剩 1 章"))
        XCTAssertEqual(playback.label, "继续"); playback.tap()
        XCTAssertTrue(app.staticTexts["speech-stop-reason"].waitForExistence(timeout: 40))
        XCTAssertEqual(app.staticTexts["speech-stop-reason"].label, "定时结束")
        XCTAssertFalse(app.alerts["需要处理"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = service + "-cached-speech"; attachment.lifetime = .keepAlways; add(attachment)
        app.terminate()
        }
    }
    func testGeminiSpeechSettingsAndVoicePersist() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library"]; app.launch()
        app.tabBars.buttons["设置"].tap(); tapSettingsRow("云端声音与缓存", in: app)
        let enabled = app.switches["cloud-speech-enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 10)); enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["cloud-speech-service"].tap(); app.buttons["Gemini TTS"].tap()
        XCTAssertEqual(app.textFields["cloud-speech-model"].value as? String, "gemini-3.8-flash-tts")
        let presets = app.buttons["gemini-voice-presets"]; revealListElement(presets, in: app); presets.tap()
        let kore = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Kore")).firstMatch
        XCTAssertTrue(kore.waitForExistence(timeout: 5)); kore.tap()
        let voice = app.textFields["cloud-speech-voice"]; revealListElement(voice, in: app)
        XCTAssertEqual(voice.value as? String, "Kore")
        let key = app.secureTextFields["cloud-speech-key"]; revealListElement(key, in: app); key.tap(); key.typeText("gemini-local-test-key")
        app.buttons["完成"].tap()
        let save = app.buttons["save-cloud-speech"]; revealListElement(save, in: app); save.tap()
        XCTAssertTrue(app.staticTexts["cloud-speech-saved"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.tabBars.buttons["设置"].tap(); tapSettingsRow("云端声音与缓存", in: app)
        XCTAssertTrue(app.buttons["cloud-speech-service"].label.contains("Gemini TTS"))
        XCTAssertEqual(enabled.value as? String, "1")
        revealListElement(voice, in: app); XCTAssertEqual(voice.value as? String, "Kore")
        revealListElement(key, in: app); XCTAssertEqual((key.value as? String)?.count, "gemini-local-test-key".count)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Gemini-voice-settings"; shot.lifetime = .keepAlways; add(shot)
    }
    func testCloudSpeechSettingsPersist() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library"]; app.launch()
        app.tabBars.buttons["设置"].tap(); tapSettingsRow("云端声音与缓存", in: app)
        let enabled = app.switches["cloud-speech-enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 10))
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(enabled.value as? String, "1")
        func scroll() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        func reveal(_ element: XCUIElement) {
            for _ in 0..<8 { if element.exists && element.isHittable { return }; scroll() }
            XCTAssertTrue(element.isHittable)
        }
        app.buttons["cloud-speech-service"].tap(); app.buttons["MiniMax"].tap(); scroll()
        let model = app.textFields["cloud-speech-model"]
        reveal(model); model.tap(); model.typeText("-custom"); app.toolbars.buttons["完成"].tap()
        let key = app.secureTextFields["cloud-speech-key"]
        reveal(key); key.tap(); key.typeText("test-voice-key-12345")
        app.toolbars.buttons["完成"].tap()
        reveal(app.buttons["save-cloud-speech"]); app.buttons["save-cloud-speech"].tap()
        XCTAssertTrue(app.staticTexts["cloud-speech-saved"].waitForExistence(timeout: 10))
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.tabBars.buttons["设置"].tap(); tapSettingsRow("云端声音与缓存", in: app)
        XCTAssertEqual(enabled.value as? String, "1")
        reveal(model); XCTAssertEqual(model.value as? String, "speech-2.8-hd-custom")
        reveal(key)
        XCTAssertNotEqual(key.value as? String, "API 密钥")
        XCTAssertEqual((key.value as? String)?.count, "test-voice-key-12345".count)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
        app.terminate(); app.launchArguments = ["--ui-testing", "--simulate-unavailable-credentials"]; app.launch()
        app.tabBars.buttons["设置"].tap(); tapSettingsRow("云端声音与缓存", in: app)
        XCTAssertTrue(app.alerts["需要处理"].waitForExistence(timeout: 5)); app.alerts.buttons["好"].tap()
        reveal(app.buttons["save-cloud-speech"]); XCTAssertFalse(app.buttons["save-cloud-speech"].isEnabled)
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.tabBars.buttons["设置"].tap(); tapSettingsRow("云端声音与缓存", in: app)
        reveal(model); XCTAssertEqual(model.value as? String, "speech-2.8-hd-custom")
        reveal(key); XCTAssertEqual((key.value as? String)?.count, "test-voice-key-12345".count)
    }
    func testSpeechPreferencesAndChapterSleepTimer() {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--english-speech-sample", "--trace-system-speech"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        XCTAssertTrue(app.buttons["听书"].waitForExistence(timeout: 10)); app.buttons["听书"].tap()
        let rate = app.sliders["speech-rate"]
        XCTAssertTrue(rate.waitForExistence(timeout: 10)); rate.adjust(toNormalizedSliderPosition: 0.3)
        let savedRate = rate.value as? String; XCTAssertNotNil(savedRate)
        app.buttons["speech-voice-picker"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("en-US\n")
        let voice = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "speech-voice-en-US-")).firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 10)); let voiceName = voice.label; voice.tap()
        app.terminate(); app.launchArguments = ["--ui-testing", "--trace-system-speech"]; app.launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        app.buttons["听书"].tap()
        XCTAssertTrue(rate.waitForExistence(timeout: 10)); XCTAssertEqual(rate.value as? String, savedRate)
        XCTAssertTrue(app.buttons["speech-voice-picker"].label.contains(voiceName))
        app.buttons["speech-start"].tap()
        let playback = app.buttons["speech-play-pause"]
        XCTAssertTrue(playback.waitForExistence(timeout: 15))
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let current = app.buttons["speech-play-pause"]
            return current.exists && current.label == "暂停" && current.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 20), .completed)
        let progress = app.sliders["本章听书进度"]
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in progress.exists && progress.normalizedSliderPosition > 0 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 15), .completed)
        playback.tap()
        func state(_ label: String) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ AND enabled == true", label), object: app.buttons["speech-play-pause"])], timeout: 5), .completed)
        }
        state("继续")
        playback.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap(); state("暂停")
        playback.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap(); state("继续")
        app.buttons["结束听书"].coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["speech-start"].waitForExistence(timeout: 5))
        app.buttons["speech-start"].coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap(); state("暂停")
        playback.tap(); state("继续")
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
    func testUnavailableSystemVoiceStopsPlaybackAndPreview() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--simulate-unavailable-system-voice"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        app.buttons["听书"].tap(); app.buttons["speech-start"].tap()
        let error = app.alerts["需要处理"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(error.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "没有可用的中文朗读声音")).firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "unavailable-system-voice"; shot.lifetime = .keepAlways; add(shot)
        error.buttons["好"].tap()
        if !app.buttons["speech-start"].waitForExistence(timeout: 2) { app.buttons["听书"].tap() }
        XCTAssertTrue(app.buttons["speech-start"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["speech-play-pause"].exists)
        let preview = app.buttons["试听声音"]
        revealListElement(preview, in: app); preview.tap()
        XCTAssertTrue(error.waitForExistence(timeout: 5)); error.buttons["好"].tap()
        if !preview.waitForExistence(timeout: 2) { app.buttons["听书"].tap() }
        revealListElement(preview, in: app)
        XCTAssertTrue(preview.exists); XCTAssertFalse(app.buttons["停止试听"].exists)
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
        app.buttons["书签"].tap(); app.buttons["添加当前位置书签"].tap()
        XCTAssertTrue(app.staticTexts["书签已保存"].exists); app.buttons["完成"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["设置"].tap()
        tapSettingsRow("存储与阅读记录", in: app)
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        app.buttons["clear-book-body"].tap()
        app.alerts.buttons["清理正文"].tap()
        XCTAssertTrue(app.staticTexts["正文已清理，阅读记录保存在本机。"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["--ui-testing"]; app.launch()
        app.tabBars.buttons["设置"].tap()
        tapSettingsRow("存储与阅读记录", in: app)
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
        tapSettingsRow("整理书架", in: app)
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
        tapSettingsRow("备份与恢复", in: app)
        app.buttons["create-backup"].tap()
        XCTAssertTrue(app.buttons["share-backup"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.alerts["需要处理"].exists)
    }

    func testEPUBCurrentPageTranslationKeepsRepeatedParagraphsDistinct() throws {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        let url = try XCTUnwrap(Bundle(for: ReadingTests.self).url(forResource: "Bilingual", withExtension: "epub"))
        app.launchEnvironment["MOREAD_TEST_EPUB"] = try Data(contentsOf: url).base64EncodedString()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-epub", "--simulate-translations"]
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店 · EPUB")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20)); book.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))
        func page() {
            app.buttons["目录"].tap()
            XCTAssertTrue(app.buttons["翻译当前页"].waitForExistence(timeout: 15)); app.buttons["翻译当前页"].tap()
            XCTAssertTrue(app.navigationBars["当前页对照"].waitForExistence(timeout: 5))
        }
        func close() { app.navigationBars["当前页对照"].buttons.firstMatch.tap(); app.buttons["完成"].tap() }
        func rows() -> [String] { app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "translation-source-")).allElementsBoundByIndex.map(\.identifier) }
        page()
        let first = rows(); XCTAssertFalse(first.isEmpty)
        let count = Int(app.staticTexts["translations-paragraph-count"].label.filter(\.isNumber)) ?? 0
        XCTAssertGreaterThan(count, 0); XCTAssertLessThan(count, 25)
        app.buttons["translations-start"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "译文已保存"), object: app.staticTexts["translations-status"])], timeout: 15), .completed)
        close()
        app.webViews.firstMatch.swipeLeft()
        page(); let second = rows(); XCTAssertFalse(second.isEmpty); XCTAssertNotEqual(second, first)
        let cached = Set(first).intersection(second).count
        let secondCount = Int(app.staticTexts["translations-paragraph-count"].label.filter(\.isNumber)) ?? 0
        XCTAssertEqual(app.staticTexts["translations-saved-count"].label, "当前范围已保存 \(cached) / \(secondCount) 段")
        XCTAssertEqual(app.buttons["translations-replace"].exists, cached > 0)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "epub-current-page-translation"; screenshot.lifetime = .keepAlways; add(screenshot)
        close()
        app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).press(forDuration: 1.2)
        func annotationMenu() -> XCUIElement? {
            if app.menuItems["批注"].exists { return app.menuItems["批注"] }
            let button = app.collectionViews.buttons["批注"]
            return button.exists ? button : nil
        }
        for _ in 0..<3 where annotationMenu() == nil {
            let next = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next Page", "Forward"])).firstMatch
            if next.waitForExistence(timeout: 2) { next.tap() }
        }
        let action = try XCTUnwrap(annotationMenu())
        let frame = action.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        XCTAssertTrue(app.navigationBars["记录这一段"].waitForExistence(timeout: 10))
        app.buttons["本段对照"].tap(); XCTAssertTrue(app.navigationBars["本段对照"].waitForExistence(timeout: 5))
        let selected = rows(); XCTAssertFalse(selected.isEmpty); XCTAssertTrue(selected.allSatisfy { second.contains($0) })
        app.navigationBars["本段对照"].buttons.firstMatch.tap(); app.buttons["保存"].tap()
        app.buttons["批注"].tap(); XCTAssertTrue(app.staticTexts["bookshop"].waitForExistence(timeout: 5)); app.buttons["完成"].tap()
        let mark = XCTAttachment(screenshot: app.screenshot()); mark.name = "epub-repeated-paragraph-highlight"; mark.lifetime = .keepAlways; add(mark)
        app.buttons["书签"].tap(); app.buttons["添加当前位置书签"].tap(); app.buttons["完成"].tap()
        app.terminate(); app.launchArguments = ["--ui-testing", "--simulate-translations"]; app.launch()
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap(); XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))
        page(); XCTAssertEqual(rows().first, second.first)
        XCTAssertEqual(app.staticTexts["translations-paragraph-count"].label, "当前页包含 \(secondCount) 个英文段落"); close()
        app.buttons["目录"].tap(); app.buttons["第二章 来信"].tap()
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Another")).firstMatch.waitForExistence(timeout: 15))
        page(); XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Another letter arrived.")).firstMatch.exists)
        XCTAssertFalse(app.alerts["需要处理"].exists)
    }

    func testEPUBContentsAndLocationSurviveRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-font"]
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
        app.buttons["排版"].tap(); app.buttons["字体与段落"].tap()
        app.switches["reader-publisher-styles"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(app.switches["reader-publisher-styles"].value as? String, "0")
        XCTAssertTrue(app.buttons["reader-custom-font"].label.contains("Noto"))
        app.navigationBars["字体与段落"].buttons.firstMatch.tap(); app.buttons["完成"].tap()
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
