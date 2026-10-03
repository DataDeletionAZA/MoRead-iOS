import Foundation
import MoReadCore
import ReadiumShared

struct EPUBSourceBlock: Encodable {
    let start: Int
    let text: String
    let selector: String

    static func blocks(in chapter: Chapter, anchors: [EPUBAnchor]) throws -> [Self] {
        let anchors = anchors.filter { $0.chapter == chapter.id }.sorted { $0.offset < $1.offset }
        let source = chapter.text as NSString
        return try anchors.enumerated().compactMap { index, anchor in
            let end = (index + 1 < anchors.count ? anchors[index + 1].offset : source.length) - 1
            guard anchor.offset >= 0, end > anchor.offset, end < source.length,
                  let selector = try Locator(jsonString: anchor.locator)?.locations.cssSelector else { return nil }
            return Self(start: anchor.offset, text: source.substring(with: NSRange(location: anchor.offset, length: end - anchor.offset)), selector: selector)
        }
    }
    static func script(blocks: [Self], selecting: Bool, translations: [ParagraphTranslation]? = nil, restoring: Locator? = nil) throws -> String {
        guard let url = Bundle.main.url(forResource: "EPUBSourceMap", withExtension: "js") else { throw MoReadError.invalid("无法读取 EPUB 正文定位组件。") }
        let script = try String(contentsOf: url, encoding: .utf8)
        // Fixed-layout Readium spreads embed evaluated code in a template literal.
        let json = String(decoding: try JSONEncoder().encode(blocks), as: UTF8.self).replacingOccurrences(of: "$", with: "\\u0024")
        let rows = String(decoding: try JSONEncoder().encode(translations), as: UTF8.self).replacingOccurrences(of: "$", with: "\\u0024")
        let target = try restoring.map { String(decoding: try JSONSerialization.data(withJSONObject: $0.json), as: UTF8.self).replacingOccurrences(of: "$", with: "\\u0024") } ?? "null"
        return "(\(script))(\(json), \(selecting), \(rows), \(target));"
    }
}
