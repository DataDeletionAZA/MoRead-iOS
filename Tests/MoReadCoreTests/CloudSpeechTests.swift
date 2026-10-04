import XCTest
@testable import MoReadCore

final class CloudSpeechTests: XCTestCase {
    private var audio: Data { Data([73, 68, 51] + Array(repeating: UInt8(0), count: 30)) }
    func testMimoPreservesTextAndRejectsIncompleteAudio() throws {
        var s = CloudSpeechSettings(); s.preset(.mimo)
        s.instructions = "A gentle narrator"; s.emotion = "happy"; s.speed = 1.2
        let text = "她说：「雨停了。」😀"
        let request = try CloudSpeechClient.request(settings: s, key: "local-test", text: text)
        XCTAssertEqual(request.url?.absoluteString, "https://api.xiaomimimo.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-test")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.last, ["role": "assistant", "content": text])
        XCTAssertTrue(messages.first?["content"]?.contains("A gentle narrator") == true)
        XCTAssertEqual((body["audio"] as? [String: String])?["voice"], "mimo_default")
        XCTAssertEqual((body["audio"] as? [String: String])?["format"], "wav")
        s.model += "-voicedesign"; s.voice = ""
        let design = try CloudSpeechClient.request(settings: s, key: "local-test", text: text)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: design.httpBody!) as? [String: Any])
        XCTAssertNil((fields["audio"] as? [String: Any])?["voice"])
        XCTAssertEqual((fields["audio"] as? [String: Any])?["optimize_text_preview"] as? Bool, false)
        s.instructions = ""; s.emotion = ""; s.speed = 1
        XCTAssertThrowsError(try CloudSpeechClient.request(settings: s, key: "local-test", text: text))
        func reply(_ reason: String, _ encoded: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": reason, "message": ["audio": ["data": encoded]]]]])
        }
        XCTAssertEqual(try MimoSpeech.decode(reply("stop", audio.base64EncodedString())), audio)
        for reason in ["length", "content_filter"] { XCTAssertThrowsError(try MimoSpeech.decode(reply(reason, audio.base64EncodedString()))) }
        for invalid in ["", "%%%", Data("<html>not audio</html>".utf8).base64EncodedString()] { XCTAssertThrowsError(try MimoSpeech.decode(reply("stop", invalid))) }
        XCTAssertEqual(try JSONDecoder().decode(CloudSpeechSettings.self, from: JSONEncoder().encode(s)), s)
    }
    func testFishModelHeadersStyleTagsAndCacheSeparation() throws {
        var s = CloudSpeechSettings(); s.preset(.fish); s.voice = " voice-id "; s.emotion = "fearful"; s.instructions = "[gently]"; s.volume = 0.5
        let request = try CloudSpeechClient.request(settings: s, key: "local-test", text: "原文😀")
        XCTAssertEqual(request.url?.absoluteString, "https://api.fish.audio/v1/tts")
        XCTAssertEqual(request.value(forHTTPHeaderField: "model"), "s2.1-pro")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertNil(body["model"]); XCTAssertEqual(body["reference_id"] as? String, "voice-id")
        XCTAssertEqual(body["text"] as? String, "[scared][gently]原文😀")
        XCTAssertEqual((body["prosody"] as? [String: Double])?["volume"] ?? 0, -6.0206, accuracy: 0.001)
        let key = try CloudSpeechClient.cacheKey(settings: s, text: "原文😀")
        s.model = "s2-pro"
        XCTAssertNotEqual(key, try CloudSpeechClient.cacheKey(settings: s, text: "原文😀"))
        s.model = "s1"; s.instructions = "Do not read this direction aloud"; s.voice = ""; s.volume = 0
        XCTAssertEqual(s.validated().volume, 0.1)
        let legacy = try CloudSpeechClient.request(settings: s, key: "local-test", text: "原文😀")
        let legacyBody = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy.httpBody!) as? [String: Any])
        XCTAssertEqual(legacyBody["text"] as? String, "(scared)原文😀"); XCTAssertNil(legacyBody["reference_id"])
        XCTAssertEqual((legacyBody["prosody"] as? [String: Double])?["volume"], -20)
        XCTAssertEqual(try JSONDecoder().decode(CloudSpeechSettings.self, from: JSONEncoder().encode(s)), s)
        s.model = "s2-pro\nInjected: value"
        XCTAssertThrowsError(try CloudSpeechClient.request(settings: s, key: "local-test", text: "原文"))
    }
    func testRequestsResponsesAndDownloadCredentials() throws {
        var settings = CloudSpeechSettings()
        let request = try CloudSpeechClient.request(settings: settings, key: "test-key", text: "雨停了。")
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/speech")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["input"] as? String, "雨停了。")
        XCTAssertEqual(body["response_format"] as? String, "mp3")
        let firstKey = try CloudSpeechClient.cacheKey(settings: settings, text: "雨停了。")
        settings.voice = "coral"
        XCTAssertNotEqual(firstKey, try CloudSpeechClient.cacheKey(settings: settings, text: "雨停了。"))
        settings.baseURL = "http://example.com/v1"
        XCTAssertThrowsError(try CloudSpeechClient.request(settings: settings, key: "test-key", text: "文本"))
        settings.preset(.miniMax); settings.groupID = "a&b"
        let mini = try CloudSpeechClient.request(settings: settings, key: "test-key", text: "文本")
        XCTAssertEqual(URLComponents(url: mini.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a&b")
        let miniBody = try XCTUnwrap(JSONSerialization.jsonObject(with: mini.httpBody!) as? [String: Any])
        XCTAssertEqual(miniBody["output_format"] as? String, "hex")
        XCTAssertEqual((miniBody["voice_setting"] as? [String: Any])?["voice_id"] as? String, settings.voice)
        let hex = audio.map { String(format: "%02X", $0) }.joined()
        let reply = try JSONSerialization.data(withJSONObject: ["base_resp": ["status_code": 0], "data": ["audio": hex]])
        XCTAssertEqual(try CloudSpeechClient.decodeMiniMax(reply), audio)
        for invalid in ["0", "gg", "<html>"] {
            XCTAssertThrowsError(try CloudSpeechClient.decodeMiniMax(JSONSerialization.data(withJSONObject: ["base_resp": ["status_code": 0], "data": ["audio": invalid]])))
        }
        XCTAssertThrowsError(try CloudSpeechClient.decodeMiniMax(JSONSerialization.data(withJSONObject: ["base_resp": ["status_code": false], "data": ["audio": hex]])))
        settings.preset(.gmi)
        let gmi = try CloudSpeechClient.request(settings: settings, key: "test-key", text: "文本")
        XCTAssertEqual(gmi.url?.path, "/api/v1/ie/requestqueue/apikey/requests")
        let queued = try CloudSpeechClient.queuedResponse(Data(#"{"request_id":"job-1","status":"success"}"#.utf8))
        XCTAssertEqual(queued.id, "job-1"); XCTAssertNil(queued.audio)
        let result = try CloudSpeechClient.queuedResponse(Data(#"{"status":"success","payload":{"url":"https://bad.example/"},"outcome":{"media_urls":[{"url":"https://audio.example/file.mp3"}]}}"#.utf8))
        XCTAssertEqual(result.audio, "https://audio.example/file.mp3")
        XCTAssertThrowsError(try CloudSpeechClient.queuedResponse(Data(#"{"status":"failed","outcome":{"url":"https://audio.example/file.mp3"}}"#.utf8)))
        XCTAssertNil(try CloudSpeechClient.downloadRequest(result.audio!, original: gmi).value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(try CloudSpeechClient.downloadRequest("https://console.gmicloud.ai/audio.mp3", original: gmi).value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertNil(try CloudSpeechClient.downloadRequest("https://console.gmicloud.ai:444/audio.mp3", original: gmi).value(forHTTPHeaderField: "Authorization"))
        XCTAssertThrowsError(try CloudSpeechClient.downloadRequest("http://audio.example/file.mp3", original: gmi))
        XCTAssertThrowsError(try CloudSpeechClient.downloadRequest("https://key@audio.example/file.mp3", original: gmi))
        XCTAssertThrowsError(try CloudSpeechClient.validateAudio(Data("<html>not audio</html>".utf8)))
    }
    func testCacheSurvivesReloadAndBodyCleanupRemovesAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let book = try store.importBook(title: "音频", chapters: TextImporter.chapters("第一章 雨\n雨停了。"))
        var settings = CloudSpeechSettings(); settings.speed = .infinity; settings.cacheMegabytes = Int.max
        XCTAssertEqual(settings.validated().speed, 1); XCTAssertEqual(settings.validated().cacheMegabytes, 2048)
        XCTAssertEqual(try JSONDecoder().decode(CloudSpeechSettings.self, from: JSONEncoder().encode(settings.validated())), settings.validated())
        let key = try CloudSpeechClient.cacheKey(settings: settings, text: "雨停了。")
        try SpeechAudioCache.write(audio, in: store.directory(book.id), key: key, megabytes: 50)
        XCTAssertEqual(try SpeechAudioCache.read(in: store.directory(book.id), key: key), audio)
        XCTAssertEqual(try SpeechAudioCache.size(root: root), Int64(audio.count))
        XCTAssertThrowsError(try SpeechAudioCache.file(in: root, key: "../book.json"))
        let cached = try SpeechAudioCache.file(in: store.directory(book.id), key: key)
        try Data("broken".utf8).write(to: cached)
        XCTAssertNil(try SpeechAudioCache.read(in: store.directory(book.id), key: key))
        try SpeechAudioCache.write(audio, in: store.directory(book.id), key: key, megabytes: 50)
        for index in 1...3 {
            let url = try SpeechAudioCache.file(in: store.directory(book.id), key: String(repeating: String(index), count: 64))
            _ = FileManager.default.createFile(atPath: url.path, contents: audio)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 18 * 1024 * 1024); try handle.close()
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: url.path)
        }
        try SpeechAudioCache.write(audio, in: store.directory(book.id), key: key, megabytes: 50)
        XCTAssertLessThanOrEqual(try SpeechAudioCache.size(root: root), 50 * 1024 * 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try SpeechAudioCache.file(in: store.directory(book.id), key: String(repeating: "1", count: 64)).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try SpeechAudioCache.file(in: store.directory(book.id), key: String(repeating: "3", count: 64)).path))
        _ = try store.clearBody(book)
        XCTAssertEqual(try SpeechAudioCache.size(root: root), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path))
    }
}
