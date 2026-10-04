import SwiftUI
import MoReadCore

struct ReviewCardExportView: View {
    let entry: ReadingReviewEntry
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var templates: [ReviewCardTemplate] = []
    @State private var selected = ReviewCardTemplate.presets[0].id
    @State private var options = ReviewCardOptions()
    @State private var editing: ReviewCardTemplate?
    @State private var deleting = false
    @State private var preview: UIImage?
    @State private var exported: URL?
    @State private var error: String?
    @State private var loaded = false
    private var saved: ReviewCardTemplate? { templates.first { $0.id == selected } }
    private var template: ReviewCardTemplate { saved ?? ReviewCardTemplate.presets.first { $0.id == selected } ?? ReviewCardTemplate.presets[0] }
    private struct Request: Equatable { let template: ReviewCardTemplate; let options: ReviewCardOptions; let revision: UUID; let books: [Book]; let maintenance: Bool; let loaded: Bool }
    private var request: Request { .init(template: template, options: options, revision: library.recordsRevision, books: library.books, maintenance: library.maintenance, loaded: loaded) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let preview { Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 420).accessibilityLabel("卡片图片预览").accessibilityIdentifier("review-card-preview") }
                    else if error == nil { ProgressView("正在生成预览…") }
                    if let error { Text(error).foregroundStyle(.secondary).accessibilityIdentifier("review-card-error") }
                }
                Section("卡片样式") {
                    Picker("模板", selection: $selected) {
                        ForEach(ReviewCardTemplate.presets + templates) { Text($0.name).tag($0.id) }
                    }.accessibilityIdentifier("review-card-style")
                    Button("新建自定义模板") { var copy = template; copy.id = UUID(); copy.name += " · 自定"; editing = copy }.disabled(!loaded)
                    if saved != nil {
                        Button("编辑模板") { editing = saved }
                        Button("另存为新模板") { var copy = template; copy.id = UUID(); copy.name += " · 副本"; editing = copy }
                        Button("删除模板", role: .destructive) { deleting = true }
                    }
                }
                Section("显示内容") {
                    Toggle("书名章节", isOn: $options.book).accessibilityIdentifier("review-card-book")
                    Toggle(entry.characterID == nil ? "我的想法" : "角色笔记", isOn: $options.thought).accessibilityIdentifier("review-card-thought")
                    Toggle("日期", isOn: $options.date)
                    Toggle("水印", isOn: $options.watermark)
                }
                Section {
                    if let exported { ShareLink("分享图片", item: exported).accessibilityIdentifier("review-card-share") }
                    Button("复制文字") { UIPasteboard.general.string = entry.markdown }
                    ShareLink("分享文字", item: entry.markdown)
                }
            }.navigationTitle("导出卡片").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task { load() }
                .task(id: request) { await render() }
                .sheet(item: $editing) { value in
                    ReviewCardTemplateEditor(initial: value) { value in
                        guard let store = library.store, !library.maintenance else { throw MoReadError.invalid("书库暂不可用。") }
                        try ReviewCardLibrary(root: store.root).save(value); load(); selected = value.id
                    }
                }
                .confirmationDialog("删除这个模板？", isPresented: $deleting, titleVisibility: .visible) {
                    Button("删除模板", role: .destructive) {
                        do {
                            guard let store = library.store, !library.maintenance else { return }
                            try ReviewCardLibrary(root: store.root).remove(selected); selected = ReviewCardTemplate.presets[0].id; load()
                        } catch { self.error = error.localizedDescription }
                    }
                }
        }
    }
    private func load() {
        do {
            guard let store = library.store, !library.maintenance else { throw MoReadError.invalid("书库暂不可用。") }
            templates = try ReviewCardLibrary(root: store.root).templates(); loaded = true
        } catch { loaded = false; self.error = error.localizedDescription }
    }
    private func render() async {
        preview = nil; exported = nil
        guard loaded else { return }
        error = nil
        do {
            try await Task.sleep(for: .milliseconds(150)); try Task.checkCancellation()
            guard let store = library.store, !library.maintenance,
                  let book = library.books.first(where: { $0.id == entry.book.id }),
                  ReadingReview.entries(books: [book], records: [book.id: try store.records(for: book)]).contains(entry) else {
                throw MoReadError.invalid("这条记录已改变，请重新打开后分享。")
            }
            let style = template
            let background: UIImage?
            if let id = style.backgroundImageID { background = UIImage(data: try ImageLibrary(root: store.root).data(id)) }
            else if style.useBookCover { background = try store.coverData(for: book.id).flatMap(UIImage.init(data:)) }
            else { background = nil }
            let image = try ReviewCardRenderer.image(entry: entry, template: style, options: options, font: library.customFont(style.customFontID, size: style.fontSize), background: background, cover: style.useBookCover && style.backgroundImageID == nil)
            guard let data = image.pngData() else { throw MoReadError.invalid("图片生成失败，请重试。") }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoRead-回顾-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("墨知-阅读回顾.png"); try data.write(to: url, options: .atomic)
            try Task.checkCancellation(); preview = image; exported = url
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private struct ReviewCardTemplateEditor: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReviewCardTemplate
    @State private var error: String?
    let save: (ReviewCardTemplate) throws -> Void
    init(initial: ReviewCardTemplate, save: @escaping (ReviewCardTemplate) throws -> Void) { _draft = State(initialValue: initial); self.save = save }
    var body: some View {
        NavigationStack {
            Form {
                TextField("模板名称", text: $draft.name).accessibilityIdentifier("review-card-template-name")
                Section("颜色与背景") {
                    ColorPicker("背景色", selection: color(\.background), supportsOpacity: false)
                    ColorPicker("文字色", selection: color(\.foreground), supportsOpacity: false)
                    ColorPicker("装饰色", selection: color(\.accent), supportsOpacity: false)
                    Toggle("渐变背景", isOn: Binding(get: { draft.gradientEnd != nil }, set: { draft.gradientEnd = $0 ? draft.accent : nil }))
                    if draft.gradientEnd != nil { ColorPicker("渐变终点", selection: Binding(get: { Color(rgb: draft.gradientEnd ?? draft.background) }, set: { draft.gradientEnd = $0.savedRGB }), supportsOpacity: false) }
                    Toggle("使用本书封面", isOn: $draft.useBookCover)
                    Picker("背景图片", selection: $draft.backgroundImageID) {
                        Text("无").tag(UUID?.none)
                        ForEach(library.images) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Section("摘录文字") {
                    Picker("字体", selection: $draft.font) { ForEach(ReaderTypography.Font.allCases, id: \.self) { Text($0.label).tag($0) } }
                    Picker("导入的字体", selection: $draft.customFontID) {
                        Text("使用上方字体").tag(UUID?.none)
                        ForEach(library.fonts) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Slider(value: $draft.fontSize, in: 23.5...141) { Text("字号") }; Text("字号 \(draft.fontSize, specifier: "%.0f")")
                    Slider(value: $draft.lineHeight, in: 1...2.5) { Text("行高") }; Text("行高 \(draft.lineHeight, specifier: "%.2f") 倍")
                    Slider(value: $draft.letterSpacing, in: -0.05...0.3) { Text("字间距") }; Text("字间距 \(draft.letterSpacing, specifier: "%.2f") 字")
                    Picker("对齐", selection: $draft.alignment) { Text("左对齐").tag("left"); Text("居中").tag("center"); Text("右对齐").tag("right") }
                    Toggle("粗体", isOn: $draft.bold); Toggle("斜体", isOn: $draft.italic)
                    Toggle("下划线", isOn: $draft.underline); Toggle("删除线", isOn: $draft.strikethrough)
                }
                Section("留白与边框") {
                    Slider(value: $draft.padding, in: 24...280) { Text("左右留白") }; Text("左右留白 \(draft.padding, specifier: "%.0f")")
                    Slider(value: $draft.cornerRadius, in: 0...141) { Text("圆角") }; Text("圆角 \(draft.cornerRadius, specifier: "%.0f")")
                    Slider(value: $draft.borderWidth, in: 0...23.5) { Text("边框粗细") }; Text("边框粗细 \(draft.borderWidth, specifier: "%.1f")")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("卡片模板").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") {
                        do { draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines); try save(draft); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("review-card-template-save") }
                }
        }
    }
    private func color(_ key: WritableKeyPath<ReviewCardTemplate, Int>) -> Binding<Color> {
        Binding(get: { Color(rgb: draft[keyPath: key]) }, set: { draft[keyPath: key] = $0.savedRGB })
    }
}
