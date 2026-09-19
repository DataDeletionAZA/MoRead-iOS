import Foundation
import CoreFoundation

public struct ChapterRule: Decodable, Identifiable, Sendable {
    public let id: Int
    public let enable: Bool
    public let name: String
    public let rule: String
}

public enum TextEncoding: String, CaseIterable, Identifiable, Sendable {
    case automatic = "自动识别", utf8 = "UTF-8", utf16LE = "UTF-16 LE", utf16BE = "UTF-16 BE", gb18030 = "GB18030", big5 = "Big5"
    public var id: String { rawValue }
    public var encoding: String.Encoding? {
        switch self {
        case .automatic: return nil
        case .utf8: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .gb18030: return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case .big5: return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        }
    }
}

public enum TextImporter {
    public static func metadata(fileName: String, text: String) -> (title: String, author: String) {
        func captures(_ pattern: String, _ value: String) -> [String]? {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = expression.firstMatch(in: value, range: NSRange(location: 0, length: value.utf16.count)) else { return nil }
            return (1..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : (value as NSString).substring(with: range)
            }
        }
        func clean(_ value: String) -> String {
            String(value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "-_—–· ")).split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200))
        }
        func author(_ value: String) -> String {
            var value = clean(value)
            for prefix in ["作者：", "作者:"] where value.hasPrefix(prefix) { value = String(value.dropFirst(prefix.count)) }
            if value.hasSuffix("著") { value.removeLast() }
            value = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            return ["完结", "全本", "精校", "校对", "修订", "出版", "网络版", "实体版", "全集", "简体", "繁体", "txt", "epub", "new"].contains(value.lowercased()) ? "" : value
        }
        let base = (fileName as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = clean(base), writer = ""
        if let parts = captures("^《([^》]+)》\\s*(.+)?$", base) { title = clean(parts[0]); writer = author(parts[1]) }
        else if let parts = captures("^(.+?)\\s+by\\s+(.+)$", base), !author(parts[1]).isEmpty { title = clean(parts[0]); writer = author(parts[1]) }
        else if let parts = captures("^[\\[【（(]([^\\]】）)]+)[\\]】）)]\\s*(.+)$", base), !author(parts[0]).isEmpty { title = clean(parts[1]); writer = author(parts[0]) }
        var count = 0, headerTitle: String?, headerAuthor: String?
        text.enumerateLines { line, stop in
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            count += 1
            if headerTitle == nil, let parts = captures("^\\s*(?:书名|标题|Title)\\s*[:：]\\s*(.+?)\\s*$", line) { headerTitle = clean(parts[0]) }
            if headerAuthor == nil, let parts = captures("^\\s*(?:作者|著者|作者名|Author)\\s*[:：]\\s*(.+?)\\s*$", line) { headerAuthor = author(parts[0]) }
            stop = count >= 24
        }
        if let headerTitle, !headerTitle.isEmpty { title = headerTitle }
        if let headerAuthor, !headerAuthor.isEmpty { writer = headerAuthor }
        return (title.isEmpty ? "未命名书籍" : title, writer)
    }
    public static let maximumBytes = 200 * 1024 * 1024
    public static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw MoReadError.invalid("文本文件超过 200 MB，请拆分后导入。") }
        return data
    }
    public static func rules() throws -> [ChapterRule] {
        guard let url = Bundle.module.url(forResource: "txtTocRule", withExtension: "json") else {
            throw MoReadError.invalid("找不到章节识别规则。")
        }
        return try JSONDecoder().decode([ChapterRule].self, from: Data(contentsOf: url))
    }

    public static func decode(_ data: Data, encoding: String.Encoding? = nil) throws -> String {
        try decoded(data, encoding: encoding).text
    }
    public static func decoded(_ data: Data, encoding: String.Encoding? = nil) throws -> (text: String, encoding: String.Encoding) {
        guard data.count <= maximumBytes else { throw MoReadError.invalid("文本文件超过 200 MB，请拆分后导入。") }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        var candidates: [String.Encoding]
        if let encoding { candidates = [encoding] }
        else if data.starts(with: [0xFF, 0xFE]) { candidates = [.utf16LittleEndian] }
        else if data.starts(with: [0xFE, 0xFF]) { candidates = [.utf16BigEndian] }
        else { candidates = [.utf8, gb, big5] }
        for candidate in candidates {
            if var text = String(data: data, encoding: candidate), !text.contains("\0") {
                if text.first == "\u{FEFF}" { text.removeFirst() }
                return (text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"), candidate)
            }
        }
        throw MoReadError.invalid("无法识别文字编码，请选择正确编码，或将文件另存为 UTF-8 后导入。")
    }

    public static func chapters(_ text: String, customRule: String? = nil) throws -> [Chapter] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MoReadError.invalid("这份文件没有正文。") }
        let expressions: [NSRegularExpression]
        if let customRule, !customRule.isEmpty {
            guard customRule.utf8.count <= 2048 else { throw MoReadError.invalid("分章规则过长。") }
            do { expressions = [try NSRegularExpression(pattern: customRule, options: [.anchorsMatchLines])] }
            catch { throw MoReadError.invalid("分章规则格式不正确：\(error.localizedDescription)") }
        } else {
            expressions = try rules().filter(\.enable).compactMap { try? NSRegularExpression(pattern: $0.rule, options: [.anchorsMatchLines]) }
        }
        let source = text as NSString
        var lines: [(start: Int, end: Int, title: String)] = []
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: [.byLines]) { line, range, full, _ in
            let title = (line ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, range.length <= 80 { lines.append((full.location, full.location + full.length, title)) }
        }
        var best: [(start: Int, end: Int, title: String)] = []
        for expression in expressions {
            try Task.checkCancellation()
            let matches = try lines.filter { line in
                let candidate = "\n" + source.substring(with: NSRange(location: line.start, length: line.end - line.start))
                var match: NSTextCheckingResult?
                var timedOut = false
                let deadline = Date().addingTimeInterval(0.05)
                expression.enumerateMatches(in: candidate, options: [.reportProgress], range: NSRange(location: 0, length: candidate.utf16.count)) { result, _, stop in
                    if let result { match = result; stop.pointee = true }
                    else if Task.isCancelled || Date() > deadline { timedOut = true; stop.pointee = true }
                }
                try Task.checkCancellation()
                guard !timedOut else { throw MoReadError.invalid("章节规则匹配耗时过长，请简化规则后重试。") }
                guard let match, match.range.length > 0 else { return false }
                // A heading starts a line; a chapter-like phrase inside prose is not a heading.
                return (candidate as NSString).substring(to: match.range.location).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if matches.count > best.count { best = matches }
        }
        if best.count >= 2 || (customRule?.isEmpty == false && !best.isEmpty) {
            var result: [Chapter] = []
            if best[0].start > 0 {
                let preface = source.substring(to: best[0].start)
                if !preface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(Chapter(id: 0, title: "序章", text: preface)) }
            }
            for (index, heading) in best.enumerated() {
                let end = index + 1 < best.count ? best[index + 1].start : source.length
                result.append(Chapter(id: result.count, title: heading.title, text: source.substring(with: NSRange(location: heading.end, length: end - heading.end))))
            }
            return result
        }
        if customRule?.isEmpty == false { throw MoReadError.invalid("这条规则没有识别出章节，请修改规则或选择自动识别。") }
        var result: [Chapter] = []
        var start = 0
        while start < source.length {
            var end = min(source.length, start + 10_000)
            if end < source.length {
                let newline = source.range(of: "\n", range: NSRange(location: end, length: min(2000, source.length - end)))
                if newline.location != NSNotFound { end = newline.location + 1 }
            }
            end = TextBoundary.floor(end, in: text)
            result.append(Chapter(id: result.count, title: result.isEmpty ? "正文" : "第 \(result.count + 1) 节", text: source.substring(with: NSRange(location: start, length: end - start))))
            start = end
        }
        return result
    }
}
