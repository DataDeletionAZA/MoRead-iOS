import Foundation
import CoreFoundation

public struct ChapterRule: Decodable, Identifiable, Sendable {
    public let id: Int
    public let enable: Bool
    public let name: String
    public let rule: String
}

public enum TextImporter {
    public static func rules() throws -> [ChapterRule] {
        guard let url = Bundle.module.url(forResource: "txtTocRule", withExtension: "json") else {
            throw MoReadError.invalid("找不到章节识别规则。")
        }
        return try JSONDecoder().decode([ChapterRule].self, from: Data(contentsOf: url))
    }

    public static func decode(_ data: Data, encoding: String.Encoding? = nil) throws -> String {
        guard data.count <= 100 * 1024 * 1024 else { throw MoReadError.invalid("文本文件超过 100 MB，请拆分后导入。") }
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
                return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
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
            let matches = lines.filter { line in
                let candidate = "\n" + source.substring(with: NSRange(location: line.start, length: line.end - line.start))
                return expression.firstMatch(in: candidate, range: NSRange(location: 0, length: candidate.utf16.count)) != nil
            }
            if matches.count > best.count { best = matches }
        }
        if best.count >= 2 {
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
