import Foundation
import CoreFoundation

/// Reads MDX/MDD v1/v2 block indexes into memory and retrieves record blocks on demand.
public struct MDictReader: Sendable {
    private struct KeyBlock: Sendable { let last: String; let position, compressed, expanded, entries: Int }
    private struct RecordBlock: Sendable { let position, offset, compressed, expanded: Int }
    private struct Key { let offset: Int; let text: String }
    private let url: URL
    private let fileSize: Int
    private let keys: [KeyBlock]
    private let records: [RecordBlock]
    private let numberWidth: Int
    private let encoding: String.Encoding
    private let unit: Int
    private let resource: Bool
    private let caseSensitive: Bool
    private let stripKeys: Bool
    private let totalRecordBytes: Int
    public let title: String
    public let declaredTitle: String

    public init(url: URL) throws {
        try Task.checkCancellation()
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size <= Int.max else { throw MoReadError.invalid("词典文件过大。") }
        let fileSize = Int(size)
        try file.seek(toOffset: 0)
        func read(_ count: Int) throws -> Data { try Self.read(file, count: count, fileSize: fileSize) }
        func integer(_ width: Int, maximum: Int = Int.max) throws -> Int {
            var value = MDictBytes(try read(width)); return try value.integer(width, maximum: maximum)
        }
        let headerSize = try integer(4, maximum: 1_048_576)
        guard headerSize > 0 else { throw MoReadError.invalid("词典文件头无效。") }
        let header = try read(headerSize)
        var checksum = MDictBytes(try read(4))
        guard try checksum.number(4, littleEndian: true) == UInt64(MDictCompression.checksum(header)),
              let xml = String(data: header, encoding: .utf16LittleEndian)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0\u{FEFF}")),
              xml.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              xml.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw MoReadError.invalid("词典文件头损坏。") }
        let delegate = MDictHeader()
        let parser = XMLParser(data: Data([0xff, 0xfe]) + (xml.data(using: .utf16LittleEndian) ?? Data()))
        parser.delegate = delegate; parser.shouldResolveExternalEntities = false
        guard parser.parse(), let attrs = delegate.attributes else { throw MoReadError.invalid("词典文件头无法读取。") }
        let version = Double(attrs["GeneratedByEngineVersion"] ?? "1.2")
        guard let version, version.isFinite, version >= 1, version < 3 else { throw MoReadError.invalid("请选择 MDX 或 MDD 1.x、2.x 词典文件。") }
        let encryption = (attrs["Encrypted"] ?? "0").lowercased()
        let encrypted = encryption == "yes" ? 1 : encryption == "no" ? 0 : Int(encryption)
        guard let encrypted, encrypted >= 0, encrypted <= 3, encrypted & 1 == 0 else { throw MoReadError.invalid("这份词典需要授权密码，请使用可直接读取的词典文件。") }
        let resource = url.pathExtension.lowercased() == "mdd"
        let charset = attrs["Encoding"].flatMap { $0.isEmpty ? nil : $0 } ?? "UTF-8"
        let encoding: String.Encoding
        if resource || ["UTF16", "UTF16LE"].contains(charset.replacingOccurrences(of: "-", with: "").uppercased()) { encoding = .utf16LittleEndian }
        else {
            let code = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            guard code != kCFStringEncodingInvalidId else { throw MoReadError.invalid("无法识别词典文字编码：\(charset)。") }
            encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(code))
        }
        let caseSensitive = attrs["KeyCaseSensitive"]?.lowercased() == "yes"
        let stripKeys = !resource && attrs["StripKey"]?.lowercased() != "no"
        let width = version >= 2 ? 8 : 4
        let unit = [String.Encoding.utf16, .utf16LittleEndian, .utf16BigEndian].contains(encoding) ? 2 : 1
        let headerBytes = try read(width * (version >= 2 ? 5 : 4))
        var numbers = MDictBytes(headerBytes)
        let keyCount = try numbers.integer(width, maximum: 1_000_000)
        let entryCount = try numbers.integer(width)
        let expandedIndex = version >= 2 ? try numbers.integer(width, maximum: MDictCompression.maximumBlock) : 0
        let indexSize = try numbers.integer(width, maximum: MDictCompression.maximumBlock)
        let keyBytes = try numbers.integer(width)
        if version >= 2 {
            guard try integer(4) == Int(MDictCompression.checksum(headerBytes)) else { throw MoReadError.invalid("词典索引头校验失败。") }
        }
        let rawIndex = try read(indexSize)
        let indexBytes = version >= 2 ? try MDictCompression.unpack(encrypted & 2 == 0 ? rawIndex : MDictCompression.decodeIndex(rawIndex), expected: expandedIndex) : rawIndex
        var index = MDictBytes(indexBytes), keys: [KeyBlock] = []
        var keyPosition = Int(try file.offset()), indexedEntries = 0
        guard keyBytes <= fileSize - keyPosition else { throw MoReadError.invalid("词典词条索引不完整。") }
        let keyEnd = keyPosition + keyBytes
        func indexText() throws -> String {
            let count = try index.integer(version >= 2 ? 2 : 1)
            let data = try index.read(count * unit)
            if version >= 2, try index.read(unit).contains(where: { $0 != 0 }) { throw MoReadError.invalid("词典词条分隔符无效。") }
            guard let text = String(data: data, encoding: encoding) else { throw MoReadError.invalid("词典词条编码损坏。") }
            return text
        }
        for _ in 0..<keyCount {
            try Task.checkCancellation()
            let count = try index.integer(width, maximum: 1_000_000)
            _ = try indexText(); let last = try indexText()
            let compressed = try index.integer(width, maximum: MDictCompression.maximumBlock)
            let expanded = try index.integer(width, maximum: MDictCompression.maximumBlock)
            guard compressed <= keyEnd - keyPosition else { throw MoReadError.invalid("词典词条分块超出文件范围。") }
            keys.append(KeyBlock(last: Self.normalize(last, resource: resource, caseSensitive: caseSensitive, stripKeys: stripKeys), position: keyPosition, compressed: compressed, expanded: expanded, entries: count))
            keyPosition += compressed; indexedEntries += count
        }
        guard index.remaining == 0, keyPosition == keyEnd, indexedEntries == entryCount else { throw MoReadError.invalid("词典词条索引损坏。") }
        try file.seek(toOffset: UInt64(keyEnd))
        let recordCount = try integer(width, maximum: 1_000_000)
        guard try integer(width) == entryCount else { throw MoReadError.invalid("词典正文数量与词条索引不符。") }
        let recordIndexSize = try integer(width)
        let compressedRecords = try integer(width)
        guard recordIndexSize == recordCount * width * 2 else { throw MoReadError.invalid("词典正文索引损坏。") }
        var recordIndex = MDictBytes(try read(recordIndexSize)), records: [RecordBlock] = []
        var recordPosition = Int(try file.offset()), total = 0
        guard compressedRecords <= fileSize - recordPosition else { throw MoReadError.invalid("词典正文不完整。") }
        let recordEnd = recordPosition + compressedRecords
        for _ in 0..<recordCount {
            try Task.checkCancellation()
            let compressed = try recordIndex.integer(width, maximum: MDictCompression.maximumBlock)
            let expanded = try recordIndex.integer(width, maximum: MDictCompression.maximumBlock)
            guard compressed <= recordEnd - recordPosition else { throw MoReadError.invalid("词典正文分块超出文件范围。") }
            records.append(RecordBlock(position: recordPosition, offset: total, compressed: compressed, expanded: expanded))
            recordPosition += compressed; total += expanded
        }
        guard recordPosition == recordEnd else { throw MoReadError.invalid("词典正文分块大小不符。") }
        self.url = url; self.fileSize = fileSize; self.keys = keys; self.records = records
        self.numberWidth = width; self.encoding = encoding; self.unit = unit; self.resource = resource
        self.caseSensitive = caseSensitive; self.stripKeys = stripKeys; totalRecordBytes = total
        declaredTitle = attrs["Title"] ?? ""
        title = declaredTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url.deletingPathExtension().lastPathComponent : declaredTitle
    }
    public func lookup(_ word: String) throws -> Data? {
        try Task.checkCancellation()
        let target = normalize(word)
        guard !target.isEmpty else { return nil }
        var lower = 0, upper = keys.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if keys[middle].last.utf16.lexicographicallyPrecedes(target.utf16) { lower = middle + 1 } else { upper = middle }
        }
        guard lower < keys.count else { return nil }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let entries = try readKeys(file, block: keys[lower])
        guard let found = entries.firstIndex(where: { normalize($0.text).utf16.elementsEqual(target.utf16) }) else { return nil }
        let start = entries[found].offset
        var end = entries.dropFirst(found + 1).first(where: { $0.offset > start })?.offset
        var next = lower + 1
        while end == nil, next < keys.count {
            end = try readKeys(file, block: keys[next]).first(where: { $0.offset > start })?.offset
            next += 1
        }
        let finish = end ?? totalRecordBytes
        guard start <= finish, finish <= totalRecordBytes, finish - start <= 16 * 1024 * 1024 else { throw MoReadError.invalid("词条过大或位置索引损坏。") }
        var result = Data(); result.reserveCapacity(finish - start)
        lower = 0; upper = records.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if records[middle].offset + records[middle].expanded <= start { lower = middle + 1 } else { upper = middle }
        }
        for block in records.dropFirst(lower) {
            if block.offset >= finish { break }
            try Task.checkCancellation()
            try file.seek(toOffset: UInt64(block.position))
            let bytes = try MDictCompression.unpack(Self.read(file, count: block.compressed, fileSize: fileSize), expected: block.expanded)
            result.append(bytes.subdata(in: max(0, start - block.offset)..<min(bytes.count, finish - block.offset)))
        }
        guard result.count == finish - start else { throw MoReadError.invalid("词条正文不完整。") }
        return result
    }
    public func definition(_ word: String) throws -> String? {
        var current = word, visited = Set<String>()
        for _ in 0..<8 {
            guard visited.insert(normalize(current)).inserted, let bytes = try lookup(current) else { return nil }
            guard let decoded = String(data: bytes, encoding: encoding) else { throw MoReadError.invalid("词条正文编码损坏。") }
            let value = String(decoded.reversed().drop(while: { $0 == "\0" }).reversed())
            guard value.hasPrefix("@@@LINK=") else { return value }
            current = String(value.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
    private func readKeys(_ file: FileHandle, block: KeyBlock) throws -> [Key] {
        try Task.checkCancellation()
        try file.seek(toOffset: UInt64(block.position))
        var bytes = MDictBytes(try MDictCompression.unpack(Self.read(file, count: block.compressed, fileSize: fileSize), expected: block.expanded))
        var result: [Key] = []
        for entry in 0..<block.entries {
            if entry % 256 == 0 { try Task.checkCancellation() }
            let offset = try bytes.integer(numberWidth, maximum: totalRecordBytes)
            guard result.last.map({ $0.offset <= offset }) ?? true else { throw MoReadError.invalid("词条位置顺序损坏。") }
            let begin = bytes.offset
            while true {
                let value = try bytes.number(unit)
                if value == 0 { break }
                guard bytes.offset - begin <= 32_768 else { throw MoReadError.invalid("词条名称过长。") }
            }
            guard let text = String(data: bytes.data.subdata(in: begin..<(bytes.offset - unit)), encoding: encoding) else { throw MoReadError.invalid("词条名称编码损坏。") }
            result.append(Key(offset: offset, text: text))
        }
        guard bytes.remaining == 0 else { throw MoReadError.invalid("词条分块与索引不符。") }
        return result
    }
    private func normalize(_ value: String) -> String { Self.normalize(value, resource: resource, caseSensitive: caseSensitive, stripKeys: stripKeys) }
    private static func normalize(_ value: String, resource: Bool, caseSensitive: Bool, stripKeys: Bool) -> String {
        var text = resource ? value.replacingOccurrences(of: "/", with: "\\") : value.trimmingCharacters(in: .whitespacesAndNewlines)
        if resource, !text.hasPrefix("\\") { text = "\\" + text }
        if stripKeys { text = String(text.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }) }
        return caseSensitive ? text : text.lowercased()
    }
    private static func read(_ file: FileHandle, count: Int, fileSize: Int) throws -> Data {
        let offset = try file.offset()
        guard count >= 0, count <= MDictCompression.maximumBlock, offset <= fileSize, UInt64(count) <= UInt64(fileSize) - offset else { throw MoReadError.invalid("词典文件不完整或分块过大。") }
        if count == 0 { return Data() }
        guard let data = try file.read(upToCount: count), data.count == count else { throw MoReadError.invalid("词典文件不完整。") }
        return data
    }
}

private final class MDictHeader: NSObject, XMLParserDelegate {
    var attributes: [String: String]?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if attributes == nil { attributes = attributeDict }
    }
}
