import SwiftUI
import MoReadCore

@main
struct MoReadApp: App {
    @StateObject private var model = LibraryModel()
    @StateObject private var companion = CompanionModel()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).environmentObject(companion)
                .tint(Color(red: 0.28, green: 0.38, blue: 0.32))
                .onOpenURL { url in Task { await model.importFile(url) } }
        }
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var books: [Book] = []
    @Published var error: String?
    @Published var importing = false
    private(set) var store: LibraryStore?
    private var pendingSaves: [UUID: Task<Void, Never>] = [:]

    init() { load() }
    func load() {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = ProcessInfo.processInfo.arguments.contains("--ui-testing") ? "MoRead-UITests" : "MoRead"
            let root = support.appendingPathComponent(folder, isDirectory: true)
            if ProcessInfo.processInfo.arguments.contains("--reset-test-library"), FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            let storage = try LibraryStore(root: root)
            books = try storage.books()
            store = storage
        } catch { self.error = error.localizedDescription }
    }
    func perform(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
    func update(_ book: Book, immediate: Bool = false) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index] = book
        pendingSaves[book.id]?.cancel()
        if immediate { perform { try store?.save(book) }; return }
        pendingSaves[book.id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            self?.perform { try self?.store?.save(book) }
        }
    }
    func flush() {
        for task in pendingSaves.values { task.cancel() }
        pendingSaves.removeAll()
        perform { for book in books { try store?.save(book) } }
    }
    func importFile(_ url: URL) async {
        guard !importing, let store else { return }
        importing = true
        defer { importing = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let book: Book
            if url.pathExtension.lowercased() == "epub" {
                book = try await EPUBService.shared.importBook(url: url, store: store)
            } else {
                let chapters = try await Task.detached(priority: .userInitiated) {
                    try TextImporter.chapters(TextImporter.decode(Data(contentsOf: url)))
                }.value
                book = try store.importBook(title: url.deletingPathExtension().lastPathComponent, chapters: chapters, original: url)
            }
            books.insert(book, at: 0)
        } catch { self.error = error.localizedDescription }
    }
    func addSample() {
        perform {
            guard let store else { return }
            let text = "第一章 雨后\n" + String(repeating: "雨停后，林遥推开旧书店的门。柜台上摆着一本空白的笔记，纸页带着淡淡的木香。她在第一页写下今天的日期，窗外的街道逐渐明亮。\n\n", count: 12)
                + "第二章 来信\n第二天，一封没有署名的信放在门口。林遥拆开信封，看见一张手绘地图。地图的尽头，是她小时候去过的灯塔。\n"
            let book = try store.importBook(title: "雨后的书店", author: "墨知示例", chapters: TextImporter.chapters(text))
            books.insert(book, at: 0)
        }
    }
    func remove(_ book: Book, permanently: Bool) {
        perform {
            pendingSaves[book.id]?.cancel()
            try store?.remove(book, permanently: permanently)
            if permanently { books.removeAll { $0.id == book.id } }
            else if let index = books.firstIndex(where: { $0.id == book.id }) { books[index].removed = true }
        }
    }
}
