import SwiftUI
import PhotosUI
import MoReadCore

struct ImageLibraryView: View {
    var select: ((ImportedImage) -> Void)?
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: PhotosPickerItem?
    @State private var importing = false
    @State private var renaming: ImportedImage?
    @State private var removing: ImportedImage?
    @State private var name = ""
    var body: some View {
        List {
            Section {
                PhotosPicker("导入图片", selection: $selection, matching: .images)
                if importing { ProgressView("正在处理图片…") }
            } footer: { Text("图片可以用于阅读背景和角色聊天背景，随书库备份保存。") }
            ForEach(model.images) { image in
                Section {
                    if let preview = model.sharedImage(image.id, maximum: 256) {
                        Image(uiImage: preview).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 180).accessibilityLabel(image.name + "预览")
                    }
                    Text(image.name).font(.headline)
                    if let select {
                        Button("选择这张图片") { select(image); dismiss() }.accessibilityIdentifier("select-image-" + image.id.uuidString)
                    }
                    Button("设为阅读背景") {
                        model.perform { try model.selectReadingBackground(image.id); UserDefaults.standard.set("image", forKey: "reader.paper") }
                    }
                    Button("重命名") { name = image.name; renaming = image }
                    Button("删除图片", role: .destructive) { removing = image }
                }
            }
        }.navigationTitle("图片库").disabled(importing || model.maintenance)
            .task(id: selection) {
                guard let selection else { return }
                importing = true; defer { importing = false; self.selection = nil }
                do {
                    guard let data = try await selection.loadTransferable(type: Data.self) else { throw MoReadError.invalid("无法读取这张图片。") }
                    let encoded = try await Task.detached(priority: .userInitiated) {
                        guard let encoded = try ReaderImage.thumbnail(data, maximum: 2048).jpegData(compressionQuality: 0.85), encoded.count <= ImageLibrary.maximumBytes else { throw MoReadError.invalid("图片内容过大，请换一张图片。") }
                        return encoded
                    }.value
                    try Task.checkCancellation()
                    guard !model.maintenance, let library = model.imageLibrary else { return }
                    _ = try library.add(encoded, name: "图片 \(model.images.count + 1)"); try model.reloadImages()
                } catch is CancellationError {} catch { model.error = error.localizedDescription }
            }
            .alert("重命名图片", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("图片名称", text: $name)
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") {
                    if let image = renaming { model.perform { try model.imageLibrary?.rename(image, to: name); try model.reloadImages() } }
                    renaming = nil
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog("删除图片？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { image in
                Button("删除图片", role: .destructive) {
                    model.perform { try model.imageLibrary?.remove(image); try model.reloadImages(); try model.loadReadingBackground() }
                    removing = nil
                }
            } message: { image in Text("删除“\(image.name)”后，使用它的阅读和聊天页面会恢复纯色背景。") }
    }
}

extension LibraryModel {
    var imageLibrary: ImageLibrary? { store.map { ImageLibrary(root: $0.root) } }
    func reloadImages() throws {
        let loaded = try imageLibrary?.images() ?? []
        imageCache.removeAllObjects(); imageCache.countLimit = 12
        images = loaded
    }
    func sharedImage(_ id: UUID?, maximum: Int = 2048) -> UIImage? {
        guard let id, images.contains(where: { $0.id == id }), let imageLibrary else { return nil }
        let key = "\(id.uuidString)-\(maximum)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let data = try? imageLibrary.data(id), let image = try? ReaderImage.thumbnail(data, maximum: maximum) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }
}
