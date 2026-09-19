import SwiftUI
import UniformTypeIdentifiers
import MoReadCore

struct BackupView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var companion: CompanionModel
    @EnvironmentObject private var speech: SpeechPlayer
    @AppStorage("backup.previousDirectory") private var previousDirectory = ""
    @State private var task: Task<Void, Never>?
    @State private var exported: URL?
    @State private var prepared: PreparedRestore?
    @State private var picker = false
    @State private var confirmRestore = false
    @State private var confirmUndo = false
    @State private var message: String?
    private var previous: URL? {
        guard previousDirectory.hasPrefix("MoRead-restore-"), !previousDirectory.contains("/"), let root = library.store?.root else { return nil }
        let url = root.deletingLastPathComponent().appendingPathComponent(previousDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    var body: some View {
        List {
            Section {
                Button("制作完整备份", systemImage: "externaldrive.badge.plus") { create() }.accessibilityIdentifier("create-backup")
                if let exported { ShareLink("保存或分享备份文件", item: exported).accessibilityIdentifier("share-backup") }
            } footer: { Text("包含书籍、阅读位置、批注、角色和聊天记录。服务商密钥由系统钥匙串管理。") }
            Section("恢复") {
                Button("选择备份文件", systemImage: "folder") { picker = true }
                if let prepared {
                    LabeledContent("备份时间", value: prepared.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("内容", value: "\(prepared.bookCount) 本书 · \(prepared.conversationCount) 个话题")
                    LabeledContent("数据大小", value: ByteCountFormatter.string(fromByteCount: prepared.manifest.bytes, countStyle: .file))
                    Button("恢复这个备份") { confirmRestore = true }
                    Button("取消选择", role: .cancel) { discardPrepared() }
                }
                if previous != nil { Button("撤销上次恢复") { confirmUndo = true } }
            }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
        }.navigationTitle("备份与恢复")
            .fileImporter(isPresented: $picker, allowedContentTypes: [.zip]) { result in
                switch result {
                case .success(let url): prepare(url)
                case .failure(let error): library.error = error.localizedDescription
                }
            }
            .alert("替换本机书库？", isPresented: $confirmRestore) {
                Button("取消", role: .cancel) {}
                Button("恢复") { restore() }
            } message: { Text("将使用所选备份替换本机书籍、角色和聊天记录。恢复前的书库会保留，可用“撤销上次恢复”返回。") }
            .alert("返回恢复前的书库？", isPresented: $confirmUndo) {
                Button("取消", role: .cancel) {}
                Button("撤销恢复") { undo() }
            } message: { Text("将返回上次恢复之前的书库。") }
            .onDisappear { if task == nil { discardPrepared() } }
    }
    private func run(_ title: String, action: @escaping @MainActor () async throws -> Void) {
        guard task == nil, !library.importing, !library.maintenance else { return }
        library.flush(); speech.pause()
        library.maintenanceTitle = title; library.maintenanceProgress = 0
        message = nil
        task = Task {
            defer { library.maintenanceTitle = nil; library.maintenanceProgress = 0; library.cancelMaintenance = nil; task = nil }
            do { await speech.stopAndWait(); await companion.stopAndWait(); try Task.checkCancellation(); try await action() }
            catch is CancellationError { message = "已取消。" }
            catch { library.error = error.localizedDescription }
        }
        library.cancelMaintenance = { task?.cancel() }
    }
    private func create() {
        run("正在制作备份…") {
            guard let root = library.store?.root else { return }
            try savePreferences(to: root)
            let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("MoReadBackups")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "MoRead-" + Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(6) + ".moread-ios.zip"
            let url = directory.appendingPathComponent(String(name))
            _ = try await BackupArchive.create(root: root, output: url) { [library] done, total in
                Task { @MainActor in if library.maintenance { library.maintenanceProgress = total > 0 ? min(1, Double(done) / Double(total)) : 1 } }
            }
            exported = url; message = "备份已生成，可以保存到“文件”或分享。"
        }
    }
    private func prepare(_ url: URL) {
        discardPrepared()
        run("正在检查备份…") {
            guard let root = library.store?.root else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let value = try await BackupArchive.prepare(url, beside: root) { [library] done, total in
                Task { @MainActor in if library.maintenance { library.maintenanceProgress = total > 0 ? min(1, Double(done) / Double(total)) : 1 } }
            }
            if Task.isCancelled { try? FileManager.default.removeItem(at: value.directory); throw CancellationError() }
            prepared = value; message = "校验通过，请核对备份时间与内容后恢复。"
        }
    }
    private func restore() {
        guard let prepared else { return }
        run("正在恢复书库…") {
            guard let root = library.store?.root else { return }
            speech.stop()
            try savePreferences(to: root)
            let previous = try BackupArchive.activate(prepared, replacing: root)
            self.prepared = nil; previousDirectory = previous.lastPathComponent
            library.load(); companion.load(); loadPreferences(from: root)
            message = "书库已恢复，恢复前的副本已保留。"
        }
    }
    private func undo() {
        guard let previous else { return }
        run("正在返回原书库…") {
            guard let root = library.store?.root else { return }
            speech.stop()
            try BackupArchive.undo(previous: previous, replacing: root)
            previousDirectory = ""
            library.load(); companion.load(); loadPreferences(from: root)
            message = "已返回恢复前的书库。"
        }
    }
    private func discardPrepared() { if let prepared { try? FileManager.default.removeItem(at: prepared.directory) }; prepared = nil }
    private func savePreferences(to root: URL) throws {
        let defaults = UserDefaults.standard
        let values = ["reader.fontSize", "reader.lineSpacing", "reader.paper", "shelf.sort", "speech.preferences", "speech.cloud"].reduce(into: [String: Any]()) { if let value = defaults.object(forKey: $1) { $0[$1] = value } }
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: root.appendingPathComponent("reader-settings.plist"), options: .atomic)
    }
    private func loadPreferences(from root: URL) {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("reader-settings.plist")), let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        let defaults = UserDefaults.standard
        let font = (values["reader.fontSize"] as? Double) ?? 21
        let spacing = (values["reader.lineSpacing"] as? Double) ?? 10
        defaults.set(font.isFinite ? min(36, max(14, font)) : 21, forKey: "reader.fontSize")
        defaults.set(spacing.isFinite ? min(24, max(0, spacing)) : 10, forKey: "reader.lineSpacing")
        let paper = values["reader.paper"] as? String ?? "paper"
        defaults.set(["paper", "night", "white"].contains(paper) ? paper : "paper", forKey: "reader.paper")
        let sort = values["shelf.sort"] as? String ?? ""
        defaults.set((ShelfSort(rawValue: sort) ?? .recent).rawValue, forKey: "shelf.sort")
        if let data = values["speech.preferences"] as? Data,
           let settings = try? JSONDecoder().decode(SpeechPreferences.self, from: data),
           let validated = try? JSONEncoder().encode(settings.validated()) { defaults.set(validated, forKey: "speech.preferences") }
        else { defaults.removeObject(forKey: "speech.preferences") }
        if let data = values["speech.cloud"] as? Data,
           let settings = try? JSONDecoder().decode(CloudSpeechSettings.self, from: data),
           let validated = try? JSONEncoder().encode(settings.validated()) { defaults.set(validated, forKey: "speech.cloud") }
        else { defaults.removeObject(forKey: "speech.cloud") }
        speech.loadPreferences(); speech.loadCloudSettings()
    }
}
