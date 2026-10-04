import XCTest
@testable import MoReadCore

final class ReviewCardCSSTests: XCTestCase {
    func testTemplateCollectionCannotSaveMoreThanItCanRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try LibraryStore(root: root)
        var value = ReviewCardTemplate(); value.css = "/*" + String(repeating: "墨", count: 3996) + "*/"
        var values: [ReviewCardTemplate] = [], data = Data()
        while true {
            value.id = UUID()
            let next = try JSONEncoder().encode(values + [value])
            if next.count > 1_048_576 { break }
            values.append(value); data = next
        }
        let file = root.appendingPathComponent("review-card-templates.json")
        try data.write(to: file)
        let library = ReviewCardLibrary(root: root)
        XCTAssertEqual(try library.templates().count, values.count)
        XCTAssertThrowsError(try library.save(value))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testColorsGradientsAndStopInterpolation() throws {
        XCTAssertEqual(try ReviewCardColor.parse("#abc").rgba, 0xAABBCCFF)
        XCTAssertEqual(try ReviewCardColor.parse("#1234").rgba, 0x11223344)
        XCTAssertEqual(try ReviewCardColor.parse("#12345678").rgba, 0x12345678)
        XCTAssertEqual(try ReviewCardColor.parse("rgb(100%, 0%, 50%)").rgba, 0xFF007FFF)
        XCTAssertEqual(try ReviewCardColor.parse("rgba(300, -2, 16, 0.5)").rgba, 0xFF00107F)
        let gradient = try ReviewCardGradient.parse("linear-gradient(to right, rgb(255, 0, 0) 20%, #fff, rgba(0,0,255,1) 80%)")
        XCTAssertEqual(gradient.angle, 90); XCTAssertEqual(gradient.stops, [0.2, 0.5, 0.8])
        XCTAssertEqual(gradient.colors.map(\.rgba), [0xFF0000FF, 0xFFFFFFFF, 0x0000FFFF])
        let descending = try ReviewCardGradient.parse("linear-gradient(-90deg, #000 70%, #f00 30%, #fff)")
        XCTAssertEqual(descending.angle, 270); XCTAssertEqual(descending.stops, [0.7, 0.7, 1])
        for bad in ["linear-gradient(red)", "linear-gradient(to nowhere, red, white)", "linear-gradient(red -1%, white)", "linear-gradient(rgb(1,2,3), potato)"] { XCTAssertThrowsError(try ReviewCardGradient.parse(bad)) }
    }
    func testDeclarationOverridesAssetsLimitsAndTextPaint() throws {
        let font = UUID(), image = UUID()
        let style = try ReviewCardCSS.parse("""
        /* card */ color: #112233; color: linear-gradient(45deg, #1234, #abc);
        background: #ffffff; background-image: url('asset:\(image)');
        font-family: 'asset:\(font)'; font-weight: 600; font-style: italic;
        text-decoration: underline line-through; text-align: end; font-size: 0.5em;
        line-height: 2em; letter-spacing: -0.05em; padding: 0;
        margin-inline: 1em; margin-top: 2em; margin-bottom: 3em;
        border-width: 0.5em; border-radius: 2em; border-color: rgba(10,20,30,0.5);
        """)
        XCTAssertEqual(style.color?.rgba, 0x112233FF); XCTAssertEqual(style.textGradient?.angle, 45)
        XCTAssertEqual(style.backgroundImageID, image); XCTAssertEqual(style.customFontID, font)
        XCTAssertTrue(style.fontSpecified); XCTAssertEqual(style.bold, true); XCTAssertEqual(style.italic, true)
        XCTAssertEqual(style.underline, true); XCTAssertEqual(style.strikethrough, true)
        XCTAssertEqual(style.alignment, "right"); XCTAssertEqual(style.size, 23.5); XCTAssertEqual(style.lineHeight, 2)
        XCTAssertEqual(style.padding, 0); XCTAssertEqual(style.inset, 47); XCTAssertEqual(style.top, 94); XCTAssertEqual(style.bottom, 141)
        XCTAssertEqual(style.borderWidth, 23.5); XCTAssertEqual(style.radius, 94)
        let text = try ReviewCardCSS.parse("background: linear-gradient(to bottom, red, white); -webkit-background-clip: text; -webkit-text-fill-color: transparent;")
        XCTAssertNotNil(text.textGradient); XCTAssertNil(text.backgroundGradient); XCTAssertNil(text.background)
        XCTAssertEqual(text.quoteColor?.rgba, 0); XCTAssertNil(text.color)
        let reset = try ReviewCardCSS.parse("background-image: none; font-family: monospace; font-family: inherit; color: red !important;")
        XCTAssertTrue(reset.backgroundSpecified); XCTAssertNil(reset.backgroundImageID); XCTAssertFalse(reset.fontSpecified)
        for bad in ["padding: -1em", "padding: 7em", "font-size: 4em", "line-height: nan", "letter-spacing: 0.1", "border-width: 1em", "background-clip: text", "background: url(https://example.com/x)", "position: fixed", "font-family: asset:../../secret", "color: #zzz", String(repeating: " ", count: 4001)] {
            XCTAssertThrowsError(try ReviewCardCSS.parse(bad), bad)
        }
    }
    func testOlderTemplatesAndCSSPersistencePreserveOriginalOnInvalidSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try LibraryStore(root: root)
        var template = ReviewCardTemplate(); template.name = "旧模板"
        let original = try JSONEncoder().encode(template)
        XCTAssertNil(try JSONDecoder().decode(ReviewCardTemplate.self, from: original).css)
        let library = ReviewCardLibrary(root: root)
        template.css = "color: linear-gradient(to right, red, white); padding: 2em;"
        try library.save(template); XCTAssertEqual(try library.templates().first?.css, template.css)
        template.css = "padding: 100em"
        XCTAssertThrowsError(try library.save(template))
        XCTAssertEqual(try library.templates().first?.css, "color: linear-gradient(to right, red, white); padding: 2em;")
    }
}
