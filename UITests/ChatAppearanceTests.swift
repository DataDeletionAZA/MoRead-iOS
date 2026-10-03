import XCTest

final class ChatAppearanceTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    private func openEditor(_ app: XCUIApplication, name: String = "阿翎") {
        app.tabBars.buttons["伴读"].tap()
        app.staticTexts["角色与世界书"].tap()
        let edit = app.buttons["edit-character-" + name]
        XCTAssertTrue(edit.waitForExistence(timeout: 10)); edit.tap()
        app.buttons["edit-chat-appearance"].tap()
        XCTAssertTrue(app.segmentedControls["chat-bubble-style"].waitForExistence(timeout: 10))
    }
    private func closeEditor(_ app: XCUIApplication, save: Bool) {
        app.navigationBars["聊天外观"].buttons.firstMatch.tap()
        app.buttons[save ? "保存" : "取消"].tap(); app.buttons["完成"].tap()
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        let visible = app.frame.insetBy(dx: 0, dy: 50)
        func ready() -> Bool { element.exists && element.isHittable && visible.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) }
        for _ in 0..<7 {
            if ready() { break }
            if element.exists && element.frame.midY < visible.minY { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(ready())
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testCharacterAppearancePreviewPersistenceAndSharedAssets() {
        executionTimeAllowance = 420
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-library", "--chat-appearance-sample", "--import-test-font"]
        app.launch()
        XCTAssertTrue(app.buttons["add-sample"].waitForExistence(timeout: 15))
        openEditor(app)
        for label in ["圆角", "描边", "纸片", "玻璃"] {
            app.segmentedControls["chat-bubble-style"].buttons[label].tap()
            screenshot(app, "chat-preview-" + label)
        }
        app.buttons["chat-background-picker"].tap()
        let image = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "select-image-")).firstMatch
        reveal(image, app: app); image.tap()
        app.sliders["chat-background-dim"].adjust(toNormalizedSliderPosition: 0.2)
        let font = app.buttons["chat-font"]; reveal(font, app: app); font.tap()
        let custom = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Noto")).firstMatch
        XCTAssertTrue(custom.waitForExistence(timeout: 5)); custom.tap()
        let slider = app.sliders["chat-font-slider"]; reveal(slider, app: app); slider.adjust(toNormalizedSliderPosition: 0.5)
        let scale = app.steppers["chat-font-scale"]
        let increase = scale.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "Increment")).firstMatch
        reveal(increase, app: app); increase.tap()
        let selectedScale = scale.label
        XCTAssertFalse(selectedScale.contains("100%"))
        closeEditor(app, save: true)
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "阿翎的书店话题")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["雨停了，书店里还亮着灯。"].waitForExistence(timeout: 10)); screenshot(app, "chat-custom-background-font-glass")
        app.buttons["返回"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "夏夏的书店话题")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["雨停了，书店里还亮着灯。"].waitForExistence(timeout: 10)); screenshot(app, "chat-other-character-default")
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        openEditor(app)
        XCTAssertTrue(app.segmentedControls["chat-bubble-style"].buttons["玻璃"].isSelected)
        reveal(font, app: app); XCTAssertTrue(font.label.contains("Noto"))
        reveal(increase, app: app); XCTAssertEqual(scale.label, selectedScale)
        let reset = app.buttons["chat-appearance-reset"]; reveal(reset, app: app); reset.tap()
        closeEditor(app, save: false)
        openEditor(app)
        XCTAssertTrue(app.segmentedControls["chat-bubble-style"].buttons["玻璃"].isSelected)
        closeEditor(app, save: false)
        app.tabBars.buttons["设置"].tap()
        let library = app.buttons["图片库"]; reveal(library, app: app); library.tap()
        let selectReader = app.buttons["设为阅读背景"]; reveal(selectReader, app: app); selectReader.tap()
        screenshot(app, "shared-image-library")
        app.navigationBars["图片库"].buttons.firstMatch.tap()
        app.tabBars.buttons["书架"].tap(); app.buttons["add-sample"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "雨后的书店")).firstMatch.tap()
        XCTAssertTrue(app.textViews["reader-text"].firstMatch.waitForExistence(timeout: 10)); screenshot(app, "shared-image-reading")
        app.terminate(); app.launch()
        app.tabBars.buttons["设置"].tap(); reveal(library, app: app); library.tap()
        let remove = app.buttons["删除图片"]; reveal(remove, app: app); remove.tap(); app.sheets.buttons["删除图片"].tap()
        XCTAssertTrue(app.buttons["设为阅读背景"].waitForNonExistence(timeout: 5))
        app.navigationBars["图片库"].buttons.firstMatch.tap()
        let fonts = app.buttons["字体库"]; reveal(fonts, app: app); fonts.tap()
        let removeFont = app.buttons["删除字体"]; reveal(removeFont, app: app); removeFont.tap(); app.sheets.buttons["删除字体"].tap()
        XCTAssertTrue(removeFont.waitForNonExistence(timeout: 5))
        app.navigationBars["字体库"].buttons.firstMatch.tap()
        app.tabBars.buttons["伴读"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "阿翎的书店话题")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["雨停了，书店里还亮着灯。"].waitForExistence(timeout: 10)); screenshot(app, "chat-deleted-background-fallback")
        app.buttons["返回"].tap()
        openEditor(app); reveal(reset, app: app); reset.tap(); closeEditor(app, save: true)
        openEditor(app)
        XCTAssertTrue(app.segmentedControls["chat-bubble-style"].buttons["圆角"].isSelected)
        XCTAssertFalse(app.buttons["不使用背景图"].exists)
    }
}
