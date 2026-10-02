import XCTest
@testable import MoReadCore

final class GeminiSpeechTests: XCTestCase {
    func testRequestKeepsTranscriptSeparateAndDisablesStorage() throws {
        var s = CloudSpeechSettings(); s.preset(.gemini)
        s.model = "models/gemini-3.8-flash-tts"; s.voice = "voice_custom"; s.instructions = "温柔地讲故事"
        s.speed = 1.25; s.volume = 0.5; s.pitch = -2; s.emotion = "calm"
        let text = "林遥说：晚安。"
        for base in ["https://speech.example", "https://speech.example/v1", "https://speech.example/v1beta", "https://speech.example/v1beta/interactions", "https://speech.example/proxy/v1beta/"] {
            s.baseURL = base
            let request = try CloudSpeechClient.request(settings: s, key: "test-key", text: text)
            XCTAssertEqual(request.url?.path, base.contains("proxy") ? "/proxy/v1beta/interactions" : "/v1beta/interactions")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["store"] as? Bool, false); XCTAssertEqual(body["model"] as? String, "gemini-3.8-flash-tts")
            let part = try XCTUnwrap((body["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]).first!
            XCTAssertEqual(part["text"] as? String, text)
            let style = try XCTUnwrap((part["annotations"] as? [[String: String]])?.first?["style"])
            XCTAssertTrue(style.contains(s.instructions)); XCTAssertTrue(style.contains("1.25")); XCTAssertTrue(style.contains("calm"))
            XCTAssertEqual(((body["generation_config"] as? [String: Any])?["speech_config"] as? [[String: String]])?.first?["voice"], s.voice)
        }
        let key = try CloudSpeechClient.cacheKey(settings: s, text: text)
        s.instructions += "，轻声"; XCTAssertNotEqual(key, try CloudSpeechClient.cacheKey(settings: s, text: text))
        s.baseURL = "https://speech.example/?key=secret"; XCTAssertThrowsError(try CloudSpeechClient.request(settings: s, key: "key", text: text))
        XCTAssertEqual(Set(GeminiSpeech.voices.map(\.id)).count, 30)
    }

    func testAudioDecodingRejectsIncompleteResponsesAndSurvivesCache() throws {
        func response(_ bytes: Data, mime: String = "audio/L16;codec=pcm;rate=24000", status: String = "completed", count: Int = 1) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["status": status, "steps": [["type": "model_output", "content": Array(repeating: ["type": "audio", "data": bytes.base64EncodedString(), "mime_type": mime], count: count)]]])
        }
        let pcm = Data(repeating: 0, count: 480)
        let wave = try GeminiSpeech.decode(response(pcm))
        XCTAssertEqual(wave.count, pcm.count + 44); XCTAssertEqual(wave.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(Array(wave[24..<28]), [0xc0, 0x5d, 0, 0]); XCTAssertEqual(wave.suffix(pcm.count), pcm)
        XCTAssertEqual(try GeminiSpeech.decode(response(wave, mime: "audio/wav")), wave)
        for mime in ["", "audio/mp3", "audio/l16;rate=bad", "audio/pcm;rate=999999", "audio/pcm;channels=2", "audio/pcm;channels"] {
            XCTAssertThrowsError(try GeminiSpeech.decode(response(pcm, mime: mime)))
        }
        XCTAssertThrowsError(try GeminiSpeech.decode(response(Data([0]))))
        XCTAssertThrowsError(try GeminiSpeech.decode(response(Data())))
        XCTAssertThrowsError(try GeminiSpeech.decode(response(pcm, mime: "audio/wav")))
        XCTAssertThrowsError(try GeminiSpeech.decode(response(pcm, status: "in_progress")))
        XCTAssertThrowsError(try GeminiSpeech.decode(response(pcm, count: 2)))
        let malformed = Data(#"{"status":"completed","steps":[{"type":"model_output","content":[{"type":"audio","mime_type":"audio/wav","data":"@@@"}]}]}"#.utf8)
        XCTAssertThrowsError(try GeminiSpeech.decode(malformed))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let book = try store.importBook(title: "朗读", chapters: TextImporter.chapters("第一章 雨\n雨停了。"))
        var s = CloudSpeechSettings(); s.preset(.gemini)
        let key = try CloudSpeechClient.cacheKey(settings: s, text: "雨停了。")
        try SpeechAudioCache.write(wave, in: store.directory(book.id), key: key, megabytes: 50)
        XCTAssertEqual(try SpeechAudioCache.read(in: store.directory(book.id), key: key), wave)
        XCTAssertEqual(try JSONDecoder().decode(CloudSpeechSettings.self, from: JSONEncoder().encode(s)), s)
    }
}
