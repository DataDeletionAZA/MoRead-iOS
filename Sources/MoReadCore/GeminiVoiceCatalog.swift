import Foundation

public enum GeminiVoiceCatalog {
    public static let maximumPageBytes = 2 * 1024 * 1024
    public static func request(settings: CloudSpeechSettings, key: String, pageToken: String = "") throws -> URLRequest {
        guard settings.service == .gemini, key.utf8.count <= 8192, !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), pageToken.utf8.count <= 8192 else {
            throw MoReadError.invalid("请先保存 Gemini 云端声音的地址和密钥。")
        }
        var probe = CloudSpeechSettings(); probe.preset(.gemini); probe.baseURL = settings.baseURL
        var request = try CloudSpeechClient.request(settings: probe, key: key, text: "音色目录")
        guard let base = request.url, var url = URLComponents(url: base.deletingLastPathComponent().appendingPathComponent("voices"), resolvingAgainstBaseURL: false) else {
            throw MoReadError.invalid("Gemini 音色目录地址无效。")
        }
        url.queryItems = [URLQueryItem(name: "page_size", value: "1000")]
        if !pageToken.isEmpty { url.queryItems?.append(URLQueryItem(name: "page_token", value: pageToken)) }
        request.url = url.url; request.httpMethod = "GET"; request.httpBody = nil; request.timeoutInterval = 30
        return request
    }
    public static func page(_ data: Data) throws -> (voices: [SavedVoice], next: String) {
        guard data.count <= maximumPageBytes, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["error"] == nil,
              json["voices"] == nil || json["voices"] is [[String: Any]],
              json["next_page_token"] == nil || json["next_page_token"] is String else { throw MoReadError.invalid("Gemini 音色目录格式无效。") }
        let rows = json["voices"] as? [[String: Any]] ?? [], next = json["next_page_token"] as? String ?? ""
        guard rows.count <= 1000, next.utf8.count <= 8192 else { throw MoReadError.invalid("Gemini 音色目录超过单页限制。") }
        let voices = try rows.compactMap { row -> SavedVoice? in
            guard let id = row["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let name = (row["display_name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let tags = ["Gemini"] + ["language_code", "persona", "pitch"].compactMap { row[$0] as? String }.filter { !$0.isEmpty }
            let gender = (row["gender"] as? String ?? "").lowercased()
            return try SavedVoice(voiceId: id, displayName: name.isEmpty ? id : name, providerHint: "GEMINI", tags: tags.joined(separator: ","), gender: gender == "female" ? "FEMALE" : gender == "male" ? "MALE" : "UNSPECIFIED").normalized()
        }
        return (voices, next)
    }
    public static func list(settings: CloudSpeechSettings, key: String, fetch: @Sendable (URLRequest) async throws -> Data = fetchPage) async throws -> [SavedVoice] {
        var token = "", seen: Set<String> = [], values: [String: SavedVoice] = [:], order: [String] = []
        let clock = ContinuousClock(), start = ContinuousClock.now
        repeat {
            try Task.checkCancellation()
            guard seen.insert(token).inserted, seen.count <= 100, start.duration(to: clock.now) < .seconds(120) else {
                throw MoReadError.invalid("Gemini 音色分页重复、过多或等待过久，请稍后重试。")
            }
            let response = try await fetch(request(settings: settings, key: key, pageToken: token))
            try Task.checkCancellation()
            let result = try page(response)
            for voice in result.voices {
                if values[voice.identity] == nil { order.append(voice.identity) }
                values[voice.identity] = voice
            }
            guard values.count <= 2000 else { throw MoReadError.invalid("在线目录超过音色库的 2000 个音色容量，已有音色保持不变。") }
            token = result.next
        } while !token.isEmpty
        return order.compactMap { values[$0] }
    }
    public static func fetchPage(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForResource = 35
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MoReadError.invalid("读取 Gemini 音色失败，请检查地址、密钥和账户权限。")
        }
        guard response.expectedContentLength <= maximumPageBytes else { throw MoReadError.invalid("Gemini 音色目录响应过大。") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumPageBytes else { throw MoReadError.invalid("Gemini 音色目录响应过大。") }
            data.append(byte)
        }
        return data
    }
}
