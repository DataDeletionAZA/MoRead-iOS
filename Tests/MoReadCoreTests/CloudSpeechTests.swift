import XCTest
@testable import MoReadCore

final class CloudSpeechTests: XCTestCase {
    private var audio: Data { Data([73, 68, 51] + Array(repeating: UInt8(0), count: 30)) }
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
