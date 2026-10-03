import XCTest
import SwiftSoup
@testable import MoReadCore

final class EPUBChineseTextTests: XCTestCase {
    func testRegionalConversionPreservesStructureAndOriginalNodeMappings() throws {
        let html = """
        <?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>軟體</title><style>p::before { content: '滑鼠'; }</style></head><body><p id="a">😀主機板 <em>滑鼠</em>，軟體。<br/>主機板&nbsp;資料庫。</p><ruby>滑鼠<rt>ㄏㄨㄚˊ</rt></ruby><img src="滑鼠.jpg" alt="滑鼠"/><svg viewBox="0 0 10 10"><linearGradient id="g"/></svg><script>const word = '滑鼠';</script></body></html>
        """
        let result = try EPUBChineseText.convert(html: html, mode: .tw2sp), document = try SwiftSoup.parse(result)
        XCTAssertEqual(try document.select("#a").text(), "😀主板 鼠标，软件。 主板 数据库。")
        XCTAssertEqual(try document.select("em").text(), "鼠标")
        XCTAssertEqual(try document.select("rt").text(), "ㄏㄨㄚˊ")
        XCTAssertEqual(try document.select("img").attr("src"), "滑鼠.jpg")
        XCTAssertEqual(try document.select("img").attr("alt"), "滑鼠")
        XCTAssertTrue(result.contains("viewBox=\"0 0 10 10\"")); XCTAssertTrue(result.contains("linearGradient"))
        XCTAssertTrue(result.contains("const word = '滑鼠';")); XCTAssertTrue(result.contains("content: '滑鼠';"))
        XCTAssertEqual(try document.select("br").size(), 1)
        let paragraph = try XCTUnwrap(document.select("#a").first())
        let mappings = try JSONDecoder().decode([EPUBChineseText.NodeConversion].self, from: Data(paragraph.attr(EPUBChineseText.attribute).utf8))
        XCTAssertEqual(mappings.map(\.index), [0, 1, 2])
        XCTAssertEqual(mappings.map(\.source), ["😀主機板 ", "，軟體。", "主機板\u{a0}資料庫。"])
        let nodes = paragraph.getChildNodes().compactMap { $0 as? TextNode }
        for row in mappings {
            XCTAssertEqual(row.display, nodes[row.index].getWholeText())
        }
        let change = try XCTUnwrap(mappings[0].stages.first?.first)
        XCTAssertEqual(change.sourceStart, 2); XCTAssertEqual(change.sourceLength, 3)
        XCTAssertEqual(change.displayStart, 2); XCTAssertEqual(change.displayLength, 2)
        XCTAssertEqual(try EPUBChineseText.convert(html: html, mode: .off), html)
    }
    func testInlineBoundariesRepeatedNodesAndMetadataEscaping() throws {
        let html = "<html><body><p id='a'>主<em>機</em>板</p><p id='b'>滑鼠<span>滑鼠</span>滑鼠</p><p id='c'>&quot;滑鼠&lt;/script&gt; &amp; 😀</p></body></html>"
        let result = try EPUBChineseText.convert(html: html, mode: .tw2sp), document = try SwiftSoup.parse(result)
        XCTAssertEqual(try document.select("#a").text(), "主机板")
        XCTAssertEqual(try document.select("#b").text(), "鼠标鼠标鼠标")
        XCTAssertEqual(try document.select("#c").text(), "\"鼠标</script> & 😀")
        XCTAssertEqual(try document.select("script").size(), 0)
        XCTAssertEqual(try document.select("em").text(), "机")
        let encoded = try document.select("#c").attr(EPUBChineseText.attribute)
        let row = try XCTUnwrap(JSONDecoder().decode([EPUBChineseText.NodeConversion].self, from: Data(encoded.utf8)).first)
        XCTAssertEqual(row.source, "\"滑鼠</script> & 😀")
        let traditional = try SwiftSoup.parse(EPUBChineseText.convert(html: "<p>鼠标和主板上的软件</p>", mode: .s2twp))
        XCTAssertEqual(try traditional.select("p").text(), "滑鼠和主機板上的軟體")
    }
    func testCancellationAndSizeBound() async throws {
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try EPUBChineseText.convert(html: "<p>滑鼠</p>", mode: .tw2sp) }
        do { _ = try await task.value; XCTFail("Cancelled conversion completed") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertThrowsError(try EPUBChineseText.convert(html: String(repeating: "x", count: 16 * 1024 * 1024 + 1), mode: .tw2sp))
    }
}
