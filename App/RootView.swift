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
    var filtered: [Book] {
        model.books.filter { !$0.removed && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.author.localizedCaseInsensitiveContains(query)) }
            .sorted { a, b in a.pinned != b.pinned ? a.pinned : (a.lastOpened ?? a.importedAt) > (b.lastOpened ?? b.importedAt) }
    }
    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    ContentUnavailableView {
                        Label(query.isEmpty ? "把故事带进来" : "没有找到这本书", systemImage: "book.closed")
                    } description: { Text("从“文件”导入 TXT 或 EPUB，阅读位置会自动保存。") }
                    actions: {
                        Button("导入书籍") { picker = true }.buttonStyle(.borderedProminent)
                        if model.books.isEmpty { Button("打开示例书") { model.addSample() }.accessibilityIdentifier("add-sample") }
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 20)], spacing: 28) {
                            ForEach(filtered) { book in
                                NavigationLink(value: book.id) { BookCover(book: book) }.buttonStyle(.plain)
                                    .contextMenu {
                                        Button(book.pinned ? "取消置顶" : "置顶", systemImage: "pin") {
                                            var copy = book; copy.pinned.toggle(); model.update(copy, immediate: true)
                                        }
                                        Menu("阅读状态") {
                                            ForEach(["未读", "在读", "已读", "搁置"], id: \.self) { state in
                                                Button(state) { var copy = book; copy.state = state; model.update(copy, immediate: true) }
                                            }
                                        }
                                        Button("移除", systemImage: "trash", role: .destructive) { remove = book }
                                    }
                            }
                        }.padding(24)
                    }
                }
            }
            .navigationTitle("墨知")
            .searchable(text: $query, prompt: "书名或作者")
            .toolbar { Button("导入", systemImage: "plus") { picker = true }.disabled(model.importing) }
            .navigationDestination(for: UUID.self) { id in ReaderView(bookID: id) }
            .overlay { if model.importing { ProgressView("正在整理书籍…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) } }
            .fileImporter(isPresented: $picker, allowedContentTypes: [.plainText, UTType(filenameExtension: "epub") ?? .data]) { result in
                switch result {
                case .success(let url): Task { await model.importFile(url) }
                case .failure(let error): model.error = error.localizedDescription
                }
            }
            .confirmationDialog("移除《\(remove?.title ?? "")》", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }), titleVisibility: .visible) {
                Button("从书架移除，保留记录") { if let book = remove { model.remove(book, permanently: false) }; remove = nil }
                Button("彻底删除书籍与记录", role: .destructive) { if let book = remove { model.remove(book, permanently: true) }; remove = nil }
            }
        }
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
                Section("伴读") { NavigationLink("AI 服务商") { AISettingsView() } }
                Section("书籍与记录") {
                    NavigationLink("已移除的书籍") {
                        List(model.books.filter(\.removed)) { book in
                            HStack { Text(book.title); Spacer(); Button("恢复") { var copy = book; copy.removed = false; model.update(copy, immediate: true) } }
                        }.navigationTitle("已移除的书籍")
                    }
                }
                Section("关于") {
                    Text("墨知 MoRead").font(.headline)
                    Text("书籍、阅读位置和笔记保存在本机。").foregroundStyle(.secondary)
                    Link("源代码与版本", destination: URL(string: "https://github.com/DataDeletionAZA/MoRead-iOS")!)
                }
            }.navigationTitle("设置")
        }
    }
}
