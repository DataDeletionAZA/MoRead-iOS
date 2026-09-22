import XCTest

final class ReadingTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func tapSettingsRow(_ title: String, in app: XCUIApplication) {
        let row = app.buttons[title]
        for _ in 0..<6 { if row.exists && row.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(row.exists && row.isHittable); row.tap()
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
        let reply = app.staticTexts["重点：森林；已核对两本书的已读原文。"]
        XCTAssertTrue(reply.waitForExistence(timeout: 15))
        app.buttons["来源 1"].tap(); XCTAssertTrue(app.staticTexts["Forest visible."].waitForExistence(timeout: 5)); app.buttons["完成"].tap()
        app.buttons["来源 2"].tap(); XCTAssertTrue(app.staticTexts["Harbor."].waitForExistence(timeout: 5)); app.buttons["完成"].tap()
        app.buttons["重点书籍"].tap(); toggle("森林"); toggle("海岸"); app.buttons["保存"].tap()
        app.buttons["重新生成"].tap(); XCTAssertTrue(reply.waitForExistence(timeout: 15))
        app.buttons["重点书籍"].tap(); XCTAssertEqual(app.switches["focus-book-森林"].value as? String, "1"); XCTAssertEqual(app.switches["focus-book-海岸"].value as? String, "0")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Per-book-reading-scopes"; shot.lifetime = .keepAlways; add(shot)
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
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library"]
        app.launchEnvironment["MOREAD_TEST_SPEECH_AUDIO"] = wave.base64EncodedString()
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        app.buttons["听书"].tap(); app.buttons["speech-start"].tap()
        let playback = app.buttons["speech-play-pause"]
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '暂停' AND enabled == true"), object: playback)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 20), .completed)
        playback.tap(); XCTAssertEqual(playback.label, "继续")
        app.buttons["speech-timer"].tap(); app.buttons["按章节"].tap(); app.buttons["本章结束"].tap()
        app.buttons["speech-next-chapter"].tap()
        XCTAssertTrue(app.buttons["speech-timer"].label.contains("还剩 1 章"))
        XCTAssertEqual(playback.label, "继续"); playback.tap()
        XCTAssertTrue(app.staticTexts["speech-stop-reason"].waitForExistence(timeout: 40))
        XCTAssertEqual(app.staticTexts["speech-stop-reason"].label, "定时结束")
        XCTAssertFalse(app.alerts["需要处理"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
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
    }
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
