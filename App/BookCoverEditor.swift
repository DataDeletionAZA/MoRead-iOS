import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import MoReadCore

struct BookCoverEditor: View {
    let bookID: UUID
    @EnvironmentObject private var model: LibraryModel
    @State private var selection: PhotosPickerItem?
    @State private var filePicker = false
    @State private var searchPicker = false
    @State private var original: UIImage?
    @State private var draft: UIImage?
    @State private var focusX = 0.5
    @State private var focusY = 0.5
    @State private var importing = false
    @State private var importTask: Task<Void, Never>?
    @State private var error: String?
    @State private var remove = false
    init(bookID: UUID, initialImage: UIImage? = nil) {
        self.bookID = bookID; _draft = State(initialValue: initialImage)
    }
    private var preview: UIImage? {
        guard let image = draft?.cgImage,
              let rect = try? BookCoverImage.cropRect(width: image.width, height: image.height, x: focusX, y: focusY),
              let cropped = image.cropping(to: rect) else { return original }
        return UIImage(cgImage: cropped)
    }
    var body: some View {
        Form {
            Section {
                if let image = preview {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 300)
                        .accessibilityLabel(draft == nil ? "当前封面" : "封面裁剪预览")
                        .accessibilityIdentifier(draft == nil ? "saved-book-cover" : "draft-book-cover")
                } else { ContentUnavailableView("文字封面", systemImage: "book.closed", description: Text("书架显示书名和作者。")) }
            }
            if let draft {
                Section("调整裁剪") {
                    if draft.size.width / draft.size.height > 2.0 / 3 {
                        Slider(value: $focusX, in: 0...1) { Text("左右位置") }.accessibilityIdentifier("cover-focus-x")
                        HStack { Text("靠左"); Spacer(); Text("靠右") }.font(.caption).foregroundStyle(.secondary)
                    } else {
                        Slider(value: $focusY, in: 0...1) { Text("上下位置") }.accessibilityIdentifier("cover-focus-y")
                        HStack { Text("靠上"); Spacer(); Text("靠下") }.font(.caption).foregroundStyle(.secondary)
                    }
                    Button("使用此裁剪") { save() }.accessibilityIdentifier("save-book-cover")
                    Button("取消裁剪", role: .cancel) { self.draft = nil; selection = nil }
                }
            } else {
                Section {
                    PhotosPicker("从照片选择", selection: $selection, matching: .images)
                    Button("从文件选择") { filePicker = true }
                    Button("网络搜索封面") { searchPicker = true }
                    if original != nil { Button("恢复文字封面", role: .destructive) { remove = true } }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--simulate-cover") {
                        Button("选择测试封面") {
                            draft = ReaderImage.coverFixture()
                            focusX = 0.5; focusY = 0.5
                        }
                    }
                    #endif
                } footer: { Text("封面按 2:3 裁剪，保存在这本书中，并随书库一起备份。") }
            }
            if importing { ProgressView("正在读取图片…") }
        }.navigationTitle("书籍封面").disabled(importing || model.maintenance)
            .task(id: model.coverRevision) {
                guard let store = model.store else { return }; let id = bookID
                do {
                    let data = try await Task.detached(priority: .utility) { try store.coverData(for: id) }.value
                    try Task.checkCancellation(); original = data.flatMap(UIImage.init(data:))
                } catch is CancellationError {} catch { self.error = error.localizedDescription }
            }
            .task(id: selection) {
                guard let selection else { return }
                importing = true; defer { importing = false }
                do {
                    guard let data = try await selection.loadTransferable(type: Data.self) else { throw MoReadError.invalid("无法读取这张图片。") }
                    try await prepare(data)
                } catch is CancellationError {} catch { self.error = error.localizedDescription }
            }
            .fileImporter(isPresented: $filePicker, allowedContentTypes: [.image]) { result in
                do {
                    let url = try result.get(), scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let data = try CharacterCardImporter.read(url, limit: 32 * 1024 * 1024)
                    importTask?.cancel()
                    importTask = Task {
                        importing = true; defer { importing = false }
                        do { try await prepare(data) } catch is CancellationError {} catch { self.error = error.localizedDescription }
                    }
                } catch { self.error = error.localizedDescription }
            }
            .sheet(isPresented: $searchPicker) {
                if let book = model.books.first(where: { $0.id == bookID }) {
                    NavigationStack { BookCoverSearchView(book: book) { image in draft = image; focusX = 0.5; focusY = 0.5 } }
                }
            }
            .onDisappear { importTask?.cancel() }
            .confirmationDialog("恢复文字封面？", isPresented: $remove, titleVisibility: .visible) {
                Button("恢复文字封面", role: .destructive) {
                    do { try model.saveBookCover(nil, for: bookID); original = nil; selection = nil }
                    catch { self.error = error.localizedDescription }
                }
            }
            .alert("封面未更换", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") }
    }
    private func prepare(_ data: Data) async throws {
        let image = try await Task.detached(priority: .userInitiated) { try ReaderImage.thumbnail(data, maximum: 2400) }.value
        try Task.checkCancellation(); draft = image; focusX = 0.5; focusY = 0.5
    }
    private func save() {
        do {
            guard draft != nil, let image = preview else { return }
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let width = min(1200, image.size.width), size = CGSize(width: width, height: width * 1.5)
            let rect = CGRect(origin: .zero, size: size)
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill(); context.fill(rect)
                image.draw(in: rect)
            }
            guard let data = rendered.jpegData(compressionQuality: 0.9) else { throw MoReadError.invalid("无法保存封面。") }
            try model.saveBookCover(data, for: bookID)
            original = rendered; draft = nil; selection = nil
        } catch { self.error = error.localizedDescription }
    }
}

extension LibraryModel {
    func saveBookCover(_ data: Data?, for id: UUID) throws {
        guard !maintenance, let store, books.contains(where: { $0.id == id }) else { throw MoReadError.invalid("书库忙碌或书籍已移除。") }
        try store.saveCover(data, for: id); coverRevision = UUID()
    }
}

#if DEBUG
extension ReaderImage {
    @MainActor static func coverFixture() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 1200), format: format).image { context in
            for (index, color) in [UIColor.systemTeal, .systemOrange, .systemIndigo].enumerated() {
                color.setFill(); context.fill(CGRect(x: 0, y: index * 400, width: 600, height: 400))
            }
        }
    }
}
#endif
