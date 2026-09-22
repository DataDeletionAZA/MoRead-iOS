import Foundation
import CryptoKit
import ReadiumZIPFoundation

public struct BackupManifest: Codable, Sendable {
    public struct File: Codable, Sendable {
        public let path: String
        public let bytes: Int64
        public let sha256: String
    }
    public var format = "MoRead-iOS"
    public var version = 1
    public var createdAt = Date()
    public var files: [File]
    public var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

public struct PreparedRestore: Sendable {
    public let directory: URL
    public let manifest: BackupManifest
    public let bookCount: Int
    public let conversationCount: Int
}

public enum BackupArchive {
    public static let maximumBytes: Int64 = 4 * 1024 * 1024 * 1024
    private static let maximumFiles = 50_000
    private static let manifestLimit = 16 * 1024 * 1024
    public typealias ProgressHandler = @Sendable (Int64, Int64) -> Void

    /// Callers keep application writers paused until the archive has finished.
    public static func create(root: URL, output: URL, onProgress: ProgressHandler = { _, _ in }) async throws -> BackupManifest {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let manager = FileManager.default
        guard !manager.fileExists(atPath: output.path), !output.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw MoReadError.invalid("请选择书库以外的新备份文件。") }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var enumerationError: Error?
        guard let iterator = manager.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationError = error; return false }) else { throw MoReadError.invalid("无法读取书库。") }
        var files: [(url: URL, path: String, bytes: Int64)] = []
        var total: Int64 = 0
        while let item = iterator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try item.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else { throw MoReadError.invalid("书库中存在链接文件，无法安全备份。") }
            guard values.isRegularFile == true else { continue }
            let url = item.resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { throw MoReadError.invalid("备份文件不在书库目录中。") }
            let path = String(url.path.dropFirst(root.path.count + 1))
            let size = Int64(values.fileSize ?? 0)
            guard safePath(path), files.count < maximumFiles - 1, size >= 0, size <= maximumBytes - total else { throw MoReadError.invalid("书库超出备份大小或文件数量限制。") }
            total += size; files.append((url, path, size))
        }
        if let enumerationError { throw enumerationError }
        try requireSpace(at: output.deletingLastPathComponent(), bytes: total)
        let partial = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".part")
        defer { try? manager.removeItem(at: partial) }
        let archive = try await Archive(url: partial, accessMode: .create)
        var manifest = BackupManifest(files: [])
        var completed: Int64 = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let digest = try checksum(file.url)
            try await archive.addEntry(with: "data/" + file.path, fileURL: file.url, compressionMethod: .deflate, bufferSize: 256 * 1024)
            manifest.files.append(.init(path: file.path, bytes: file.bytes, sha256: digest))
            completed += file.bytes; onProgress(completed, total)
        }
        let data = try JSONEncoder().encode(manifest)
        guard data.count <= manifestLimit else { throw MoReadError.invalid("备份文件清单过大。") }
        try await archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
            data.subdata(in: Int(position)..<min(data.count, Int(position) + size))
        }
        try Task.checkCancellation()
        try manager.moveItem(at: partial, to: output)
        return manifest
    }

    public static func prepare(_ input: URL, beside root: URL, onProgress: ProgressHandler = { _, _ in }) async throws -> PreparedRestore {
        try preflight(input)
        let manager = FileManager.default
        let archive = try await Archive(url: input, accessMode: .read)
        let entries = try await archive.entries()
        guard entries.count <= maximumFiles, entries.allSatisfy({ $0.type == .file }), let manifestEntry = entries.first(where: { $0.path == "manifest.json" }), manifestEntry.uncompressedSize <= manifestLimit else { throw MoReadError.invalid("这不是有效的墨知 iOS 备份。") }
        let manifestSink = try BackupSink(limit: Int64(manifestLimit))
        let crc = try await archive.extract(manifestEntry) { chunk in
            _ = try await manifestSink.write(chunk)
        }
        let (data, manifestBytes, _) = try await manifestSink.finish()
        guard crc == manifestEntry.checksum, manifestBytes == manifestEntry.uncompressedSize else { throw MoReadError.invalid("备份清单损坏。") }
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: data)
        guard manifest.format == "MoRead-iOS", manifest.version == 1, manifest.files.count + 1 == entries.count else { throw MoReadError.invalid("备份格式不匹配，请使用对应版本的墨知 iOS。") }
        var names: Set<String> = ["manifest.json"]
        var total: Int64 = 0
        for file in manifest.files {
            let name = "data/" + file.path
            guard safePath(file.path), names.insert(name.lowercased().precomposedStringWithCanonicalMapping).inserted,
                  file.bytes >= 0, file.bytes <= maximumBytes - total,
                  file.sha256.count == 64 else { throw MoReadError.invalid("备份包含重复文件、非法路径或过大的内容。") }
            if ["json", "plist"].contains((file.path as NSString).pathExtension.lowercased()), file.bytes > 128 * 1024 * 1024 { throw MoReadError.invalid("备份中的记录文件过大。") }
            total += file.bytes
        }
        guard Set(entries.map(\.path)) == Set(manifest.files.map { "data/" + $0.path }).union(["manifest.json"]) else { throw MoReadError.invalid("备份内容与清单不一致。") }
        try requireSpace(at: root.deletingLastPathComponent(), bytes: total)
        let staging = root.deletingLastPathComponent().appendingPathComponent("MoRead-restore-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        var valid = false
        defer { if !valid { try? manager.removeItem(at: staging) } }
        let indexed = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        var completed: Int64 = 0
        let expectedTotal = total
        for file in manifest.files {
            try Task.checkCancellation()
            guard let entry = indexed["data/" + file.path], entry.uncompressedSize == UInt64(file.bytes) else { throw MoReadError.invalid("备份文件大小不一致。") }
            let url = staging.appendingPathComponent(file.path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard manager.createFile(atPath: url.path, contents: nil) else { throw MoReadError.invalid("无法写入恢复文件。") }
            let sink = try BackupSink(limit: file.bytes, url: url)
            let before = completed
            let checksum = try await archive.extract(entry, bufferSize: 256 * 1024) { chunk in
                try Task.checkCancellation()
                let written = try await sink.write(chunk)
                onProgress(before + written, expectedTotal)
            }
            let (_, written, digest) = try await sink.finish()
            guard written == file.bytes, checksum == entry.checksum, digest == file.sha256 else { throw MoReadError.invalid("备份中的文件损坏，原书库保持不变。") }
            completed += written
        }
        _ = try FontLibrary(root: staging).fonts()
        let library = try LibraryStore(root: staging)
        let books = try library.books()
        _ = try library.organization()
        for book in books {
            _ = try library.coverData(for: book.id)
            guard !book.chapters.isEmpty, book.chapters.enumerated().allSatisfy({ $0.offset == $0.element.id && $0.element.length >= 0 }), ["txt", "epub"].contains(book.format),
                  book.chapters.indices.contains(book.position.chapter), book.chapters.indices.contains(book.readThrough.chapter),
                  book.position.offset >= 0, book.position.offset <= book.chapters[book.position.chapter].length,
                  book.readThrough.offset >= 0, book.readThrough.offset <= book.chapters[book.readThrough.chapter].length else { throw MoReadError.invalid("备份中的书籍索引无效。") }
            guard book.hasBody || book.removed else { throw MoReadError.invalid("备份中的正文清理状态无效。") }
            for index in book.chapters.indices where book.hasBody {
                let chapter = try library.chapter(index, in: book)
                guard chapter.text.utf16.count == book.chapters[index].length else { throw MoReadError.invalid("备份中的章节长度不一致。") }
            }
            try BookCharactersStore(library: library, bookID: book.id).validateBackup()
            let records = try library.records(for: book), notes = records.notes ?? []
            guard Set(notes.map(\.id)).count == notes.count else { throw MoReadError.invalid("备份包含重复笔记编号。") }
            for note in notes { try note.validate() }
            let knowledge = records.chapterKnowledge ?? []
            guard Set(knowledge.map(\.chapter)).count == knowledge.count else { throw MoReadError.invalid("备份包含重复的章节提纲。") }
            for entry in knowledge {
                try entry.validate()
                guard entry.bookID == book.id else { throw MoReadError.invalid("章节提纲与书籍不一致。") }
                if entry.visible(in: book) { try library.validateKnowledge(entry) }
            }
            if book.format == "epub", book.hasBody {
                guard manager.fileExists(atPath: library.directory(book.id).appendingPathComponent("original.epub").path), manager.fileExists(atPath: library.directory(book.id).appendingPathComponent("epub-map.json").path) else { throw MoReadError.invalid("备份缺少 EPUB 正文或定位信息。") }
            }
        }
        let companion = try CompanionStore(root: staging)
        _ = try companion.settings(); _ = try companion.characters()
        let conversations = try companion.conversations()
        if manager.fileExists(atPath: PersonaMemoryStore.url(in: staging).path) { try PersonaMemoryStore(root: staging).validate() }
        valid = true
        return PreparedRestore(directory: staging, manifest: manifest, bookCount: books.count, conversationCount: conversations.count)
    }

    /// Swapping directories is one filesystem operation. The old library remains at the prepared path.
    @discardableResult public static func activate(_ prepared: PreparedRestore, replacing root: URL) throws -> URL {
        try swap(prepared.directory, with: root)
        return prepared.directory
    }
    public static func undo(previous: URL, replacing root: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: previous.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw MoReadError.invalid("找不到恢复前的书库。") }
        _ = try LibraryStore(root: previous).books()
        try swap(previous, with: root)
    }
    private static func swap(_ other: URL, with root: URL) throws {
        guard other.deletingLastPathComponent().standardizedFileURL == root.deletingLastPathComponent().standardizedFileURL,
              other.lastPathComponent.hasPrefix("MoRead-restore-"), other != root else { throw MoReadError.invalid("恢复数据必须位于书库所在磁盘。") }
        try LibraryStore.swapDirectories(root, other)
    }

    private static func safePath(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 && !value.contains("\\") && !value.contains("\0") && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func checksum(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        return hex(hash.finalize())
    }
    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    private static func requireSpace(at url: URL, bytes: Int64) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        if let free = attributes[.systemFreeSize] as? NSNumber, free.int64Value < bytes + 64 * 1024 * 1024 { throw MoReadError.invalid("可用空间不足，请先腾出存储空间。") }
    }
    private static func preflight(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 22, size <= maximumBytes else { throw MoReadError.invalid("备份文件大小无效。") }
        let length = min(size, 65_557)
        try handle.seek(toOffset: size - length)
        let tail = [UInt8](try handle.readToEnd() ?? Data())
        // Bound the ZIP directory before the archive library allocates its entry list.
        for index in stride(from: tail.count - 22, through: 0, by: -1) where Array(tail[index..<index + 4]) == [0x50, 0x4b, 0x05, 0x06] {
            let comment = Int(tail[index + 20]) | Int(tail[index + 21]) << 8
            guard index + 22 + comment == tail.count else { continue }
            guard index < 20 || Array(tail[(index - 20)..<(index - 16)]) != [0x50, 0x4b, 0x06, 0x07] else { throw MoReadError.invalid("备份超出当前支持的 ZIP 大小范围。") }
            let count = Int(tail[index + 10]) | Int(tail[index + 11]) << 8
            guard count > 0, count <= maximumFiles else { throw MoReadError.invalid("备份包含过多文件。") }
            return
        }
        throw MoReadError.invalid("备份文件不完整。")
    }
}

private actor BackupSink {
    private let limit: Int64
    private let handle: FileHandle?
    private var data = Data()
    private var count: Int64 = 0
    private var hash = SHA256()
    init(limit: Int64, url: URL? = nil) throws {
        self.limit = limit; handle = try url.map { try FileHandle(forWritingTo: $0) }
    }
    deinit { try? handle?.close() }
    func write(_ chunk: Data) throws -> Int64 {
        guard Int64(chunk.count) <= limit - count else { throw MoReadError.invalid("备份解压后的大小超出清单。") }
        if let handle { try handle.write(contentsOf: chunk) } else { data.append(chunk) }
        count += Int64(chunk.count); hash.update(data: chunk)
        return count
    }
    func finish() throws -> (Data, Int64, String) {
        try handle?.synchronize(); try handle?.close()
        return (data, count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
