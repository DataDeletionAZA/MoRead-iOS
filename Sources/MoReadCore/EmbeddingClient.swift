import Foundation
import CryptoKit

public enum EmbeddingClient {
    public static func request(provider: AIProvider, key: String, texts: [String]) throws -> URLRequest {
        guard provider.dialect != .claude else { throw MoReadError.invalid("请选择提供向量接口的 OpenAI 兼容或 Gemini 服务商。") }
        guard !key.isEmpty, !provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !texts.isEmpty, texts.count <= 32, texts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 8192 }),
              var components = URLComponents(string: provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", components.host?.isEmpty == false,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            throw MoReadError.invalid("请检查向量服务商的 HTTPS 地址、模型、密钥及输入长度。")
        }
        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let body: [String: Any]
        if provider.dialect == .gemini {
            guard !provider.model.contains(where: { "/?#".contains($0) }) else { throw MoReadError.invalid("向量模型名称格式不正确。") }
            if path.isEmpty { path = "v1beta" }
            path += "/models/\(provider.model):batchEmbedContents"
            body = ["requests": texts.map { ["model": "models/\(provider.model)", "content": ["parts": [["text": $0]]]] }]
        } else {
            for endpoint in ["chat/completions", "responses", "embeddings"] {
                if path == endpoint { path = ""; break }
                if path.hasSuffix("/" + endpoint) { path.removeLast(endpoint.count + 1); break }
            }
            if path.isEmpty { path = "v1" }
            path += "/embeddings"
            body = ["model": provider.model, "input": texts, "encoding_format": "float"]
        }
        components.path = "/" + path
        guard let url = components.url else { throw MoReadError.invalid("向量接口地址无效。") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(provider.dialect == .gemini ? key : "Bearer \(key)", forHTTPHeaderField: provider.dialect == .gemini ? "x-goog-api-key" : "Authorization")
        return request
    }
    public static func fingerprint(_ provider: AIProvider) throws -> String {
        let url = try request(provider: provider, key: "configuration-check", texts: ["configuration-check"]).url!.absoluteString
        return SHA256.hash(data: Data((provider.id.uuidString + "\n" + url + "\n" + provider.model).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func decode(_ data: Data, dialect: AIProtocol, count: Int) throws -> [[Float]] {
        guard data.count <= 16 * 1024 * 1024, count > 0, count <= 32,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["error"] == nil else { throw MoReadError.invalid("向量服务商返回了无效数据。") }
        let raw: [[Any]]
        if dialect == .gemini {
            guard let rows = json["embeddings"] as? [[String: Any]], rows.count == count,
                  rows.allSatisfy({ $0["values"] is [Any] }) else { throw MoReadError.invalid("返回的向量数量与输入不一致。") }
            raw = rows.map { $0["values"] as! [Any] }
        } else {
            guard let rows = json["data"] as? [[String: Any]], rows.count == count else { throw MoReadError.invalid("返回的向量数量与输入不一致。") }
            var ordered = [[Any]?](repeating: nil, count: count)
            for row in rows {
                guard let number = row["index"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue >= 0, number.doubleValue < Double(count),
                      number.doubleValue == Double(number.intValue), ordered[number.intValue] == nil,
                      let vector = row["embedding"] as? [Any] else { throw MoReadError.invalid("向量的顺序标识无效。") }
                ordered[number.intValue] = vector
            }
            guard ordered.allSatisfy({ $0 != nil }) else { throw MoReadError.invalid("返回的向量不完整。") }
            raw = ordered.map { $0! }
        }
        var result: [[Float]] = []
        for vector in raw {
            guard !vector.isEmpty, vector.count <= 8192, result.isEmpty || vector.count == result[0].count else { throw MoReadError.invalid("向量维度无效或不一致。") }
            let values = try vector.map { value -> Float in
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, Float(number.doubleValue).isFinite else { throw MoReadError.invalid("向量包含无效数字。") }
                return number.floatValue
            }
            result.append(try normalized(values))
        }
        return result
    }
    public static func normalized(_ vector: [Float]) throws -> [Float] {
        guard !vector.isEmpty, vector.count <= 8192, vector.allSatisfy(\.isFinite) else { throw MoReadError.invalid("向量维度或数字无效。") }
        let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0 else { throw MoReadError.invalid("服务商返回了零向量。") }
        return vector.map { Float(Double($0) / norm) }
    }
    public static func embed(provider: AIProvider, key: String, texts: [String]) async throws -> [[Float]] {
        let request = try request(provider: provider, key: key, texts: texts)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw MoReadError.invalid("向量请求失败，请检查服务商地址、密钥和模型。") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 16 * 1024 * 1024 else { throw MoReadError.invalid("向量响应超过大小限制。") }
            data.append(byte)
        }
        return try decode(data, dialect: provider.dialect, count: texts.count)
    }
}
