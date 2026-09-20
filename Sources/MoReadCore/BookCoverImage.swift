import Foundation
import ImageIO
import CoreGraphics

public enum BookCoverImage {
    public static let maximumBytes = 4 * 1024 * 1024
    public static func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...2048).contains(width), (1...2048).contains(height),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw MoReadError.invalid("封面图片损坏或过大，请重新选择。")
        }
    }
    public static func cropRect(width: Int, height: Int, x: Double = 0.5, y: Double = 0.5) throws -> CGRect {
        guard width > 0, height > 0, width <= 2400, height <= 2400, x.isFinite, y.isFinite,
              (0...1).contains(x), (0...1).contains(y) else { throw MoReadError.invalid("封面裁剪位置无效。") }
        let w = Double(width), h = Double(height)
        let cropWidth = min(w, h * 2 / 3), cropHeight = min(h, w * 3 / 2)
        return CGRect(x: (w - cropWidth) * x, y: (h - cropHeight) * y, width: cropWidth, height: cropHeight)
    }
}

extension LibraryStore {
    public func coverData(for id: UUID) throws -> Data? {
        _ = try book(id)
        let url = directory(id).appendingPathComponent("cover.jpg")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try CharacterCardImporter.read(url, limit: BookCoverImage.maximumBytes)
        try BookCoverImage.validate(data)
        return data
    }
    public func saveCover(_ data: Data?, for id: UUID) throws {
        _ = try book(id)
        let url = directory(id).appendingPathComponent("cover.jpg")
        if let data {
            try BookCoverImage.validate(data)
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
