import SwiftUI
import MoReadCore

struct TextCleanupView: View {
    let bookID: UUID
    var listeningOnly = false
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var companion: CompanionModel
    @EnvironmentObject private var speech: SpeechPlayer
    @State private var rules: [TextReplacementRule] = []
    @State private var editing: TextReplacementRule?
    @State private var preview: BookTextCleanupPreview?
    @State private var task: Task<Void, Never>?
    @State private var confirmation = false
    @State private var message: String?
    @State private var error: String?
    @State private var editMode = EditMode.inactive
    @State private var sample = ""
    @State private var listeningPreview: String?
    @State private var previewTask: Task<Void, Never>?
    private var store: TextReplacementStore? { library.store.map { TextReplacementStore(root: $0.root) } }
    var body: some View {
        List {
            Section {
                ForEach(rules.filter { $0.forListeningOnly == listeningOnly }) { rule in
                    ruleRow(rule)
                }.onMove { indices, destination in
                    var selected = rules.filter { $0.forListeningOnly == listeningOnly }; selected.move(fromOffsets: indices, toOffset: destination)
                    save(selected + rules.filter { $0.forListeningOnly != listeningOnly })
                }
                Button("添加规则", systemImage: "plus") { var value = TextReplacementRule(); value.isRegex = false; value.forListeningOnly = listeningOnly; editing = value }.accessibilityIdentifier("cleanup-add")
            } header: { Text(listeningOnly ? "听书净化规则" : "正文替换规则") } footer: { Text(listeningOnly ? "规则按顺序处理每句朗读文字，适用于 TXT 和 EPUB 的系统声音及云端声音。修改从下一句开始生效；书里的原文、书签和批注位置保持不变。" : "按从上到下的顺序应用。保存规则后，先预览再确认，才会修改这本书。规则也可用于其他 TXT 书籍。") }
            if listeningOnly {
                Section {
                    TextField("填写想测试的句子", text: $sample, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("listening-cleanup-sample")
                    Button("预览朗读内容") { previewListening() }.disabled(previewTask != nil).accessibilityIdentifier("listening-cleanup-preview")
                    if previewTask != nil { ProgressView() }
                    if let listeningPreview { Text(listeningPreview.isEmpty ? "这段文字会跳过。" : listeningPreview).textSelection(.enabled).accessibilityIdentifier("listening-cleanup-result") }
                } header: { Text("测试文字") } footer: { Text("这里只在本机试验替换结果。规则按实际朗读的一句话分别匹配，替换内容为空时跳过匹配文字。") }
            } else {
                Section {
                    Button("预览整本书") { run(applying: false) }.disabled(!rules.contains { $0.enabled && !$0.forListeningOnly }).accessibilityIdentifier("cleanup-preview")
                    if let preview {
                        Text("匹配 \(preview.matches) 处 · 改动 \(preview.changedChapters) 章").accessibilityIdentifier("cleanup-summary")
                        if preview.detachedAnnotations > 0 { Text("\(preview.detachedAnnotations) 条批注的引文将变化。批注文字保留在记录中，原文高亮会取消。").foregroundStyle(.secondary) }
                        Button("应用到这本书") { confirmation = true }.disabled(preview.changedChapters == 0).accessibilityIdentifier("cleanup-apply")
                    }
                } footer: { Text("预览包含全书章节，可能看到尚未读到的内容。与新正文不符的 AI 引文、翻译和记忆会停止使用，需要时可重新生成。") }
                if let preview {
                    ForEach(preview.examples) { example in
                        Section(example.title) {
                            Text("修改前").font(.caption).foregroundStyle(.secondary)
                            Text(example.before).textSelection(.enabled)
                            Text("修改后").font(.caption).foregroundStyle(.secondary)
                            Text(example.after).textSelection(.enabled)
                        }
                    }
                }
            }
            if !listeningOnly { NavigationLink("听书文字净化") { TextCleanupView(bookID: bookID, listeningOnly: true) } }
            if let message { Text(message).accessibilityIdentifier("cleanup-message") }
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("cleanup-error") }
        }
        .disabled(task != nil)
        .navigationTitle(listeningOnly ? "听书文字净化" : "正文清理")
        .environment(\.editMode, $editMode)
        .toolbar { Button(editMode == .active ? "完成排序" : "调整顺序") { withAnimation { editMode = editMode == .active ? .inactive : .active } }.disabled(task != nil || rules.isEmpty) }
        .safeAreaInset(edge: .bottom) {
            if task != nil {
                HStack { ProgressView(); Text("正在处理…"); Spacer(); Button("取消") { task?.cancel() } }.padding().background(.regularMaterial)
            }
        }
        .interactiveDismissDisabled(task != nil)
        .onDisappear { previewTask?.cancel() }
        .onChange(of: sample) { _, _ in previewTask?.cancel(); listeningPreview = nil }
        .onAppear { do { rules = try store?.rules() ?? [] } catch { self.error = error.localizedDescription } }
        .sheet(item: $editing) { rule in
            TextReplacementEditor(rule: rule) { value in
                var updated = rules
                if let index = updated.firstIndex(where: { $0.id == value.id }) { updated[index] = value } else { updated.append(value) }
                save(updated)
            }
        }
        .alert("修改整本书正文？", isPresented: $confirmation) {
            Button("取消", role: .cancel) {}
            Button("确认应用") { run(applying: true) }
        } message: { Text("将应用预览中的清理规则，书签和阅读位置会随正文调整。需要保留可恢复的当前版本时，请先在设置中制作完整备份。") }
    }
    private func ruleRow(_ rule: TextReplacementRule) -> some View {
        HStack {
            Toggle(rule.name, isOn: Binding(get: { rule.enabled }, set: { enabled in
                var updated = rules
                if let index = updated.firstIndex(where: { $0.id == rule.id }) { updated[index].enabled = enabled; save(updated) }
            })).accessibilityIdentifier("cleanup-enable-" + rule.id.uuidString)
            Button("编辑", systemImage: "pencil") { editing = rule }.labelStyle(.iconOnly).buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44).accessibilityLabel("编辑规则“" + rule.name + "”")
        }.swipeActions {
            Button("删除", role: .destructive) { save(rules.filter { $0.id != rule.id }) }
        }
    }
    private func save(_ updated: [TextReplacementRule]) {
        do { try store?.save(updated); rules = updated; preview = nil; previewTask?.cancel(); listeningPreview = nil; message = nil; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func previewListening() {
        guard previewTask == nil else { return }
        let text = sample, rules = rules
        let maximum = speech.cloudSettings.enabled ? speech.cloudSettings.maximumCharacters : 1000
        guard text.utf16.count <= 4096 else { error = "测试文字最多 4096 字。"; return }
        error = nil; listeningPreview = nil
        previewTask = Task {
            defer { previewTask = nil }
            do {
                let worker = Task.detached {
                    var offset = 0, lines: [String] = []
                    while let source = SpeechText.next(in: text, from: offset, maximumLength: maximum) {
                        try Task.checkCancellation()
                        let value = try source.purified(rules: rules)
                        if !value.text.isEmpty { lines.append(value.text) }
                        offset = source.end
                    }
                    return lines.joined(separator: "\n")
                }
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation(); listeningPreview = value
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func run(applying: Bool) {
        guard task == nil, !library.importing, !library.maintenance, let root = library.store?.root else { return }
        let rules = rules, preview = preview
        library.flush(); speech.pause(); library.maintenanceTitle = applying ? "正在清理正文…" : "正在预览正文…"
        error = nil; message = nil
        task = Task {
            defer { library.maintenanceTitle = nil; library.cancelMaintenance = nil; task = nil }
            do {
                await speech.stopAndWait(); await companion.stopAndWait(); try Task.checkCancellation()
                if applying, let preview {
                    let worker = Task.detached { try LibraryStore(root: root).applyTextCleanup(preview) }
                    _ = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    self.preview = nil; library.load(); companion.load(); message = "正文已更新。"
                } else {
                    let id = bookID
                    let worker = Task.detached { try LibraryStore(root: root).previewTextCleanup(bookID: id, rules: rules) }
                    self.preview = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                }
            } catch is CancellationError { message = "已取消，正文保持不变。" }
            catch { self.error = error.localizedDescription }
        }
        library.cancelMaintenance = { task?.cancel() }
    }
}

private struct TextReplacementEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: TextReplacementRule
    let save: (TextReplacementRule) -> Void
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $rule.name).accessibilityIdentifier("cleanup-rule-name")
                TextField("匹配内容", text: $rule.pattern, axis: .vertical).accessibilityIdentifier("cleanup-pattern")
                TextField("替换为（留空表示删除）", text: $rule.replacement, axis: .vertical).accessibilityIdentifier("cleanup-replacement")
                Toggle("忽略英文大小写", isOn: $rule.ignoreCase)
                Section {
                    Toggle("使用正则表达式", isOn: $rule.isRegex).accessibilityIdentifier("cleanup-regex")
                } footer: { Text("正则表达式用于匹配一类文字。例如 ^广告：.*$ 匹配以“广告：”开头的整行；替换内容可用 $1 引用第一组匹配。关闭时，只替换填写的原样文字。") }
                if let error { Text(error).foregroundStyle(.red) }
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
                .navigationTitle("清理规则")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") {
                        do { _ = try rule.expression(); save(rule); dismiss() } catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("cleanup-save-rule") }
                }
        }
    }
}
