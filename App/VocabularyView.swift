import SwiftUI
import MoReadCore

struct VocabularyView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var words: [VocabularyWord] = []
    @State private var query = ""
    @State private var filter = VocabularyFilter.all
    @State private var editing: VocabularyWord?
    @State private var error: String?
    @State private var reading: SourcePassage?
    @State private var lookup: VocabularyWord?
    @State private var undo: Undo?
    private struct Undo {
        let original: VocabularyWord
        let replacement: VocabularyWord?
        let message: String
    }
    private var groups: [VocabularyGroup] { VocabularyGroup.groups(words, query: query, filter: filter) }
    var body: some View {
        List {
            Section { overview }
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("vocabulary-error") }
            if groups.isEmpty { Text(emptyMessage).foregroundStyle(.secondary).accessibilityIdentifier("vocabulary-empty") }
            ForEach(groups) { group in
                Section {
                    ForEach(group.words) { word in card(word) }
                } header: { HStack { Text(title(group.period)); Spacer(); Text("\(group.words.count) 个") } }
            }
        }.navigationTitle("生词本").searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索字词和释义")
            .disabled(model.maintenance)
            .task(id: model.vocabularyRevision) { reload() }
            .onChange(of: model.store.map(ObjectIdentifier.init)) { _, _ in undo = nil }
            .sheet(item: $editing) { word in
                NavigationStack { VocabularyEditor(original: word) { changed in
                    undo = .init(original: word, replacement: changed, message: "已更新 \(word.word)")
                } }
            }
            .navigationDestination(item: $reading) { passage in ReaderView(bookID: passage.bookID, initialPassage: passage, initialPassageScope: .wholeBook) }
            .navigationDestination(isPresented: Binding(get: { lookup != nil }, set: { if !$0 { lookup = nil } })) {
                if let lookup { DictionaryLookupView(word: lookup.word, source: lookup.source) }
            }
            .safeAreaInset(edge: .bottom) {
                if let undo {
                    HStack(spacing: 12) {
                        Text(undo.message).font(.subheadline).lineLimit(2)
                        Spacer(minLength: 0)
                        Button("撤销") {
                            if change({ try $0.undo(undo.original, after: undo.replacement) }) { self.undo = nil }
                        }.accessibilityIdentifier("vocabulary-undo")
                        Button("关闭提示", systemImage: "xmark.circle.fill") { self.undo = nil }.labelStyle(.iconOnly).foregroundStyle(.secondary)
                    }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal).padding(.bottom, 6)
                        .disabled(model.maintenance)
                }
            }
    }
    private var overview: some View {
        let learned = words.filter(\.learned).count
        return VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(VocabularyFilter.allCases, id: \.rawValue) { item in
                    let count = item == .all ? words.count : item == .learned ? learned : words.count - learned
                    Button { filter = item } label: {
                        VStack(spacing: 5) { Text("\(count)").font(.title2.bold()); Text(item.label).font(.subheadline) }
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .foregroundStyle(filter == item ? Color.accentColor : Color.primary)
                            .background(filter == item ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityLabel(item.label).accessibilityValue("\(count) 个")
                        .accessibilityAddTraits(filter == item ? .isSelected : [])
                        .accessibilityIdentifier("vocabulary-filter-" + item.rawValue)
                }
            }
            HStack {
                ProgressView(value: Double(learned), total: Double(max(1, words.count))).accessibilityLabel("掌握进度")
                Text("已掌握 \(words.isEmpty ? 0 : learned * 100 / words.count)%").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("vocabulary-mastery")
            }
        }.padding(.vertical, 4)
    }
    private func card(_ word: VocabularyWord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Button { lookup = word } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(word.word).font(.title3.bold())
                        if !word.phonetic.isEmpty { Text(word.phonetic).font(.caption).foregroundStyle(.secondary) }
                        if !word.gloss.isEmpty { Text(word.gloss).font(.subheadline) }
                        if !word.preview.isEmpty { Text(word.preview).lineLimit(2).font(.subheadline).foregroundStyle(.secondary) }
                        if !word.context.isEmpty { context(word).lineLimit(2).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(word.learned ? Color.secondary : Color.primary)
                }.buttonStyle(.plain).accessibilityIdentifier("vocabulary-word-" + word.word)
                Toggle("已掌握", isOn: Binding(get: { word.learned }, set: { value in
                    var item = word; item.learned = value
                    commit(word, after: item, message: "\(word.word) 已标为\(value ? "已掌握" : "学习中")")
                })).labelsHidden().fixedSize().accessibilityLabel("\(word.word)，已掌握").accessibilityIdentifier("vocabulary-learned-" + word.word)
                Menu { actions(word) } label: { Image(systemName: "ellipsis").frame(minWidth: 32, minHeight: 44) }
                    .accessibilityLabel("\(word.word) 的更多操作").accessibilityIdentifier("vocabulary-more-" + word.word)
            }
            if let source = word.source {
                Button("阅读原文") { open(source) }.font(.caption).accessibilityIdentifier("vocabulary-source-" + word.word)
            }
        }.buttonStyle(.borderless).padding(.vertical, 6)
            .contextMenu { actions(word) }
    }
    @ViewBuilder private func actions(_ word: VocabularyWord) -> some View {
        Button(word.learned ? "标为学习中" : "标为已掌握", systemImage: word.learned ? "arrow.uturn.backward" : "checkmark.circle") {
            var item = word; item.learned.toggle()
            commit(word, after: item, message: "\(word.word) 已标为\(item.learned ? "已掌握" : "学习中")")
        }
        Button("编辑释义与读音", systemImage: "square.and.pencil") { editing = word }.accessibilityIdentifier("vocabulary-edit-" + word.word)
        Button("移出生词本", systemImage: "trash", role: .destructive) { commit(word, after: nil, message: "已移出 \(word.word)") }
            .accessibilityIdentifier("vocabulary-remove-" + word.word)
    }
    private func context(_ word: VocabularyWord) -> Text {
        let text = String(word.context.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        guard let range = word.contextMatch(in: text) else { return Text(text) }
        return Text(String(text[..<range.lowerBound])) + Text(String(text[range])).bold().foregroundColor(.primary) + Text(String(text[range.upperBound...]))
    }
    private var emptyMessage: String {
        if words.isEmpty { return "阅读时查到释义后，点“加入生词本”，就能在这里复习。" }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty { return "没有匹配“\(needle)”的生词。" }
        return filter == .learning ? "这些生词都已掌握。" : "还没有标为已掌握的生词。"
    }
    private func title(_ period: VocabularyGroup.Period) -> String {
        switch period {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .week: return "过去一周"
        case .month(let year, let month):
            let calendar = ReadingCalendar.calendar()
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return "\(year)年\(month)月" }
            return year == calendar.component(.year, from: Date()) ? date.formatted(.dateTime.month(.wide)) : date.formatted(.dateTime.year().month(.wide))
        }
    }
    private func reload() { do { words = try model.vocabulary?.words() ?? [] } catch { self.error = error.localizedDescription } }
    private func commit(_ original: VocabularyWord, after replacement: VocabularyWord?, message: String) {
        if change({ store in
            if let replacement { try store.update(replacement, replacing: original) } else { try store.remove(original) }
        }) { undo = .init(original: original, replacement: replacement, message: message) }
    }
    @discardableResult private func change(_ action: (VocabularyStore) throws -> Void) -> Bool {
        guard !model.maintenance, let store = model.vocabulary else { return false }
        do { try action(store); error = nil; model.vocabularyRevision = UUID(); reload(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    private func open(_ source: SourcePassage) {
        do {
            guard let book = model.books.first(where: { $0.id == source.bookID && !$0.removed && $0.hasBody }), let store = model.store,
                  source.isValid(in: try store.chapter(source.chapter, in: book), scope: .wholeBook) else { throw MoReadError.invalid("原文已变更或移除，无法返回这个位置。") }
            reading = source; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct VocabularyEditor: View {
    let original: VocabularyWord
    let onSaved: (VocabularyWord) -> Void
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: VocabularyWord
    @State private var error: String?
    init(original: VocabularyWord, onSaved: @escaping (VocabularyWord) -> Void) { self.original = original; self.onSaved = onSaved; _draft = State(initialValue: original) }
    var body: some View {
        Form {
            Section("完整释义") { TextEditor(text: $draft.definition).frame(minHeight: 160).accessibilityIdentifier("vocabulary-definition") }
            Section("简短释义与读音") {
                TextField("简短释义（最多 24 字）", text: $draft.gloss).accessibilityIdentifier("vocabulary-gloss")
                TextField("音标或读音（最多 64 字）", text: $draft.phonetic).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("vocabulary-phonetic")
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(original.word)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            guard !model.maintenance, let store = model.vocabulary else { return }
                            draft.definition = draft.definition.trimmingCharacters(in: .whitespacesAndNewlines)
                            draft.gloss = draft.gloss.trimmingCharacters(in: .whitespacesAndNewlines)
                            draft.phonetic = draft.phonetic.trimmingCharacters(in: .whitespacesAndNewlines)
                            try store.update(draft, replacing: original); model.vocabularyRevision = UUID(); onSaved(draft); dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(model.maintenance || draft.definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.definition.count > 12_000 || draft.gloss.count > 24 || draft.phonetic.count > 64)
                        .accessibilityIdentifier("vocabulary-edit-save")
                }
            }
    }
}
