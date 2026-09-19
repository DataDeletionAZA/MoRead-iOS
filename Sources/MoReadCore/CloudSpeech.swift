import Foundation
import CryptoKit

public enum SpeechService: String, Codable, CaseIterable, Sendable {
    case openAI, miniMax, gmi
    public var label: String { switch self { case .openAI: return "OpenAI 兼容"; case .miniMax: return "MiniMax"; case .gmi: return "GMI Cloud" } }
}

public struct CloudSpeechSettings: Codable, Equatable, Sendable {
    public var id = UUID()
    public var enabled = false
    public var service: SpeechService = .openAI
    public var baseURL = "https://api.openai.com/v1"
    public var model = "gpt-4o-mini-tts"
    public var voice = "alloy"
    public var speed: Double = 1
    public var volume: Double = 1
    public var pitch = 0
    public var emotion = ""
    public var instructions = ""
    public var groupID = ""
    public var maximumCharacters = 400
    public var cacheMegabytes = 300
    public init() {}
    public mutating func preset(_ service: SpeechService) {
        self.service = service; speed = 1; volume = 1; pitch = 0; emotion = ""; instructions = ""; groupID = ""
        switch service {
        case .openAI: baseURL = "https://api.openai.com/v1"; model = "gpt-4o-mini-tts"; voice = "alloy"
        case .miniMax: baseURL = "https://api.minimax.io/v1"; model = "speech-2.8-hd"; voice = "English_expressive_narrator"
        case .gmi: baseURL = "https://console.gmicloud.ai"; model = "minimax-tts-speech-2.8-hd"; voice = "English_expressive_narrator"
        }
    }
    public func validated() -> Self {
        var result = self
        result.speed = speed.isFinite ? min(service == .openAI ? 4 : 2, max(service == .openAI ? 0.25 : 0.5, speed)) : 1
        result.volume = volume.isFinite ? min(10, max(0, volume)) : 1
        result.pitch = min(12, max(-12, pitch))
        result.maximumCharacters = min(2000, max(80, maximumCharacters)); result.cacheMegabytes = min(2048, max(50, cacheMegabytes))
        result.instructions = String(instructions.prefix(4096))
        return result
    }
}

public enum CloudSpeechClient {
    public static let maximumAudioBytes = 30 * 1024 * 1024
    public static func request(settings: CloudSpeechSettings, key: String, text: String) throws -> URLRequest {
        let s = settings.validated()
        guard !key.isEmpty, !key.contains(where: { $0.isNewline }), !s.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.model.utf8.count <= 512,
              !s.voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.voice.utf8.count <= 512,
              s.baseURL.utf8.count <= 8192, s.groupID.utf8.count <= 512, s.emotion.utf8.count <= 128, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 4096,
              var url = URLComponents(string: s.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw MoReadError.invalid("请检查云端声音的 HTTPS 地址、模型、声音名称和密钥。")
        }
        let endpoint: String
        var body: [String: Any]
        switch s.service {
        case .openAI:
            endpoint = "audio/speech"
            body = ["model": s.model, "input": text, "voice": s.voice, "speed": s.speed, "response_format": "mp3"]
            if !s.instructions.isEmpty, !["tts-1", "tts-1-hd"].contains(s.model) { body["instructions"] = s.instructions }
        case .miniMax:
            endpoint = "t2a_v2"
            var voice: [String: Any] = ["voice_id": s.voice, "speed": s.speed, "vol": s.volume, "pitch": s.pitch]
            if !s.emotion.isEmpty { voice["emotion"] = s.emotion }
            body = ["model": s.model, "text": text, "stream": false, "output_format": "hex", "voice_setting": voice,
                    "audio_setting": ["format": "mp3", "sample_rate": 32000, "bitrate": 128000, "channel": 1]]
            if !s.groupID.isEmpty { url.queryItems = [URLQueryItem(name: "GroupId", value: s.groupID)] }
        case .gmi:
            endpoint = "api/v1/ie/requestqueue/apikey/requests"
            var payload: [String: Any] = ["text": text, "voice_id": s.voice, "speed": String(s.speed), "vol": String(s.volume), "pitch": String(s.pitch), "format": "mp3", "language_boost": "auto", "audio_sample_rate": "32000", "bitrate": "128000", "channel": "2"]
            if !s.emotion.isEmpty { payload["emotion"] = s.emotion }
            body = ["model": s.model, "payload": payload]
        }
        var path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path != endpoint, !path.hasSuffix("/" + endpoint) {
            if path.isEmpty, s.service != .gmi { path = "v1" }
            path = path.isEmpty ? endpoint : path + "/" + endpoint
        }
        url.path = "/" + path
        guard let endpointURL = url.url else { throw MoReadError.invalid("云端声音地址无效。") }
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"; request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    public static func cacheKey(settings: CloudSpeechSettings, text: String) throws -> String {
        let value = try request(settings: settings, key: "cache", text: text)
        var bytes = Data((value.url!.absoluteString + "\n").utf8); bytes.append(value.httpBody!)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    public static func validateAudio(_ data: Data) throws -> Data {
        let prefix = Array(data.prefix(12))
        guard data.count > 16, data.count <= maximumAudioBytes,
              prefix.starts(with: [73, 68, 51]) || (prefix.count >= 2 && prefix[0] == 255 && prefix[1] & 0xe0 == 0xe0) ||
              (prefix.starts(with: [82, 73, 70, 70]) && Array(prefix.suffix(4)) == [87, 65, 86, 69]) || prefix.starts(with: [102, 76, 97, 67]) else {
            throw MoReadError.invalid("语音服务没有返回可识别的音频。")
        }
        return data
    }
    public static func decodeMiniMax(_ data: Data) throws -> Data {
        guard data.count <= maximumAudioBytes * 2 + 65536,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["base_resp"] as? [String: Any], let code = status["status_code"] as? NSNumber,
              CFGetTypeID(code) != CFBooleanGetTypeID(), code.doubleValue == 0,
              let content = json["data"] as? [String: Any], let hex = content["audio"] as? String,
              !hex.isEmpty, hex.utf8.count <= maximumAudioBytes * 2, hex.utf8.count.isMultiple(of: 2) else {
            throw MoReadError.invalid("MiniMax 未能生成语音，请检查模型、声音和账户额度。")
        }
        let raw = Array(hex.utf8)
        func nibble(_ v: UInt8) -> UInt8? {
            switch v { case 48...57: return v - 48; case 65...70: return v - 55; case 97...102: return v - 87; default: return nil }
        }
        var audio = Data(capacity: raw.count / 2)
        for i in stride(from: 0, to: raw.count, by: 2) {
            guard let a = nibble(raw[i]), let b = nibble(raw[i + 1]) else { throw MoReadError.invalid("MiniMax 音频编码不完整。") }
            audio.append(a * 16 + b)
        }
        return try validateAudio(audio)
    }
    public static func queuedResponse(_ data: Data) throws -> (id: String?, audio: String?) {
        guard data.count <= maximumAudioBytes * 2,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["error"] == nil else { throw MoReadError.invalid("GMI 语音响应无效。") }
        let status = (json["status"] as? String ?? json["state"] as? String ?? "").lowercased()
        guard !["failed", "failure", "error", "cancelled", "canceled"].contains(status) else { throw MoReadError.invalid("GMI 语音任务未成功，请检查声音和账户额度。") }
        func audio(in node: Any, depth: Int = 0) -> String? {
            guard depth < 12 else { return nil }
            if let object = node as? [String: Any] {
                for name in ["audio_url", "audioUrl", "output_url", "file_url", "url", "audio_base64", "audioBase64", "audio"] {
                    if let value = object[name] as? String, !value.isEmpty { return value }
                }
                for name in ["outcome", "media_urls", "data", "output", "result", "results"] {
                    if let value = object[name], let found = audio(in: value, depth: depth + 1) { return found }
                }
            } else if let array = node as? [Any] { for value in array { if let found = audio(in: value, depth: depth + 1) { return found } } }
            return nil
        }
        let id = json["request_id"] as? String ?? json["requestId"] as? String ?? json["id"] as? String
        return (id, audio(in: json))
    }
    public static func downloadRequest(_ value: String, original: URLRequest) throws -> URLRequest {
        guard let url = URL(string: value), let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "https", c.host?.isEmpty == false, c.user == nil, c.password == nil, c.fragment == nil else { throw MoReadError.invalid("语音下载地址无效。") }
        var request = URLRequest(url: url); request.timeoutInterval = 120
        if url.host?.lowercased() == original.url?.host?.lowercased(), (url.port ?? 443) == (original.url?.port ?? 443) {
            request.setValue(original.value(forHTTPHeaderField: "Authorization"), forHTTPHeaderField: "Authorization")
        }
        return request
    }
    public static func synthesize(settings: CloudSpeechSettings, key: String, text: String) async throws -> Data {
        try Task.checkCancellation()
        let original = try request(settings: settings, key: key, text: text)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        func fetch(_ request: URLRequest, limit: Int) async throws -> Data {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw MoReadError.invalid("云端语音请求失败，请检查地址、密钥、模型及账户额度。") }
            guard response.expectedContentLength <= limit else { throw MoReadError.invalid("语音响应超过大小限制。") }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else { throw MoReadError.invalid("语音响应超过大小限制。") }
                data.append(byte)
            }
            return data
        }
        var data = try await fetch(original, limit: settings.service == .openAI ? maximumAudioBytes : maximumAudioBytes * 2 + 65536)
        switch settings.service {
        case .openAI: return try validateAudio(data)
        case .miniMax: return try decodeMiniMax(data)
        case .gmi:
            var requestID: String?
            for attempt in 0..<80 {
                try Task.checkCancellation()
                let result = try queuedResponse(data)
                if let audio = result.audio {
                    if audio.hasPrefix("https://") { return try validateAudio(try await fetch(downloadRequest(audio, original: original), limit: maximumAudioBytes)) }
                    let encoded = audio.hasPrefix("data:audio/") ? String(audio.split(separator: ",", maxSplits: 1).last ?? "") : audio
                    guard encoded.utf8.count <= maximumAudioBytes * 4 / 3 + 4, let decoded = Data(base64Encoded: encoded) else { throw MoReadError.invalid("GMI 音频编码无效。") }
                    return try validateAudio(decoded)
                }
                requestID = result.id ?? requestID
                guard let id = requestID, !id.isEmpty, id.utf8.count <= 128, id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else { throw MoReadError.invalid("GMI 未返回有效的语音任务编号。") }
                if attempt == 79 { break }
                try await Task.sleep(for: .milliseconds(1500))
                var poll = original; poll.httpMethod = "GET"; poll.httpBody = nil; poll.url = original.url!.appendingPathComponent(id)
                data = try await fetch(poll, limit: maximumAudioBytes * 2)
            }
            throw MoReadError.invalid("云端语音等待超时，请稍后重试。")
        }
    }
}

public enum SpeechAudioCache {
    public static func file(in bookDirectory: URL, key: String) throws -> URL {
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw MoReadError.invalid("音频缓存标识无效。") }
        return bookDirectory.appendingPathComponent("speech-" + key + ".mp3")
    }
    public static func read(in bookDirectory: URL, key: String) throws -> Data? {
        let url = try file(in: bookDirectory, key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= CloudSpeechClient.maximumAudioBytes else { try FileManager.default.removeItem(at: url); return nil }
        guard let data = try? CloudSpeechClient.validateAudio(Data(contentsOf: url)) else { try FileManager.default.removeItem(at: url); return nil }
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }
    public static func write(_ data: Data, in bookDirectory: URL, key: String, megabytes: Int) throws {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: bookDirectory.appendingPathComponent("book.json").path) else { throw CancellationError() }
        try CloudSpeechClient.validateAudio(data).write(to: file(in: bookDirectory, key: key), options: .atomic)
        // ponytail: each new clip scans the cache; use a stored LRU index if large libraries make pruning slow.
        let files = try entries(root: bookDirectory.deletingLastPathComponent()).sorted { $0.date > $1.date }
        var total = 0
        let budget = min(2048, max(50, megabytes)) * 1024 * 1024
        for item in files { total += item.size; if total > budget { try FileManager.default.removeItem(at: item.url) } }
    }
    public static func size(root: URL) throws -> Int64 { try entries(root: root).reduce(0) { $0 + Int64($1.size) } }
    public static func clear(root: URL) throws { for item in try entries(root: root) { try FileManager.default.removeItem(at: item.url) } }
    private static func entries(root: URL) throws -> [(url: URL, size: Int, date: Date)] {
        let fm = FileManager.default
        var result: [(URL, Int, Date)] = []
        for book in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where UUID(uuidString: book.lastPathComponent) != nil {
            for url in try fm.contentsOfDirectory(at: book, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) where url.lastPathComponent.hasPrefix("speech-") && url.pathExtension == "mp3" {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                if values.isRegularFile == true { result.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)) }
            }
        }
        return result
    }
}
