import SwiftUI
import MoReadCore

struct TextSelectionEditor: View {
    let passage: SourcePassage
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var companion: CompanionModel
    @EnvironmentObject private var speech: SpeechPlayer
    @State private var replacement = ""
    @State private var loaded = false
    @State private var task: Task<Void, Never>?
    @State private var error: String?
    var body: some View {
        Form {
            Section("修改后的文字") {
                TextEditor(text: $replacement).frame(minHeight: 180).accessibilityIdentifier("source-edit-text")
                Text("\(replacement.utf16.count) / 20000 字符").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("查看原文") { Text(passage.text).textSelection(.enabled) }
                Button("保存正文") { save() }.disabled(task != nil || replacement == passage.text || replacement.utf16.count > 20_000)
                    .accessibilityIdentifier("source-edit-save")
            } footer: { Text("保存会替换本书选中的原文；留空会删除。书签与阅读位置随正文调整，修改范围内的批注保留记录，旧引文停止高亮。") }
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("source-edit-error") }
        }
        .disabled(task != nil)
        .navigationTitle("编辑选中文字").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(task != nil)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { task?.cancel(); dismiss() }.disabled(task != nil) } }
        .safeAreaInset(edge: .bottom) {
            if task != nil { HStack { ProgressView(); Text("正在保存…"); Spacer(); Button("停止") { task?.cancel() } }.padding().background(.regularMaterial) }
        }
        .interactiveDismissDisabled(task != nil)
        .onAppear { if !loaded { loaded = true; replacement = passage.text } }
        .onDisappear { task?.cancel() }
    }
    private func save() {
        guard task == nil, !library.maintenance, !library.importing, let root = library.store?.root else { return }
        library.flush(); library.maintenanceTitle = "正在修改正文…"; error = nil
        let passage = passage, replacement = replacement
        task = Task {
            defer { library.maintenanceTitle = nil; library.cancelMaintenance = nil; task = nil }
            do {
                await speech.stopAndWait(); await companion.stopAndWait(); try Task.checkCancellation()
                let store = try LibraryStore(root: root)
                if try store.book(passage.bookID).format == "epub" {
                    _ = try await EPUBService.shared.replaceSelectedText(passage, with: replacement, store: store)
                } else {
                    let worker = Task.detached { try store.replaceSelectedText(passage, with: replacement) }
                    _ = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                }
                library.load(); companion.load(); onSaved()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
        library.cancelMaintenance = { task?.cancel() }
    }
}

struct ChapterRecognitionView: View {
    let bookID: UUID
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var companion: CompanionModel
    @EnvironmentObject private var speech: SpeechPlayer
    @State private var rule = ""
    @State private var preview: ChapterRecognitionPreview?
    @State private var task: Task<Void, Never>?
    @State private var confirmation = false
    @State private var message: String?
    @State private var error: String?
    var body: some View {
        List {
            Section {
                TextField("留空自动识别", text: $rule, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("chapter-recognition-rule")
                Button("预览新目录") { run(applying: false) }.accessibilityIdentifier("chapter-recognition-preview")
            } header: { Text("章节识别规则") } footer: { Text("可填写匹配章节标题的正则表达式，例如 ^第[0-9一二三四五六七八九十百]+章.*$。留空使用内置规则；没有标题时按正文长度分节。识别使用当前本地正文。") }
            if let preview {
                Section {
                    Text("原目录 \(preview.sourceChapters.count) 章 → 新目录 \(preview.chapters.count) 章").accessibilityIdentifier("chapter-recognition-summary")
                    if preview.detachedAnnotations > 0 { Text("\(preview.detachedAnnotations) 条批注引文无法完整对应到新章节，将保留笔记并停止旧高亮。").foregroundStyle(.secondary) }
                    Button("应用新目录") { confirmation = true }.accessibilityIdentifier("chapter-recognition-apply")
                } footer: { Text("阅读位置和书签按原文对应到新章节。与新章节不符的 AI 提纲、翻译和记忆会停止使用，需要时可重新生成。预览显示全书标题，可能涉及后文。") }
                Section("新目录") {
                    ForEach(preview.chapters) { chapter in
                        LabeledContent(chapter.title, value: "\(chapter.length) 字符")
                    }
                }
            }
            if let message { Text(message).accessibilityIdentifier("chapter-recognition-message") }
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("chapter-recognition-error") }
        }
        .disabled(task != nil)
        .navigationTitle("重新识别章节").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(task != nil)
        .safeAreaInset(edge: .bottom) {
            if task != nil { HStack { ProgressView(); Text("正在处理…"); Spacer(); Button("取消") { task?.cancel() } }.padding().background(.regularMaterial) }
        }
        .interactiveDismissDisabled(task != nil)
        .onChange(of: rule) { _, _ in task?.cancel(); preview = nil; message = nil; error = nil }
        .onDisappear { task?.cancel() }
        .alert("应用新目录？", isPresented: $confirmation) {
            Button("取消", role: .cancel) {}
            Button("确认应用") { run(applying: true) }
        } message: { Text("将同时更新章节、阅读位置和书签。需要保留可恢复的当前版本时，请先在设置中制作完整备份。") }
    }
    private func run(applying: Bool) {
        guard task == nil, !library.maintenance, !library.importing, let root = library.store?.root else { return }
        let bookID = bookID, rule = rule, preview = preview
        library.flush(); library.maintenanceTitle = applying ? "正在更新章节…" : "正在识别章节…"
        error = nil; message = nil
        task = Task {
            defer { library.maintenanceTitle = nil; library.cancelMaintenance = nil; task = nil }
            do {
                await speech.stopAndWait(); await companion.stopAndWait(); try Task.checkCancellation()
                if applying, let preview {
                    let worker = Task.detached { try LibraryStore(root: root).applyChapterRecognition(preview) }
                    _ = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    library.load(); companion.load(); self.preview = nil; message = "目录已更新。"
                } else {
                    let worker = Task.detached { try LibraryStore(root: root).previewChapterRecognition(bookID: bookID, customRule: rule) }
                    self.preview = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
        library.cancelMaintenance = { task?.cancel() }
    }
}
