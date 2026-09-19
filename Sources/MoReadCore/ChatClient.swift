import Foundation

public enum AIProtocol: String, Codable, CaseIterable, Sendable {
    case openAI = "OpenAI 兼容"
    case responses = "OpenAI Responses"
    case claude = "Claude"
    case gemini = "Gemini"
}

public struct AIProvider: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name = "我的服务商"
    public var baseURL = "https://api.openai.com/v1"
    public var model = ""
    public var dialect: AIProtocol = .openAI
    public var maxTokens = 4096
    public init() {}
}

public struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var role: String
    public var content: String
    public var createdAt = Date()
    public var status = "complete"
    public var sources: [SourcePassage] = []
    public init(role: String, content: String) { self.role = role; self.content = content }
}

public enum ChatRequest {
    public static func make(provider: AIProvider, key: String, messages: [ChatMessage]) throws -> URLRequest {
        guard !key.isEmpty, !provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              var components = URLComponents(string: provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", components.host != nil,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            throw MoReadError.invalid("请填写 HTTPS 接口地址、模型名称和密钥。")
        }
        guard provider.dialect != .gemini || !provider.model.contains(where: { "/?#".contains($0) }) else {
            throw MoReadError.invalid("Gemini 模型名称格式不正确。")
        }
        let system = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        let turns = messages.filter { ["user", "assistant"].contains($0.role) }.map { ["role": $0.role, "content": $0.content] }
        var body: [String: Any]
        var headers: [String: String] = [:]
        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let maxTokens = min(max(256, provider.maxTokens), 65536)
        switch provider.dialect {
        case .openAI, .responses:
            if path.isEmpty { path = "v1" }
            let suffix = provider.dialect == .openAI ? "chat/completions" : "responses"
            if !path.hasSuffix(suffix) { path += "/" + suffix }
            headers["Authorization"] = "Bearer \(key)"
            if provider.dialect == .openAI {
                body = ["model": provider.model, "messages": messages.map { ["role": $0.role, "content": $0.content] }, "stream": true]
            } else {
                body = ["model": provider.model, "instructions": system, "input": turns, "stream": true, "store": false, "max_output_tokens": maxTokens]
            }
        case .claude:
            if path.isEmpty { path = "v1" }
            if !path.hasSuffix("messages") { path += "/messages" }
            headers["x-api-key"] = key; headers["anthropic-version"] = "2023-06-01"
            body = ["model": provider.model, "system": system, "messages": turns, "stream": true, "max_tokens": maxTokens]
        case .gemini:
            if path.isEmpty { path = "v1beta" }
            path += "/models/\(provider.model):streamGenerateContent"
            components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
            headers["x-goog-api-key"] = key
            let contents: [[String: Any]] = turns.map { ["role": $0["role"] == "assistant" ? "model" : "user", "parts": [["text": $0["content"] ?? ""]]] }
            body = ["contents": contents, "systemInstruction": ["parts": [["text": system]]], "generationConfig": ["maxOutputTokens": maxTokens]]
        }
        components.path = "/" + path
        guard let url = components.url else { throw MoReadError.invalid("接口地址无效。") }
        let encoded = try JSONSerialization.data(withJSONObject: body)
        guard encoded.count <= 6 * 1024 * 1024 else { throw MoReadError.invalid("对话内容过长，请开启新话题。") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = encoded; request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
}

public struct ChatStreamDecoder {
    public let dialect: AIProtocol
    public private(set) var finished = false
    public init(dialect: AIProtocol) { self.dialect = dialect }
    public mutating func consume(_ payload: String) throws -> String {
        if payload == "[DONE]" { finished = true; return "" }
        guard let data = payload.data(using: .utf8), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MoReadError.invalid("服务商返回了无法识别的回复。") }
        if json["error"] != nil || json["type"] as? String == "error" { throw MoReadError.invalid("服务商返回错误，请检查模型和服务商设置。") }
        switch dialect {
        case .openAI:
            guard let choice = (json["choices"] as? [[String: Any]])?.first else { return "" }
            if let finish = choice["finish_reason"] as? String {
                guard finish == "stop" else { throw MoReadError.invalid(finish == "length" ? "回复达到服务商长度上限，已保留收到的部分。" : "服务商没有正常完成回复。") }
                finished = true
            }
            return (choice["delta"] as? [String: Any])?["content"] as? String ?? ""
        case .responses:
            let type = json["type"] as? String
            if type == "response.completed" { finished = true }
            if type == "response.failed" || type == "response.incomplete" { throw MoReadError.invalid("服务商未完成回复，已保留收到的部分。") }
            return type == "response.output_text.delta" ? json["delta"] as? String ?? "" : ""
        case .claude:
            let type = json["type"] as? String
            if type == "message_stop" { finished = true }
            let delta = json["delta"] as? [String: Any]
            if let reason = delta?["stop_reason"] as? String, !["end_turn", "stop_sequence"].contains(reason) { throw MoReadError.invalid("回复未完整结束，已保留收到的部分。") }
            return delta?["type"] as? String == "text_delta" ? delta?["text"] as? String ?? "" : ""
        case .gemini:
            guard let candidate = (json["candidates"] as? [[String: Any]])?.first else {
                if json["promptFeedback"] != nil { throw MoReadError.invalid("服务商未提供回答，请检查请求内容。") }
                return ""
            }
            if let reason = candidate["finishReason"] as? String {
                guard reason == "STOP" else { throw MoReadError.invalid("回复未完整结束，已保留收到的部分。") }
                finished = true
            }
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            return parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        }
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private actor CollectedReply {
    private var value = ""
    private var size = 0
    private var overflow = false
    func append(_ text: String, limit: Int) {
        guard !overflow else { return }
        guard text.utf8.count <= limit - size else { overflow = true; return }
        size += text.utf8.count; value += text
    }
    func result() throws -> String {
        guard !overflow else { throw MoReadError.invalid("服务商返回的内容过长，未保存。") }
        return value
    }
}

public enum ChatClient {
    public static func complete(provider: AIProvider, key: String, messages: [ChatMessage], maximumBytes: Int = 64 * 1024) async throws -> String {
        let reply = CollectedReply()
        try await stream(provider: provider, key: key, messages: messages) { await reply.append($0, limit: min(1024 * 1024, max(1, maximumBytes))) }
        return try await reply.result()
    }

    public static func stream(provider: AIProvider, key: String, messages: [ChatMessage], onDelta: @escaping @Sendable (String) async -> Void) async throws {
        let request = try ChatRequest.make(provider: provider, key: key, messages: messages)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForResource = 300
        let delegate = NoRedirects()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MoReadError.invalid("服务商没有返回有效响应。") }
        guard (200...299).contains(http.statusCode) else { throw MoReadError.invalid("连接失败（HTTP \(http.statusCode)）。请检查地址、密钥、模型或服务商余额。") }
        var decoder = ChatStreamDecoder(dialect: provider.dialect)
        var event: [String] = []
        var eventSize = 0
        var total = 0
        var hasText = false
        // Split bytes explicitly so a server cannot allocate an unbounded line through AsyncBytes.lines.
        var line = Data()
        func consumeLine(_ value: String) throws -> String {
            if value.isEmpty {
                defer { event.removeAll(keepingCapacity: true); eventSize = 0 }
                return event.isEmpty ? "" : try decoder.consume(event.joined(separator: "\n"))
            }
            if value.hasPrefix("data:") {
                var part = String(value.dropFirst(5)); if part.hasPrefix(" ") { part.removeFirst() }
                eventSize += part.utf8.count
                guard eventSize <= 2 * 1024 * 1024 else { throw MoReadError.invalid("服务商返回的数据块过大。") }
                event.append(part)
            }
            return ""
        }
        for try await byte in bytes {
            try Task.checkCancellation()
            total += 1
            guard total <= 16 * 1024 * 1024, line.count <= 2 * 1024 * 1024 else { throw MoReadError.invalid("服务商返回的内容过大。") }
            if byte == 10 {
                if line.last == 13 { line.removeLast() }
                guard let value = String(data: line, encoding: .utf8) else { throw MoReadError.invalid("服务商返回了无效文字编码。") }
                let delta = try consumeLine(value); line.removeAll(keepingCapacity: true)
                if !delta.isEmpty { hasText = true; await onDelta(delta) }
                if decoder.finished { break }
            } else { line.append(byte) }
        }
        if !line.isEmpty, let value = String(data: line, encoding: .utf8) { _ = try consumeLine(value) }
        let final = try consumeLine("")
        if !final.isEmpty { hasText = true; await onDelta(final) }
        guard decoder.finished else { throw MoReadError.invalid("连接提前中断，已保留收到的回复，可以重试。") }
        guard hasText else { throw MoReadError.invalid("服务商返回了空回复。") }
    }
}
