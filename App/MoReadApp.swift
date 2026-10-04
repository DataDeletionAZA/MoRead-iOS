import SwiftUI
import MoReadCore
import CoreText

@main
struct MoReadApp: App {
    @AppStorage("app.tintRGB") private var tint = 0x476153
    @StateObject private var model = LibraryModel()
    @StateObject private var companion = CompanionModel()
    @StateObject private var speech = SpeechPlayer()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).environmentObject(companion).environmentObject(speech)
                .tint(Color(rgb: tint))
                .onOpenURL { url in Task {
                    if FontLibrary.extensions.contains(url.pathExtension.lowercased()) { model.showFonts = true; await model.importFonts([url]) }
                    else if url.pathExtension.lowercased() == "mdx" { model.showDictionaries = true; await model.importDictionaries([url]) }
                    else { await model.queueImports([url]) }
                } }
                .onChange(of: model.books.filter { !$0.removed }.map(\.id)) { _, _ in speech.validateBooks(model.books) }
        }
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var books: [Book] = []
    @Published var organization = ShelfOrganization()
    @Published var recordsRevision = UUID()
    @Published var coverRevision = UUID()
    @Published var error: String?
    @Published var importing = false
    @Published var readingBackground: UIImage?
    var readingBackgroundData: Data?
    var readingBackgroundID = UUID()
    @Published var images: [ImportedImage] = []
    let imageCache = NSCache<NSString, UIImage>()
    @Published var fonts: [ImportedFont] = []
    @Published var showFonts = false
    @Published var showDictionaries = false
    @Published var dictionaryRevision = UUID()
    @Published var dictionaryNotice: String?
    @Published var vocabularyRevision = UUID()
    var vocabulary: VocabularyStore? { store.map { VocabularyStore(root: $0.root) } }
    private(set) var dictionaryLibrary: LocalDictionaries?
    private var fontDescriptors: [UUID: CTFontDescriptor] = [:]
    @Published var textImport: TextImportDraft?
    var importQueue: [TextImportDraft] = []
    @Published var maintenanceTitle: String?
    @Published var maintenanceProgress = 0.0
    var cancelMaintenance: (() -> Void)?
    var maintenance: Bool { maintenanceTitle != nil }
    private(set) var store: LibraryStore?
    private var pendingSaves: [UUID: Task<Void, Never>] = [:]

    init() { load(reset: true) }
    func load(reset: Bool = false) {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = ProcessInfo.processInfo.arguments.contains("--ui-testing") ? "MoRead-UITests" : "MoRead"
            let root = support.appendingPathComponent(folder, isDirectory: true)
            if reset, ProcessInfo.processInfo.arguments.contains("--reset-test-library"), FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            #if DEBUG
            if reset, ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--reset-test-library") {
                for key in ["app.tintRGB", "reader.pageMode", "reader.fontSize", "reader.lineSpacing", "reader.paper", "reader.typography", "reader.tapZones", "reader.keys", "reader.autoRead", "stats.widgets", "review.focusMotion"] { UserDefaults.standard.removeObject(forKey: key) }
            }
            #endif
            let storage = try LibraryStore(root: root)
            books = try storage.books()
            organization = try storage.organization()
            organization.prune(keeping: Set(books.map(\.id)))
            store = storage
            dictionaryLibrary = LocalDictionaries(root: root); dictionaryRevision = UUID(); vocabularyRevision = UUID()
            try reloadFonts()
            try reloadImages()
            try loadReadingBackground()
            coverRevision = UUID()
            recordsRevision = UUID()
        } catch { self.error = error.localizedDescription }
    }
    var fontLibrary: FontLibrary? { store.map { FontLibrary(root: $0.root) } }
    func reloadFonts() throws {
        guard let fontLibrary else { return }
        let loaded = try fontLibrary.fonts()
        var descriptors: [UUID: CTFontDescriptor] = [:]
        for font in loaded { descriptors[font.id] = try FontLibrary.descriptors(at: fontLibrary.file(font)).first }
        fontDescriptors = descriptors; fonts = loaded
    }
    func customFont(_ id: UUID?, size: CGFloat) -> UIFont? {
        guard let id, let descriptor = fontDescriptors[id] else { return nil }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as UIFont
    }
    func importFonts(_ urls: [URL]) async {
        guard !importing, !maintenance, let fontLibrary else { return }
        importing = true
        defer { importing = false }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let font = try await Task.detached(priority: .userInitiated) { try fontLibrary.add(url) }.value
                try reloadFonts()
                var typography = ReaderTypography(data: UserDefaults.standard.data(forKey: "reader.typography") ?? Data())
                typography.customFontID = font.id
                UserDefaults.standard.set(typography.encoded(), forKey: "reader.typography")
            } catch { self.error = error.localizedDescription; break }
        }
    }
    @discardableResult func modifyRecords(for book: Book, _ change: (inout BookRecords) throws -> Void) throws -> BookRecords {
        guard !maintenance, let store else { throw MoReadError.invalid("书库忙碌，请稍后再试。") }
        let value = try store.modifyRecords(for: book, change)
        recordsRevision = UUID()
        return value
    }
    func perform(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
    @discardableResult func update(_ book: Book, immediate: Bool = false) -> Bool {
        guard !maintenance, let index = books.firstIndex(where: { $0.id == book.id }), let store else { return false }
        pendingSaves[book.id]?.cancel()
        if immediate {
            do { try store.save(book); books[index] = book; return true }
            catch { self.error = error.localizedDescription; return false }
        }
        books[index] = book
        pendingSaves[book.id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            self?.perform { try self?.store?.save(book) }
        }
        return true
    }
    @discardableResult func organize(_ change: (inout ShelfOrganization) throws -> Void) -> Bool {
        guard !maintenance, let store else { return false }
        do {
            var value = organization
            try change(&value)
            value.prune(keeping: Set(books.map(\.id)))
            try store.saveOrganization(value)
            organization = value
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func flush() {
        guard !maintenance else { return }
        for task in pendingSaves.values { task.cancel() }
        pendingSaves.removeAll()
        perform { for book in books { try store?.save(book) } }
    }
    @discardableResult func importFile(_ url: URL) async -> Book? {
        guard !importing, !maintenance, let store else { return nil }
        importing = true
        defer { importing = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard ["txt", "epub"].contains(url.pathExtension.lowercased()) else { throw MoReadError.invalid("请选择 TXT 或 EPUB 文件。") }
            let book: Book
            if url.pathExtension.lowercased() == "epub" {
                book = try await EPUBService.shared.importBook(url: url, store: store)
            } else {
                let chapters = try await Task.detached(priority: .userInitiated) {
                    try TextImporter.chapters(TextImporter.decode(TextImporter.read(url)))
                }.value
                book = try store.importBook(title: url.deletingPathExtension().lastPathComponent, chapters: chapters, original: url)
            }
            books.insert(book, at: 0)
            return book
        } catch { self.error = error.localizedDescription; return nil }
    }
    static var sampleText: String {
        "第一章 雨后\n" + String(repeating: "雨停后，林遥推开旧书店的门。柜台上摆着一本空白的笔记，纸页带着淡淡的木香。她在第一页写下今天的日期，窗外的街道逐渐明亮。\n\n", count: 12)
            + "第二章 来信\n第二天，一封没有署名的信放在门口。林遥拆开信封，看见一张手绘地图。地图的尽头，是她小时候去过的灯塔。\n"
    }
    func addSample() {
        guard !maintenance else { return }
        perform {
            guard let store else { return }
            var chapters = try TextImporter.chapters(Self.sampleText)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--syntax-reading-sample") {
                chapters[0].text = "她说：「The lighthouse shines through the rain, and this story reminds me of home.」😀\n\n" + String(repeating: "林遥推开书店的门，开始阅读这封来自灯塔的信。\n\n", count: 45)
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--continuous-short-chapters") {
                chapters = [Chapter(id: 0, title: "短章一", text: "清晨，林遥打开了书店的门。她把第一封信放在桌上，慢慢读完最后一行。"),
                            Chapter(id: 1, title: "短章二", text: "中午，江舟送来一张地图。两个人沿着河岸走向灯塔，途中停下来读第二封信。"),
                            Chapter(id: 2, title: "短章三", text: "傍晚，灯塔亮起了灯。林遥合上笔记，带着第三封信回到书店。")]
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--listening-cleanup-sample") {
                chapters = [.init(id: 0, title: "净化测试一", text: "广告：请关注。\n😀林遥打开书店。\n广告：请关注。"), .init(id: 1, title: "净化测试二", text: "广告：请关注。"), .init(id: 2, title: "净化测试三", text: "林遥拿起书。")]
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--chinese-conversion-sample") {
                chapters[0].text = "林遙把滑鼠放在主機板旁，開啟軟體閱讀書店的來信。\n資料庫記錄了雨後的故事。這封信提到了遊標與解析度。"
                chapters[1].text = "第二封信仍在桌上。滑鼠和主機板留在書店。"
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--translation-sample") {
                chapters[0].text = "After the rain, Lin opened the bookshop.\nA letter arrived at noon.\nThe map showed a lighthouse."
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--translation-pages-sample") {
                chapters[0].text = (1...24).map { "Paragraph \($0). After the rain, Lin opened the bookshop door. A notebook was waiting on the counter. She wrote the date on its first page." }.joined(separator: "\n")
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--english-speech-sample") {
                chapters[0].text = String(repeating: "After the rain, Lin opened the bookshop door. A notebook was waiting on the counter. She wrote the date on its first page. ", count: 12)
                chapters[1].text = "A letter arrived."
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--simulate-knowledge") || ProcessInfo.processInfo.arguments.contains("--simulate-characters") {
                chapters[0].text = "林遥独自推开书店的大门。\n" + chapters[0].text
                if ProcessInfo.processInfo.arguments.contains("--simulate-characters") { chapters[1].text = "江舟送来了灯塔地图，与林遥约好第二天出发。" }
                if ProcessInfo.processInfo.arguments.contains("--characters-profile") {
                    chapters[0].text = "林遥又名小遥，是二十岁的女店主，穿着蓝衣。江舟是林遥的老师。\n" + chapters[0].text
                    chapters[1].text = "小遥打开灯塔的大门，江舟跟在她身后。"
                }
            }
            #endif
            let book = try store.importBook(title: "雨后的书店", author: "墨知示例", chapters: chapters)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--syntax-reading-sample") {
                let chapter = try store.chapter(0, in: book), range = (chapters[0].text as NSString).range(of: "lighthouse")
                let annotation = Annotation(passage: .init(bookID: book.id, chapter: chapter, offset: range.location, text: "lighthouse"), style: "wave")
                try store.modifyRecords(for: book) { $0.annotations.append(annotation) }
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--review-motion-sample") {
                let chapter = try store.chapter(0, in: book)
                var annotation = Annotation(passage: .init(bookID: book.id, chapter: chapter, offset: 0, text: String(chapter.text.prefix(20))), note: "雨后的第一段。")
                annotation.createdAt = Date(timeIntervalSince1970: 3)
                var middle = ReadingNote(title: "书店随记", content: "窗外的雨停了，灯光照在书页上。", book: book)
                middle.updatedAt = Date(timeIntervalSince1970: 2)
                var last = ReadingNote(title: "灯塔随记", content: "远处的灯塔亮起了灯。", book: book)
                last.updatedAt = Date(timeIntervalSince1970: 1)
                try store.modifyRecords(for: book) { $0.annotations = [annotation]; $0.notes = [middle, last] }
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--long-review-card") {
                let note = ReadingNote(title: "长篇读书笔记", content: "**灯塔**与*书店*\n" + String(repeating: "灯塔在雨后的海边亮起，书店里有温暖的灯光。\n", count: 2000) + "长笔记的最后一行。", book: book)
                try note.validate(); try store.modifyRecords(for: book) { $0.notes = [note] }
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
               let encoded = ProcessInfo.processInfo.environment["MOREAD_TEST_SPEECH_AUDIO"], encoded.utf8.count < 200000,
               let audio = Data(base64Encoded: encoded),
               let data = UserDefaults.standard.data(forKey: "speech.cloud"),
               let settings = try? JSONDecoder().decode(CloudSpeechSettings.self, from: data) {
                for item in book.chapters {
                    let chapter = try store.chapter(item.id, in: book)
                    var offset = 0
                    while let segment = SpeechText.next(in: chapter.text, from: offset, maximumLength: settings.maximumCharacters) {
                        offset = segment.end
                        var spoken = segment
                        if ProcessInfo.processInfo.arguments.contains("--listening-cleanup-sample") {
                            var ad = TextReplacementRule(); ad.pattern = "广告：请关注。"; ad.isRegex = false; ad.forListeningOnly = true
                            var name = TextReplacementRule(); name.pattern = "林遥"; name.replacement = "小遥"; name.isRegex = false; name.forListeningOnly = true
                            spoken = try segment.purified(rules: [ad, name])
                        }
                        if !spoken.text.isEmpty {
                            let key = try CloudSpeechClient.cacheKey(settings: settings, text: spoken.text)
                            try SpeechAudioCache.write(audio, in: store.directory(book.id), key: key, megabytes: settings.cacheMegabytes)
                        }
                    }
                }
            }
            #endif
            books.insert(book, at: 0)
        }
    }
    func remove(_ book: Book, permanently: Bool) {
        guard !maintenance else { return }
        perform {
            pendingSaves[book.id]?.cancel()
            try store?.remove(book, permanently: permanently)
            if permanently { books.removeAll { $0.id == book.id }; organize { $0.prune(keeping: Set(books.map(\.id))) } }
            else if let index = books.firstIndex(where: { $0.id == book.id }) { books[index].removed = true }
        }
    }
    func clearBody(_ id: UUID) {
        guard !maintenance, !importing, let store, let index = books.firstIndex(where: { $0.id == id }) else { return }
        pendingSaves[id]?.cancel(); pendingSaves[id] = nil
        do { books[index] = try store.clearBody(books[index]) }
        catch {
            if let current = try? store.books().first(where: { $0.id == id }) { books[index] = current }
            self.error = error.localizedDescription
        }
    }
}
