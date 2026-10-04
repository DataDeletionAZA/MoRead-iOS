import Foundation

public struct VoiceDesignSpecification: Equatable, Codable, Sendable {
    public var name: String
    public var description: String
    public var gender: String
    public var language: String
    public init(name: String = "", description: String = "", gender: String = "female", language: String = "zh-CN") {
        self.name = name; self.description = description; self.gender = gender; self.language = language
    }
    public func normalized() throws -> Self {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, value.name.utf16.count <= 80, !value.name.contains(where: \.isNewline),
              !value.description.isEmpty, value.description.utf16.count <= 2000,
              ["female", "male", "neutral"].contains(gender), language.utf8.count <= 64,
              language.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression)?.upperBound == language.endIndex else {
            throw MoReadError.invalid("请填写 80 字以内的名称、2000 字以内的声音描述，并检查声音类型和语言代码。")
        }
        return value
    }
    public func matchesSound(_ other: Self) -> Bool {
        description.trimmingCharacters(in: .whitespacesAndNewlines) == other.description.trimmingCharacters(in: .whitespacesAndNewlines) && gender == other.gender && language == other.language
    }
}

public struct DesignedVoice: Equatable, Sendable {
    public let id: String
    public let preview: Data?
}

public enum GeminiVoiceDesign {
    public static let maximumResponseBytes = CloudSpeechClient.maximumAudioBytes * 4 / 3 + 65536
    public static func validateID(_ id: String) throws {
        guard id.utf8.count <= 512, id.range(of: "^voice_[A-Za-z0-9_-]+$", options: .regularExpression)?.upperBound == id.endIndex else {
            throw MoReadError.invalid("服务未返回有效的自定义音色 ID。")
        }
    }
    public static func createRequest(settings: CloudSpeechSettings, key: String, specification: VoiceDesignSpecification) throws -> URLRequest {
        let spec = try specification.normalized()
        let model = settings.model.hasPrefix("models/") ? String(settings.model.dropFirst(7)) : settings.model
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.utf8.count <= 512,
              !model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw MoReadError.invalid("请填写 Gemini 声音设计模型。") }
        var request = try baseRequest(settings: settings, key: key)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["store": true, "voice": ["model": model, "type": "prompted", "display_name": spec.name, "gender": spec.gender, "language_code": spec.language, "prompted": ["input": spec.description]]])
        return request
    }
    public static func voiceRequest(settings: CloudSpeechSettings, key: String, id: String, deleting: Bool = false) throws -> URLRequest {
        try validateID(id)
        var request = try baseRequest(settings: settings, key: key)
        request.url = request.url?.appendingPathComponent(id)
        request.httpMethod = deleting ? "DELETE" : "GET"
        return request
    }
    private static func baseRequest(settings: CloudSpeechSettings, key: String) throws -> URLRequest {
        var request = try GeminiVoiceCatalog.request(settings: settings, key: key)
        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        url.queryItems = nil; request.url = url.url; request.timeoutInterval = 120
        return request
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumResponseBytes,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], value["error"] == nil else {
            throw MoReadError.invalid("Gemini 声音设计响应无效。")
        }
        return value
    }
    public static func created(_ data: Data) throws -> DesignedVoice {
        let value = try object(data), id = value["id"] as? String ?? ""
        try validateID(id)
        // A valid identity survives a missing sample so GetVoice can recover it without another creation.
        let preview = (value["sample_audio"] as? [String: Any]).flatMap { try? GeminiSpeech.decodeAudio($0) }
        return DesignedVoice(id: id, preview: preview)
    }
    public static func preview(_ data: Data, id: String) throws -> Data {
        try validateID(id)
        let value = try object(data)
        guard value["id"] as? String == id, let sample = value["sample_audio"] as? [String: Any] else {
            throw MoReadError.invalid("音色已生成，但服务暂未提供对应试听，请稍后重新获取。")
        }
        return try GeminiSpeech.decodeAudio(sample)
    }
    public static func fetch(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForResource = 150
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MoReadError.invalid("声音设计服务未返回有效响应。") }
        if request.httpMethod == "DELETE", http.statusCode == 404 { return Data() }
        guard (200...299).contains(http.statusCode) else { throw MoReadError.invalid("声音设计请求失败，请检查 Gemini 地址、密钥、模型和账户权限。") }
        let limit = request.httpMethod == "DELETE" ? 65536 : maximumResponseBytes
        guard response.expectedContentLength <= limit else { throw MoReadError.invalid("声音设计响应过大。") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw MoReadError.invalid("声音设计响应过大。") }
            data.append(byte)
        }
        return data
    }
}
