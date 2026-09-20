import Foundation

public struct ChatTool: Sendable {
    public let name: String
    public let description: String
    public let parameters: Data
    public init(name: String, description: String, parameters: Data) { self.name = name; self.description = description; self.parameters = parameters }
}

public struct ChatToolCall: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let arguments: String
    public init(id: String, name: String, arguments: String) { self.id = id; self.name = name; self.arguments = arguments }
    public func object() throws -> [String: Any] {
        guard arguments.utf8.count <= 256 * 1024, let value = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else { throw MoReadError.invalid("工具参数必须是有效的 JSON 对象。") }
        return value
    }
}

public struct ChatToolResult: Codable, Hashable, Sendable {
    public let call: ChatToolCall
    public let content: String
    public let failed: Bool
    public init(call: ChatToolCall, content: String, failed: Bool = false) { self.call = call; self.content = content; self.failed = failed }
}

public struct ChatToolRound: Sendable {
    public let text: String
    public let calls: [ChatToolCall]
    public let replay: Data
    public init(text: String, calls: [ChatToolCall], replay: Data) { self.text = text; self.calls = calls; self.replay = replay }
}

public struct ChatToolExchange: Sendable {
    public let round: ChatToolRound
    public let results: [ChatToolResult]
    public init(round: ChatToolRound, results: [ChatToolResult]) { self.round = round; self.results = results }
}

public enum ChatToolWire {
    static func apply(to body: inout [String: Any], dialect: AIProtocol, tools: [ChatTool], exchanges: [ChatToolExchange]) throws {
        guard tools.count <= 32, exchanges.count <= 8 else { throw MoReadError.invalid("工具调用超过上限。") }
        let specs: [[String: Any]] = try tools.map { tool in
            guard tool.parameters.count <= 32 * 1024, let schema = try JSONSerialization.jsonObject(with: tool.parameters) as? [String: Any] else { throw MoReadError.invalid("工具格式无效。") }
            switch dialect {
            case .openAI: return ["type": "function", "function": ["name": tool.name, "description": tool.description, "parameters": schema]]
            case .responses: return ["type": "function", "name": tool.name, "description": tool.description, "parameters": schema, "strict": false]
            case .claude: return ["name": tool.name, "description": tool.description, "input_schema": schema]
            case .gemini: return ["name": tool.name, "description": tool.description, "parameters": schema]
            }
        }
        if !tools.isEmpty {
            body["tools"] = dialect == .gemini ? [["functionDeclarations": specs]] : specs
            if dialect == .responses { body["include"] = ["reasoning.encrypted_content"] }
        }
        let key = dialect == .responses ? "input" : dialect == .gemini ? "contents" : "messages"
        var history = body[key] as? [[String: Any]] ?? []
        for exchange in exchanges {
            guard exchange.round.calls.count == exchange.results.count,
                  zip(exchange.round.calls, exchange.results).allSatisfy({ $0.id == $1.call.id }),
                  exchange.round.replay.count <= 2 * 1024 * 1024,
                  exchange.results.allSatisfy({ $0.content.utf8.count <= 128 * 1024 }) else { throw MoReadError.invalid("工具结果与调用不一致。") }
            let native = try JSONSerialization.jsonObject(with: exchange.round.replay)
            switch dialect {
            case .openAI:
                guard let assistant = native as? [String: Any] else { throw MoReadError.invalid("工具消息无效。") }
                history.append(assistant)
                history += exchange.results.map { ["role": "tool", "tool_call_id": $0.call.id, "content": $0.content] }
            case .responses:
                guard let output = native as? [[String: Any]] else { throw MoReadError.invalid("工具消息无效。") }
                history += output
                history += exchange.results.map { ["type": "function_call_output", "call_id": $0.call.id, "output": $0.content] }
            case .claude:
                guard let blocks = native as? [[String: Any]] else { throw MoReadError.invalid("工具消息无效。") }
                history.append(["role": "assistant", "content": blocks])
                history.append(["role": "user", "content": exchange.results.map { ["type": "tool_result", "tool_use_id": $0.call.id, "content": $0.content, "is_error": $0.failed] as [String: Any] }])
            case .gemini:
                guard let parts = native as? [[String: Any]] else { throw MoReadError.invalid("工具消息无效。") }
                history.append(["role": "model", "parts": parts])
                let replies: [[String: Any]] = exchange.results.map { result in
                    var response: [String: Any] = ["name": result.call.name, "response": [result.failed ? "error" : "result": result.content]]
                    if parts.contains(where: { ($0["functionCall"] as? [String: Any])?["id"] as? String == result.call.id }) { response["id"] = result.call.id }
                    return ["functionResponse": response]
                }
                history.append(["role": "user", "parts": replies])
            }
        }
        body[key] = history
    }
}

struct ToolStreamAccumulator {
    let dialect: AIProtocol
    init(dialect: AIProtocol) { self.dialect = dialect }
    private var slots: [Int: [String: Any]] = [:]
    private var arguments: [Int: String] = [:]
    private var parts: [[String: Any]] = []
    private var responses: [[String: Any]] = []
    private var reasoning: [[String: Any]] = []
    private var size = 0
    mutating func consume(_ json: [String: Any], bytes: Int) throws {
        size += bytes
        guard size <= 16 * 1024 * 1024 else { throw MoReadError.invalid("工具回复过长。") }
        switch dialect {
        case .openAI:
            let delta = ((json["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any] ?? [:]
            if let detail = delta["reasoning_details"] as? [[String: Any]] { reasoning += detail }
            for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = try fragment["index"].map(index) ?? slots.keys.max() ?? 0
                var slot = slots[index] ?? [:]
                if let id = fragment["id"] as? String, !id.isEmpty { slot["id"] = id }
                slot["type"] = "function"
                if let function = fragment["function"] as? [String: Any] {
                    var current = slot["function"] as? [String: Any] ?? [:]
                    if let name = function["name"] as? String { current["name"] = name }
                    if let part = function["arguments"] as? String { current["arguments"] = (current["arguments"] as? String ?? "") + part }
                    slot["function"] = current
                }
                if let extra = fragment["extra_content"] as? [String: Any] { slot["extra_content"] = Self.merge(slot["extra_content"] as? [String: Any] ?? [:], extra) }
                slots[index] = slot
            }
        case .responses:
            if json["type"] as? String == "response.completed" { responses = (json["response"] as? [String: Any])?["output"] as? [[String: Any]] ?? [] }
        case .claude:
            let type = json["type"] as? String
            if type == "content_block_start" { slots[try index(json["index"])] = json["content_block"] as? [String: Any] ?? [:] }
            if type == "content_block_delta", let delta = json["delta"] as? [String: Any] {
                let index = try index(json["index"])
                guard var slot = slots[index] else { throw MoReadError.invalid("工具数据块缺少开头。") }
                if delta["type"] as? String == "input_json_delta" { arguments[index, default: ""] += delta["partial_json"] as? String ?? "" }
                for field in ["text", "thinking", "signature"] { if let value = delta[field] as? String { slot[field] = (slot[field] as? String ?? "") + value } }
                slots[index] = slot
            }
        case .gemini:
            if let content = ((json["candidates"] as? [[String: Any]])?.first)?["content"] as? [String: Any], let received = content["parts"] as? [[String: Any]] { parts += received }
        }
        guard slots.count <= 64, parts.count <= 4096, reasoning.count <= 256 else { throw MoReadError.invalid("工具数据块数量过多。") }
    }
    func finish(text: String) throws -> ChatToolRound {
        var calls: [ChatToolCall] = [], native: Any
        switch dialect {
        case .openAI:
            let ordered = slots.keys.sorted().compactMap { slots[$0] }
            for slot in ordered {
                let function = slot["function"] as? [String: Any] ?? [:]
                calls.append(ChatToolCall(id: slot["id"] as? String ?? "", name: function["name"] as? String ?? "", arguments: function["arguments"] as? String ?? ""))
            }
            var assistant: [String: Any] = ["role": "assistant", "content": text, "tool_calls": ordered]
            if !reasoning.isEmpty { assistant["reasoning_details"] = reasoning }
            native = assistant
        case .responses:
            for item in responses where item["type"] as? String == "function_call" {
                calls.append(ChatToolCall(id: item["call_id"] as? String ?? "", name: item["name"] as? String ?? "", arguments: item["arguments"] as? String ?? ""))
            }
            native = responses
        case .claude:
            var blocks: [[String: Any]] = []
            for index in slots.keys.sorted() {
                var slot = slots[index]!
                if slot["type"] as? String == "tool_use" {
                    let raw = try arguments[index] ?? Self.string(slot["input"] ?? [:])
                    let call = ChatToolCall(id: slot["id"] as? String ?? "", name: slot["name"] as? String ?? "", arguments: raw)
                    slot["input"] = try call.object(); calls.append(call)
                }
                blocks.append(slot)
            }
            native = blocks
        case .gemini:
            for part in parts {
                if let function = part["functionCall"] as? [String: Any] {
                    calls.append(ChatToolCall(id: function["id"] as? String ?? "local-" + UUID().uuidString, name: function["name"] as? String ?? "", arguments: try Self.string(function["args"] ?? [:])))
                }
            }
            native = parts
        }
        guard calls.count <= 8, Set(calls.map(\.id)).count == calls.count else { throw MoReadError.invalid("单轮工具调用过多或标识重复。") }
        for call in calls {
            guard !call.id.isEmpty, call.id.utf8.count <= 256, !call.name.isEmpty, call.name.utf8.count <= 128 else { throw MoReadError.invalid("工具调用标识无效。") }
            _ = try call.object()
        }
        let replay = try JSONSerialization.data(withJSONObject: native)
        guard replay.count <= 2 * 1024 * 1024 else { throw MoReadError.invalid("工具续接消息过长。") }
        return ChatToolRound(text: text, calls: calls, replay: replay)
    }
    private func index(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0, number.doubleValue < 64, number.doubleValue == Double(number.intValue) else { throw MoReadError.invalid("工具数据块编号无效。") }
        return number.intValue
    }
    private static func string(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
    private static func merge(_ old: [String: Any], _ new: [String: Any]) -> [String: Any] {
        old.merging(new) { lhs, rhs in
            if let lhs = lhs as? [String: Any], let rhs = rhs as? [String: Any] { return merge(lhs, rhs) }
            return rhs
        }
    }
}

public enum ChatToolEvent: Sendable {
    case started(ChatToolCall)
    case finished(ChatToolResult)
}

public enum ChatToolLoop {
    public static func run(tools: [ChatTool], stream: ([ChatToolExchange]) async throws -> ChatToolRound,
                           execute: (ChatToolCall) async throws -> String, validate: () async throws -> Void,
                           report: (ChatToolEvent) async throws -> Void) async throws {
        var exchanges: [ChatToolExchange] = [], resultBytes = 0
        let allowed = Set(tools.map(\.name))
        for _ in 0..<8 {
            try Task.checkCancellation(); try await validate()
            let round = try await stream(exchanges)
            try Task.checkCancellation(); try await validate()
            guard round.calls.count <= 8, Set(round.calls.map(\.id)).count == round.calls.count else { throw MoReadError.invalid("单轮工具调用过多或标识重复。") }
            if round.calls.isEmpty { return }
            var results: [ChatToolResult] = []
            for call in round.calls {
                try Task.checkCancellation(); try await validate()
                try await report(.started(call))
                let result: ChatToolResult
                do {
                    guard allowed.contains(call.name) else { throw MoReadError.invalid("这个工具没有启用。") }
                    _ = try call.object()
                    let content = try await execute(call)
                    guard content.utf8.count <= 128 * 1024, content.utf8.count <= 512 * 1024 - resultBytes else { throw MoReadError.invalid("本次查询结果已达到长度上限，请缩小问题范围。") }
                    resultBytes += content.utf8.count
                    result = ChatToolResult(call: call, content: content)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    try Task.checkCancellation()
                    result = ChatToolResult(call: call, content: error is MoReadError ? error.localizedDescription : "查询未完成，请换用其他可用工具或说明缺少的资料。", failed: true)
                }
                try await validate(); try await report(.finished(result)); results.append(result)
            }
            exchanges.append(ChatToolExchange(round: round, results: results))
        }
        throw MoReadError.invalid("已达到本轮 8 轮查询上限，已保留查到的内容；可继续提问。")
    }
}
