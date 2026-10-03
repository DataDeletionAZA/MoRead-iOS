import Foundation
import zlib

// MDX block checksums and index obfuscation are file-format operations, not credential cryptography.
enum MDictCompression {
    static let maximumBlock = 32 * 1024 * 1024
    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(adler32(1, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))) }
    }
    static func unpack(_ block: Data, expected: Int) throws -> Data {
        guard block.count >= 8, (0...maximumBlock).contains(expected) else { throw MoReadError.invalid("词典分块大小无效。") }
        var cursor = MDictBytes(block)
        let kind = try cursor.number(4, littleEndian: true)
        let checksum = try cursor.number(4)
        let compressed = try cursor.read(cursor.remaining)
        let output: Data
        switch kind {
        case 0: output = compressed
        case 1: output = try lzo(compressed, expected: expected)
        case 2:
            var bytes = Data(count: max(1, expected)), length = uLongf(max(1, expected)), consumed = uLong(compressed.count)
            let status = bytes.withUnsafeMutableBytes { destination in
                compressed.withUnsafeBytes { source in
                    uncompress2(destination.bindMemory(to: Bytef.self).baseAddress, &length, source.bindMemory(to: Bytef.self).baseAddress, &consumed)
                }
            }
            guard status == Z_OK, length == expected, consumed == compressed.count else { throw MoReadError.invalid("词典压缩分块损坏或大小不符。") }
            output = bytes.prefix(expected)
        default: throw MoReadError.invalid("词典使用了无法识别的压缩格式。")
        }
        guard output.count == expected, UInt64(Self.checksum(output)) == checksum else { throw MoReadError.invalid("词典校验失败，文件可能损坏。") }
        return output
    }
    // Classic LZO1X instructions: https://www.kernel.org/doc/html/latest/staging/lzo.html
    static func lzo(_ data: Data, expected: Int) throws -> Data {
        guard (0...maximumBlock).contains(expected) else { throw MoReadError.invalid("词典分块过大。") }
        var input = MDictBytes(data), output = [UInt8](), state = 0
        output.reserveCapacity(expected)
        func literals(_ count: Int) throws {
            guard count <= expected - output.count else { throw MoReadError.invalid("词典解压大小不符。") }
            output.append(contentsOf: try input.read(count))
        }
        func length(_ value: Int, mask: Int) throws -> Int {
            if value != 0 { return value }
            var result = mask
            while true {
                let next = try input.number(1)
                result += next == 0 ? 255 : Int(next)
                guard result <= maximumBlock else { throw MoReadError.invalid("词典分块过大。") }
                if next != 0 { return result }
            }
        }
        if let first = data.first, first > 17 {
            _ = try input.number(1)
            let count = Int(first) - 17
            try literals(count); state = min(count, 4)
        }
        while input.remaining > 0 {
            try Task.checkCancellation()
            let code = Int(try input.number(1))
            var count: Int, distance: Int, trailing: Int
            if code < 16 {
                if state == 0 {
                    try literals(length(code, mask: 15) + 3); state = 4; continue
                }
                count = state == 4 ? 3 : 2
                distance = (state == 4 ? 2049 : 1) + (code >> 2) + Int(try input.number(1)) * 4
                trailing = code & 3
            } else if code >= 64 {
                count = (code >> 5) + 1
                distance = 1 + ((code >> 2) & 7) + Int(try input.number(1)) * 8
                trailing = code & 3
            } else {
                count = try length(code & (code >= 32 ? 31 : 7), mask: code >= 32 ? 31 : 7) + 2
                let operand = Int(try input.number(2, littleEndian: true))
                trailing = operand & 3
                distance = code >= 32 ? 1 + (operand >> 2) : 16384 + ((code & 8) << 11) + (operand >> 2)
                if code < 32, distance == 16384 {
                    guard count == 3, trailing == 0, input.remaining == 0, output.count == expected else { throw MoReadError.invalid("词典压缩结束标记无效。") }
                    return Data(output)
                }
            }
            guard distance > 0, distance <= output.count, count <= expected - output.count else { throw MoReadError.invalid("词典压缩引用超出范围。") }
            for _ in 0..<count { output.append(output[output.count - distance]) }
            try literals(trailing); state = trailing
        }
        throw MoReadError.invalid("词典压缩分块不完整。")
    }
    static func decodeIndex(_ input: Data) throws -> Data {
        guard input.count >= 8 else { throw MoReadError.invalid("词典索引不完整。") }
        var bytes = Array(input)
        let key = Array(ripemd128(Data(bytes[4..<8]) + Data([0x95, 0x36, 0, 0])))
        var previous: UInt8 = 0x36
        for index in 8..<bytes.count {
            let byte = bytes[index]
            bytes[index] = (byte >> 4 | byte << 4) ^ previous ^ UInt8(truncatingIfNeeded: index - 8) ^ key[(index - 8) % 16]
            previous = byte
        }
        return Data(bytes)
    }
    // RIPEMD-128: https://homes.esat.kuleuven.be/~bosselae/ripemd/rmd128.txt
    static func ripemd128(_ data: Data) -> Data {
        let order = [Array(0..<16), [7,4,13,1,10,6,15,3,12,0,9,5,2,14,11,8], [3,10,14,4,9,15,8,1,2,7,0,6,13,11,5,12], [1,9,11,10,0,8,12,4,13,3,7,15,14,5,6,2]].flatMap { $0 }
        let parallelOrder = [[5,14,7,0,9,2,11,4,13,6,15,8,1,10,3,12], [6,11,3,7,0,13,5,10,14,15,8,12,4,9,1,2], [15,5,1,3,7,14,6,9,11,8,12,2,10,0,4,13], [8,6,4,1,3,11,15,0,5,12,2,13,9,7,10,14]].flatMap { $0 }
        let shifts = [[11,14,15,12,5,8,7,9,11,13,14,15,6,7,9,8], [7,6,8,13,11,9,7,15,7,12,15,9,11,7,13,12], [11,13,6,7,14,9,13,15,14,8,13,6,5,12,7,5], [11,12,14,15,14,15,9,8,9,14,5,6,8,6,5,12]].flatMap { $0 }
        let parallelShifts = [[8,9,9,11,13,15,15,5,7,7,8,11,14,14,12,6], [9,13,15,7,12,8,9,11,7,7,12,7,6,15,13,11], [9,7,15,11,8,6,6,14,12,13,5,14,13,13,7,5], [15,5,8,11,14,14,6,14,6,9,12,9,12,5,15,8]].flatMap { $0 }
        let constants: [UInt32] = [0, 0x5a827999, 0x6ed9eba1, 0x8f1bbcdc]
        let parallelConstants: [UInt32] = [0x50a28be6, 0x5c4dd124, 0x6d703ef3, 0]
        func f(_ round: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
            switch round { case 0: return x ^ y ^ z; case 1: return (x & y) | (~x & z); case 2: return (x | ~y) ^ z; default: return (x & z) | (y & ~z) }
        }
        func rotate(_ x: UInt32, _ n: Int) -> UInt32 { (x << n) | (x >> (32 - n)) }
        var bytes = Array(data), bitCount = (UInt64(data.count) &* 8).littleEndian
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        withUnsafeBytes(of: &bitCount) { bytes.append(contentsOf: $0) }
        var h: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]
        for base in stride(from: 0, to: bytes.count, by: 64) {
            let words: [UInt32] = (0..<16).map { i in (0..<4).reduce(0) { $0 | (UInt32(bytes[base + i * 4 + $1]) << ($1 * 8)) } }
            var a = h[0], b = h[1], c = h[2], d = h[3], aa = a, bb = b, cc = c, dd = d
            for j in 0..<64 {
                let t = rotate(a &+ f(j / 16, b, c, d) &+ words[order[j]] &+ constants[j / 16], shifts[j])
                a = d; d = c; c = b; b = t
                let tt = rotate(aa &+ f(3 - j / 16, bb, cc, dd) &+ words[parallelOrder[j]] &+ parallelConstants[j / 16], parallelShifts[j])
                aa = dd; dd = cc; cc = bb; bb = tt
            }
            h = [h[1] &+ c &+ dd, h[2] &+ d &+ aa, h[3] &+ a &+ bb, h[0] &+ b &+ cc]
        }
        return Data(h.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } })
    }
}

struct MDictBytes {
    let data: Data
    private(set) var offset: Int
    init(_ data: Data) { self.data = data; offset = data.startIndex }
    var remaining: Int { data.endIndex - offset }
    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw MoReadError.invalid("词典文件不完整。") }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
    mutating func number(_ count: Int, littleEndian: Bool = false) throws -> UInt64 {
        guard (1...8).contains(count), count <= remaining else { throw MoReadError.invalid("词典数字字段不完整。") }
        var value: UInt64 = 0
        for i in 0..<count { value |= UInt64(data[offset + i]) << ((littleEndian ? i : count - 1 - i) * 8) }
        offset += count; return value
    }
    mutating func integer(_ count: Int, maximum: Int = Int.max) throws -> Int {
        let value = try number(count)
        guard value <= UInt64(maximum) else { throw MoReadError.invalid("词典索引或分块过大。") }
        return Int(value)
    }
}
