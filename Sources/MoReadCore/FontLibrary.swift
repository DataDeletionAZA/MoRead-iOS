import Foundation
import CoreText

public struct ImportedFont: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let originalName: String
    public let fileExtension: String
    public let importedAt: Date
}

public struct FontLibrary: Sendable {
    public static let maximumBytes = 64 * 1024 * 1024
    public static let extensions = ["ttf", "otf", "ttc"]
    public let root: URL
    public init(root: URL) { self.root = root.appendingPathComponent("fonts", isDirectory: true) }
    public func file(_ font: ImportedFont) -> URL { directory(font.id).appendingPathComponent("font." + font.fileExtension) }
    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    public func fonts() throws -> [ImportedFont] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])
        return try urls.map { url in
            guard let id = UUID(uuidString: url.lastPathComponent), try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw MoReadError.invalid("字体库目录无效。") }
            let info = url.appendingPathComponent("font.json")
            guard try info.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]).fileSize ?? Int.max <= 4096,
                  try info.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw MoReadError.invalid("字体记录无效。") }
            let font = try JSONDecoder().decode(ImportedFont.self, from: Data(contentsOf: info))
            guard font.id == id, Self.extensions.contains(font.fileExtension), font.name == Self.name(font.name), !font.name.isEmpty,
                  font.originalName.count <= 255 else { throw MoReadError.invalid("字体记录无效。") }
            _ = try Self.descriptors(at: file(font))
            return font
        }.sorted { $0.importedAt > $1.importedAt }
    }

    public static func descriptors(at url: URL) throws -> [CTFontDescriptor] {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximumBytes,
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], !descriptors.isEmpty, descriptors.count <= 256,
              descriptors.allSatisfy({ CTFontGetGlyphCount(CTFontCreateWithFontDescriptor($0, 16, nil)) > 0 }) else { throw MoReadError.invalid("请选择有效的字体文件，大小不能超过 64 MB。") }
        return descriptors
    }

    public func add(_ source: URL, name: String? = nil) throws -> ImportedFont {
        let ext = source.pathExtension.lowercased()
        guard Self.extensions.contains(ext) else { throw MoReadError.invalid("请选择 TTF、OTF 或 TTC 字体。") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID(), staging = root.appendingPathComponent(".import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let target = staging.appendingPathComponent("font." + ext)
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw MoReadError.invalid("无法保存字体。") }
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: target)
        defer { try? input.close(); try? output.close() }
        var count = 0
        while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            guard chunk.count <= Self.maximumBytes - count else { throw MoReadError.invalid("字体文件超过 64 MB。") }
            count += chunk.count; try output.write(contentsOf: chunk)
        }
        try output.synchronize(); try output.close()
        let descriptors = try Self.descriptors(at: target)
        let detected = CTFontCopyFullName(CTFontCreateWithFontDescriptor(descriptors[0], 16, nil)) as String
        let displayName = Self.name(name ?? detected)
        guard !displayName.isEmpty else { throw MoReadError.invalid("请输入字体名称。") }
        let font = ImportedFont(id: id, name: displayName, originalName: String(source.lastPathComponent.prefix(255)), fileExtension: ext, importedAt: Date())
        try JSONEncoder().encode(font).write(to: staging.appendingPathComponent("font.json"), options: .atomic)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: directory(id))
        return font
    }
    public func rename(_ font: ImportedFont, to name: String) throws {
        var updated = font; updated.name = Self.name(name)
        guard !updated.name.isEmpty else { throw MoReadError.invalid("请输入字体名称。") }
        try JSONEncoder().encode(updated).write(to: directory(font.id).appendingPathComponent("font.json"), options: .atomic)
    }
    public func remove(_ font: ImportedFont) throws { try FileManager.default.removeItem(at: directory(font.id)) }
    private static func name(_ value: String) -> String {
        String(value.components(separatedBy: .controlCharacters).joined().trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
    }
}
