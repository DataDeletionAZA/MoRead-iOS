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
    func testListeningCleanupKeepsSourceCoordinatesAndAudioIdentity() throws {
        var ad = TextReplacementRule(); ad.pattern = "广告：请关注。"; ad.isRegex = false; ad.forListeningOnly = true
        var name = TextReplacementRule(); name.pattern = "林遥"; name.replacement = "林小遥"; name.forListeningOnly = true; name.isRegex = false
        var body = name; body.forListeningOnly = false; body.replacement = "正文规则"
        let text = "广告：请关注。\n😀林遥打开书店。"
        let first = try XCTUnwrap(SpeechText.next(in: text, from: 0))
        XCTAssertTrue(try first.purified(rules: [ad, name]).text.isEmpty)
        let source = try XCTUnwrap(SpeechText.next(in: text, from: first.end))
        let cleaned = try source.purified(rules: [ad, name, body])
        XCTAssertEqual(cleaned.text, "😀林小遥打开书店。")
        XCTAssertEqual(cleaned.offset, source.offset); XCTAssertEqual(cleaned.end, source.end)
        XCTAssertEqual(cleaned.sourceRange(forSpokenRange: NSRange(location: 4, length: 2)), NSRange(location: source.offset, length: source.end - source.offset))
        XCTAssertTrue(cleaned.transformed)
        XCTAssertFalse(try source.purified(rules: [body]).transformed)
        XCTAssertEqual(source.sourceRange(forSpokenRange: NSRange(location: 1, length: 1)), NSRange(location: source.offset, length: 0))
        XCTAssertEqual(source.sourceRange(forSpokenRange: NSRange(location: Int.max, length: Int.max)), NSRange(location: source.end, length: 0))
        let settings = CloudSpeechSettings()
        XCTAssertNotEqual(try CloudSpeechClient.cacheKey(settings: settings, text: source.text), try CloudSpeechClient.cacheKey(settings: settings, text: cleaned.text))
        var disabled = name; disabled.enabled = false
        XCTAssertEqual(try source.purified(rules: [disabled]), source)
        name.replacement = String(repeating: "字", count: 4000)
        let doubled = try XCTUnwrap(SpeechText.next(in: "林遥和林遥。", from: 0))
        XCTAssertThrowsError(try doubled.purified(rules: [name]))
    }

}
