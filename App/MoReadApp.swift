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
    @Published var error: String?
    @Published var importing = false
    @Published var readingBackground: UIImage?
    var readingBackgroundData: Data?
    var readingBackgroundID = UUID()
    @Published var fonts: [ImportedFont] = []
    @Published var showFonts = false
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
                for key in ["app.tintRGB", "reader.pageMode", "reader.fontSize", "reader.lineSpacing", "reader.paper", "reader.typography"] { UserDefaults.standard.removeObject(forKey: key) }
            }
            #endif
            let storage = try LibraryStore(root: root)
            books = try storage.books()
            organization = try storage.organization()
            organization.prune(keeping: Set(books.map(\.id)))
            store = storage
            try reloadFonts()
            try loadReadingBackground()
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
            let book = try store.importBook(title: "雨后的书店", author: "墨知示例", chapters: TextImporter.chapters(Self.sampleText))
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
               let encoded = ProcessInfo.processInfo.environment["MOREAD_TEST_SPEECH_AUDIO"], encoded.utf8.count < 200000,
               let audio = Data(base64Encoded: encoded),
               let data = UserDefaults.standard.data(forKey: "speech.cloud"),
               let settings = try? JSONDecoder().decode(CloudSpeechSettings.self, from: data) {
                for item in book.chapters {
                    let chapter = try store.chapter(item.id, in: book)
                    var offset = 0
                    while let segment = SpeechText.next(in: chapter.text, from: offset, maximumLength: settings.maximumCharacters) {
                        let key = try CloudSpeechClient.cacheKey(settings: settings, text: segment.text)
                        try SpeechAudioCache.write(audio, in: store.directory(book.id), key: key, megabytes: settings.cacheMegabytes)
                        offset = segment.end
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
