import SwiftUI
import MoReadCore

struct VectorMemoryView: View {
    @FocusState private var editingModel: Bool
    @EnvironmentObject private var companion: CompanionModel
    @EnvironmentObject private var library: LibraryModel
    var body: some View {
        Form {
            Section {
                Picker("向量服务商", selection: $companion.settings.embeddingProvider) {
                    Text("请选择").tag(nil as UUID?)
                    ForEach(companion.settings.providers.filter { $0.dialect != .claude }) { provider in
                        Text(provider.name).tag(Optional(provider.id))
                    }
                }.onChange(of: companion.settings.embeddingProvider) { _, _ in companion.saveSettings() }
                TextField("向量模型名称", text: Binding(get: { companion.settings.embeddingModel ?? "" }, set: {
                    companion.settings.embeddingModel = $0; companion.saveSettings()
                })).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("embedding-model")
                    .focused($editingModel).submitLabel(.done).onSubmit { editingModel = false }
                NavigationLink("管理 AI 服务商") { AISettingsView() }
            } header: { Text("理解原文的模型") } footer: {
                Text("填写服务商提供的向量模型名称。它与聊天模型分别设置，用来按意思寻找原文。更换模型或服务商后，下次使用时会重建对应记忆。")
            }.disabled(companion.busy)
            Section {
                ForEach(library.books.filter { !$0.removed && $0.hasBody }) { book in
                    NavigationLink { BookMemoryView(bookID: book.id) } label: {
                        HStack {
                            Text(book.title)
                            Spacer()
                            Text((companion.settings.vectorBooks ?? []).contains(book.id) ? "已开启" : "未开启").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !library.books.contains(where: { !$0.removed && $0.hasBody }) { Text("导入书籍后，在这里选择要记住的书。").foregroundStyle(.secondary) }
            } header: { Text("按书开启") } footer: {
                Text("开启后，整理原文和发送伴读问题时，会把这本书已读范围内的片段与问题发送给所选向量服务商，可能产生其 API 费用。向量和原文位置保存在本机，随完整备份保存。")
            }
            if let status = companion.memoryStatus {
                Section { ProgressView(status); Button("停止整理与检索", role: .cancel) { companion.stop() } }
            }
        }.navigationTitle("向量记忆")
    }
}

private struct BookMemoryView: View {
    let bookID: UUID
    @EnvironmentObject private var companion: CompanionModel
    @EnvironmentObject private var library: LibraryModel
    @State private var saved = false
    @State private var count = 0
    @State private var clearing = false
    private var book: Book? { library.books.first { $0.id == bookID && !$0.removed && $0.hasBody } }
    var body: some View {
        Form {
            if let book {
                Section {
                    Toggle("在伴读中使用向量记忆", isOn: Binding(get: {
                        (companion.settings.vectorBooks ?? []).contains(bookID)
                    }, set: { enabled in
                        var ids = Set(companion.settings.vectorBooks ?? [])
                        if enabled { ids.insert(bookID) } else { ids.remove(bookID) }
                        companion.settings.vectorBooks = Array(ids); companion.saveSettings()
                    })).accessibilityIdentifier("enable-book-memory").disabled(companion.busy)
                } footer: { Text("只整理已读原文。之后继续阅读，伴读会自动补充新读到的部分。关闭后，已保存的记忆仍在本机，可单独清理。") }
                Section {
                    Text(count > 0 ? "已保存 \(count) 段原文" : "尚未整理原文").accessibilityIdentifier("book-memory-state")
                    Button(saved ? "更新已读原文" : "整理已读原文") { companion.buildMemory(book, library: library) }
                        .accessibilityIdentifier("build-book-memory")
                        .disabled(companion.busy || book.readThrough == ReadingPosition() || !(companion.settings.vectorBooks ?? []).contains(bookID))
                    if book.readThrough == ReadingPosition() { Text("读过一些正文后，即可开始整理。").font(.footnote).foregroundStyle(.secondary) }
                    if let status = companion.memoryStatus {
                        ProgressView(status)
                        Button("停止整理与检索", role: .cancel) { companion.stop() }
                    }
                    Button("清理这本书的向量记忆", role: .destructive) { clearing = true }.disabled(companion.busy || !saved)
                } footer: { Text("整理可随时停止，已经完成的章节会保留。清理向量记忆会移除本机的原文检索索引。") }
            }
        }.navigationTitle(book?.title ?? "向量记忆")
            .task { refresh() }
            .onChange(of: companion.memoryStatus) { _, _ in refresh() }
            .alert("清理向量记忆？", isPresented: $clearing) {
                Button("取消", role: .cancel) {}
                Button("清理", role: .destructive) { if let book { companion.clearMemory(book, library: library); refresh() } }
            } message: { Text("下次使用时，会重新向所选服务商请求向量。") }
    }
    private func refresh() {
        guard let url = library.store?.directory(bookID).appendingPathComponent("vectors.sqlite") else { return }
        saved = FileManager.default.fileExists(atPath: url.path)
        companion.perform { count = saved ? try BookVectorIndex(url: url).count() : 0 }
    }
}
