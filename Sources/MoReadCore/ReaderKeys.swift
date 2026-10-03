import Foundation

public struct ReaderKey: Codable, Hashable, Sendable {
    public var code: Int
    public var modifiers: Int
    public init(code: Int, modifiers: Int = 0) { self.code = code; self.modifiers = modifiers & 15 }
    public var isValid: Bool { (4..<224).contains(code) && ![41, 57, 71, 83, 102].contains(code) && (0...15).contains(modifiers) }
    public var label: String {
        let names = [40: "回车", 43: "Tab", 45: "-", 46: "=", 47: "[", 48: "]", 49: "\\", 50: "#", 51: ";", 52: "'", 53: "`", 54: ",", 55: ".", 56: "/", 42: "退格", 44: "空格", 73: "Insert", 74: "Home", 75: "Page Up", 76: "Delete", 77: "End", 78: "Page Down", 79: "→", 80: "←", 81: "↓", 82: "↑"]
        let name: String
        if (4...29).contains(code) { name = String(UnicodeScalar(65 + code - 4)!) }
        else if (30...39).contains(code) { name = String((code - 29) % 10) }
        else if (58...69).contains(code) { name = "F\(code - 57)" }
        else { name = names[code] ?? "按键 \(code)" }
        return [(1, "⇧"), (2, "⌃"), (4, "⌥"), (8, "⌘")].filter { modifiers & $0.0 != 0 }.map(\.1).joined() + name
    }
}
public struct ReaderKeyBinding: Codable, Equatable, Sendable {
    public var key: ReaderKey
    public var forward: Bool
    public init(key: ReaderKey, forward: Bool) { self.key = key; self.forward = forward }
}
public struct ReaderKeys: Codable, Equatable, Sendable {
    public var enabled = false
    public var bindings = [ReaderKeyBinding(key: .init(code: 80), forward: false), ReaderKeyBinding(key: .init(code: 79), forward: true)]
    public init() {}
    public init(data: Data) {
        self = (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
        var seen = Set<ReaderKey>()
        bindings = Array(bindings.filter { $0.key.isValid && seen.insert($0.key).inserted }.prefix(32))
    }
    public mutating func bind(_ key: ReaderKey, forward: Bool) {
        guard key.isValid else { return }
        bindings.removeAll { $0.key == key }
        if bindings.count < 32 { bindings.append(.init(key: key, forward: forward)) }
    }
    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public func direction(for key: ReaderKey) -> Bool? { enabled ? bindings.first { $0.key == key }?.forward : nil }
}
