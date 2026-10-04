import SwiftUI
import MoReadCore

struct ReviewCardRulesView: View {
    @Binding var rules: [ReaderSyntaxRule]
    let text: String
    var paragraphs = false
    @State private var editing: ReaderSyntaxRule?
    var body: some View {
        List {
            Section {
                Button("添加文字规则") { editing = .init() }.disabled(rules.count >= 64)
                Button("添加对白示例") { rules += ReaderSyntaxRule.examples }.disabled(rules.count > 61)
            } footer: { Text(paragraphs ? "规则逐段应用于正文。重叠时排在前面的规则优先。" : "规则应用于卡片摘录；笔记卡片应用于标题。重叠时排在前面的规则优先。") }
            Section {
                ForEach($rules) { $rule in
                    HStack {
                        Button { editing = rule } label: {
                            VStack(alignment: .leading) { Text(rule.name); Text(rule.mode.rawValue).font(.caption).foregroundStyle(.secondary) }
                        }.accessibilityIdentifier("review-rule-" + rule.name)
                        Spacer()
                        Toggle("启用“\(rule.name)”", isOn: $rule.enabled).labelsHidden()
                    }
                }.onDelete { rules.remove(atOffsets: $0) }.onMove { rules.move(fromOffsets: $0, toOffset: $1) }
            }
        }.navigationTitle("文字着色规则").navigationBarTitleDisplayMode(.inline)
            .toolbar { EditButton() }
            .sheet(item: $editing) { rule in
                ReviewCardRuleEditor(initial: rule, text: text, paragraphs: paragraphs) { rule in
                    if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule }
                    else if rules.count < 64 { rules.append(rule) }
                }
            }
    }
}

private struct ReviewCardRuleEditor: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReaderSyntaxRule
    @State private var error: String?
    @State private var matchCount: Int?
    let text: String
    let paragraphs: Bool
    let save: (ReaderSyntaxRule) -> Void
    init(initial: ReaderSyntaxRule, text: String, paragraphs: Bool, save: @escaping (ReaderSyntaxRule) -> Void) { _draft = State(initialValue: initial); self.text = text; self.paragraphs = paragraphs; self.save = save }
    var body: some View {
        NavigationStack {
            Form {
                TextField("规则名称", text: $draft.name).accessibilityIdentifier("review-rule-name")
                Section("匹配文字") {
                    Picker("匹配方式", selection: $draft.mode) { ForEach(ReaderSyntaxRule.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.accessibilityIdentifier("review-rule-mode")
                    if draft.mode == .delimited {
                        TextField("开始符号", text: $draft.start).accessibilityIdentifier("review-rule-start")
                        TextField("结束符号", text: $draft.end).accessibilityIdentifier("review-rule-end")
                        Toggle("符号本身也着色", isOn: $draft.includeDelimiters)
                    } else {
                        Text("正则表达式按文字规律寻找内容。例如“灯塔|书店”会寻找这两个词。")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("匹配表达式", text: $draft.pattern, axis: .vertical).font(.system(.body, design: .monospaced)).accessibilityIdentifier("review-rule-pattern")
                        Toggle("忽略大小写", isOn: $draft.ignoreCase)
                    }
                    Button(paragraphs ? "检查当前正文" : "检查当前摘录") {
                        do { try draft.validate(); matchCount = try (paragraphs ? ReaderSyntax.paragraphMatches(text, rules: [draft]) : ReaderSyntax.matches(text, rules: [draft])).filter { !$0.glyphsOnly }.count }
                        catch { self.error = error.localizedDescription }
                    }
                    if let matchCount { Text("找到 \(matchCount) 处匹配").accessibilityIdentifier("review-rule-matches") }
                }.autocorrectionDisabled().textInputAutocapitalization(.never)
                Section("颜色与字形") {
                    ColorPicker("文字颜色", selection: color(\.foreground), supportsOpacity: false)
                    Toggle("文字背景色", isOn: Binding(get: { draft.background != nil }, set: { draft.background = $0 ? 0xFFF2CC : nil }))
                    if draft.background != nil { ColorPicker("背景颜色", selection: Binding(get: { Color(rgb: draft.background ?? 0xFFF2CC) }, set: { draft.background = $0.savedRGB }), supportsOpacity: false) }
                    Picker("字体", selection: $draft.font) {
                        Text("跟随摘录").tag(ReaderTypography.Font?.none)
                        ForEach(ReaderTypography.Font.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }
                    Picker("导入的字体", selection: $draft.customFontID) {
                        Text("使用上方字体").tag(UUID?.none)
                        ForEach(library.fonts) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Toggle("粗体", isOn: $draft.bold); Toggle("斜体", isOn: $draft.italic)
                    Toggle("下划线", isOn: $draft.underline); Toggle("删除线", isOn: $draft.strikethrough)
                }
                Section("高级文字样式") {
                    TextEditor(text: $draft.css).font(.system(.body, design: .monospaced)).frame(minHeight: 160)
                        .autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityIdentifier("review-rule-css")
                    Menu("插入样式示例") {
                        Button("渐变文字") { append("color: linear-gradient(to right, #c64a26, #446bd0); font-weight: bold;") }
                        Button("渐变背景") { append("background: linear-gradient(to right, #ffe0b2, #fff5cc); color: #38444b;") }
                    }
                    if !library.images.isEmpty { Menu("插入图片库背景") { ForEach(library.images) { image in Button(image.name) { append("background-image: url('asset:\(image.id.uuidString)');") } } } }
                    if !library.fonts.isEmpty { Menu("插入字体库字体") { ForEach(library.fonts) { font in Button(font.name) { append("font-family: 'asset:\(font.id.uuidString)';") } } } }
                    Text("支持颜色、背景、渐变、字体、粗体、斜体和文字装饰。整张卡片的字号、行距和留白在模板中设置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("文字规则").navigationBarTitleDisplayMode(.inline)
                .onChange(of: draft) { _, _ in matchCount = nil }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") {
                        do { draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines); try draft.validate(); save(draft); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("review-rule-save") }
                }
                .alert("请检查文字规则", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
        }
    }
    private func color(_ key: WritableKeyPath<ReaderSyntaxRule, Int>) -> Binding<Color> {
        Binding(get: { Color(rgb: draft[keyPath: key]) }, set: { draft[keyPath: key] = $0.savedRGB })
    }
    private func append(_ value: String) { draft.css += (draft.css.isEmpty ? "" : "\n") + value }
}
