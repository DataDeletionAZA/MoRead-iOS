import Foundation
import CryptoKit

public struct LocalDictionary: Codable, Equatable, Identifiable, Sendable {
    public struct Resource: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public let name: String
        public let sha256: String
    }
    public let id: UUID
    public let title: String
    public let originalName: String
    public let sha256: String
    public var enabled: Bool
    public var resources: [Resource]
}

public struct DictionaryDefinition: Identifiable, Sendable {
    public var id: UUID { dictionaryID }
    public let dictionaryID: UUID
    public let title: String
    public let html: String
}

public actor LocalDictionaries {
    public static let maximumBytes = 4 * 1024 * 1024 * 1024
    private let root: URL
    private var readers: [(URL, MDictReader)] = []
    public init(root: URL) { self.root = root.appendingPathComponent("dictionaries", isDirectory: true) }
    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func main(_ item: LocalDictionary) -> URL { directory(item.id).appendingPathComponent("main.mdx") }
    private func resource(_ item: LocalDictionary, _ resource: LocalDictionary.Resource) -> URL { directory(item.id).appendingPathComponent(resource.id.uuidString + ".mdd") }

    public func list() throws -> [LocalDictionary] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]).map { url in
            try Task.checkCancellation()
            guard let id = UUID(uuidString: url.lastPathComponent), try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw MoReadError.invalid("词典目录无效。") }
            let metadata = url.appendingPathComponent("dictionary.json")
            try checkFile(metadata, maximum: 1_048_576)
            let item = try JSONDecoder().decode(LocalDictionary.self, from: Data(contentsOf: metadata))
            guard item.id == id, !item.title.isEmpty, item.title.count <= 200, item.originalName.count <= 255,
                  validHash(item.sha256), item.resources.count <= 1000, Set(item.resources.map(\.id)).count == item.resources.count,
                  item.resources.allSatisfy({ $0.name.count <= 255 && validHash($0.sha256) }) else { throw MoReadError.invalid("词典记录无效。") }
            try checkFile(main(item))
            for part in item.resources { try checkFile(resource(item, part)) }
            return item
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    @discardableResult public func add(_ source: URL) throws -> (dictionary: LocalDictionary, duplicate: Bool) {
        guard source.pathExtension.lowercased() == "mdx" else { throw MoReadError.invalid("请选择 MDX 词典文件。") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let target = staging.appendingPathComponent("main.mdx")
        let digest = try copy(source, to: target)
        for item in try list() where item.sha256 == digest {
            if try fingerprint(main(item)) == digest { return (item, true) }
        }
        let reader = try MDictReader(url: target)
        try reader.validateFirstRecord()
        let plain = reader.declaredTitle.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholder = plain.lowercased().filter { $0.isLetter || $0.isNumber }
        let title = plain.isEmpty || ["title", "titlenohtmlcodeallowed", "untitled", "notitle"].contains(placeholder) ? source.deletingPathExtension().lastPathComponent : plain
        let item = LocalDictionary(id: UUID(), title: String(title.prefix(200)), originalName: String(source.lastPathComponent.prefix(255)), sha256: digest, enabled: true, resources: [])
        try JSONEncoder().encode(item).write(to: staging.appendingPathComponent("dictionary.json"), options: .atomic)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: directory(item.id))
        return (item, false)
    }
    @discardableResult public func addResource(_ source: URL, to id: UUID) throws -> Bool {
        guard source.pathExtension.lowercased() == "mdd" else { throw MoReadError.invalid("请选择 MDD 资源文件。") }
        var item = try require(id)
        guard item.resources.count < 1000 else { throw MoReadError.invalid("这本词典的资源包数量已达上限。") }
        let staging = directory(id).appendingPathComponent(".import-" + UUID().uuidString + ".mdd")
        defer { try? FileManager.default.removeItem(at: staging) }
        let digest = try copy(source, to: staging)
        for part in item.resources where part.sha256 == digest {
            if try fingerprint(resource(item, part)) == digest { return false }
        }
        try MDictReader(url: staging).validateFirstRecord()
        let part = LocalDictionary.Resource(id: UUID(), name: String(source.lastPathComponent.prefix(255)), sha256: digest)
        let target = resource(item, part)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: target)
        do { item.resources.append(part); try save(item) }
        catch { try? FileManager.default.removeItem(at: target); throw error }
        return true
    }
    public func setEnabled(_ id: UUID, _ enabled: Bool) throws { var item = try require(id); item.enabled = enabled; try save(item) }
    public func remove(_ id: UUID) throws {
        _ = try require(id)
        try FileManager.default.removeItem(at: directory(id))
        readers.removeAll { $0.0.deletingLastPathComponent() == directory(id) }
    }
    public func lookup(_ word: String) throws -> [DictionaryDefinition] {
        let query = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 80 else { throw MoReadError.invalid("请输入不超过 80 字的字词或短语。") }
        return try list().filter(\.enabled).compactMap { item in
            guard let html = try reader(main(item)).definition(query) else { return nil }
            return DictionaryDefinition(dictionaryID: item.id, title: item.title, html: String(html.prefix(2_000_000)))
        }
    }
    public func resource(_ id: UUID, path: String) throws -> Data? {
        guard path.count <= 4096 else { throw MoReadError.invalid("词典资源名称过长。") }
        let item = try require(id)
        for part in item.resources {
            if let data = try reader(resource(item, part)).lookup(path) { return data }
        }
        return nil
    }
    public func validateBackup() throws {
        for item in try list() {
            for (url, hash) in [(main(item), item.sha256)] + item.resources.map({ (resource(item, $0), $0.sha256) }) {
                guard try fingerprint(url) == hash else { throw MoReadError.invalid("备份中的词典文件校验失败。") }
                try MDictReader(url: url).validateFirstRecord()
            }
        }
    }
    private func require(_ id: UUID) throws -> LocalDictionary {
        guard let item = try list().first(where: { $0.id == id }) else { throw MoReadError.invalid("这本词典已不存在。") }
        return item
    }
    private func save(_ item: LocalDictionary) throws { try JSONEncoder().encode(item).write(to: directory(item.id).appendingPathComponent("dictionary.json"), options: .atomic) }
    private func validHash(_ hash: String) -> Bool { hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private func checkFile(_ url: URL, maximum: Int = maximumBytes) throws {
        let value = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard value.isRegularFile == true, value.isSymbolicLink != true, let size = value.fileSize, size > 0, size <= maximum else { throw MoReadError.invalid("词典文件无效或超过 4 GB。") }
    }
    private func reader(_ url: URL) throws -> MDictReader {
        if let index = readers.firstIndex(where: { $0.0 == url }) { let entry = readers.remove(at: index); readers.append(entry); return entry.1 }
        let value = try MDictReader(url: url)
        readers.append((url, value)); if readers.count > 6 { readers.removeFirst() }
        return value
    }
    private func fingerprint(_ url: URL) throws -> String { try copy(url, to: nil) }
    private func copy(_ source: URL, to target: URL?) throws -> String {
        try checkFile(source)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var output: FileHandle?
        if let target {
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw MoReadError.invalid("无法保存词典文件。") }
            output = try FileHandle(forWritingTo: target)
        }
        defer { try? output?.close() }
        var digest = SHA256(), total = 0
        while let bytes = try input.read(upToCount: 256 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            guard bytes.count <= Self.maximumBytes - total else { throw MoReadError.invalid("单个词典文件不能超过 4 GB。") }
            total += bytes.count; digest.update(data: bytes); try output?.write(contentsOf: bytes)
        }
        try output?.synchronize()
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
