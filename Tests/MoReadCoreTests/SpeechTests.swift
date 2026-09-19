import XCTest
@testable import MoReadCore

final class SpeechTests: XCTestCase {
    func testSpeechAdvancesAndKeepsUnicodeOffsets() {
        let text = "  雨停了。😀她打开书。\n第二段。"
        var offset = 0
        var spoken = ""
        while let segment = SpeechText.next(in: text, from: offset) {
            XCTAssertGreaterThan(segment.end, offset)
            XCTAssertEqual((text as NSString).substring(with: NSRange(location: segment.offset, length: segment.end - segment.offset)), segment.text)
            spoken += segment.text; offset = segment.end
        }
        XCTAssertEqual(spoken.replacingOccurrences(of: "\n", with: "").trimmingCharacters(in: .whitespaces), "雨停了。😀她打开书。第二段。")
        XCTAssertNil(SpeechText.next(in: " \n", from: 0))
    }
}
