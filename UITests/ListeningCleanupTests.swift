import XCTest

final class ListeningCleanupTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    func testPurifiedPlaybackPreviewAndEmptyChapterTimer() {
        executionTimeAllowance = 300
        var wave = Data()
        func word<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wave.append(contentsOf: $0) } }
        let samples = 48000
        wave.append(Data("RIFF".utf8)); word(UInt32(36 + samples * 2)); wave.append(Data("WAVEfmt ".utf8)); word(UInt32(16))
        word(UInt16(1)); word(UInt16(1)); word(UInt32(8000)); word(UInt32(16000)); word(UInt16(2)); word(UInt16(16))
        wave.append(Data("data".utf8)); word(UInt32(samples * 2))
        for index in 0..<samples { word(Int16(sin(Double(index) * 2 * .pi * 220 / 8000) * 100)) }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--listening-cleanup-sample"]
        app.launchEnvironment["MOREAD_TEST_SPEECH_AUDIO"] = wave.base64EncodedString()
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15)); app.buttons["add-sample"].tap()
        func openBook() { app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap() }
        func reveal(_ item: XCUIElement) { for _ in 0..<4 where !item.isHittable { app.swipeUp() }; XCTAssertTrue(item.isHittable) }
        func replace(_ item: XCUIElement, text: String) {
            item.tap(); let old = item.value as? String ?? ""
            item.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + text)
        }
        func addRule(_ pattern: String, _ replacement: String = "") {
            app.buttons["cleanup-add"].tap()
            let input = app.descendants(matching: .any)["cleanup-pattern"]
            XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText(pattern)
            if !replacement.isEmpty { let field = app.descendants(matching: .any)["cleanup-replacement"]; field.tap(); field.typeText(replacement) }
            app.buttons["cleanup-save-rule"].tap()
        }
        openBook(); app.buttons["听书"].tap()
        let cleanup = app.buttons["listening-cleanup-open"]; reveal(cleanup); cleanup.tap()
        addRule("广告：请关注。"); addRule("林遥", "小遥")
        let sample = app.descendants(matching: .any)["listening-cleanup-sample"]
        reveal(sample); replace(sample, text: "广告：请关注。\n林遥拿起书。")
        let preview = app.buttons["listening-cleanup-preview"]; reveal(preview); preview.tap()
        let result = app.staticTexts["listening-cleanup-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10)); XCTAssertEqual(result.label, "小遥拿起书。")
        app.navigationBars["听书文字净化"].buttons.firstMatch.tap()
        app.buttons["speech-start"].tap()
        let playback = app.buttons["speech-play-pause"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ AND enabled == YES", "暂停"), object: playback)], timeout: 20), .completed)
        XCTAssertEqual(app.staticTexts["speech-spoken-text"].label, "😀小遥打开书店。")
        playback.tap()
        app.buttons["speech-timer"].tap(); app.buttons["按章节"].tap(); app.buttons["读完 2 章"].tap()
        playback.tap()
        XCTAssertTrue(app.staticTexts["speech-stop-reason"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["speech-stop-reason"].label, "定时结束")
        XCTAssertFalse(app.alerts["需要处理"].exists)
        app.buttons["speech-start"].tap()
        let spoken = app.staticTexts["speech-spoken-text"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "小遥拿起书。"), object: spoken)], timeout: 15), .completed)
        app.buttons["speech-play-pause"].tap()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "listening-cleaned-speech"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["结束听书"].tap(); app.buttons["完成"].tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "林遥拿起书。")).firstMatch.waitForExistence(timeout: 10))
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); openBook(); app.buttons["听书"].tap(); reveal(cleanup); cleanup.tap()
        XCTAssertEqual(app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "cleanup-enable-")).count, 2)
    }
}
