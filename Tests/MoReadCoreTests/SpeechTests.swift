import XCTest
@testable import MoReadCore

final class SpeechTests: XCTestCase {
    func testListeningTimerCountsOnlyPlaybackAndNaturalChapters() throws {
        var timed = ListeningTimer(minutes: 1)
        timed.elapse(12.5, playing: true); XCTAssertEqual(timed.remainingSeconds, 47.5)
        timed.elapse(120, playing: false); XCTAssertEqual(timed.remainingSeconds, 47.5)
        timed.elapse(-100, playing: true); timed.elapse(.infinity, playing: true)
        XCTAssertEqual(timed.remainingSeconds, 47.5)
        timed.completeChapter(); XCTAssertFalse(timed.expired)
        timed.elapse(80, playing: true); XCTAssertTrue(timed.expired); XCTAssertEqual(timed.remainingSeconds, 0)
        var chapters = ListeningTimer(chapters: 2)
        chapters.elapse(3600, playing: true); XCTAssertFalse(chapters.expired)
        chapters.completeChapter(); XCTAssertEqual(chapters.remainingChapters, 1)
        chapters.completeChapter(); XCTAssertTrue(chapters.expired)
        chapters.completeChapter(); XCTAssertEqual(chapters.remainingChapters, 0)
        XCTAssertEqual(ListeningTimer(minutes: Int.max).remainingSeconds, 86400)
        XCTAssertEqual(ListeningTimer(chapters: -1).remainingChapters, 1)
        var settings = SpeechPreferences(); settings.rate = .nan; settings.pitch = 100; settings.voiceIdentifier = "voice-id"
        let valid = settings.validated()
        XCTAssertEqual(valid.rate, 0.45); XCTAssertEqual(valid.pitch, 2)
        XCTAssertEqual(try JSONDecoder().decode(SpeechPreferences.self, from: JSONEncoder().encode(valid)), valid)
    }
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
