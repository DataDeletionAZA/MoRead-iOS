import XCTest
@testable import MoReadCore

final class MDictTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Dictionary"))
    }
    func testOriginalDictionaryVariantsAndResourceRecords() throws {
        for name in ["sample-v1.mdx", "sample-v2.mdx", "sample-utf16.mdx", "sample-index-encrypted.mdx", "sample-lzo.mdx"] {
            let reader = try MDictReader(url: fixture(name))
            XCTAssertEqual(reader.title, "MoRead Test", name)
            XCTAssertEqual(try reader.definition("APPLE"), "<b>apple</b> 苹果", name)
            XCTAssertEqual(try reader.definition("world"), "世界", name)
            XCTAssertEqual(try reader.definition("book"), try reader.definition("books"), name)
            XCTAssertNil(try reader.definition("missing"), name)
        }
        let resources = try MDictReader(url: fixture("sample.mdd"))
        XCTAssertEqual(String(data: try XCTUnwrap(resources.lookup("style.css")), encoding: .utf8), "body{color:blue}")
        XCTAssertTrue(String(data: try XCTUnwrap(resources.lookup("/image.svg")), encoding: .utf8)?.hasPrefix("<svg") == true)
        XCTAssertNil(try resources.lookup("/missing.png"))
        XCTAssertNoThrow(try MDictReader(url: fixture("sample-classical.mdx")))
    }
    func testCorruptionTruncationAndBoundedDecompression() throws {
        let source = try Data(contentsOf: fixture("sample-v2.mdx"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.mdx")
        for size in [0, 3, 20, 100, source.count - 1] {
            try source.prefix(size).write(to: url)
            XCTAssertThrowsError(try MDictReader(url: url))
        }
        var corrupted = source; corrupted[20] ^= 1
        try corrupted.write(to: url); XCTAssertThrowsError(try MDictReader(url: url))
        try source.write(to: url)
        let reader = try MDictReader(url: url)
        try source.prefix(100).write(to: url)
        XCTAssertThrowsError(try reader.definition("apple"))
        XCTAssertThrowsError(try MDictCompression.unpack(Data(repeating: 0, count: 8), expected: MDictCompression.maximumBlock + 1))
        XCTAssertThrowsError(try MDictCompression.lzo(Data([18, 97, 72, 255, 17, 0, 0]), expected: 4))
        XCTAssertThrowsError(try MDictCompression.lzo(Data([18, 97, 32, 255, 0, 0, 17, 0, 0]), expected: 4))
        XCTAssertThrowsError(try MDictCompression.lzo(Data([17, 0, 0, 99]), expected: 0))
    }
    func testLZOMatchOverlapAndLongDistances() throws {
        let end: [UInt8] = [17, 0, 0]
        XCTAssertEqual(try MDictCompression.lzo(Data(end), expected: 0), Data())
        XCTAssertEqual(try MDictCompression.lzo(Data([20, 97, 98, 99, 72, 0] + end), expected: 6), Data("abcabc".utf8))
        XCTAssertEqual(try MDictCompression.lzo(Data([18, 97, 0, 0] + end), expected: 3), Data("aaa".utf8))
        XCTAssertEqual(try MDictCompression.lzo(Data([18, 97, 32, 6, 0, 0] + end), expected: 40), Data(repeating: 97, count: 40))
        XCTAssertEqual(try MDictCompression.lzo(Data([20, 97, 98, 99, 33, 9, 0, 88, 0, 0] + end), expected: 9), Data("abcabcXXX".utf8))
        for (size, match) in [(2050, [UInt8(0), 0]), (16385, [UInt8(17), 4, 0]), (32769, [UInt8(25), 4, 0])] {
            let payload = (0..<size).map { UInt8($0 % 251) }
            let extended = size - 18
            let prefix: [UInt8] = [0] + Array(repeating: 0, count: extended / 255) + [UInt8(extended % 255)]
            let start = size == 2050 ? 1 : 0
            let decoded = try MDictCompression.lzo(Data(prefix + payload + match + end), expected: size + 3)
            XCTAssertEqual(decoded, Data(payload + payload[start..<(start + 3)]))
        }
    }
    func testRIPEMD128ReferenceVectors() {
        for (input, digest) in ["": "cdf26213a150dc3ecb610f18f6b38b46", "a": "86be7afa339d0fc7cfc785e72f578d33", "abc": "c14a12199c66e4ba84636b0f69144c77", "message digest": "9e327b3d6e523062afc1132d7df9d1b8", String(repeating: "1234567890", count: 8): "3f45ef194732c2dbb2c4a2c769795fa3"] {
            XCTAssertEqual(MDictCompression.ripemd128(Data(input.utf8)).map { String(format: "%02x", $0) }.joined(), digest)
        }
    }
    func testMultipleKeyBlocksSplitUTF8RecordsAndLinkCycles() throws {
        let reader = try MDictReader(url: fixture("sample-boundaries.mdx"))
        XCTAssertEqual(reader.title, "Boundary & Test")
        for i in 0..<100 {
            XCTAssertEqual(try reader.definition(String(format: "word%03d", i)), "<b>\(i)</b> " + String(repeating: "跨块释义。", count: i % 5 + 1))
        }
        XCTAssertEqual(try reader.definition("alias"), try reader.definition("word099"))
        XCTAssertNil(try reader.definition("loopa"))
        XCTAssertNil(try reader.definition("word050missing"))
        XCTAssertEqual(try MDictReader(url: fixture("sample-gbk.mdx")).definition("中文"), "中文释义")
        XCTAssertEqual(try MDictReader(url: fixture("sample-big5.mdx")).definition("中文"), "中文釋義")
    }
    func testHeaderDeclarationFlagsAndCorruption() throws {
        let source = try Data(contentsOf: fixture("sample-v2.mdx"))
        var cursor = MDictBytes(source)
        let headerSize = try cursor.integer(4)
        let header = try XCTUnwrap(String(data: cursor.read(headerSize), encoding: .utf16LittleEndian))
        XCTAssertTrue(header.contains("Encrypted=\"0\""))
        XCTAssertTrue(header.contains("GeneratedByEngineVersion=\"2.0\""))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mdx")
        defer { try? FileManager.default.removeItem(at: url) }
        func writeHeader(_ value: String) throws {
            let bytes = try XCTUnwrap(value.data(using: .utf16LittleEndian))
            var size = UInt32(bytes.count).bigEndian, checksum = MDictCompression.checksum(bytes).littleEndian
            let changed = withUnsafeBytes(of: &size) { Data($0) } + bytes + withUnsafeBytes(of: &checksum) { Data($0) } + source.dropFirst(headerSize + 8)
            try changed.write(to: url)
        }
        try writeHeader("<?xml version=\"1.0\" encoding=\"UTF-16\"?>" + header.replacingOccurrences(of: "Encrypted=\"0\"", with: "Encrypted=\"No\""))
        XCTAssertEqual(try MDictReader(url: url).definition("apple"), "<b>apple</b> 苹果")
        try writeHeader(header.replacingOccurrences(of: "GeneratedByEngineVersion=\"2.0\"", with: "GeneratedByEngineVersion=\"3.0\""))
        XCTAssertThrowsError(try MDictReader(url: url))
        try writeHeader(header.replacingOccurrences(of: "Encrypted=\"0\"", with: "Encrypted=\"Yes\""))
        XCTAssertThrowsError(try MDictReader(url: url))
        try writeHeader("<!DOCTYPE Dictionary [<!ENTITY text 'expanded'>]>" + header)
        XCTAssertThrowsError(try MDictReader(url: url))
        for offset in source.indices {
            var changed = source; changed[offset] ^= 0x80
            try changed.write(to: url)
            do {
                let reader = try MDictReader(url: url)
                for word in ["apple", "books", "hello", "world"] { _ = try reader.definition(word) }
            } catch { }
        }
    }
    func testCancelledReadingStops() async throws {
        let url = try fixture("sample-boundaries.mdx")
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MDictReader(url: url).definition("word099")
        }
        do { _ = try await task.value; XCTFail("Cancelled dictionary lookup completed") }
        catch is CancellationError { }
    }
}
