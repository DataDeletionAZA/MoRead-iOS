import UIKit
import MoReadCore

final class ReviewCardTextLayout {
    private struct Paint { let range: NSRange; let style: ReviewCardCSS; let glyphsOnly: Bool }
    private struct TextPaint { let range: NSRange; let gradient: ReviewCardGradient; let wholeQuote: Bool }
    private let storage: NSTextStorage
    private let layout = NSLayoutManager()
    private let container: NSTextContainer
    private var paints: [Paint] = []
    private var textPaints: [TextPaint] = []
    private let images: [UUID: UIImage]
    let width: CGFloat
    var height: CGFloat { ceil(layout.usedRect(for: container).height) }
    init(base: NSAttributedString, width: CGFloat, rules: [ReviewCardSyntaxRule], gradient: ReviewCardGradient?, fonts: [UUID: UIFont], images: [UUID: UIImage]) throws {
        self.width = width; self.images = images
        storage = NSTextStorage(attributedString: base)
        container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude)); container.lineFragmentPadding = 0
        layout.addTextContainer(container); storage.addLayoutManager(layout)
        let matches = try ReviewCardSyntax.matches(base.string, rules: rules)
        let styles = try Dictionary(uniqueKeysWithValues: rules.map { ($0.id, try $0.style()) })
        var inherited = IndexSet(integersIn: 0..<base.length)
        for match in matches {
            guard let style = styles[match.ruleID] else { continue }
            let range = match.range
            let baseFont = storage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont ?? .systemFont(ofSize: 47)
            var font = style.customFontID.flatMap { fonts[$0] } ?? baseFont
            if style.fontSpecified && style.customFontID == nil, let choice = style.font {
                let design: UIFontDescriptor.SystemDesign = choice == .serif ? .serif : choice == .monospace ? .monospaced : .default
                let system = UIFont.systemFont(ofSize: baseFont.pointSize)
                font = UIFont(descriptor: system.fontDescriptor.withDesign(design) ?? system.fontDescriptor, size: baseFont.pointSize)
            }
            var traits = font.fontDescriptor.symbolicTraits
            if style.bold == true { traits.insert(.traitBold) } else { traits.remove(.traitBold) }
            if style.italic == true { traits.insert(.traitItalic) } else { traits.remove(.traitItalic) }
            font = UIFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits) ?? font.fontDescriptor, size: font.pointSize)
            storage.addAttributes([.font: font, .underlineStyle: !match.glyphsOnly && style.underline == true ? NSUnderlineStyle.single.rawValue : 0,
                                   .strikethroughStyle: !match.glyphsOnly && style.strikethrough == true ? NSUnderlineStyle.single.rawValue : 0], range: range)
            if !match.glyphsOnly {
                inherited.remove(integersIn: range.location..<NSMaxRange(range))
                if let color = style.quoteColor ?? style.color { storage.addAttribute(.foregroundColor, value: ReviewCardRenderer.rgba(color), range: range) }
                if let background = style.background { storage.addAttribute(.backgroundColor, value: ReviewCardRenderer.rgba(background), range: range) }
                if let gradient = style.textGradient { textPaints.append(.init(range: range, gradient: gradient, wholeQuote: false)) }
            }
            paints.append(.init(range: range, style: style, glyphsOnly: match.glyphsOnly))
        }
        if let gradient { for range in inherited.rangeView { textPaints.append(.init(range: NSRange(location: range.lowerBound, length: range.count), gradient: gradient, wholeQuote: true)) } }
        for paint in textPaints { storage.addAttribute(.foregroundColor, value: UIColor.clear, range: paint.range) }
        layout.ensureLayout(for: container)
    }
    private func fragments(_ range: NSRange) -> (NSRange, [CGRect]) {
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rectangles: [CGRect] = []
        layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: container) { rect, _ in rectangles.append(rect) }
        return (glyphs, rectangles)
    }
    func draw(at point: CGPoint, context: CGContext) {
        context.saveGState(); context.translateBy(x: point.x, y: point.y)
        defer { context.restoreGState() }
        let all = layout.glyphRange(for: container)
        layout.drawBackground(forGlyphRange: all, at: .zero)
        for paint in paints where !paint.glyphsOnly && (paint.style.backgroundGradient != nil || paint.style.backgroundImageID != nil) {
            let (_, rectangles) = fragments(paint.range), bounds = rectangles.reduce(CGRect.null) { $0.union($1) }
            guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { continue }
            context.saveGState()
            let path = CGMutablePath(); for rectangle in rectangles { path.addRect(rectangle) }; context.addPath(path); context.clip()
            if let gradient = paint.style.backgroundGradient { ReviewCardRenderer.gradient(gradient, in: bounds, context: context) }
            if let id = paint.style.backgroundImageID, let image = images[id], image.size.width > 0, image.size.height > 0 {
                let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
            }
            context.restoreGState()
        }
        layout.drawGlyphs(forGlyphRange: all, at: .zero)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        for paint in textPaints {
            autoreleasepool {
                let (glyphs, rectangles) = fragments(paint.range)
                let bounds = rectangles.reduce(CGRect.null) { $0.union($1) }.integral
                guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return }
                storage.addAttribute(.foregroundColor, value: UIColor.white, range: paint.range)
                let mask = UIGraphicsImageRenderer(size: bounds.size, format: format).image { layer in
                    layer.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
                    layout.drawGlyphs(forGlyphRange: glyphs, at: .zero)
                }
                storage.addAttribute(.foregroundColor, value: UIColor.clear, range: paint.range)
                let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { layer in
                    layer.cgContext.saveGState(); layer.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
                    ReviewCardRenderer.gradient(paint.gradient, in: paint.wholeQuote ? CGRect(x: 0, y: 0, width: width, height: height) : bounds, context: layer.cgContext)
                    layer.cgContext.restoreGState()
                    mask.draw(in: CGRect(origin: .zero, size: bounds.size), blendMode: .destinationIn, alpha: 1)
                }
                image.draw(at: bounds.origin)
            }
        }
    }
}
