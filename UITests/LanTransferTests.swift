import XCTest

final class LanTransferUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    private func open(_ app: XCUIApplication) -> (URL, String) {
        XCTAssertTrue(app.buttons["书架选项"].waitForExistence(timeout: 15)); app.buttons["书架选项"].tap(); app.buttons["lan-open"].tap()
        let address = app.staticTexts["lan-address"].firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        let code = app.staticTexts["lan-code"].label.filter(\.isNumber)
        XCTAssertEqual(code.count, 6)
        return (URL(string: address.label)!, code)
    }
    private func send(_ address: URL, code: String, name: String, text: String) async throws -> Int {
        var components = URLComponents(url: address, resolvingAgainstBaseURL: false)!; components.host = "127.0.0.1"; components.path = "/upload"
        var request = URLRequest(url: components.url!); request.httpMethod = "POST"; request.timeoutInterval = 5
        request.httpBody = Data(text.utf8); request.setValue(code, forHTTPHeaderField: "X-MoRead-Code")
        request.setValue(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), forHTTPHeaderField: "X-File-Name")
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as! HTTPURLResponse).statusCode
    }
    @MainActor func testRealTransferRetainsFilesThenImportsAfterRestart() async throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library"]; app.launch()
        let (address, code) = open(app)
        let text = "第一章 远方\n电脑送来的故事，终于在手机上打开。\n第二章 回信\n这是完整传输的第二章。\n"
        let first = try await send(address, code: code, name: "LANBookA.txt", text: text); XCTAssertEqual(first, 200)
        let second = try await send(address, code: code, name: "LANBookB.txt", text: text); XCTAssertEqual(second, 200)
        XCTAssertTrue(app.otherElements["lan-received-LANBookA.txt"].exists || app.staticTexts["LANBookA.txt"].exists)
        let remove = app.buttons["移除待导入文件 LANBookB.txt"]
        for _ in 0..<4 where !remove.isHittable { app.swipeUp() }
        XCTAssertTrue(remove.isHittable); remove.tap()
        XCTAssertFalse(app.staticTexts["LANBookB.txt"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "LAN-received-book"; shot.lifetime = .keepAlways; add(shot)
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch(); _ = open(app)
        XCTAssertTrue(app.staticTexts["LANBookA.txt"].exists)
        app.buttons["lan-import"].tap()
        XCTAssertTrue(app.textFields["import-title"].waitForExistence(timeout: 15)); XCTAssertEqual(app.textFields["import-title"].value as? String, "LANBookA")
        app.buttons["confirm-text-import"].tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "LANBookA")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        XCTAssertTrue(app.textViews["reader-text"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue((app.textViews["reader-text"].firstMatch.value as? String)?.contains("电脑送来的故事") == true)
        app.terminate(); app.launch(); _ = open(app)
        XCTAssertFalse(app.staticTexts["LANBookA.txt"].exists); XCTAssertFalse(app.buttons["lan-import"].exists)
    }
    @MainActor func testLeavingClosesListenerAndOpeningAgainReceives() async throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-test-library"]; app.launch()
        let (address, code) = open(app); app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["书架选项"].waitForExistence(timeout: 5))
        do { _ = try await send(address, code: code, name: "closed.txt", text: "closed"); XCTFail("Listener should be closed") } catch {}
        let (reopened, newCode) = open(app)
        let status = try await send(reopened, code: newCode, name: "restart.txt", text: "A new transfer after reopening.")
        XCTAssertEqual(status, 200); XCTAssertTrue(app.staticTexts["restart.txt"].waitForExistence(timeout: 5))
        app.buttons["lan-toggle"].tap()
        XCTAssertTrue(app.buttons["开启接收"].waitForExistence(timeout: 5)); XCTAssertTrue(app.staticTexts["restart.txt"].exists)
    }
}
