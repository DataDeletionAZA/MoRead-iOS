import Foundation
import SwiftSoup

public enum EPUBChineseText {
    public struct NodeConversion: Codable, Equatable, Sendable {
        public let index: Int
        public let source: String
        public let display: String
        public let stages: [[Change]]
        public struct Change: Codable, Equatable, Sendable {
            public let sourceStart: Int
            public let sourceLength: Int
            public let displayStart: Int
            public let displayLength: Int
        }
        init(index: Int, conversion: ChineseTextConversion) {
            self.index = index; source = conversion.source; display = conversion.text
            stages = conversion.stages.map { edits in edits.map {
                Change(sourceStart: $0.source.location, sourceLength: $0.source.length,
                       displayStart: $0.display.location, displayLength: $0.display.length)
            } }
        }
    }
    public static let attribute = "data-moread-chinese"

    /// Text-node boundaries preserve inline styles and ruby; metadata maps displayed selections back to the source.
    public static func convert(html: String, mode: ChineseConversionMode) throws -> String {
        if mode == .off { return html }
        try Task.checkCancellation()
        guard html.utf8.count <= 16 * 1024 * 1024 else { throw MoReadError.invalid("本页过大，无法转换文字显示。") }
        let document = try SwiftSoup.parse(html)
        document.outputSettings().prettyPrint(pretty: false).syntax(syntax: .xml)
        var stack: [Element] = [document], count = 0
        while let element = stack.popLast() {
            try Task.checkCancellation(); count += 1
            guard count <= 1_000_000 else { throw MoReadError.invalid("本页排版结构过大，无法转换文字显示。") }
            guard !["script", "style"].contains(element.tagNameNormal()) else { continue }
            // The resource always starts from the original or edited XHTML, never from a converted page.
            try element.removeAttr(attribute)
            let nodes = element.getChildNodes().compactMap { $0 as? TextNode }
            var mappings: [NodeConversion] = []
            for (index, node) in nodes.enumerated() {
                let value = try ChineseTextConversion(node.getWholeText(), mode: mode)
                guard value.text != value.source else { continue }
                mappings.append(.init(index: index, conversion: value)); node.text(value.text)
            }
            if !mappings.isEmpty {
                let encoded = try JSONEncoder().encode(mappings)
                try element.attr(attribute, String(decoding: encoded, as: UTF8.self))
            }
            stack.append(contentsOf: element.children().array().reversed())
        }
        try Task.checkCancellation()
        let result = try document.outerHtml()
        guard result.utf8.count <= 64 * 1024 * 1024 else { throw MoReadError.invalid("本页转换后的排版内容过大。") }
        return result
    }
}
