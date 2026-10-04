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
    init(bookID: UUID? = nil, kind: ReadingReviewFilter.Kind = .all) {
        var value = ReadingReviewFilter(); value.kind = kind; if let bookID { value.bookIDs = [bookID] }
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
    @State private var entries: [ReadingReviewEntry]
    @State private var sessionEntries: [ReadingReviewEntry]
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("review.focusMotion") private var motionValue = ReviewFocusMotion.paper.rawValue
    @StateObject private var tilt = ReviewTilt()
    @State private var visible = false
    @State private var selected: String?
    @State private var exporting: ReadingReviewEntry?
    private struct SourceRequest: Identifiable {
        let id = UUID()
        let passage: SourcePassage
        let scope: ReadingScope?
    }
    @State private var source: SourceRequest?
    @State private var editing: ReadingReviewEntry?
    @State private var discussing: ReadingReviewEntry?
    @State private var deleting: ReadingReviewEntry?
    @State private var loading = false
    @State private var error: String?
    private struct Request: Equatable { let books: [Book]; let revision: UUID; let maintenance: Bool }
    private var request: Request {
        let bookIDs = Set(sessionEntries.map { $0.book.id })
        return .init(books: library.books.filter { bookIDs.contains($0.id) }, revision: library.recordsRevision, maintenance: library.maintenance)
    }
    private struct CompositionRequest: Identifiable {
        let mode: ReviewComposition.Mode
        let entries: [ReadingReviewEntry]
        var id: ReviewComposition.Mode { mode }
    }
    @State private var composing: CompositionRequest?
    private var index: Int? { entries.firstIndex { $0.id == selected } }
    private var motion: ReviewFocusMotion { ReviewFocusMotion(saved: motionValue) }
    private var usesTilt: Bool { visible && scenePhase == .active && !reduceMotion && motion != .paper && source == nil && exporting == nil && composing == nil && editing == nil && discussing == nil && deleting == nil && !loading }
    init(entries: [ReadingReviewEntry], initialID: String? = nil) {
        _entries = State(initialValue: entries); _sessionEntries = State(initialValue: entries)
        _selected = State(initialValue: entries.first(where: { $0.id == initialID })?.id ?? entries.first?.id)
    }
    var body: some View {
        Group {
            if loading { ProgressView("正在读取记录…") }
            else if entries.isEmpty { ContentUnavailableView("没有符合条件的记录", systemImage: "note.text") }
            else {
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 0) {
                                ForEach(entries) { entry in
                                    card(entry, size: geometry.size).id(entry.id)
                                }
                            }.scrollTargetLayout()
                        }.scrollTargetBehavior(.paging).scrollPosition(id: $selected, anchor: .leading).scrollIndicators(.hidden)
                            .coordinateSpace(name: "review-pager").accessibilityIdentifier("review-pager").clipped()
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                                if size.width > 0, size.height > 0, let selected { proxy.scrollTo(selected, anchor: .leading) }
                            }
                    }
                }
            }
        }.navigationTitle("阅读回顾").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu("翻页动效", systemImage: "square.3.layers.3d") {
                        Picker("翻页动效", selection: $motionValue) {
                            ForEach(ReviewFocusMotion.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                        }
                    }.accessibilityIdentifier("review-motion-menu").accessibilityLabel("翻页动效，" + motion.label)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("导出卡片", systemImage: "photo") { if let index { exporting = entries[index] } }
                        .disabled(index == nil || loading).accessibilityIdentifier("review-card-export")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu("邀请角色", systemImage: "sparkles") {
                        ForEach(ReviewComposition.Mode.allCases) { mode in Button(mode.rawValue) { if let index { composing = .init(mode: mode, entries: [entries[index]]) } } }
                    }.disabled(index == nil || loading)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("上一篇", systemImage: "chevron.left") { move(-1) }.disabled(loading || index == nil || index == 0)
                    Spacer()
                    Text(index.map { "\($0 + 1) / \(entries.count)" } ?? "0 / 0").monospacedDigit().accessibilityIdentifier("reading-review-position")
                    Spacer()
                    Button("下一篇", systemImage: "chevron.right") { move(1) }.disabled(loading || index == nil || index == entries.count - 1)
                }
            }
            .onAppear { visible = true }
            .onDisappear { visible = false; tilt.stop() }
            .task(id: usesTilt) { tilt.setEnabled(usesTilt) }
            .task(id: request) { await refresh() }
            .sheet(item: $editing) { ReviewRecordEditor(entry: $0) }
            .sheet(item: $discussing) { entry in
                if case .annotation(let annotation) = entry.content {
                    NavigationStack {
                        AnnotationDiscussionView(bookID: entry.book.id, annotationID: annotation.id)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { discussing = nil } } }
                    }
                }
            }
            .alert(item: $deleting) { entry in
                Alert(title: Text("删除这条记录？"), message: Text("这条划线或笔记将被删除，书籍原文保持完整。"),
                      primaryButton: .destructive(Text("删除")) { delete(entry) }, secondaryButton: .cancel(Text("取消")))
            }
            .alert("未能完成操作", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
            .sheet(item: $exporting) { ReviewCardExportView(entry: $0) }
            .sheet(item: $composing) { request in ReviewComposer(entries: request.entries, mode: request.mode) }
            .sheet(item: $source) { request in
                NavigationStack {
                    ReaderView(bookID: request.passage.bookID, initialPassage: request.passage, initialPassageScope: request.scope)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回回顾") { source = nil } } }
                }
            }
    }
    private func card(_ entry: ReadingReviewEntry, size: CGSize) -> some View {
        let motion = self.motion, tiltValue = tilt.value, reduceMotion = self.reduceMotion
        let horizontal = motion == .paper ? 0.0 : motion == .flow ? 40.0 : 22.0
        let vertical = motion == .paper ? 0.0 : 18.0
        return VStack(alignment: .leading, spacing: 18) {
            Text(entry.title).font(.title2.bold()).accessibilityIdentifier("reading-review-title")
            Text(entry.book.title + " · " + entry.author).font(.caption).foregroundStyle(.secondary)
            if case .note(let note) = entry.content, note.characterID != nil && note.userEdited {
                Text("已由我编辑").font(.caption).foregroundStyle(.secondary)
            }
            ReadingReviewText(quote: entry.quote, bodyText: entry.body)
            if let passage = entry.passage {
                Button("返回原文", systemImage: "book") { source = .init(passage: passage, scope: entry.characterID == nil ? .wholeBook : nil) }
            }
            HStack {
                ShareLink("分享这篇记录", item: entry.markdown)
                Spacer()
                Menu("记录操作", systemImage: "ellipsis.circle") {
                    if case .annotation = entry.content { Button("批注讨论", systemImage: "text.bubble") { discussing = entry } }
                    Button("编辑记录", systemImage: "square.and.pencil") { editing = entry }
                    Button("复制全文", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.markdown }
                    Button("删除记录", systemImage: "trash", role: .destructive) { deleting = entry }
                }.accessibilityIdentifier("review-record-actions")
            }
        }.padding(24).frame(width: max(1, size.width - horizontal * 2), height: max(1, size.height - vertical * 2))
            .background {
                if motion != .paper {
                    RoundedRectangle(cornerRadius: 24).fill(Color(uiColor: .secondarySystemBackground))
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                }
            }
            .overlay { if motion != .paper { RoundedRectangle(cornerRadius: 24).stroke(.secondary.opacity(0.2), lineWidth: 1).allowsHitTesting(false) } }
            .padding(.horizontal, horizontal).padding(.vertical, vertical)
            .overlay {
                if motion != .paper {
                    GeometryReader { proxy in
                        let position = proxy.frame(in: .named("review-pager")).minX / max(1, size.width)
                        let frame = motion.frame(position: position, tiltX: tiltValue.x, tiltY: tiltValue.y, reduceMotion: reduceMotion)
                        LinearGradient(colors: [.clear, .white.opacity(colorScheme == .dark ? 0.07 : 0.26), .clear],
                                       startPoint: UnitPoint(x: frame.glare - 0.7, y: 0), endPoint: UnitPoint(x: frame.glare + 0.7, y: 1))
                            .background(.black.opacity(frame.shade)).clipShape(RoundedRectangle(cornerRadius: 24))
                            .padding(.horizontal, horizontal).padding(.vertical, vertical)
                    }.allowsHitTesting(false)
                }
            }
            .visualEffect { content, proxy in
                let width = max(1, proxy.size.width), position = proxy.frame(in: .named("review-pager")).minX / width
                let frame = motion.frame(position: position, tiltX: tiltValue.x, tiltY: tiltValue.y, reduceMotion: reduceMotion)
                return content.scaleEffect(frame.scale).opacity(frame.alpha)
                    .rotationEffect(.degrees(frame.rotationZ))
                    .rotation3DEffect(.degrees(frame.rotationX), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
                    .rotation3DEffect(.degrees(frame.rotationY), axis: (x: 0, y: 1, z: 0), anchor: UnitPoint(x: frame.pivotX, y: 0.5), perspective: 0.4)
                    .offset(x: frame.translationX * width, y: frame.drop)
            }.zIndex(selected == entry.id ? 1 : 0)
    }
    private func move(_ step: Int) {
        guard let index, entries.indices.contains(index + step) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) { selected = entries[index + step].id }
    }
    private func delete(_ entry: ReadingReviewEntry) {
        do {
            guard let book = library.books.first(where: { $0.id == entry.book.id }) else { throw MoReadError.invalid("书籍已删除。") }
            try library.modifyRecords(for: book) { try ReadingReview.delete(entry, book: book, records: &$0) }
        } catch { self.error = error.localizedDescription }
    }
    private func refresh() async {
        guard let store = library.store, !library.maintenance else { entries = []; loading = false; return }
        let query = request, ids = sessionEntries.map(\.id), oldIndex = index ?? 0
        loading = true
        let work = Task.detached(priority: .userInitiated) {
            var records: [UUID: BookRecords] = [:]
            for book in query.books { try Task.checkCancellation(); records[book.id] = try store.records(for: book) }
            let values = Dictionary(ReadingReview.entries(books: query.books, records: records).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return ids.compactMap { values[$0] }
        }
        do {
            let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            try Task.checkCancellation()
            guard library.store === store, request == query else { return }
            entries = value
            if !value.contains(where: { $0.id == selected }) { selected = value.isEmpty ? nil : value[min(oldIndex, value.count - 1)].id }
        } catch is CancellationError { return }
        catch { if request == query { entries = []; self.error = error.localizedDescription } }
        if request == query { loading = false }
    }
}
