import SwiftUI
import MoReadCore

@main
struct MoReadApp: App {
    @StateObject private var model = LibraryModel()
    @StateObject private var companion = CompanionModel()
    @StateObject private var speech = SpeechPlayer()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).environmentObject(companion).environmentObject(speech)
                .tint(Color(red: 0.28, green: 0.38, blue: 0.32))
                .onOpenURL { url in Task { await model.queueImports([url]) } }
                .onChange(of: model.books.filter { !$0.removed }.map(\.id)) { _, _ in speech.validateBooks(model.books) }
        }
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var books: [Book] = []
    @Published var organization = ShelfOrganization()
    @Published var error: String?
    @Published var importing = false
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
            let storage = try LibraryStore(root: root)
            books = try storage.books()
            organization = try storage.organization()
            organization.prune(keeping: Set(books.map(\.id)))
            store = storage
        } catch { self.error = error.localizedDescription }
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
