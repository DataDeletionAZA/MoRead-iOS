import XCTest
@testable import MoReadCore

final class CharacterCardTests: XCTestCase {
    func testVersionsMacrosAndWorldBookBoundaries() throws {
        let json = Data(#"{"spec":"chara_card_v2","data":{"name":"翎","description":"{{char}}陪{{user}}读书","character_book":{"entries":[{"content":"隐藏设定","enabled":false,"constant":true},{"content":"灯塔位于海边","keys":["灯塔"]},{"content":"总是耐心","constant":true}]},"extensions":{"unknown":7}}}"#.utf8)
        let card = try CharacterCardImporter.parse(json)
        XCTAssertEqual(card.name, "翎")
        XCTAssertEqual(card.sourceJSON, json)
        XCTAssertEqual(card.worldBook.count, 3)
        let plain = card.prompt(user: "读者", conversation: "你好")
        XCTAssertTrue(plain.contains("翎陪读者读书"))
        XCTAssertTrue(plain.contains("总是耐心"))
        XCTAssertFalse(plain.contains("隐藏设定"))
        XCTAssertFalse(plain.contains("灯塔位于海边"))
        XCTAssertTrue(card.prompt(user: "读者", conversation: "灯塔在哪里").contains("灯塔位于海边"))
        XCTAssertEqual(try CharacterCardImporter.parse(Data(#"{"name":"旧卡"}"#.utf8)).name, "旧卡")
    }
    func testPNGPrecedenceAndMalformedLength() throws {
        func chunk(_ type: String, _ payload: Data) -> Data {
            let n = UInt32(payload.count)
            return Data([UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]) + Data(type.utf8) + payload + Data(repeating: 0, count: 4)
        }
        let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let v2 = Data("chara\0".utf8) + Data(Data(#"{"name":"旧"}"#.utf8).base64EncodedString().utf8)
        let v3 = Data("ccv3\0".utf8) + Data(Data(#"{"data":{"name":"新"}}"#.utf8).base64EncodedString().utf8)
        let png = signature + chunk("tEXt", v2) + chunk("tEXt", v3) + chunk("IEND", Data())
        let card = try CharacterCardImporter.parse(png)
        XCTAssertEqual(card.name, "新"); XCTAssertEqual(card.avatar, png)
        XCTAssertThrowsError(try CharacterCardImporter.parse(signature + Data(repeating: 255, count: 12)))
        XCTAssertThrowsError(try CharacterCardImporter.parse(Data("{}".utf8)))
    }
}
