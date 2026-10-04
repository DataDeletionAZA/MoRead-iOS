import SwiftUI
import ImageIO
import MoReadCore

struct BookDetailView: View {
    let bookID: UUID
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.colorScheme) private var scheme
    @AppStorage("app.tintRGB") private var tint = 0x476153
    @State private var image: UIImage?
    @State private var palette: CoverPalette?
    @State private var records = BookRecords()
    @State private var description = ""
    @State private var expandedDescription = false
    @State private var illustrations = 0
    @State private var error: String?
    @State private var editing = false
    @State private var refresh = UUID()
    private var book: Book? { library.books.first { $0.id == bookID } }
    private struct Request: Equatable { let book: Book?; let cover: UUID; let records: UUID; let refresh: UUID; let maintenance: Bool }
    private var request: Request { .init(book: book, cover: library.coverRevision, records: library.recordsRevision, refresh: refresh, maintenance: library.maintenance) }
    private var atmosphere: CoverPalette.Atmosphere {
        CoverPalette.atmosphere(palette, background: scheme == .dark ? 0x000000 : 0xF2F2F7, dark: scheme == .dark, fallback: UInt32(clamping: tint))
    }
    private var accent: Color { Color(rgb: Int(atmosphere.accent)) }
    private var notes: [ReadingReviewEntry] {
        guard let book else { return [] }
        return ReadingReview.entries(books: [book], records: [bookID: records]).filter { if case .note = $0.content { return true }; return false }.sorted { $0.date > $1.date }
    }
    var body: some View {
        Group {
            if let book {
                ScrollView {
                    VStack(spacing: 22) {
                        hero(book)
                        if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("book-detail-error") }
                        if !description.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("简介").font(.headline)
                                Text(description).font(.subheadline).lineLimit(expandedDescription ? nil : 4).textSelection(.enabled)
                                Button(expandedDescription ? "收起" : "展开简介") { expandedDescription.toggle() }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                        }
                        glance(book)
                        assets(book)
                        if !notes.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("最近笔记").font(.headline)
                                ForEach(notes.prefix(3)) { note in
                                    NavigationLink { ReadingReviewPager(entries: notes, initialID: note.id) } label: {
                                        VStack(alignment: .leading, spacing: 6) { Text(note.title).font(.subheadline.bold()); Text(note.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            NavigationLink("向量索引") { BookMemoryView(bookID: bookID) }
                            NavigationLink("随读段评设置") { ProactiveSettingsView() }
                            NavigationLink("书籍信息") { information(book) }.accessibilityIdentifier("book-detail-information")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                    }.padding(.horizontal, 20).padding(.vertical, 12)
                }.background(alignment: .top) {
                    ZStack(alignment: .top) {
                        Color(uiColor: .systemGroupedBackground)
                        LinearGradient(colors: [Color(rgb: Int(atmosphere.top)), Color(rgb: Int(atmosphere.middle)), .clear], startPoint: .top, endPoint: .bottom).frame(height: 680)
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill().frame(height: 420).clipped().blur(radius: 38).opacity(0.12)
                                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)).accessibilityHidden(true)
                        }
                    }.ignoresSafeArea()
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu("编辑书籍", systemImage: "pencil") {
                            Button("编辑资料") { editing = true }
                            NavigationLink("更换封面") { BookCoverEditor(bookID: bookID) }
                        }.accessibilityIdentifier("book-detail-edit")
                    }
                }
            } else { ContentUnavailableView("书籍已移除", systemImage: "book.closed") }
        }.navigationTitle("书籍详情").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar).tint(accent)
            .disabled(library.maintenance)
            .onAppear { refresh = UUID() }
            .task(id: request) { await load() }
            .sheet(isPresented: $editing) { BookMetadataEditor(bookID: bookID) }
    }
    private func hero(_ book: Book) -> some View {
        VStack(spacing: 14) {
            NavigationLink { BookCoverEditor(bookID: bookID) } label: {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10).fill(Color(rgb: 0xE4DDC9)).offset(x: 5, y: 4)
                    if let image { Image(uiImage: image).resizable().scaledToFill().frame(width: 138, height: 204).clipped() }
                    else { Text(book.title).font(.system(size: 23, weight: .medium, design: .serif)).foregroundStyle(Color(rgb: 0x30483A)).padding(18).frame(width: 138, height: 204, alignment: .topLeading).background(Color(rgb: 0xE7E1CF)) }
                    LinearGradient(stops: [.init(color: .black.opacity(0.3), location: 0), .init(color: .white.opacity(0.24), location: 0.06), .init(color: .clear, location: 0.13)], startPoint: .leading, endPoint: .trailing)
                }.frame(width: 138, height: 204).clipShape(RoundedRectangle(cornerRadius: 8)).shadow(color: accent.opacity(0.25), radius: 16, x: 3, y: 10)
            }.buttonStyle(.plain).accessibilityLabel("更换封面").accessibilityIdentifier("book-detail-cover")
            Text(book.title).font(.title2.bold()).multilineTextAlignment(.center).textSelection(.enabled).padding(.top, 10)
            Text("\(book.author.isEmpty ? "未知作者" : book.author) · \(book.chapters.count) 章").font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Menu(book.state) {
                    ForEach(["未读", "在读", "已读", "搁置"], id: \.self) { state in
                        Button(state) { var changed = book; changed.state = state; library.update(changed, immediate: true) }
                    }
                }.accessibilityIdentifier("book-detail-state")
                if let group = library.organization.bookGroups[bookID] { Text(library.organization.groupPath(group)).lineLimit(1).foregroundStyle(.secondary) }
            }.font(.subheadline)
            let tags = library.organization.tags.filter { (library.organization.bookTags[bookID] ?? []).contains($0.id) }
            if !tags.isEmpty { Text(tags.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            VStack(spacing: 8) {
                HStack {
                    Text(book.lastOpened == nil ? "尚未开始" : "第 \(book.position.chapter + 1) / \(book.chapters.count) 章").font(.subheadline)
                    Spacer(); Text(book.progress, format: .percent.precision(.fractionLength(0))).font(.headline).foregroundStyle(accent)
                }
                ProgressView(value: book.progress).accessibilityIdentifier("book-detail-progress")
                if book.lastOpened != nil, let chapter = book.chapters.first(where: { $0.id == book.position.chapter }) { Text(chapter.title).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(.vertical, 6)
            HStack(spacing: 12) {
                NavigationLink { ReaderView(bookID: bookID, initialSheet: .speech) } label: { Label("听书", systemImage: "headphones").padding(.vertical, 6) }.buttonStyle(.bordered).accessibilityIdentifier("book-detail-listen")
                NavigationLink { ReaderView(bookID: bookID) } label: {
                    Label(book.lastOpened == nil ? "开始阅读" : "继续阅读", systemImage: "book.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
                        .foregroundStyle(ChatAppearance.darkText(onRGB: Int(atmosphere.accent)) ? Color.black : .white)
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("book-detail-read")
            }.disabled(book.removed || !book.hasBody)
        }
    }
    private func glance(_ book: Book) -> some View {
        let stats = ReadingStatistics(books: [book], records: [bookID: records], period: .total)
        return HStack {
            stat("阅读时长", "\(Int(stats.totalSeconds / 60)) 分钟")
            Divider(); stat("阅读天数", "\(stats.periodDays.count) 天")
            Divider(); stat("连续阅读", "\(stats.streak) 天")
        }.fixedSize(horizontal: false, vertical: true).padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 7) { Text(value).font(.headline); Text(label).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
    }
    private func assets(_ book: Book) -> some View {
        let entries = ReadingReview.entries(books: [book], records: [bookID: records])
        let annotations = entries.filter { if case .annotation = $0.content { return true }; return false }.count
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            NavigationLink { ReadingReviewView(bookID: bookID, kind: .annotation) } label: { asset("划线与批注", "pencil.tip.crop.circle", annotations) }.accessibilityIdentifier("book-detail-annotations")
            NavigationLink { ReadingNotesView(bookID: bookID) } label: { asset("读书笔记", "note.text", entries.count - annotations) }.accessibilityIdentifier("book-detail-notes")
            NavigationLink { IllustrationGallery(bookID: bookID) } label: { asset("插图廊", "photo", illustrations) }
            NavigationLink { ReaderView(bookID: bookID, initialSheet: .bookmarks) } label: { asset("书签", "bookmark", records.bookmarks.count) }.disabled(book.removed || !book.hasBody).accessibilityIdentifier("book-detail-bookmarks")
        }.buttonStyle(.plain)
    }
    private func asset(_ title: String, _ icon: String, _ count: Int) -> some View {
        HStack { Image(systemName: icon).foregroundStyle(accent); Text(title).font(.subheadline); Spacer(minLength: 2); Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
            .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
    private func information(_ book: Book) -> some View {
        Form {
            LabeledContent("书名", value: book.title); LabeledContent("作者", value: book.author.isEmpty ? "未知作者" : book.author)
            LabeledContent("格式", value: book.format.uppercased()); LabeledContent("章节", value: "\(book.chapters.count)")
            LabeledContent("导入时间", value: book.importedAt.formatted(date: .abbreviated, time: .shortened))
            if let last = book.lastOpened { LabeledContent("最近阅读", value: last.formatted(date: .abbreviated, time: .shortened)) }
            Button("编辑资料") { editing = true }
        }.navigationTitle("书籍信息")
    }
    private func load() async {
        guard let book, let store = library.store, !library.maintenance else { return }
        let expected = request
        do {
            let result = try await Task.detached(priority: .utility) {
                (try store.records(for: book), try store.coverData(for: book.id), try store.illustrations(for: book.id).filter { $0.visible(in: book) }.count,
                 book.hasBody ? BookDescription.extract(try book.chapters.prefix(4).map { try store.chapter($0.id, in: book) }) : "")
            }.value
            try Task.checkCancellation(); guard request == expected, library.store === store else { return }
            records = result.0; illustrations = result.2; description = result.3; error = nil
            let art = result.1.flatMap(Self.art); image = art?.0; palette = art?.1
        } catch is CancellationError {} catch { if request == expected { self.error = error.localizedDescription } }
    }
    private static func art(_ data: Data) -> (UIImage, CoverPalette?)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 480] as CFDictionary) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 36 * 36 * 4)
        let rendered = bytes.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(data: pointer.baseAddress, width: 36, height: 36, bitsPerComponent: 8, bytesPerRow: 36 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: 36, height: 36)); return true
        }
        let pixels: [UInt32] = rendered ? stride(from: 0, to: bytes.count, by: 4).map { i in
            let alpha = UInt32(bytes[i + 3])
            func channel(_ n: Int) -> UInt32 { min(255, UInt32(bytes[i + n]) * 255 / max(1, alpha)) }
            return alpha << 24 | channel(0) << 16 | channel(1) << 8 | channel(2)
        } : []
        return (UIImage(cgImage: thumbnail), CoverPalette.extract(argb: pixels))
    }
}
