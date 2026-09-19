import SwiftUI
import PhotosUI
import ImageIO
import MoReadCore

struct ReaderBackgroundView: View {
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("reader.paper") private var paper = "paper"
    @AppStorage("reader.typography") private var settings = Data()
    @State private var selection: PhotosPickerItem?
    @State private var importing = false
    @State private var error: String?
    private var typography: ReaderTypography { ReaderTypography(data: settings) }
    var body: some View {
        Form {
            PhotosPicker("从照片选择背景", selection: $selection, matching: .images)
            if importing { ProgressView("正在处理图片…") }
            if let image = model.readingBackground {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260).accessibilityLabel("阅读背景预览")
                Button("使用这张背景") { paper = "image" }
                Stepper(value: Binding(get: { typography.backgroundOpacity ?? 0.25 }, set: {
                    var value = typography; value.backgroundOpacity = $0; settings = value.encoded()
                }), in: 0.05...1, step: 0.05) {
                    LabeledContent("图片浓度", value: "\(Int(((typography.backgroundOpacity ?? 0.25) * 100).rounded()))%")
                }
                Button("移除背景图片", role: .destructive) {
                    do { try model.saveReadingBackground(nil); selection = nil; if paper == "image" { paper = "paper" } }
                    catch { self.error = error.localizedDescription }
                }
            }
            Text("图片会居中铺满阅读区域；降低浓度可让文字更清楚。背景随书库备份保存。").font(.caption).foregroundStyle(.secondary)
        }.navigationTitle("阅读背景图片").disabled(importing || model.maintenance)
            .task(id: selection) {
                guard let selection else { return }
                importing = true; defer { importing = false }
                do {
                    guard let data = try await selection.loadTransferable(type: Data.self) else { throw MoReadError.invalid("无法读取这张图片。") }
                    let encoded = try await Task.detached(priority: .userInitiated) {
                        let image = try ReaderImage.thumbnail(data, maximum: 2048)
                        guard let encoded = image.jpegData(compressionQuality: 0.85), encoded.count <= 4 * 1024 * 1024 else { throw MoReadError.invalid("图片内容过大，请换一张图片。") }
                        return encoded
                    }.value
                    try Task.checkCancellation(); try model.saveReadingBackground(encoded); paper = "image"
                } catch is CancellationError {} catch { self.error = error.localizedDescription }
            }
            .alert("背景未更换", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") }
    }
}

enum ReaderImage {
    static func thumbnail(_ data: Data, maximum: Int) throws -> UIImage {
        guard data.count <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maximum, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { throw MoReadError.invalid("无法读取图片，请选择不超过 32 MB 的图片。") }
        return UIImage(cgImage: image)
    }
}

@MainActor
final class ReaderTextView: UITextView {
    private var paperImage: UIImage?
    private var paperColor = UIColor.clear
    private var opacity = 0.25
    private var paperSize = CGSize.zero
    func setPaper(_ color: UIColor, image: UIImage?, opacity: Double) {
        guard paperColor != color || paperImage !== image || self.opacity != opacity else { return }
        paperColor = color; paperImage = image; self.opacity = opacity; paperSize = .zero
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != paperSize, bounds.width > 0, bounds.height > 0 else { return }
        paperSize = bounds.size
        guard let image = paperImage else { backgroundColor = paperColor; return }
        let format = UIGraphicsImageRendererFormat(); format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            paperColor.setFill(); context.fill(CGRect(origin: .zero, size: bounds.size))
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height), blendMode: .normal, alpha: opacity)
        }
        backgroundColor = UIColor(patternImage: rendered)
    }
}

extension LibraryModel {
    func saveReadingBackground(_ data: Data?) throws {
        guard !maintenance, let root = store?.root else { throw MoReadError.invalid("书库忙碌，请稍后再试。") }
        let url = root.appendingPathComponent("reader-background.jpg")
        let image = try data.map { try ReaderImage.thumbnail($0, maximum: 2048) }
        if let data { try data.write(to: url, options: .atomic) }
        else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        readingBackground = image; readingBackgroundData = data; readingBackgroundID = UUID()
    }
    func loadReadingBackground() throws {
        readingBackground = nil; readingBackgroundData = nil; readingBackgroundID = UUID()
        guard let url = store?.root.appendingPathComponent("reader-background.jpg"), FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try CharacterCardImporter.read(url, limit: 4 * 1024 * 1024)
        readingBackground = try ReaderImage.thumbnail(data, maximum: 2048); readingBackgroundData = data
    }
}
