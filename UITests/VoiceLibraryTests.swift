import XCTest

final class VoiceLibraryUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<14 {
            if element.exists && element.frame.midY > 130 && element.frame.midY < app.frame.maxY - 90 && element.isHittable { return }
            if element.exists && element.frame.midY < 130 { app.swipeDown() } else { app.swipeUp() }
        }
        XCTFail("Control is not visible")
    }
    private func open(_ app: XCUIApplication) {
        XCTAssertTrue(app.tabBars.buttons["设置"].waitForExistence(timeout: 15)); app.tabBars.buttons["设置"].tap()
        let row = app.buttons["云端音色库"]; reveal(row, in: app); row.tap()
        XCTAssertTrue(app.buttons["voice-library-add"].waitForExistence(timeout: 5))
    }
    private func add(_ id: String, name: String, app: XCUIApplication) {
        app.buttons["voice-library-add"].coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap(); app.buttons["添加音色"].tap()
        app.textFields["voice-name"].tap(); app.textFields["voice-name"].typeText(name)
        app.textFields["voice-id"].tap(); app.textFields["voice-id"].typeText(id)
        app.textFields["voice-tags"].tap(); app.textFields["voice-tags"].typeText("narrator,warm")
        app.buttons["voice-save"].tap()
        let preview = app.buttons["voice-preview-" + id]; reveal(preview, in: app); XCTAssertTrue(preview.exists)
    }
    func testSaveSelectPinEditPresetsAndRestart() {
        executionTimeAllowance = 300
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library"]; app.launch(); open(app)
        add("alloy", name: "My narrator", app: app)
        app.buttons["voice-select-alloy"].tap()
        XCTAssertTrue(app.staticTexts["voices-message"].label.contains("My narrator"))
        app.buttons["voice-actions-alloy"].tap(); app.buttons["置顶"].tap()
        let pinned = app.switches["voices-pinned-only"]; reveal(pinned, in: app); pinned.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        app.buttons["voice-library-add"].coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap(); app.buttons["导入 Gemini 预设"].tap()
        XCTAssertEqual(app.staticTexts["voices-message"].label, "新增 30 个音色")
        app.buttons["voice-library-add"].coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap(); app.buttons["导入 Gemini 预设"].tap()
        XCTAssertEqual(app.staticTexts["voices-message"].label, "新增 0 个音色")
        let menu = app.buttons["voice-actions-alloy"]; reveal(menu, in: app); menu.tap(); app.buttons["编辑"].tap()
        let name = app.textFields["voice-name"]; name.tap(); name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "My narrator".count) + "Night voice")
        app.buttons["voice-save"].tap()
        XCTAssertTrue(app.staticTexts["Night voice"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); open(app)
        let filter = app.switches["voices-pinned-only"]; filter.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Night voice"].exists); XCTAssertTrue(app.staticTexts["当前声音"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "saved-cloud-voice-library"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["voice-actions-alloy"].tap(); app.buttons["删除"].tap(); app.alerts.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["Night voice"].exists)
        app.buttons["voice-actions-alloy"].tap(); app.buttons["删除"].tap(); app.alerts.buttons["删除"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["Night voice"])], timeout: 5), .completed)
        app.terminate(); app.launch(); open(app)
        XCTAssertFalse(app.staticTexts["Night voice"].exists)
    }
    func testOnlineCatalogImportFailureStopAndRestart() {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchEnvironment["MOREAD_TEST_SPEECH_SERVICE"] = "gemini"
        app.launchEnvironment["MOREAD_TEST_SPEECH_AUDIO"] = "catalog-configuration"
        func launch(_ flags: [String] = []) {
            app.launchArguments = ["--ui-testing", "--simulate-voice-catalog"] + flags; app.launch(); open(app)
        }
        func load() { app.buttons["voice-library-add"].coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap(); app.buttons["读取 Gemini 在线音色"].tap() }
        func status(_ text: String) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: app.staticTexts["voice-catalog-status"])], timeout: 10), .completed)
        }
        launch(["--reset-test-library"]); load(); status("已读取 2 个在线音色，新增 2 个")
        load(); status("新增 0 个")
        let entry = app.buttons["voice-actions-voice_first"]; reveal(entry, in: app); entry.tap(); app.buttons["编辑"].tap()
        let name = app.textFields["voice-name"]; name.tap(); name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Online narrator".count) + "My online voice")
        app.buttons["voice-save"].tap(); load(); status("新增 0 个")
        XCTAssertTrue(app.staticTexts["My online voice"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "online-voice-catalog-import"; shot.lifetime = .keepAlways; add(shot)
        app.terminate(); launch(["--failed-voice-catalog"]); load(); status("在线音色服务暂不可用")
        reveal(entry, in: app); XCTAssertTrue(app.staticTexts["My online voice"].exists)
        app.terminate(); launch(["--empty-voice-catalog"]); load(); status("服务未返回音色")
        reveal(entry, in: app); XCTAssertTrue(app.staticTexts["My online voice"].exists)
        app.terminate(); launch(["--slow-voice-catalog"]); load()
        let stop = app.buttons["voice-catalog-stop"]; XCTAssertTrue(stop.waitForExistence(timeout: 5)); stop.tap(); status("已停止读取")
        load(); XCTAssertTrue(stop.waitForExistence(timeout: 5))
        app.navigationBars["云端音色库"].buttons.firstMatch.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap(); app.buttons["云端音色库"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: app.staticTexts["voice-catalog-status"])], timeout: 11), .timedOut)
        reveal(entry, in: app); XCTAssertTrue(app.staticTexts["My online voice"].exists)
    }
    func testChoosingVoiceKeepsDraftUntilSettingsSaved() {
        executionTimeAllowance = 240
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library"]; app.launch(); open(app)
        add("nova", name: "New voice", app: app)
        app.navigationBars["云端音色库"].buttons.firstMatch.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        func settings() { let row = app.buttons["云端声音与缓存"]; reveal(row, in: app); row.tap() }
        func choose() {
            let row = app.buttons["从音色库选择"]; reveal(row, in: app); row.tap()
            let use = app.buttons["voice-select-nova"]; reveal(use, in: app); use.tap()
        }
        settings()
        let voice = app.textFields["cloud-speech-voice"]; reveal(voice, in: app); XCTAssertEqual(voice.value as? String, "alloy")
        choose(); reveal(voice, in: app); XCTAssertEqual(voice.value as? String, "nova")
        let picker = app.buttons["从音色库选择"]; reveal(picker, in: app); picker.tap()
        let preview = app.buttons["voice-preview-nova"]; reveal(preview, in: app); preview.tap()
        XCTAssertEqual(app.staticTexts["voices-message"].label, "请先返回并保存云端声音设置，再试听。")
        XCTAssertFalse(app.staticTexts["voice-preview-status"].exists)
        app.navigationBars["云端音色库"].buttons.firstMatch.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        app.navigationBars["云端声音与缓存"].buttons.firstMatch.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap(); settings()
        reveal(voice, in: app); XCTAssertEqual(voice.value as? String, "alloy")
        choose()
        let save = app.buttons["save-cloud-speech"]; reveal(save, in: app); save.tap()
        XCTAssertTrue(app.staticTexts["cloud-speech-saved"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["设置"].waitForExistence(timeout: 15)); app.tabBars.buttons["设置"].tap(); settings()
        reveal(voice, in: app); XCTAssertEqual(voice.value as? String, "nova")
    }
    func testPreviewPlaybackStopFailureAndLeaving() {
        executionTimeAllowance = 300
        var wave = Data()
        func word<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wave.append(contentsOf: $0) } }
        let samples = 64000
        wave.append(Data("RIFF".utf8)); word(UInt32(36 + samples * 2)); wave.append(Data("WAVEfmt ".utf8)); word(UInt32(16))
        word(UInt16(1)); word(UInt16(1)); word(UInt32(8000)); word(UInt32(16000)); word(UInt16(2)); word(UInt16(16))
        wave.append(Data("data".utf8)); word(UInt32(samples * 2))
        for index in 0..<samples { word(Int16(sin(Double(index) * 2 * .pi * 220 / 8000) * 100)) }
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library"]
        app.launchEnvironment["MOREAD_TEST_VOICE_AUDIO"] = wave.base64EncodedString(); app.launch(); open(app)
        add("alloy", name: "Normal voice", app: app)
        app.buttons["voice-preview-alloy"].tap()
        let status = app.staticTexts["voice-preview-status"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "正在试听"), object: status)], timeout: 10), .completed)
        app.buttons["voice-preview-alloy"].tap(); XCTAssertFalse(status.exists)
        add("failure", name: "Failed voice", app: app)
        let fail = app.buttons["voice-preview-failure"]; reveal(fail, in: app); fail.tap()
        XCTAssertTrue(app.staticTexts["voice-preview-error"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["voice-preview-error"].label, "试听服务暂不可用")
        add("slow", name: "Slow voice", app: app)
        let slow = app.buttons["voice-preview-slow"]; reveal(slow, in: app); slow.tap()
        XCTAssertTrue(status.waitForExistence(timeout: 5)); slow.tap(); XCTAssertFalse(status.exists)
        slow.tap(); XCTAssertTrue(status.waitForExistence(timeout: 5))
        app.navigationBars["云端音色库"].buttons.firstMatch.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        app.buttons["云端音色库"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: status)], timeout: 11), .timedOut)
        XCTAssertFalse(app.staticTexts["voice-preview-error"].exists)
    }
}
