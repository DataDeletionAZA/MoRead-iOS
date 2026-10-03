import Foundation
import ImageIO

public struct ImportedImage: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let importedAt: Date
}

public struct ImageLibrary: Sendable {
    public static let maximumBytes = 4 * 1024 * 1024
    public let root: URL
    public init(root: URL) { self.root = root.appendingPathComponent("images", isDirectory: true) }
    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func file(_ id: UUID) -> URL { directory(id).appendingPathComponent("image.jpg") }
    public var selectionURL: URL { root.deletingLastPathComponent().appendingPathComponent("reader-background.json") }
    public func selectBackground(_ id: UUID?) throws {
        if let id { _ = try data(id) }
        try JSONEncoder().encode(id).write(to: selectionURL, options: .atomic)
    }
    public func selectedBackground() throws -> UUID? {
        guard FileManager.default.fileExists(atPath: selectionURL.path) else { return nil }
        return try JSONDecoder().decode(UUID?.self, from: CharacterCardImporter.read(selectionURL, limit: 128))
    }
    public func migrateLegacyBackground() throws -> ImportedImage? {
        let manager = FileManager.default
        let legacy = root.deletingLastPathComponent().appendingPathComponent("reader-background.jpg")
        guard !manager.fileExists(atPath: selectionURL.path), manager.fileExists(atPath: legacy.path) else { return nil }
        let data = try CharacterCardImporter.read(legacy, limit: Self.maximumBytes)
        let image = try add(data, name: "阅读背景")
        try selectBackground(image.id)
        try manager.removeItem(at: legacy)
        return image
    }
    public func images() throws -> [ImportedImage] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]).map { url in
            guard let id = UUID(uuidString: url.lastPathComponent), try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw MoReadError.invalid("图片库目录无效。") }
            let metadata = url.appendingPathComponent("image.json")
            guard try metadata.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw MoReadError.invalid("图片记录无效。") }
            let image = try JSONDecoder().decode(ImportedImage.self, from: CharacterCardImporter.read(metadata, limit: 4096))
            guard image.id == id, image.name == Self.name(image.name), !image.name.isEmpty else { throw MoReadError.invalid("图片记录无效。") }
            _ = try data(id)
            return image
        }.sorted { $0.importedAt > $1.importedAt }
    }
    public func data(_ id: UUID) throws -> Data {
        let url = file(id), values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw MoReadError.invalid("图片文件无效。") }
        let data = try CharacterCardImporter.read(url, limit: Self.maximumBytes)
        try Self.validate(data)
        return data
    }
    private static func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 2048, height <= 2048,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) != nil else { throw MoReadError.invalid("图片内容无效。") }
    }
    public func add(_ data: Data, name: String) throws -> ImportedImage {
        try Self.validate(data)
        let name = Self.name(name)
        guard !name.isEmpty else { throw MoReadError.invalid("请输入图片名称。") }
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let image = ImportedImage(id: UUID(), name: name, importedAt: Date())
        let staging = root.appendingPathComponent(".import-" + UUID().uuidString)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        try data.write(to: staging.appendingPathComponent("image.jpg"), options: .atomic)
        try JSONEncoder().encode(image).write(to: staging.appendingPathComponent("image.json"), options: .atomic)
        try manager.moveItem(at: staging, to: directory(image.id))
        return image
    }
    public func rename(_ image: ImportedImage, to name: String) throws {
        var updated = image; updated.name = Self.name(name)
        guard !updated.name.isEmpty else { throw MoReadError.invalid("请输入图片名称。") }
        try JSONEncoder().encode(updated).write(to: directory(image.id).appendingPathComponent("image.json"), options: .atomic)
    }
    public func remove(_ image: ImportedImage) throws { try FileManager.default.removeItem(at: directory(image.id)) }
    private static func name(_ value: String) -> String {
        String(value.components(separatedBy: .controlCharacters).joined().trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
    }
}
