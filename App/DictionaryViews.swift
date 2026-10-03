import SwiftUI
import UniformTypeIdentifiers
import MoReadCore

extension LibraryModel {
    func changeDictionaries(_ action: (LocalDictionaries) async throws -> String) async {
        guard !importing, !maintenance, let dictionaryLibrary else { return }
        importing = true; dictionaryNotice = nil
        defer { importing = false; dictionaryRevision = UUID() }
        do { dictionaryNotice = try await action(dictionaryLibrary) }
        catch { self.error = error.localizedDescription }
    }
    func importDictionaries(_ urls: [URL], resourcesFor id: UUID? = nil) async {
        await changeDictionaries { library in
            var imported = 0, duplicates = 0
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let duplicate: Bool
                if let id { duplicate = try await !library.addResource(url, to: id) }
                else { duplicate = try await library.add(url).duplicate }
                if duplicate { duplicates += 1 } else { imported += 1 }
            }
            return "已导入 \(imported) 个文件，\(duplicates) 个文件已存在。"
        }
    }
}

struct DictionaryManagerView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var dictionaries: [LocalDictionary] = []
    @State private var picker = false
    @State private var resourceTarget: UUID?
    @State private var removing: LocalDictionary?
    var body: some View {
        List {
            Section {
                Button("导入 MDX 词典", systemImage: "plus") { resourceTarget = nil; picker = true }.accessibilityIdentifier("dictionary-import")
                NavigationLink("查字词") { DictionaryLookupView() }
                NavigationLink("生词本") { VocabularyView() }
                if model.importing { ProgressView("正在处理词典…") }
                if let notice = model.dictionaryNotice { Text(notice).font(.caption).accessibilityIdentifier("dictionary-notice") }
            } footer: { Text("先导入 MDX，再为对应词典添加 MDD 图片、样式或声音资源。每个文件最多 4 GB。") }
            ForEach(dictionaries) { dictionary in
                Section(dictionary.title) {
                    Text(dictionary.originalName).font(.caption).foregroundStyle(.secondary)
                    Toggle("启用", isOn: Binding(get: { dictionary.enabled }, set: { value in
                        Task { await model.changeDictionaries { library in try await library.setEnabled(dictionary.id, value); return value ? "词典已启用。" : "词典已停用。" } }
                    })).accessibilityIdentifier("dictionary-enabled-" + dictionary.id.uuidString)
                    Button("添加 MDD 资源（\(dictionary.resources.count)）") { resourceTarget = dictionary.id; picker = true }
                    ForEach(dictionary.resources) { Text($0.name).font(.caption).foregroundStyle(.secondary) }
                    Button("删除词典", role: .destructive) { removing = dictionary }
                }
            }
        }.navigationTitle("词典管理")
            .disabled(model.importing || model.maintenance)
            .task(id: model.dictionaryRevision) {
                do { dictionaries = try await model.dictionaryLibrary?.list() ?? [] }
                catch { model.error = error.localizedDescription }
            }
            .fileImporter(isPresented: $picker, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await model.importDictionaries(urls, resourcesFor: resourceTarget) }
                case .failure(let error): model.error = error.localizedDescription
                }
            }
            .confirmationDialog("删除词典及其资源包？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { dictionary in
                Button("删除词典", role: .destructive) {
                    Task { await model.changeDictionaries { library in try await library.remove(dictionary.id); return "词典已删除。" } }
                    removing = nil
                }.accessibilityIdentifier("dictionary-delete-confirm")
            } message: { Text($0.title) }
    }
}

struct DictionaryLookupView: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var companion: CompanionModel
    @FocusState private var queryFocused: Bool
    @State private var query: String
    private let source: SourcePassage?
    private let sourceWord: String
    @State private var notice: String?
    @State private var searched = ""
    @State private var entries: [DictionaryDefinition] = []
    @State private var selected: UUID?
    @State private var positions: [UUID: CGPoint] = [:]
    @State private var plainText: [UUID: String] = [:]
    @State private var simple = false
    @State private var searching = false
    @State private var error: String?
    @State private var lookupTask: Task<Void, Never>?
    @State private var useAI = false
    @State private var aiEntry: AIDictionaryEntry?
    @State private var aiTask: Task<Void, Never>?
    @State private var aiRequest = UUID()
    @State private var aiBusy = false
    @State private var aiScroll: Int?
    init(word: String = "", source: SourcePassage? = nil) {
        self.source = source; sourceWord = VocabularyWord.normalize(word)
        _query = State(initialValue: String(word.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)))
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("字词或短语", text: $query).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($queryFocused).submitLabel(.search).onSubmit { useAI ? aiLookup() : search() }.accessibilityIdentifier("dictionary-query")
                Button("查询") { useAI ? aiLookup() : search() }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || query.count > 80 || aiBusy || model.maintenance)
                    .accessibilityIdentifier("dictionary-search")
            }.padding(.horizontal)
            if searching { ProgressView("正在查词…") }
            if let notice { Text(notice).font(.caption).accessibilityIdentifier("vocabulary-notice") }
            if let error { Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal) }
            Picker("查询方式", selection: $useAI) { Text("本地词典").tag(false); Text("AI 词典").tag(true) }
                .pickerStyle(.segmented).padding(.horizontal).accessibilityIdentifier("dictionary-mode")
            if useAI { aiContent }
            if !useAI, !entries.isEmpty {
                Picker("词典", selection: $selected) { ForEach(entries) { Text($0.title).tag(Optional($0.id)) } }
                    .pickerStyle(.menu).accessibilityIdentifier("dictionary-source")
            }
            if !useAI, let entry = entries.first(where: { $0.id == selected }), let library = model.dictionaryLibrary {
                HStack {
                    Button(simple ? "查看词典排版" : "简明释义") { simple.toggle() }.accessibilityIdentifier("dictionary-simple")
                    Button("加入生词本") {
                        let definition = plainText[entry.id] ?? "", brief = DictionaryGloss.extract(definition)
                        save(definition: definition, gloss: brief.meaning, phonetic: brief.phonetic)
                    }.disabled((plainText[entry.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.maintenance)
                        .accessibilityIdentifier("vocabulary-save")
                }
                ZStack {
                    DictionaryWebView(entry: entry, library: library, position: Binding(get: { positions[entry.id] ?? .zero }, set: { positions[entry.id] = $0 }), plainText: Binding(get: { plainText[entry.id] ?? "" }, set: { plainText[entry.id] = $0 }), error: $error) { word in query = word; search() }
                        .id(entry.id.uuidString + searched).opacity(simple ? 0 : 1).allowsHitTesting(!simple).accessibilityHidden(simple)
                    if simple { ScrollView { Text(plainText[entry.id].map { $0.isEmpty ? "这条释义没有可显示的文字。" : $0 } ?? "正在读取文字…").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding().accessibilityIdentifier("dictionary-plain") } }
                }
            } else if !useAI {
                ContentUnavailableView(searched.isEmpty ? "查字词" : "没有找到释义", systemImage: "character.book.closed", description: Text(searched.isEmpty ? "输入字词，或在正文中选中文字后查词。" : "可以更换字词，或在词典管理中导入并启用其他词典。"))
            }
        }.navigationTitle(useAI ? "AI 词典" : "本地词典")
            .toolbar { ToolbarItem(placement: .primaryAction) { NavigationLink("管理") { DictionaryManagerView() } }; ToolbarItem(placement: .secondaryAction) { NavigationLink("生词本") { VocabularyView() } } }
            .task(id: model.dictionaryRevision) { if !query.isEmpty { search() } }
            .onDisappear { lookupTask?.cancel(); stopAI() }
            .onChange(of: query) { _, _ in stopAI() }
            .onChange(of: companion.settings.resolvedProvider(for: .dictionary)) { _, _ in stopAI() }
            .onChange(of: model.maintenance) { _, value in if value { stopAI() } }
    }
    private var aiContent: some View {
        VStack(spacing: 10) {
            ModelAssignmentPicker(task: .dictionary).padding(.horizontal)
            HStack {
                if aiBusy { ProgressView(); Button("停止查词", action: stopAI).accessibilityIdentifier("dictionary-ai-stop") }
                else { Button(aiEntry == nil ? "AI 查词" : "重新生成", action: aiLookup).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || query.count > 80 || model.maintenance).accessibilityIdentifier("dictionary-ai-start") }
                if let aiEntry { Button("加入生词本") { save(definition: aiEntry.definition, gloss: aiEntry.gloss, phonetic: aiEntry.phonetic) }.disabled(aiBusy || model.maintenance).accessibilityIdentifier("vocabulary-save") }
            }
            Text("发送所查字词与附近已读语境，按所选服务商规则计费。AI 释义可能有误，可与本地词典对照。")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            if let aiEntry {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(aiEntry.definition.components(separatedBy: "\n\n").enumerated()), id: \.offset) { index, paragraph in
                            let heading = paragraph.range(of: #"^#{1,6}\s+"#, options: .regularExpression)
                            let text = heading.map { String(paragraph[$0.upperBound...]) } ?? paragraph
                            Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                                .font(heading == nil ? .body : .headline).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).id(index)
                        }
                    }.scrollTargetLayout().padding()
                }.scrollPosition(id: $aiScroll, anchor: .top).accessibilityIdentifier("dictionary-ai-definition")
            } else { ContentUnavailableView(aiBusy ? "正在结合语境查询…" : "AI 查词", systemImage: "character.book.closed", description: Text("解释现代汉语、文言文及外语字词，也可在没有本地词典时使用。")) }
        }
    }
    private func save(definition: String, gloss: String, phonetic: String) {
        do {
            guard let vocabulary = model.vocabulary, !model.maintenance else { return }
            let origin = VocabularyWord.normalize(searched) == sourceWord ? source : nil
            _ = try vocabulary.saveDefinition(word: searched, definition: definition, source: origin, context: try context(for: origin), gloss: gloss, phonetic: phonetic)
            model.vocabularyRevision = UUID(); notice = "已保存生词与释义。"
        } catch { self.error = error.localizedDescription }
    }
    private func stopAI() { aiRequest = UUID(); aiTask?.cancel(); aiTask = nil; aiBusy = false }
    private func aiLookup() {
        guard !model.maintenance else { return }
        queryFocused = false
        let word = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if searched != word { search() }
        stopAI(); error = nil; notice = nil
        let provider = companion.settings.resolvedProvider(for: .dictionary)
        do {
            let origin = VocabularyWord.normalize(word) == sourceWord ? source : nil
            var context = ""
            if let origin {
                guard let book = model.books.first(where: { $0.id == origin.bookID && !$0.removed && $0.hasBody }), let store = model.store else { throw MoReadError.invalid("书籍已不可用，请重新选词。") }
                context = try AIDictionaryEntry.context(source: origin, chapter: store.chapter(origin.chapter, in: book), through: book.readThrough)
            }
            let messages = try AIDictionaryEntry.messages(word: word, context: context)
            let token = UUID(); aiRequest = token; aiBusy = true
            aiTask = Task {
                defer { if aiRequest == token { aiTask = nil; aiBusy = false } }
                do {
                    let raw = try await companion.dictionaryReply(provider: provider, messages: messages)
                    try Task.checkCancellation()
                    guard aiRequest == token, searched == word, !model.maintenance, companion.settings.resolvedProvider(for: .dictionary) == provider else { return }
                    if let origin {
                        guard let book = model.books.first(where: { $0.id == origin.bookID && !$0.removed && $0.hasBody }), let store = model.store,
                              try AIDictionaryEntry.context(source: origin, chapter: store.chapter(origin.chapter, in: book), through: book.readThrough).hasPrefix(context) else { throw MoReadError.invalid("原文或阅读范围已变化，请重新选词。") }
                    }
                    aiEntry = try AIDictionaryEntry.parse(raw); aiScroll = nil
                } catch is CancellationError { }
                catch { if aiRequest == token { self.error = error.localizedDescription } }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func search() {
        lookupTask?.cancel()
        let word = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, word.count <= 80, let library = model.dictionaryLibrary else { return }
        queryFocused = false; stopAI(); aiEntry = nil; aiScroll = nil
        error = nil; notice = nil; searching = true; entries = []; selected = nil; positions = [:]; plainText = [:]; searched = word
        lookupTask = Task {
            do {
                let values = try await library.lookup(word)
                try Task.checkCancellation()
                entries = values; selected = values.first?.id; searching = false
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription; searching = false } }
        }
    }
    private func context(for source: SourcePassage?) throws -> String {
        guard let source, let book = model.books.first(where: { $0.id == source.bookID && $0.hasBody }), let store = model.store else { return source?.text ?? "" }
        let chapter = try store.chapter(source.chapter, in: book)
        guard source.isValid(in: chapter, scope: .wholeBook) else { return source.text }
        let start = TextBoundary.floor(max(0, source.offset - 120), in: chapter.text)
        let end = TextBoundary.floor(min(chapter.text.utf16.count, source.offset + source.text.utf16.count + 180), in: chapter.text)
        return String((chapter.text as NSString).substring(with: NSRange(location: start, length: end - start)).prefix(12_000))
    }
}

extension CompanionModel {
    func dictionaryReply(provider: AIProvider?, messages: [ChatMessage]) async throws -> String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--simulate-ai-dictionary") {
            let query = messages.last?.content ?? ""
            try await Task.sleep(for: .seconds(query.contains("slow") ? 8 : 0.3))
            if query.contains("fail") { throw MoReadError.invalid("词典服务暂不可用。") }
            let word = String(query.components(separatedBy: "\n").first?.dropFirst(3) ?? "")
            return String(decoding: try JSONSerialization.data(withJSONObject: ["gloss": "语境词义", "phonetic": "/fixture/", "definition": "## \(word)\n\n1. 根据当前语境解释字词。\n\n模型：\(provider?.model ?? "fixture")"]), as: UTF8.self)
        }
        #endif
        guard var provider else { throw MoReadError.invalid("请先在模型分工中选择词典模型。") }
        provider.maxTokens = min(provider.maxTokens, 6000)
        let key = try await KeychainStore.readAsync(provider.id)
        try Task.checkCancellation()
        return try await ChatClient.complete(provider: provider, key: key, messages: messages, maximumBytes: 64_000)
    }
}
