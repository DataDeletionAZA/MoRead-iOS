import SwiftUI
import Photos
import MoReadCore

struct IllustrationGallery: View {
    let bookID: UUID
    @EnvironmentObject private var library: LibraryModel
    @State private var items: [BookIllustration] = []
    @State private var category: String?
    @State private var query = ""
    @State private var error: String?
    private var book: Book? { library.books.first { $0.id == bookID } }
    private var visible: [BookIllustration] { items.filter { item in book.map { item.visible(in: $0) } == true } }
    private var filtered: [BookIllustration] { visible.filter { (category == nil || $0.category == category) && (query.isEmpty || $0.prompt.localizedCaseInsensitiveContains(query) || $0.originalPrompt?.localizedCaseInsensitiveContains(query) == true || $0.category.localizedCaseInsensitiveContains(query)) } }
    var body: some View {
        List {
            if book?.removed == false, book?.hasBody == true { NavigationLink("生成新插图") { IllustrationGenerator(bookID: bookID) } }
            if !visible.isEmpty {
                Picker("分类", selection: $category) {
                    Text("全部插图").tag(String?.none)
                    Text("未分类").tag(String?.some(""))
                    ForEach(Set(visible.map(\.category).filter { !$0.isEmpty }).sorted(), id: \.self) { Text($0).tag(String?.some($0)) }
                }.accessibilityIdentifier("illustration-category-filter")
            }
            if let error { Text(error).foregroundStyle(.secondary) }
            if filtered.isEmpty { Text("这里还没有可显示的插图。").foregroundStyle(.secondary) }
            ForEach(filtered) { item in
                NavigationLink { IllustrationDetail(item: item) } label: {
                    HStack(spacing: 12) {
                        IllustrationThumbnail(item: item).frame(width: 72, height: 90)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.originalPrompt ?? item.prompt).lineLimit(2)
                            Text((item.category.isEmpty ? "未分类" : item.category) + " · " + item.createdAt.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.accessibilityIdentifier("illustration-row-" + item.id.uuidString)
            }
        }.navigationTitle("插图廊").searchable(text: $query, prompt: "搜索画面描述或分类")
            .onAppear { reload() }.onChange(of: library.books) { _, _ in reload() }
    }
    private func reload() {
        do { items = try library.store?.illustrations(for: bookID) ?? []; error = nil; if let category, !visible.contains(where: { $0.category == category }) { self.category = nil } }
        catch { self.error = error.localizedDescription }
    }
}

struct IllustrationThumbnail: View {
    let item: BookIllustration
    @EnvironmentObject private var library: LibraryModel
    @State private var image: UIImage?
    var body: some View {
        Group { if let image { Image(uiImage: image).resizable().scaledToFit() } else { Image(systemName: "photo") } }
            .task(id: item.id) {
                guard let store = library.store else { return }
                image = try? await Task.detached(priority: .utility) { try ReaderImage.thumbnail(store.illustrationData(item), maximum: 240) }.value
            }.accessibilityHidden(true)
    }
}

struct ChatIllustrationButton: View {
    let reference: IllustrationReference
    let open: (BookIllustration) -> Void
    @EnvironmentObject private var library: LibraryModel
    @State private var item: BookIllustration?
    var body: some View {
        Group {
            if let item {
                Button { open(item) } label: {
                    HStack {
                        IllustrationThumbnail(item: item).frame(width: 96, height: 120)
                        VStack(alignment: .leading) { Text("查看插图"); Text(item.originalPrompt ?? item.prompt).font(.caption).lineLimit(3) }
                        Spacer(); Image(systemName: "chevron.right")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 16)).accessibilityIdentifier("chat-illustration-" + item.id.uuidString)
            } else { Text("这张插图当前不可用。").font(.caption).foregroundStyle(.secondary) }
        }.task(id: library.recordsRevision) { reload() }.onChange(of: library.books) { _, _ in reload() }
    }
    private func reload() {
        guard let book = library.books.first(where: { $0.id == reference.bookID }),
              let saved = try? library.store?.illustrations(for: reference.bookID).first(where: { $0.id == reference.illustrationID }), saved.visible(in: book) else { item = nil; return }
        item = saved
    }
}

struct IllustrationDetail: View {
    let item: BookIllustration
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var url: URL?
    @State private var category = ""
    @State private var status: String?
    @State private var deleting = false
    @State private var saving = false
    @State private var readingSource: SourcePassage?
    @FocusState private var editingCategory: Bool
    private var available: Bool { library.books.first(where: { $0.id == item.bookID }).map { item.visible(in: $0) } == true }
    var body: some View {
        Form {
            if available {
                if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 500).accessibilityIdentifier("illustration-detail-image") }
                Section("画面描述") { Text(item.originalPrompt ?? item.prompt).textSelection(.enabled); Text(item.model + " · \(item.width) × \(item.height)").font(.caption).foregroundStyle(.secondary) }
                if let name = item.characterName { Text("由\(name)生成").font(.caption).foregroundStyle(.secondary) }
                if let original = item.originalPrompt, original != item.prompt { Section("绘图提示词") { Text(item.prompt).textSelection(.enabled) } }
                if let source = item.source { Section("原文") { Text(source.text).textSelection(.enabled) } }
                if item.source != nil || (item.anchor != nil && item.anchorRevision != nil),
                   let book = library.books.first(where: { $0.id == item.bookID }), !book.removed, book.hasBody {
                    Button("阅读原文", systemImage: "book") {
                        do { library.flush(); readingSource = try library.store?.locateIllustration(item) }
                        catch { status = error.localizedDescription }
                    }.accessibilityIdentifier("illustration-read-source")
                }
                Section("分类") {
                    TextField("分类名称", text: $category).focused($editingCategory).submitLabel(.done).onSubmit { editingCategory = false }.accessibilityIdentifier("illustration-category")
                    Button("保存分类") {
                        editingCategory = false
                        do { guard !library.maintenance else { return }; try library.store?.categorizeIllustration(item, category: category); status = "分类已保存。" }
                        catch { status = error.localizedDescription }
                    }
                }
                if let url {
                    Section("导出") {
                        ShareLink("分享或存储到文件", item: url)
                        Button("保存到照片") { savePhoto(url) }
                    }
                }
                if let book = library.books.first(where: { $0.id == item.bookID }), !book.removed, book.hasBody {
                    Section {
                        if let image { NavigationLink("用作书籍封面") { BookCoverEditor(bookID: item.bookID, initialImage: image) } }
                        NavigationLink("修改描述并重新生成") { IllustrationGenerator(bookID: item.bookID, source: item.source, prompt: item.originalPrompt ?? item.prompt) }
                    }
                }
                Button("删除这张插图", role: .destructive) { deleting = true }
            } else { Text("这张插图的原文或已读范围已经变化。").foregroundStyle(.secondary) }
            if let status { Text(status).font(.caption).accessibilityIdentifier("illustration-detail-status") }
        }.navigationTitle("插图").scrollDismissesKeyboard(.interactively).disabled(saving || library.maintenance)
            .navigationDestination(item: $readingSource) { passage in ReaderView(bookID: passage.bookID, initialPassage: passage) }
            .task(id: item.id) {
                guard available, let store = library.store else { return }
                do {
                    category = try store.illustrations(for: item.bookID).first(where: { $0.id == item.id })?.category ?? item.category
                    let preview = try await Task.detached(priority: .utility) { try ReaderImage.thumbnail(store.illustrationData(item), maximum: 2400) }.value
                    try Task.checkCancellation(); image = preview; url = try store.illustrationURL(item)
                } catch { status = error.localizedDescription }
            }
            .alert("删除这张插图？", isPresented: $deleting) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    do { guard !library.maintenance else { return }; try library.store?.deleteIllustration(item); library.recordsRevision = UUID(); dismiss() }
                    catch { status = error.localizedDescription }
                }
            } message: { Text("已导出到照片或文件中的副本会保留。") }
    }
    private func savePhoto(_ url: URL) {
        saving = true
        Task {
            defer { saving = false }
            let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard permission == .authorized || permission == .limited else { status = "未获得保存照片权限，也可以选择“分享或存储到文件”。"; return }
            do {
                try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url) }
                status = "已保存到照片。"
            } catch { status = error.localizedDescription }
        }
    }
}
