import SwiftUI
import UniformTypeIdentifiers
import MoReadCore

struct RootView: View {
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var companion: CompanionModel
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView {
            BookshelfView().tabItem { Label("书架", systemImage: "books.vertical") }
            CompanionHome().tabItem { Label("伴读", systemImage: "bubble.left.and.bubble.right") }
            StatisticsView().tabItem { Label("足迹", systemImage: "chart.bar.xaxis") }
            SettingsView().tabItem { Label("设置", systemImage: "slider.horizontal.3") }
        }
        .disabled(model.maintenance)
        .sheet(isPresented: $model.showFonts) {
            NavigationStack { FontLibraryView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { model.showFonts = false } } } }
        }
        .sheet(item: $model.textImport, onDismiss: { Task { await model.nextImport() } }) { TextImportView(draft: $0) }
        .task {
            #if DEBUG
            if companion.simulatedHybrid, companion.conversations.isEmpty, let card = companion.characters.first {
                companion.perform {
                    var provider = AIProvider(); provider.name = "本地检索测试"; provider.model = "fixture"; provider.baseURL = "https://example.invalid/v1"
                    companion.settings.providers = [provider]; companion.settings.selectedProvider = provider.id
                    if let store = model.store {
                        let visible = "At the harbor, the lighthouse beacon shone."
                        let chapters = [Chapter(id: 0, title: "Harbor", text: "harbor boats harbor boats harbor boats."), Chapter(id: 1, title: "Garden", text: "Birds sang in the garden."), Chapter(id: 2, title: "Lighthouse", text: visible + " Future secret identity.")]
                        var book = try store.importBook(title: "海岸与灯塔", chapters: chapters); book.readThrough = .init(chapter: 2, offset: visible.utf16.count)
                        try store.save(book); model.load()
                        companion.settings.vectorBooks = [book.id]; companion.saveSettings()
                        let chat = Conversation(title: "检索测试", bookID: nil, characterID: card.id)
                        try companion.store?.save(chat); companion.conversations = [chat]
                    }
                }
            }
            if companion.simulatedTools, companion.conversations.isEmpty, let card = companion.characters.first {
                companion.perform {
                    var provider = AIProvider(); provider.name = "本地工具测试"; provider.model = "fixture"; provider.baseURL = "https://example.invalid/v1"
                    companion.settings.providers = [provider]; companion.settings.selectedProvider = provider.id; companion.saveSettings()
                    if let store = model.store {
                        let chapters = [Chapter(id: 0, title: "First", text: "lighthouse first clue."), Chapter(id: 1, title: "Second", text: "lighthouse second clue."), Chapter(id: 2, title: "Future secret", text: "lighthouse secret identity.")]
                        var book = try store.importBook(title: "查询测试", chapters: chapters)
                        book.readThrough = .init(chapter: 1, offset: chapters[1].text.utf16.count)
                        try store.save(book); model.load()
                        let chat = Conversation(title: "工具查询", bookID: book.id, characterID: card.id)
                        try companion.store?.save(chat); companion.conversations = [chat]
                    }
                }
            }
            if companion.simulatedRerank, companion.conversations.isEmpty, let card = companion.characters.first {
                companion.perform {
                    var provider = AIProvider(); provider.name = "本地排序测试"; provider.model = "fixture"; provider.baseURL = "https://example.invalid/v1"
                    companion.settings.providers = [provider]; companion.settings.selectedProvider = provider.id
                    var policy = RerankSettings(); policy.enabled = true; policy.providerID = provider.id; policy.model = "fixture-rerank"
                    companion.settings.rerank = policy; companion.saveSettings()
                    if let store = model.store {
                        let chapters = [Chapter(id: 0, title: "First", text: "lighthouse first clue."), Chapter(id: 1, title: "Second", text: "lighthouse second clue."), Chapter(id: 2, title: "Future", text: "lighthouse secret identity.")]
                        var book = try store.importBook(title: "灯塔线索", chapters: chapters)
                        book.readThrough = .init(chapter: 1, offset: chapters[1].text.utf16.count)
                        try store.save(book); model.load()
                    }
                    let chat = Conversation(title: "寻找灯塔", bookID: nil, characterID: card.id)
                    try companion.store?.save(chat); companion.conversations = [chat]
                }
            }
            if companion.simulatedMemory, companion.conversations.isEmpty, let card = companion.characters.first {
                var provider = AIProvider(); provider.name = "本地记忆测试"; provider.model = "fixture"; provider.baseURL = "https://example.invalid"
                companion.settings.providers = [provider]; companion.settings.selectedProvider = provider.id
                companion.settings.embeddingProvider = provider.id; companion.settings.embeddingModel = "fixture-vector"
                var policy = PersonaMemorySettings(); policy.enabled = true; policy.providerID = provider.id
                companion.settings.personaMemory = policy; companion.saveSettings()
                var chat = Conversation(title: "书店的记忆", bookID: nil, characterID: card.id)
                chat.messages = (0..<12).map { ChatMessage(role: $0.isMultiple(of: 2) ? "user" : "assistant", content: "第\($0)条：用户喜欢安静的书店。") }
                companion.perform { try companion.store?.save(chat); companion.conversations = [chat] }
            }
            if companion.simulatedIdentities, companion.settings.providers.isEmpty {
                var provider = AIProvider(); provider.name = "本地身份测试"; provider.model = "fixture"; provider.baseURL = "https://example.invalid"
                companion.settings.providers = [provider]; companion.settings.selectedProvider = provider.id; companion.saveSettings()
            }
            if companion.simulatedSummary, companion.conversations.isEmpty, let card = companion.characters.first {
                var provider = AIProvider(); provider.name = "本地提要测试"; provider.model = "fixture"; provider.baseURL = "https://example.invalid"
                companion.settings.providers = [provider]
                var policy = SummarySettings(); policy.providerID = provider.id
                companion.settings.summarySettings = policy; companion.saveSettings()
                var conversation = Conversation(title: "书店里的对话", bookID: nil, characterID: card.id)
                conversation.messages = (0..<32).map { ChatMessage(role: $0.isMultiple(of: 2) ? "user" : "assistant", content: "第\($0)条：我们慢慢读雨后的书店。") }
                companion.perform { try companion.store?.save(conversation); companion.conversations = [conversation] }
            }
            if companion.simulatedAnnotations {
                var provider = AIProvider(); provider.name = "本地段评测试"; provider.model = "fixture"; provider.baseURL = "https://example.invalid"
                companion.settings.providers = [provider]; companion.settings.selectedProvider = provider.id
                var policy = companion.settings.proactive ?? ProactiveSettings(); policy.enabled = true
                companion.settings.proactive = policy; companion.saveSettings()
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--import-test-font"),
               model.fonts.isEmpty, let url = Bundle.main.url(forResource: "NotoSerifSC", withExtension: "ttf") { await model.importFonts([url]) }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--import-test-background"), model.readingBackground == nil {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { context in
                    UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 150, height: 400))
                    UIColor.systemOrange.setFill(); context.fill(CGRect(x: 150, y: 0, width: 150, height: 400))
                }
                model.perform { try model.saveReadingBackground(image.jpegData(compressionQuality: 0.85)) }
                UserDefaults.standard.set("image", forKey: "reader.paper")
            }
            #endif
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--preview-test-text") {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("雨后的书店.txt")
                do {
                    let large = ProcessInfo.processInfo.arguments.contains("--large-preview-test-text")
                    let text = large ? String(repeating: LibraryModel.sampleText, count: 8000) : LibraryModel.sampleText
                    try Data(text.utf8).write(to: url, options: .atomic)
                    await model.queueImports(large ? [url] : [url, url]); try? FileManager.default.removeItem(at: url)
                } catch { model.error = error.localizedDescription }
            }
        }
        .overlay {
            if let title = model.maintenanceTitle {
                VStack(spacing: 18) {
                    Text(title).font(.headline)
                    ProgressView(value: model.maintenanceProgress)
                    Button("取消") { model.cancelMaintenance?() }
                }.padding(28).frame(maxWidth: 320).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            }
        }
        .alert("需要处理", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.flush() } }
        .onChange(of: companion.error) { _, error in if let error { model.error = error; companion.error = nil } }
    }
}

struct BookshelfView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var picker = false
    @State private var query = ""
    @State private var remove: Book?
    @State private var editing: Book?
    @State private var showFilters = false
    @State private var filter = ShelfFilter()
    @AppStorage("shelf.sort") private var sort = ShelfSort.recent.rawValue
    var filtered: [Book] {
        model.organization.sorted(model.organization.filtered(model.books, query: query, filter: filter), by: ShelfSort(rawValue: sort) ?? .recent, collection: filter.collectionID)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                categories
                if filtered.isEmpty {
                    ContentUnavailableView {
                        Label(filter.isActive ? "这个范围还没有书" : query.isEmpty ? "把故事带进来" : "没有找到这本书", systemImage: "book.closed")
                    } description: { Text("从“文件”导入 TXT 或 EPUB，阅读位置会自动保存。") }
                    actions: {
                        Button("导入书籍") { picker = true }.buttonStyle(.borderedProminent)
                        if filter.isActive { Button("清除筛选") { filter = ShelfFilter() } }
                        if model.books.isEmpty {
                            Button("打开示例书") { model.addSample() }.accessibilityIdentifier("add-sample")
                            Button("打开 EPUB 示例") {
                                if let url = Bundle.main.url(forResource: "sample", withExtension: "epub") { Task { await model.importFile(url) } }
                            }.accessibilityIdentifier("add-epub-sample")
                        }
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 20)], spacing: 28) {
                            ForEach(filtered) { book in
                                NavigationLink(value: book.id) { BookCover(book: book) }.buttonStyle(.plain)
                                    .draggable("moread-book:" + book.id.uuidString)
                                    .dropDestination(for: String.self) { values, _ in
                                        guard let id = draggedBook(values), id != book.id else { return false }
                                        if model.organize({ $0.move(id, before: book.id, among: model.books, collection: filter.collectionID) }) { sort = ShelfSort.manual.rawValue; return true }
                                        return false
                                    }
                                    .accessibilityAction(named: "编辑资料") { editing = book }
                                    .contextMenu {
                                        Button("编辑资料", systemImage: "pencil") { editing = book }
                                        Button(book.pinned ? "取消置顶" : "置顶", systemImage: "pin") {
                                            var copy = book; copy.pinned.toggle(); model.update(copy, immediate: true)
                                        }
                                        Menu("阅读状态") {
                                            ForEach(["未读", "在读", "已读", "搁置"], id: \.self) { state in
                                                Button(state) { var copy = book; copy.state = state; model.update(copy, immediate: true) }
                                            }
                                        }
                                        Menu("移动到分组") {
                                            Button("未分组") { model.organize { $0.bookGroups[book.id] = nil } }
                                            ForEach(model.organization.groups) { group in Button(model.organization.groupPath(group.id)) { model.organize { $0.bookGroups[book.id] = group.id } } }
                                        }
                                        Menu("放入合集") {
                                            Button("移出合集") { model.organize { $0.setCollection(nil, for: [book.id]) } }
                                            ForEach(model.organization.collections) { collection in Button(collection.name) { model.organize { $0.setCollection(collection.id, for: [book.id]) } } }
                                        }
                                        Button("移除", systemImage: "trash", role: .destructive) { remove = book }
                                    }
                            }
                        }.padding(24)
                    }
                }
            }
            .navigationTitle("墨知")
            .searchable(text: $query, prompt: "书名、作者或标签")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu("书架选项", systemImage: "ellipsis.circle") {
                        Button("筛选与排序", systemImage: "line.3.horizontal.decrease.circle") { showFilters = true }
                        NavigationLink("整理书架", destination: ShelfManager())
                    }
                }
                ToolbarItem(placement: .primaryAction) { Button("导入", systemImage: "plus") { picker = true }.disabled(model.importing) }
            }
            .navigationDestination(for: UUID.self) { id in ReaderView(bookID: id) }
            .overlay { if model.importing { ProgressView("正在整理书籍…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) } }
            .sheet(item: $editing) { BookMetadataEditor(bookID: $0.id) }
            .sheet(isPresented: $showFilters) { ShelfFiltersView(filter: $filter, sort: $sort) }
            .fileImporter(isPresented: $picker, allowedContentTypes: [.plainText, UTType(filenameExtension: "epub") ?? .data], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    let group = filter.groupID, collection = filter.collectionID
                    Task { await model.queueImports(urls, group: group, collection: collection) }
                case .failure(let error): model.error = error.localizedDescription
                }
            }
            .confirmationDialog("移除《\(remove?.title ?? "")》", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }), titleVisibility: .visible) {
                Button("从书架移除，保留记录") { if let book = remove { model.remove(book, permanently: false) }; remove = nil }
                Button("彻底删除书籍与记录", role: .destructive) { if let book = remove { model.remove(book, permanently: true) }; remove = nil }
            }
            .onChange(of: model.organization) { _, value in
                if let id = filter.groupID, !value.groups.contains(where: { $0.id == id }) { filter.groupID = nil }
                if let id = filter.collectionID, !value.collections.contains(where: { $0.id == id }) { filter.collectionID = nil }
                filter.tags.formIntersection(value.tags.map(\.id))
            }
        }
    }
    @ViewBuilder private var categories: some View {
        if filter.isActive || !model.organization.groups.isEmpty || !model.organization.collections.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Button("全部") { filter = ShelfFilter() }.buttonStyle(.bordered)
                    ForEach(model.organization.groups) { group in
                        Button { filter.groupID = group.id; filter.ungrouped = false; filter.collectionID = nil } label: { Label(model.organization.groupPath(group.id), systemImage: "folder") }
                            .buttonStyle(.bordered).tint(filter.groupID == group.id ? .accentColor : .secondary)
                            .dropDestination(for: String.self) { values, _ in
                                guard let id = draggedBook(values) else { return false }
                                return model.organize { $0.bookGroups[id] = group.id }
                            }
                    }
                    ForEach(model.organization.collections) { collection in
                        Button { filter.collectionID = collection.id; filter.groupID = nil; filter.ungrouped = false } label: { Label(collection.name, systemImage: "square.stack") }
                            .buttonStyle(.bordered).tint(filter.collectionID == collection.id ? .accentColor : .secondary)
                            .dropDestination(for: String.self) { values, _ in
                                guard let id = draggedBook(values) else { return false }
                                return model.organize { $0.setCollection(collection.id, for: [id]) }
                            }
                    }
                    if filter.isActive { Button("筛选中", systemImage: "line.3.horizontal.decrease.circle.fill") { showFilters = true }.buttonStyle(.bordered) }
                }.padding(.horizontal, 20).padding(.vertical, 8)
            }
        }
    }
    private func draggedBook(_ values: [String]) -> UUID? {
        guard let first = values.first, first.hasPrefix("moread-book:"), let id = UUID(uuidString: String(first.dropFirst("moread-book:".count))), model.books.contains(where: { $0.id == id && !$0.removed }) else { return nil }
        return id
    }
}

struct BookCover: View {
    let book: Book
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.86, green: 0.85, blue: 0.78).gradient)
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Text(book.format.uppercased()).font(.caption2.monospaced()); Spacer(); if book.pinned { Image(systemName: "pin.fill") } }.foregroundStyle(.black.opacity(0.55))
                    Text(book.title).font(.system(size: 25, weight: .medium, design: .serif)).foregroundStyle(Color(red: 0.19, green: 0.25, blue: 0.21)).lineLimit(4)
                    Spacer(minLength: 0)
                    Text(book.author.isEmpty ? "本地藏书" : book.author).font(.caption).foregroundStyle(.black.opacity(0.65))
                }.padding(18)
            }.frame(height: 215)
            Text(book.title).font(.subheadline.weight(.medium)).lineLimit(1)
            HStack { Text(book.state); Spacer(); Text(book.progress, format: .percent.precision(.fractionLength(0))) }.font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}

struct StatisticsView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var seconds: Double = 0
    @State private var annotationCount = 0
    var body: some View {
        NavigationStack {
            List {
                Section("阅读足迹") {
                    LabeledContent("藏书", value: "\(model.books.filter { !$0.removed }.count) 本")
                    LabeledContent("已读", value: "\(model.books.filter { $0.state == "已读" }.count) 本")
                    LabeledContent("阅读时长", value: "\(Int(seconds / 60)) 分钟")
                    LabeledContent("批注", value: "\(annotationCount) 条")
                }
            }.navigationTitle("足迹")
                .onAppear {
                    model.perform {
                        seconds = 0; annotationCount = 0
                        for book in model.books {
                            if let records = try model.store?.records(for: book) {
                                seconds += records.readingSeconds.values.reduce(0, +)
                                annotationCount += records.annotations.count
                            }
                        }
                    }
                }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: LibraryModel
    var body: some View {
        NavigationStack {
            List {
                Section("伴读") {
                    NavigationLink("我的身份") { UserMaskSettingsView() }
                    NavigationLink("AI 服务商") { AISettingsView() }
                    NavigationLink("向量记忆") { VectorMemoryView() }
                    NavigationLink("原文相关性排序") { RerankSettingsView() }
                    NavigationLink("伴读工具") { CompanionToolsSettingsView() }
                    NavigationLink("随读段评") { ProactiveSettingsView() }
                    NavigationLink("对话记忆") { SummarySettingsView() }
                    NavigationLink("长期记忆") { PersonaMemorySettingsView() }
                }
                Section("阅读与外观") {
                    NavigationLink("字体库") { FontLibraryView() }
                    NavigationLink("主题与外观") { ThemeView() }
                }
                Section("听书") { NavigationLink("云端声音与缓存") { CloudSpeechView() } }
                Section("书籍与记录") {
                    NavigationLink("整理书架") { ShelfManager() }
                    NavigationLink("备份与恢复") { BackupView() }
                    NavigationLink("存储与阅读记录") { StorageView() }
                }
                Section("关于") {
                    Text("墨知 MoRead").font(.headline)
                    Text("书籍、阅读位置和笔记保存在本机。").foregroundStyle(.secondary)
                    Link("源代码与版本", destination: URL(string: "https://github.com/DataDeletionAZA/MoRead-iOS")!)
                    NavigationLink("开源许可") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                ForEach(["THIRD_PARTY_NOTICES.md", "LICENSE", "THIRD_PARTY_LICENSES.txt"], id: \.self) { name in
                                    if let url = Bundle.main.url(forResource: name, withExtension: nil), let text = try? String(contentsOf: url, encoding: .utf8) { Text(text).textSelection(.enabled) }
                                }
                            }.font(.footnote).padding()
                        }.navigationTitle("开源许可")
                    }
                }
            }.navigationTitle("设置")
        }
    }
}
