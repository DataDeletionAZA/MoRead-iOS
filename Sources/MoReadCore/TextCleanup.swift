import Foundation

public struct TextReplacementRule: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name = "新规则"
    public var pattern = ""
    public var replacement = ""
    public var enabled = true
    public var ignoreCase = false
    public var forListeningOnly = false
    public var isRegex = true
    public init() {}
    public func expression() throws -> NSRegularExpression {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf16.count <= 48,
              !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, pattern.utf16.count <= 1000,
              replacement.utf16.count <= 4000 else { throw MoReadError.invalid("请填写规则名称和匹配内容；名称最多 48 字，匹配内容最多 1000 字，替换内容最多 4000 字。") }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if ignoreCase { options.insert(.caseInsensitive) }
        do { return try NSRegularExpression(pattern: isRegex ? pattern : NSRegularExpression.escapedPattern(for: pattern), options: options) }
        catch { throw MoReadError.invalid("规则“\(name)”的表达式无效：\(error.localizedDescription)") }
    }
}

public struct TextCleanupResult: Sendable {
    public let text: String
    public let matches: Int
    struct Edit: Sendable { let range: NSRange; let length: Int }
    let stages: [[Edit]]
    let sourceLength: Int
    private func offset(_ offset: Int, in edits: [Edit], afterInsertion: Bool) -> Int {
        var delta = 0
        for edit in edits {
            if offset < edit.range.location { break }
            if edit.range.length == 0, offset == edit.range.location {
                if afterInsertion { delta += edit.length }; continue
            }
            if offset < NSMaxRange(edit.range) { return edit.range.location + delta }
            delta += edit.length - edit.range.length
        }
        return offset + delta
    }
    public func mapPosition(_ value: Int) -> Int {
        TextBoundary.floor(stages.reduce(min(sourceLength, max(0, value))) { offset($0, in: $1, afterInsertion: false) }, in: text)
    }
    public func mapUnchangedRange(_ range: NSRange) -> NSRange? {
        guard range.location >= 0, range.length > 0, range.location <= sourceLength, range.length <= sourceLength - range.location else { return nil }
        var range = range
        for edits in stages {
            if edits.contains(where: { edit in
                NSIntersectionRange(range, edit.range).length > 0 || (edit.range.length == 0 && edit.range.location > range.location && edit.range.location < NSMaxRange(range))
            }) { return nil }
            let start = offset(range.location, in: edits, afterInsertion: true)
            let end = offset(NSMaxRange(range), in: edits, afterInsertion: false)
            range = NSRange(location: start, length: max(0, end - start))
        }
        guard NSMaxRange(range) <= text.utf16.count,
              TextBoundary.floor(range.location, in: text) == range.location, TextBoundary.floor(NSMaxRange(range), in: text) == NSMaxRange(range) else { return nil }
        return range
    }
}

public enum TextCleanup {
    public static func apply(_ source: String, rules: [TextReplacementRule], forListening: Bool = false) throws -> TextCleanupResult {
        var text = source, count = 0
        var stages: [[TextCleanupResult.Edit]] = []
        let maximum = min(Int.max / 4 - 100_000, source.utf16.count) * 4 + 100_000
        for rule in rules where rule.enabled && rule.forListeningOnly == forListening {
            try Task.checkCancellation()
            let expression = try rule.expression(), body = text as NSString
            let references = rule.isRegex ? captureReferences(rule.replacement, digits: String(expression.numberOfCaptureGroups).count) : []
            let deadline = ProcessInfo.processInfo.systemUptime + 0.3
            let output = NSMutableString()
            var cursor = 0, edits: [TextCleanupResult.Edit] = [], failure: Error?
            expression.enumerateMatches(in: text, options: [.reportProgress, .reportCompletion], range: NSRange(location: 0, length: body.length)) { match, flags, stop in
                do {
                    try Task.checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw MoReadError.invalid("规则“\(rule.name)”匹配超时，请缩小范围或简化表达式。") }
                    guard !flags.contains(.internalError) else { throw MoReadError.invalid("规则“\(rule.name)”匹配过于复杂，请简化表达式。") }
                    guard let match else { return }
                    let range = match.range
                    guard range.location >= cursor, NSMaxRange(range) <= body.length,
                          TextBoundary.floor(range.location, in: text) == range.location, TextBoundary.floor(NSMaxRange(range), in: text) == NSMaxRange(range) else { throw MoReadError.invalid("规则“\(rule.name)”切断了完整字符，请调整匹配内容。") }
                    // Bound capture expansion before Foundation allocates the replacement string.
                    var expansion = rule.replacement.utf16.count
                    for group in references where group < match.numberOfRanges {
                        let captured = match.range(at: group)
                        if captured.location != NSNotFound { expansion += captured.length }
                        guard expansion <= maximum else { throw MoReadError.invalid("替换结果过长，请检查规则。") }
                    }
                    guard expansion <= maximum - output.length else { throw MoReadError.invalid("替换结果过长，请检查规则。") }
                    let replacement = rule.isRegex ? expression.replacementString(for: match, in: text, offset: 0, template: rule.replacement) : rule.replacement
                    guard range.location - cursor + replacement.utf16.count <= maximum - output.length else { throw MoReadError.invalid("替换结果过长，请检查规则。") }
                    output.append(body.substring(with: NSRange(location: cursor, length: range.location - cursor)))
                    output.append(replacement)
                    if body.substring(with: range) != replacement { edits.append(.init(range: range, length: replacement.utf16.count)) }
                    cursor = NSMaxRange(range); count += 1
                } catch { failure = error; stop.pointee = true }
            }
            if let failure { throw failure }
            try Task.checkCancellation()
            guard body.length - cursor <= maximum - output.length else { throw MoReadError.invalid("替换结果过长，请检查规则。") }
            output.append(body.substring(from: cursor))
            text = output as String
            if !edits.isEmpty { stages.append(edits) }
        }
        return .init(text: text, matches: count, stages: stages, sourceLength: source.utf16.count)
    }
    private static func captureReferences(_ template: String, digits: Int) -> [Int] {
        let units = Array(template.utf16)
        var index = 0, result: [Int] = []
        while index < units.count {
            if units[index] == 92 { index += 2; continue }
            if units[index] == 36 {
                var end = index + 1, group = 0
                while end < units.count, end <= index + digits, (48...57).contains(units[end]) { group = group * 10 + Int(units[end] - 48); end += 1 }
                if end > index + 1 { result.append(group); index = end; continue }
            }
            index += 1
        }
        return result
    }
}

public struct TextReplacementStore: Sendable {
    public let url: URL
    public init(root: URL) { url = root.appendingPathComponent("text-replacement-rules.json") }
    public func rules() throws -> [TextReplacementRule] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let value = try JSONDecoder().decode([TextReplacementRule].self, from: CharacterCardImporter.read(url, limit: 4 * 1024 * 1024))
        try validate(value); return value
    }
    public func save(_ rules: [TextReplacementRule]) throws {
        try validate(rules)
        let data = try JSONEncoder().encode(rules)
        guard data.count <= 4 * 1024 * 1024 else { throw MoReadError.invalid("规则文件超过 4 MB，原规则已保留。") }
        try data.write(to: url, options: .atomic)
    }
    private func validate(_ rules: [TextReplacementRule]) throws {
        guard rules.count <= 500, Set(rules.map(\.id)).count == rules.count else { throw MoReadError.invalid("规则数量超过 500 条，或存在重复编号。") }
        for rule in rules { _ = try rule.expression() }
    }
}
