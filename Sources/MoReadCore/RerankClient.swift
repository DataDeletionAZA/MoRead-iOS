import Foundation

public struct RerankSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var providerID: UUID?
    public var model = ""
    public var endpoint = "rerank"
    public init() {}
}

public enum RerankClient {
    public static func request(provider: AIProvider, key: String, endpoint: String = "rerank", query: String, documents: [String]) throws -> URLRequest {
        let endpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !key.isEmpty, !provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.utf16.count <= 512,
              (2...24).contains(documents.count), documents.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 800 }),
              documents.reduce(0, { $0 + $1.utf16.count }) <= 12_000,
              !endpoint.isEmpty, !endpoint.contains(where: { ":?#%\\".contains($0) }), !endpoint.split(separator: "/").contains(".."),
              var components = URLComponents(string: provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", components.host?.isEmpty == false,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            throw MoReadError.invalid("请检查重排服务商的 HTTPS 地址、模型、密钥和接口路径。")
        }
        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path != endpoint && !path.hasSuffix("/" + endpoint) {
            for suffix in ["chat/completions", "responses", "embeddings", "rerank"] {
                if path == suffix { path = ""; break }
                if path.hasSuffix("/" + suffix) { path.removeLast(suffix.count + 1); break }
            }
            path = path.isEmpty ? endpoint : path + "/" + endpoint
        }
        components.path = "/" + path
        guard let url = components.url else { throw MoReadError.invalid("重排接口地址无效。") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 5
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": provider.model, "query": query, "documents": documents, "top_n": documents.count, "return_documents": false])
        return request
    }
    public static func decode(_ data: Data, count: Int) throws -> [Int] {
        guard data.count <= 64_000, (2...24).contains(count),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil,
              let results = root["results"] as? [[String: Any]], results.count == count else { throw MoReadError.invalid("重排结果不完整。") }
        var seen = Set<Int>(), scored: [(Int, Double)] = []
        for result in results {
            guard let index = result["index"] as? NSNumber, CFGetTypeID(index) != CFBooleanGetTypeID(),
                  index.doubleValue >= 0, index.doubleValue < Double(count), index.doubleValue == Double(index.intValue), seen.insert(index.intValue).inserted,
                  let score = result["relevance_score"] as? NSNumber, CFGetTypeID(score) != CFBooleanGetTypeID(), score.doubleValue.isFinite else {
                throw MoReadError.invalid("重排结果的段落编号或分数无效。")
            }
            scored.append((index.intValue, score.doubleValue))
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.map(\.0)
    }
    public static func rank(provider: AIProvider, key: String, endpoint: String, query: String, documents: [String]) async throws -> [Int] {
        let request = try request(provider: provider, key: key, endpoint: endpoint, query: query, documents: documents)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw MoReadError.invalid("重排请求失败，请检查服务商设置。") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 64_000 else { throw MoReadError.invalid("重排响应过长。") }
            data.append(byte)
        }
        return try decode(data, count: documents.count)
    }
    public static func reorder(query: String, passages: [SourcePassage], pinnedID: String? = nil, rank: (String, [String]) async throws -> [Int]) async throws -> [SourcePassage] {
        let pinned = passages.filter { $0.id == pinnedID }, candidates = passages.filter { $0.id != pinnedID }
        var documents: [String] = [], budget = 12_000
        for passage in candidates.prefix(24) {
            let text = TextBoundary.prefix(passage.text, end: min(800, budget))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
            documents.append(text); budget -= text.utf16.count
            if budget == 0 { break }
        }
        guard documents.count >= 2 else { return passages }
        let indices = try await rank(TextBoundary.prefix(query, end: 512), documents)
        try Task.checkCancellation()
        guard indices.count == documents.count, Set(indices) == Set(documents.indices) else { throw MoReadError.invalid("重排结果的段落编号无效。") }
        return pinned + indices.map { candidates[$0] } + candidates.dropFirst(documents.count)
    }
}
