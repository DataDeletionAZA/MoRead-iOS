import XCTest
@testable import MoReadCore

final class CoverPaletteTests: XCTestCase {
    func testTransparentGrayAndSmallVibrantMarkKeepReadableThemeColors() throws {
        XCTAssertNil(CoverPalette.extract(argb: [0x00FF0000, 0x7F00FF00]))
        let gray = try XCTUnwrap(CoverPalette.extract(argb: [0xFF808080]))
        XCTAssertEqual(gray.dominant, 0x808080); XCTAssertNil(gray.vibrant)
        let cover = try XCTUnwrap(CoverPalette.extract(argb: Array(repeating: 0xFFF5F1E8, count: 96) + Array(repeating: 0xFFBF3020, count: 4)))
        XCTAssertEqual(cover.vibrant, 0xBF3020)
        for background: UInt32 in [0xFFFFFF, 0xF2F2F7, 0x000000, 0x1C1C1E] {
            let dark = background < 0x808080
            for palette in [nil, gray, cover] {
                let value = CoverPalette.atmosphere(palette, background: background, dark: dark, fallback: 0x476153)
                XCTAssertGreaterThanOrEqual(CoverPalette.contrast(value.accent, background), 4.5)
                XCTAssertNotEqual(value.top, value.middle)
            }
        }
        XCTAssertEqual(CoverPalette.atmosphere(gray, background: 0xFFFFFF, dark: false, fallback: 0x476153), CoverPalette.atmosphere(nil, background: 0xFFFFFF, dark: false, fallback: 0x476153))
    }
}
