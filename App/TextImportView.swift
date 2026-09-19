import SwiftUI
import MoReadCore

struct TextImportDraft: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let group: UUID?
    let collection: UUID?
    func discard() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    static func stage(_ source: URL, group: UUID?, collection: UUID?) throws -> Self {
        let format = source.pathExtension.lowercased()
        guard ["txt", "epub"].contains(format) else { throw MoReadError.invalid("请选择 TXT 或 EPUB 文件。") }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var failure: NSError?
        var result: Result<Self, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &failure) { url in
            result = Result { try copy(url, group: group, collection: collection) }
        }
        if let failure { throw failure }
        guard let result else { throw MoReadError.invalid("无法读取所选文件。") }
        return try result.get()
    }
    private static func copy(_ source: URL, group: UUID?, collection: UUID?) throws -> Self {
        let format = source.pathExtension.lowercased()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoReadImport-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
        let url = directory.appendingPathComponent(source.lastPathComponent)
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw MoReadError.invalid("无法准备导入文件。") }
        let output = try FileHandle(forWritingTo: url); defer { try? output.close() }
        var size = 0
        let limit = format == "txt" ? TextImporter.maximumBytes : 500 * 1024 * 1024
        while let data = try input.read(upToCount: 256 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            size += data.count
            guard size <= limit else { throw MoReadError.invalid("文件超过 \(limit / 1024 / 1024) MB，请先缩小文件。") }
            try output.write(contentsOf: data)
        }
        try output.synchronize()
        complete = true
        return Self(url: url, group: group, collection: collection)
    }
}

extension LibraryModel {
    func queueImports(_ urls: [URL], group: UUID? = nil, collection: UUID? = nil) async {
        guard !importing, !maintenance, textImport == nil, importQueue.isEmpty else { error = "请先完成当前导入。"; return }
        importing = true
        for url in urls {
            do {
                let draft = try await Task.detached(priority: .userInitiated) { try TextImportDraft.stage(url, group: group, collection: collection) }.value
                importQueue.append(draft)
            } catch { self.error = error.localizedDescription }
        }
        importing = false
        await nextImport()
    }
    func nextImport() async {
        guard textImport == nil, !importing, !maintenance else { return }
        while !importQueue.isEmpty {
            let draft = importQueue.removeFirst()
            if draft.url.pathExtension.lowercased() == "txt" { textImport = draft; return }
            if let book = await importFile(draft.url) { classifyImport(book, draft: draft) }
            draft.discard()
        }
    }
    func cancelTextImport(_ draft: TextImportDraft) {
        guard textImport?.id == draft.id else { return }
        textImport = nil; draft.discard()
    }
    func confirmTextImport(_ draft: TextImportDraft, title: String, author: String, chapters: [Chapter]) async throws {
        guard !importing, !maintenance, textImport?.id == draft.id, let store else { throw MoReadError.invalid("导入已结束，请重新选择文件。") }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines), author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200, author.count <= 120 else { throw MoReadError.invalid("书名需要在 1 到 200 个字之间，作者最多 120 个字。") }
        importing = true
        defer { importing = false }
        let root = store.root
        let book = try await Task.detached(priority: .userInitiated) {
            try LibraryStore(root: root).importBook(title: title, author: author, chapters: chapters, original: draft.url)
        }.value
        books.insert(book, at: 0); classifyImport(book, draft: draft)
        textImport = nil; draft.discard()
    }
    private func classifyImport(_ book: Book, draft: TextImportDraft) {
        organize {
            if let id = draft.group, $0.groups.contains(where: { $0.id == id }) { $0.bookGroups[book.id] = id }
            if let id = draft.collection, $0.collections.contains(where: { $0.id == id }) { $0.setCollection(id, for: [book.id]) }
        }
    }
}

struct TextImportView: View {
    let draft: TextImportDraft
    @EnvironmentObject private var model: LibraryModel
    @State private var title = ""
    @State private var author = ""
    @State private var encoding = TextEncoding.automatic
    @State private var rule = "automatic"
    @State private var custom = ""
    @State private var rules: [ChapterRule] = []
    @State private var chapters: [Chapter] = []
    @State private var detectedEncoding = ""
    @State private var metadataApplied = false
    @State private var error: String?
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var revision = UUID()
    @FocusState private var editingRule: Bool
    var body: some View {
        NavigationStack {
            List {
                Section("书籍资料") {
                    TextField("书名", text: $title).accessibilityIdentifier("import-title")
                    TextField("作者", text: $author)
                    Text(draft.url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
                Section("文字与目录") {
                    Picker("文字编码", selection: $encoding) { ForEach(TextEncoding.allCases) { Text($0.rawValue).tag($0) } }
                    Picker("章节规则", selection: $rule) {
                        Text("自动识别").tag("automatic")
                        Text("自定义规则").tag("custom")
                        ForEach(rules) { Text($0.name).tag(String($0.id)) }
                    }.pickerStyle(.navigationLink)
                    if rule == "custom" {
                        TextField("例如：^第[一二三四五六七八九十0-9]+章.*$", text: $custom, axis: .vertical).font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled().focused($editingRule).accessibilityIdentifier("import-rule")
                        Text("规则用于匹配章节标题所在的整行。修改后点击“更新预览”，确认目录与正文是否正确。").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("更新预览") { editingRule = false; refresh() }.disabled(busy)
                    if busy { ProgressView(model.importing ? "正在加入书架…" : "正在识别正文与目录…") }
                    if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("import-error") }
                    if !chapters.isEmpty {
                        LabeledContent("识别结果", value: "\(detectedEncoding) · \(chapters.count) 章").accessibilityIdentifier("import-result")
                    }
                }
                if !chapters.isEmpty {
                    Section("正文预览") { Text(String(chapters[0].text.prefix(1200))).textSelection(.enabled).accessibilityIdentifier("import-preview") }
                    Section("章节目录") {
                        ForEach(chapters) { chapter in
                            NavigationLink(chapter.title) {
                                ScrollView { Text(String(chapter.text.prefix(5000))).frame(maxWidth: .infinity, alignment: .leading).padding().textSelection(.enabled) }.navigationTitle(chapter.title)
                            }
                        }
                    }
                }
            }.disabled(model.importing).scrollDismissesKeyboard(.interactively).navigationTitle("导入预览")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(model.importQueue.isEmpty ? "取消导入" : "跳过此文件") { task?.cancel(); model.cancelTextImport(draft) }.disabled(model.importing) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("加入书架") {
                            busy = true
                            Task {
                                defer { busy = false }
                                do { try await model.confirmTextImport(draft, title: title, author: author, chapters: chapters) }
                                catch { self.error = error.localizedDescription }
                            }
                        }.disabled(busy || chapters.isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("confirm-text-import")
                    }
                }
        }.interactiveDismissDisabled()
            .task { title = draft.url.deletingPathExtension().lastPathComponent; rules = (try? TextImporter.rules()) ?? []; refresh() }
            .onChange(of: encoding) { _, _ in refresh() }
            .onChange(of: rule) { _, _ in refresh() }
            .onChange(of: custom) { _, _ in task?.cancel(); revision = UUID(); chapters = []; busy = false; error = nil }
            .onDisappear { task?.cancel() }
    }
    private func refresh() {
        task?.cancel(); chapters = []; error = nil
        let pattern: String?
        if rule == "custom" {
            guard !custom.isEmpty else { busy = false; return }
            pattern = custom
        } else { pattern = rules.first { String($0.id) == rule }?.rule }
        busy = true
        let encoding = encoding.encoding, url = draft.url, current = UUID()
        revision = current
        task = Task {
            defer { if revision == current { busy = false } }
            let worker = Task.detached(priority: .userInitiated) {
                let decoded = try TextImporter.decoded(TextImporter.read(url), encoding: encoding)
                let chapters = try TextImporter.chapters(decoded.text, customRule: pattern)
                return (chapters, TextEncoding.allCases.first { $0.encoding == decoded.encoding }?.rawValue ?? "", TextImporter.metadata(fileName: url.lastPathComponent, text: decoded.text))
            }
            do {
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard revision == current else { return }
                chapters = value.0; detectedEncoding = value.1
                if !metadataApplied {
                    if title == draft.url.deletingPathExtension().lastPathComponent { title = value.2.title }
                    if author.isEmpty { author = value.2.author }
                    metadataApplied = true
                }
            } catch is CancellationError {} catch { if revision == current { self.error = error.localizedDescription } }
        }
    }
}
