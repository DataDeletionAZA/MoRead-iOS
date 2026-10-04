import SwiftUI
import MoReadCore

struct ReadingReviewView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var filter: ReadingReviewFilter
    @State private var entries: [ReadingReviewEntry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var selected: ReadingReviewEntry?
    @State private var choosingBooks = false
    @State private var composing: ReviewComposition.Mode?
    private struct Request: Equatable { let books: [Book]; let revision: UUID; let maintenance: Bool }
    private var request: Request { .init(books: library.books, revision: library.recordsRevision, maintenance: library.maintenance) }
    private var visible: [ReadingReviewEntry] { filter.apply(to: entries) }
    private var authors: [ReadingReviewEntry] {
        var seen = Set<UUID>()
        return entries.filter { if let id = $0.characterID { return seen.insert(id).inserted }; return false }
            .sorted { $0.author.localizedStandardCompare($1.author) == .orderedAscending }
    }
    init(bookID: UUID? = nil) {
        var value = ReadingReviewFilter(); if let bookID { value.bookIDs = [bookID] }
        _filter = State(initialValue: value)
    }
    var body: some View {
        List {
            Section {
                Button(filter.bookIDs.isEmpty ? "全部书籍" : "已选 \(filter.bookIDs.count) 本书") { choosingBooks = true }.accessibilityIdentifier("review-books")
                Picker("内容", selection: $filter.kind) { ForEach(ReadingReviewFilter.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.accessibilityIdentifier("review-kind")
                Picker("来源", selection: $filter.source) { ForEach(ReadingReviewFilter.Source.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.accessibilityIdentifier("review-source")
                if filter.source == .companion {
                    Picker("角色", selection: $filter.characterID) {
                        Text("全部角色").tag(UUID?.none)
                        ForEach(authors) { Text($0.author).tag($0.characterID) }
                    }.accessibilityIdentifier("review-character")
                }
                Toggle("从最早开始", isOn: $filter.oldestFirst)
            }
            if loading { ProgressView("正在读取记录…") }
            else if let error { Text(error).foregroundStyle(.secondary) }
            else if visible.isEmpty { ContentUnavailableView("没有符合条件的记录", systemImage: "note.text", description: Text("试试其他书籍、作者或关键词。")) }
            else {
                Section("\(visible.count) 条记录") {
                    ForEach(visible) { entry in
                        Button { selected = entry } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(entry.book.title + " · " + entry.author).font(.caption).foregroundStyle(.secondary)
                                if case .note(let note) = entry.content {
                                    if note.characterID != nil && note.userEdited { Text("已由我编辑").font(.caption).foregroundStyle(.secondary) }
                                    if let from = note.fromChapter, let to = note.toChapter { Text("覆盖第 \(from)–\(to) 章").font(.caption).foregroundStyle(.secondary) }
                                }
                                Text(entry.title).font(.headline)
                                if !entry.quote.isEmpty { Text(entry.quote).lineLimit(4) }
                                if !entry.body.isEmpty { Text(entry.body).lineLimit(4).foregroundStyle(.secondary) }
                            }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.primary)
                        }.accessibilityIdentifier("review-entry-" + entry.title)
                    }
                }
            }
        }.navigationTitle("划线与笔记回顾").searchable(text: $filter.query, prompt: "搜索书名、作者、摘录与笔记")
            .toolbar {
                Button("全屏回顾", systemImage: "rectangle.expand.vertical") { selected = visible.first }.disabled(visible.isEmpty)
                if !visible.isEmpty { ShareLink("导出筛选结果", item: ReadingReview.markdown(visible)) }
                Menu("邀请角色", systemImage: "sparkles") {
                    ForEach(ReviewComposition.Mode.allCases) { mode in Button(mode.rawValue) { composing = mode } }
                }.disabled(visible.isEmpty)
            }
            .task(id: request) { await load() }
            .sheet(item: $composing) { ReviewComposer(entries: visible, mode: $0) }
            .fullScreenCover(item: $selected) { entry in NavigationStack { ReadingReviewPager(entries: visible, initialID: entry.id) } }
            .sheet(isPresented: $choosingBooks) {
                NavigationStack {
                    List {
                        Button("全部书籍") { filter.bookIDs = [] }
                        ForEach(library.books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) { book in
                            Toggle(book.title, isOn: Binding(get: { filter.bookIDs.contains(book.id) }, set: { if $0 { filter.bookIDs.insert(book.id) } else { filter.bookIDs.remove(book.id) } }))
                        }
                    }.navigationTitle("选择书籍").toolbar { Button("完成") { choosingBooks = false } }
                }
            }
    }
    private func load() async {
        entries = []; error = nil
        guard let store = library.store, !library.maintenance else { loading = false; return }
        let query = request; loading = true
        let work = Task.detached(priority: .userInitiated) {
            var records: [UUID: BookRecords] = [:]
            for book in query.books { try Task.checkCancellation(); records[book.id] = try store.records(for: book) }
            try Task.checkCancellation()
            return ReadingReview.entries(books: query.books, records: records)
        }
        do {
            let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            try Task.checkCancellation()
            guard library.store === store, request == query else { return }
            entries = value
        } catch is CancellationError {} catch { if request == query { self.error = error.localizedDescription } }
        if request == query { loading = false }
    }
}

struct ReadingReviewPager: View {
    let entries: [ReadingReviewEntry]
    var initialID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var exporting: ReadingReviewEntry?
    @State private var source: SourcePassage?
    @State private var sourceScope: ReadingScope?
    private struct CompositionRequest: Identifiable {
        let mode: ReviewComposition.Mode
        let entries: [ReadingReviewEntry]
        var id: ReviewComposition.Mode { mode }
    }
    @State private var composing: CompositionRequest?
    private var index: Int? { entries.firstIndex { $0.id == selected } }
    var body: some View {
        Group {
            if entries.isEmpty { ContentUnavailableView("没有符合条件的记录", systemImage: "note.text") }
            else {
                TabView(selection: $selected) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 18) {
                            Text(entry.title).font(.title2.bold()).accessibilityIdentifier("reading-review-title")
                            Text(entry.book.title + " · " + entry.author).font(.caption).foregroundStyle(.secondary)
                            ReadingReviewText(quote: entry.quote, bodyText: entry.body)
                            if let passage = entry.passage {
                                Button("返回原文", systemImage: "book") { sourceScope = entry.characterID == nil ? .wholeBook : nil; source = passage }
                            }
                            ShareLink("分享这篇记录", item: entry.markdown)
                        }.padding(24).tag(Optional(entry.id))
                    }
                }.tabViewStyle(.page(indexDisplayMode: .never))
            }
        }.navigationTitle("阅读回顾").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("导出卡片", systemImage: "photo") { if let index { exporting = entries[index] } }
                        .disabled(index == nil).accessibilityIdentifier("review-card-export")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu("邀请角色", systemImage: "sparkles") {
                        ForEach(ReviewComposition.Mode.allCases) { mode in Button(mode.rawValue) { if let index { composing = .init(mode: mode, entries: [entries[index]]) } } }
                    }.disabled(index == nil)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("上一篇", systemImage: "chevron.left") { if let index, index > 0 { selected = entries[index - 1].id } }.disabled(index == nil || index == 0)
                    Spacer()
                    Text(index.map { "\($0 + 1) / \(entries.count)" } ?? "0 / 0").monospacedDigit().accessibilityIdentifier("reading-review-position")
                    Spacer()
                    Button("下一篇", systemImage: "chevron.right") { if let index, index + 1 < entries.count { selected = entries[index + 1].id } }.disabled(index == nil || index == entries.count - 1)
                }
            }
            .onAppear { if index == nil { selected = entries.first(where: { $0.id == initialID })?.id ?? entries.first?.id } }
            .onChange(of: entries.map(\.id)) { _, ids in if !ids.isEmpty && (selected.map({ !ids.contains($0) }) ?? true) { selected = ids.first } }
            .sheet(item: $exporting) { ReviewCardExportView(entry: $0) }
            .sheet(item: $composing) { request in ReviewComposer(entries: request.entries, mode: request.mode) }
            .sheet(item: $source) { passage in
                NavigationStack {
                    ReaderView(bookID: passage.bookID, initialPassage: passage, initialPassageScope: sourceScope)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回回顾") { source = nil } } }
                }
            }
    }
}
