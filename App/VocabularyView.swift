import SwiftUI
import MoReadCore

struct VocabularyView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var words: [VocabularyWord] = []
    @State private var query = ""
    @State private var filter = "all"
    @State private var editing: VocabularyWord?
    @State private var removing: VocabularyWord?
    @State private var error: String?
    @State private var reading: SourcePassage?
    private var visible: [VocabularyWord] {
        words.filter { (filter == "all" || $0.learned == (filter == "learned")) && (query.isEmpty || ($0.word + " " + $0.definition + " " + $0.gloss).localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        List {
            Picker("掌握状态", selection: $filter) { Text("全部").tag("all"); Text("学习中").tag("learning"); Text("已掌握").tag("learned") }.pickerStyle(.segmented)
            if let error { Text(error).foregroundStyle(.red) }
            if visible.isEmpty { Text("还没有符合条件的生词。查到释义后，可以点“加入生词本”。").foregroundStyle(.secondary) }
            ForEach(visible) { word in
                Section {
                    NavigationLink { DictionaryLookupView(word: word.word, source: word.source) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(word.word).font(.headline)
                            if !word.phonetic.isEmpty { Text(word.phonetic).font(.caption) }
                            if !word.gloss.isEmpty { Text(word.gloss).font(.subheadline) }
                            Text(word.definition).lineLimit(4).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("vocabulary-word-" + word.word)
                    if let source = word.source {
                        Text(word.context).lineLimit(3).font(.caption).foregroundStyle(.secondary)
                        Button("阅读原文") { open(source) }.accessibilityIdentifier("vocabulary-source-" + word.word)
                    }
                    Toggle("已掌握", isOn: Binding(get: { word.learned }, set: { value in
                        change { store in var item = word; item.learned = value; try store.update(item, replacing: word) }
                    })).accessibilityIdentifier("vocabulary-learned-" + word.word)
                    Button("编辑释义与读音") { editing = word }.accessibilityIdentifier("vocabulary-edit-" + word.word)
                    Button("移出生词本", role: .destructive) { removing = word }.accessibilityIdentifier("vocabulary-remove-" + word.word)
                }
            }
        }.navigationTitle("生词本").searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索字词和释义")
            .disabled(model.maintenance)
            .task(id: model.vocabularyRevision) { reload() }
            .sheet(item: $editing) { word in NavigationStack { VocabularyEditor(original: word) } }
            .navigationDestination(item: $reading) { passage in ReaderView(bookID: passage.bookID, initialPassage: passage, initialPassageScope: .wholeBook) }
            .confirmationDialog("移出这个生词？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { word in
                Button("移出生词本", role: .destructive) { change { try $0.remove(word) }; removing = nil }.accessibilityIdentifier("vocabulary-remove-confirm")
            } message: { Text($0.word) }
    }
    private func reload() { do { words = try model.vocabulary?.words() ?? [] } catch { self.error = error.localizedDescription } }
    private func change(_ action: (VocabularyStore) throws -> Void) {
        guard !model.maintenance, let store = model.vocabulary else { return }
        do { try action(store); error = nil; model.vocabularyRevision = UUID(); reload() }
        catch { self.error = error.localizedDescription }
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
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: VocabularyWord
    @State private var error: String?
    init(original: VocabularyWord) { self.original = original; _draft = State(initialValue: original) }
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
                            try store.update(draft, replacing: original); model.vocabularyRevision = UUID(); dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(model.maintenance || draft.definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.definition.count > 12_000 || draft.gloss.count > 24 || draft.phonetic.count > 64)
                        .accessibilityIdentifier("vocabulary-edit-save")
                }
            }
    }
}
