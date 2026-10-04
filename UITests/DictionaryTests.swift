import XCTest

final class DictionaryTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil, subdirectory: "Dictionary"))
        return try Data(contentsOf: url).base64EncodedString()
    }
    private func lookup(_ app: XCUIApplication, _ word: String, submit: Bool = true) {
        let field = app.textFields["dictionary-query"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
        if let value = field.value as? String, value != field.placeholderValue { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)) }
        field.typeText(word); if submit { app.buttons["dictionary-search"].tap() }
    }
    private func manager(_ app: XCUIApplication) {
        app.tabBars.buttons["设置"].tap()
        let link = app.buttons["词典管理"]
        for _ in 0..<4 { if link.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(link.waitForExistence(timeout: 5)); link.tap()
    }
    func testAIDictionaryWithoutConfiguredModelShowsSetupMessage() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); manager(app)
        app.buttons["查字词"].tap(); lookup(app, "apple")
        app.segmentedControls["dictionary-mode"].buttons["AI 词典"].tap(); app.buttons["dictionary-ai-start"].tap()
        XCTAssertTrue(app.staticTexts["请先在模型分工中选择词典模型。"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["vocabulary-save"].exists)
    }
    func testAIDictionarySaveSwitchSourceCancelAndFailure() throws {
        executionTimeAllowance = 360
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-dictionary", "--simulate-ai-dictionary", "--simulate-model-roles"]
        app.launchEnvironment["MOREAD_TEST_MDX"] = try fixture("sample-v2.mdx"); app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); manager(app)
        app.buttons["查字词"].tap(); lookup(app, "apple")
        app.segmentedControls["dictionary-mode"].buttons["AI 词典"].tap()
        app.buttons["model-role-dictionary"].tap(); app.buttons["批量测试 · batch-fixture"].tap()
        app.buttons["dictionary-ai-start"].tap()
        let definition = app.scrollViews["dictionary-ai-definition"]
        XCTAssertTrue(definition.waitForExistence(timeout: 10)); XCTAssertTrue(definition.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "batch-fixture")).firstMatch.exists)
        app.buttons["vocabulary-save"].tap(); XCTAssertTrue(app.staticTexts["vocabulary-notice"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "ai-dictionary-definition"; screenshot.lifetime = .keepAlways; add(screenshot)
        lookup(app, "slow", submit: false); app.buttons["dictionary-ai-start"].tap()
        XCTAssertTrue(app.buttons["dictionary-ai-stop"].waitForExistence(timeout: 5)); app.buttons["dictionary-ai-stop"].tap()
        XCTAssertFalse(definition.exists)
        lookup(app, "fail", submit: false); app.buttons["dictionary-search"].tap()
        XCTAssertTrue(app.staticTexts["词典服务暂不可用。"].waitForExistence(timeout: 10)); XCTAssertFalse(app.buttons["vocabulary-save"].exists)
        lookup(app, "slow", submit: false); app.buttons["dictionary-ai-start"].tap()
        app.buttons["model-role-dictionary"].tap(); app.buttons["使用默认模型"].tap()
        XCTAssertFalse(app.buttons["dictionary-ai-stop"].exists)
        lookup(app, "apple", submit: false); app.buttons["dictionary-search"].tap()
        XCTAssertTrue(definition.waitForExistence(timeout: 10)); XCTAssertTrue(definition.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "chat-fixture")).firstMatch.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["生词本"].tap()
        let row = app.buttons["vocabulary-word-apple"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); XCTAssertTrue(row.label.contains("语境词义")); XCTAssertTrue(row.label.contains("/fixture/"))
        let learned = app.switches["vocabulary-learned-apple"]
        learned.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        row.tap()
        let save = app.buttons["vocabulary-save"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)], timeout: 10), .completed)
        save.tap(); app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5)); XCTAssertFalse(row.label.contains("/fixture/")); XCTAssertFalse(row.label.contains("语境词义")); XCTAssertTrue(row.label.contains("苹果")); XCTAssertEqual(learned.value as? String, "1")
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); manager(app); app.buttons["生词本"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5)); XCTAssertFalse(row.label.contains("/fixture/")); XCTAssertEqual(learned.value as? String, "1")
    }
    func testVocabularySaveEditLearnSearchRestartAndDelete() throws {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-dictionary"]
        app.launchEnvironment["MOREAD_TEST_MDX"] = try fixture("sample-v2.mdx"); app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); manager(app)
        app.buttons["查字词"].tap(); lookup(app, "APPLE")
        let save = app.buttons["vocabulary-save"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)], timeout: 10), .completed)
        save.tap(); XCTAssertTrue(app.staticTexts["vocabulary-notice"].waitForExistence(timeout: 5))
        save.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["生词本"].tap()
        let row = app.buttons["vocabulary-word-apple"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); XCTAssertEqual(app.buttons.matching(identifier: "vocabulary-word-apple").count, 1)
        app.buttons["vocabulary-more-apple"].tap(); app.buttons["vocabulary-edit-apple"].tap()
        let gloss = app.textFields["vocabulary-gloss"]
        gloss.tap(); gloss.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (gloss.value as? String)?.count ?? 0)); gloss.typeText("水果")
        app.textFields["vocabulary-phonetic"].tap(); app.textFields["vocabulary-phonetic"].typeText("/apple/")
        app.buttons["vocabulary-edit-save"].tap()
        let learned = app.switches["vocabulary-learned-apple"]
        XCTAssertTrue(learned.waitForExistence(timeout: 5)); learned.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["vocabulary-filter-learning"].tap(); XCTAssertFalse(row.exists)
        app.buttons["vocabulary-undo"].tap(); XCTAssertTrue(row.waitForExistence(timeout: 5)); XCTAssertEqual(learned.value as? String, "0")
        learned.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap(); XCTAssertFalse(row.exists)
        app.buttons["vocabulary-filter-learned"].tap(); XCTAssertTrue(row.exists)
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); manager(app); app.buttons["生词本"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5)); XCTAssertEqual(learned.value as? String, "1")
        XCTAssertTrue(row.label.contains("水果")); XCTAssertTrue(row.label.contains("/apple/"))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "vocabulary-saved-word"; screenshot.lifetime = .keepAlways; add(screenshot)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.exists); search.tap(); search.typeText("missing")
        XCTAssertFalse(row.exists)
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7)); search.typeText("苹果")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.buttons["vocabulary-more-apple"].tap(); app.buttons["vocabulary-remove-apple"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)], timeout: 10), .completed)
        app.buttons["vocabulary-undo"].tap(); XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("水果")); XCTAssertTrue(row.label.contains("/apple/")); XCTAssertEqual(learned.value as? String, "1")
        app.buttons["vocabulary-more-apple"].tap(); app.buttons["vocabulary-remove-apple"].tap()
        app.terminate(); app.launch(); manager(app); app.buttons["生词本"].tap(); XCTAssertFalse(row.exists)
    }
    func testVocabularyOverviewDateGroupsTrimmedSearchAndEditUndo() {
        executionTimeAllowance = 300
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library", "--vocabulary-cards-sample"]; app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); manager(app); app.buttons["生词本"].tap()
        let row = app.buttons["vocabulary-word-serendipity"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["vocabulary-filter-all"].value as? String, "5 个")
        XCTAssertEqual(app.buttons["vocabulary-filter-learning"].value as? String, "4 个")
        XCTAssertEqual(app.buttons["vocabulary-filter-learned"].value as? String, "1 个")
        XCTAssertEqual(app.staticTexts["vocabulary-mastery"].label, "已掌握 20%")
        XCTAssertTrue(app.staticTexts["今天"].exists); XCTAssertTrue(row.label.contains("A Serendipity by the old bookshop."))
        XCTAssertFalse(row.label.contains("##")); XCTAssertFalse(row.label.contains("**"))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Vocabulary-overview-cards"; shot.lifetime = .keepAlways; add(shot)
        row.press(forDuration: 1.2); app.buttons["vocabulary-edit-serendipity"].tap()
        let gloss = app.textFields["vocabulary-gloss"]
        XCTAssertTrue(gloss.waitForExistence(timeout: 5)); gloss.tap(); gloss.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "惊喜")
        app.buttons["vocabulary-edit-save"].tap(); XCTAssertTrue(row.label.contains("惊喜"))
        app.buttons["vocabulary-undo"].tap(); XCTAssertTrue(row.label.contains("意外之喜")); XCTAssertFalse(row.label.contains("惊喜"))
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("  之喜  ")
        XCTAssertTrue(row.waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["vocabulary-word-lighthouse"].exists)
        app.buttons["vocabulary-filter-learned"].tap(); XCTAssertFalse(row.exists)
        search.tap(); search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (search.value as? String ?? "").count) + "\n")
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消", "Close", "关闭"])).firstMatch
        if cancel.exists { cancel.tap() }
        app.buttons["vocabulary-filter-all"].tap()
        let yesterday = app.staticTexts["昨天"]
        for _ in 0..<6 { if yesterday.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(yesterday.exists)
        let week = app.staticTexts["过去一周"]
        for _ in 0..<6 { if week.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(week.exists)
        let grouping = XCTAttachment(screenshot: app.screenshot()); grouping.name = "Vocabulary-date-groups"; grouping.lifetime = .keepAlways; add(grouping)
    }
    func testLookupResourcesEntryLinksRestartAndReaderEntry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-dictionary"]
        app.launchEnvironment["MOREAD_TEST_MDX"] = try fixture("sample-classical.mdx")
        app.launchEnvironment["MOREAD_TEST_MDD"] = try fixture("sample.mdd")
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        manager(app)
        XCTAssertTrue(app.buttons["添加 MDD 资源（1）"].waitForExistence(timeout: 10))
        app.buttons["查字词"].tap(); lookup(app, "学而时习之")
        XCTAssertTrue(app.webViews.staticTexts["学习后按时温习。"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "dictionary-classical-stylesheet"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["dictionary-simple"].tap()
        XCTAssertTrue(app.staticTexts["dictionary-plain"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["dictionary-plain"].label.contains("学习后按时温习。"))
        app.buttons["dictionary-simple"].tap()
        app.webViews.links["故"].tap()
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "旧的，原来的。")).firstMatch.waitForExistence(timeout: 10))
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        app.buttons["目录"].tap(); app.buttons["查字词"].tap(); lookup(app, "故人")
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "老朋友。")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts["需要处理"].exists)
    }
    func testDisableDuplicateAndDelete() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-dictionary"]
        app.launchEnvironment["MOREAD_TEST_MDX"] = try fixture("sample-v2.mdx"); app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); manager(app)
        let toggle = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "dictionary-enabled-")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.terminate(); app.launchArguments = ["--ui-testing", "--import-test-dictionary"]; app.launch(); manager(app)
        XCTAssertEqual(app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "dictionary-enabled-")).count, 1)
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertTrue(app.staticTexts["dictionary-notice"].label.contains("1 个文件已存在"))
        app.buttons["查字词"].tap(); lookup(app, "apple")
        XCTAssertTrue(app.staticTexts["没有找到释义"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["查字词"].tap(); lookup(app, "apple")
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "苹果")).firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["删除词典"].tap(); app.sheets.buttons.matching(identifier: "dictionary-delete-confirm").firstMatch.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: toggle)], timeout: 10), .completed)
    }
    func testLongDictionaryScrollBoundariesAndSourcePosition() throws {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-dictionary"]
        app.launchEnvironment["MOREAD_TEST_MDX"] = try fixture("sample-scroll.mdx")
        app.launchEnvironment["MOREAD_TEST_MDX_SECOND"] = try fixture("sample-v2.mdx")
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap(); app.buttons["目录"].tap(); app.buttons["查字词"].tap()
        lookup(app, "apple")
        let sources = app.buttons["dictionary-source"]
        XCTAssertTrue(sources.waitForExistence(timeout: 10)); sources.tap(); app.buttons["滚动词典"].tap()
        let web = app.webViews.firstMatch, top = web.staticTexts["长释义起点"], bottom = web.staticTexts["长释义终点"]
        XCTAssertTrue(top.waitForExistence(timeout: 10))
        let initialTop = sources.frame.minY
        func drag(_ from: CGFloat, _ to: CGFloat) {
            web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from)).press(forDuration: 0.05, thenDragTo: web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)))
        }
        drag(0.25, 0.8)
        XCTAssertTrue(sources.exists); XCTAssertEqual(sources.frame.minY, initialTop, accuracy: 2)
        for _ in 0..<18 { if bottom.isHittable { break }; drag(0.8, 0.2) }
        XCTAssertTrue(bottom.isHittable)
        drag(0.8, 0.2); drag(0.8, 0.2)
        XCTAssertEqual(sources.frame.minY, initialTop, accuracy: 2)
        drag(0.25, 0.75)
        let paragraphs = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "段落 "))
        let anchor = try XCTUnwrap(paragraphs.allElementsBoundByIndex.first { $0.isHittable && $0.frame.minY > web.frame.minY + 20 })
        let anchorLabel = anchor.label, anchorY = anchor.frame.minY
        sources.tap(); app.buttons["MoRead Test"].tap()
        XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "苹果")).firstMatch.waitForExistence(timeout: 10))
        sources.tap(); app.buttons["滚动词典"].tap()
        let restored = web.staticTexts[anchorLabel]
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: restored)], timeout: 10), .completed)
        XCTAssertEqual(restored.frame.minY, anchorY, accuracy: 5)
        app.buttons["dictionary-simple"].tap(); app.buttons["dictionary-simple"].tap()
        XCTAssertEqual(restored.frame.minY, anchorY, accuracy: 5)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "dictionary-long-scroll-restored"; screenshot.lifetime = .keepAlways; add(screenshot)
        for _ in 0..<18 { if top.isHittable { break }; drag(0.25, 0.8) }
        XCTAssertTrue(top.isHittable); drag(0.25, 0.8)
        XCTAssertTrue(sources.exists); XCTAssertEqual(sources.frame.minY, initialTop, accuracy: 2)
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["排版"].waitForExistence(timeout: 5))
    }
    func testStaticDictionaryDisplayAndPlainTextFallback() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--import-test-dictionary"]
        app.launchEnvironment["MOREAD_TEST_MDX"] = try fixture("sample-display.mdx")
        app.launchEnvironment["MOREAD_TEST_MDD"] = try fixture("sample.mdd"); app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); manager(app)
        app.buttons["查字词"].tap(); lookup(app, "layout")
        XCTAssertTrue(app.webViews.staticTexts["这是本地释义。"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.images["词典图片"].exists)
        XCTAssertFalse(app.staticTexts["脚本已执行"].exists)
        let link = app.webViews.links["外部链接"], frame = link.frame
        XCTAssertTrue(app.webViews.firstMatch.frame.contains(frame))
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        XCTAssertTrue(app.webViews.staticTexts["这是本地释义。"].exists)
        lookup(app, "hidden"); app.buttons["dictionary-simple"].tap()
        let plain = app.staticTexts["dictionary-plain"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "简明释义仍可阅读。"), object: plain)], timeout: 10), .completed)
        XCTAssertFalse(plain.label.contains("display:none")); XCTAssertFalse(plain.label.contains("脚本内容"))
    }
    func testSelectionLookupInContinuousPagedAndEPUBReading() throws {
        executionTimeAllowance = 360
        let app = XCUIApplication()
        for mode in ["上下滚动", "无动画翻页", "EPUB"] {
            app.launchArguments = ["--ui-testing", "--reset-test-library", "--translation-pages-sample", "--import-test-dictionary", "--simulate-ai-dictionary", "--simulate-model-roles"]
            app.launchEnvironment["MOREAD_TEST_MDX"] = try fixture("sample-reading.mdx"); app.launch()
            let sample = app.buttons[mode == "EPUB" ? "add-epub-sample" : "add-sample"]
            XCTAssertTrue(sample.waitForExistence(timeout: 15)); sample.tap()
            let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch
            XCTAssertTrue(book.waitForExistence(timeout: 20)); book.tap()
            XCTAssertTrue(app.buttons["排版"].waitForExistence(timeout: 15))
            if mode == "无动画翻页" { app.buttons["排版"].tap(); app.buttons["reader-page-mode"].tap(); app.buttons[mode].tap(); app.buttons["完成"].tap() }
            if mode == "EPUB" {
                let web = app.webViews.firstMatch
                XCTAssertTrue(web.waitForExistence(timeout: 15))
                func selectableText() -> XCUIElement? { web.staticTexts.allElementsBoundByIndex.first(where: { $0.isHittable && $0.label.count > 40 && $0.frame.height > 50 }) }
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in selectableText() != nil }, object: nil)], timeout: 15), .completed)
                let text = try XCTUnwrap(selectableText())
                let frame = text.frame
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + min(80, frame.width / 2), dy: frame.minY + 12)).press(forDuration: 1.2)
            } else {
                app.textViews["reader-text"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.12)).press(forDuration: 1.2)
            }
            func action() -> XCUIElement? {
                if app.menuItems["查字词"].exists { return app.menuItems["查字词"] }
                let button = app.collectionViews.buttons["查字词"]; return button.exists ? button : nil
            }
            for _ in 0..<4 where action() == nil {
                let next = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next Page", "Forward"])).firstMatch
                if next.waitForExistence(timeout: 2) { next.tap() }
            }
            let menu = try XCTUnwrap(action()), frame = menu.frame
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            XCTAssertTrue(app.textFields["dictionary-query"].waitForExistence(timeout: 10))
            let word = try XCTUnwrap(app.textFields["dictionary-query"].value as? String)
            XCTAssertFalse(word.isEmpty); XCTAssertNotEqual(word, "字词或短语")
            if mode == "上下滚动" {
                app.segmentedControls["dictionary-mode"].buttons["AI 词典"].tap(); app.buttons["dictionary-ai-start"].tap()
                XCTAssertTrue(app.scrollViews["dictionary-ai-definition"].waitForExistence(timeout: 10))
                app.buttons["vocabulary-save"].tap(); XCTAssertTrue(app.staticTexts["vocabulary-notice"].waitForExistence(timeout: 5))
                app.segmentedControls["dictionary-mode"].buttons["本地词典"].tap()
            }
            let save = app.buttons["vocabulary-save"]
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)], timeout: 10), .completed, "Selected word: " + word)
            save.tap(); XCTAssertTrue(app.staticTexts["vocabulary-notice"].waitForExistence(timeout: 5))
            app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); manager(app); app.buttons["生词本"].tap()
            let source = app.buttons["vocabulary-source-" + word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
            XCTAssertTrue(source.waitForExistence(timeout: 5)); source.tap()
            XCTAssertTrue(app.buttons["排版"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["无法打开原文"].exists)
            if mode == "EPUB" { XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10)) }
            else { XCTAssertTrue(app.textViews["reader-text"].firstMatch.waitForExistence(timeout: 10)) }
            let image = XCTAttachment(screenshot: app.screenshot()); image.name = "vocabulary-source-" + mode; image.lifetime = .keepAlways; add(image)
            app.terminate()
        }
    }

}
