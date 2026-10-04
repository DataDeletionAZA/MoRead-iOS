import UIKit
import MoReadCore

struct ReaderSyntaxAssets {
    let id = UUID()
    var fonts: [UUID: UIFont] = [:]
    var images: [UUID: UIImage] = [:]
    static let empty = Self()
}

final class ReaderSyntaxPaint: NSObject {
    static let key = NSAttributedString.Key("MoReadSyntaxPaint")
    let range: NSRange
    let style: ReviewCardCSS
    let image: UIImage?
    let ink: UIColor
    init(range: NSRange, style: ReviewCardCSS, image: UIImage?, ink: UIColor) {
        self.range = range; self.style = style; self.image = image; self.ink = ink
    }
}

extension TextReader {
    func applySyntax(to value: NSMutableAttributedString) {
        guard typography.syntaxEnabled == true else { return }
        do {
            let rules = typography.syntaxRules ?? []
            let matches = try ReaderSyntax.paragraphMatches(value.string, rules: rules)
            let styles = try Dictionary(uniqueKeysWithValues: rules.filter(\.enabled).map { ($0.id, try $0.style()) })
            for match in matches {
                guard let style = styles[match.ruleID] else { continue }
                let range = match.range
                let base = value.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont ?? font
                var selected = style.customFontID.flatMap { syntaxAssets.fonts[$0]?.withSize(base.pointSize) } ?? base
                if style.fontSpecified && style.customFontID == nil, let choice = style.font {
                    var typography = ReaderTypography(); typography.font = choice
                    selected = typography.uiFont(size: base.pointSize)
                }
                var traits = selected.fontDescriptor.symbolicTraits
                if style.bold == true { traits.insert(.traitBold) } else { traits.remove(.traitBold) }
                if style.italic == true { traits.insert(.traitItalic) } else { traits.remove(.traitItalic) }
                selected = UIFont(descriptor: selected.fontDescriptor.withSymbolicTraits(traits) ?? selected.fontDescriptor, size: base.pointSize)
                value.addAttribute(.font, value: selected, range: range)
                guard !match.glyphsOnly else { continue }
                let color = (style.quoteColor ?? style.color).map(ReviewCardRenderer.rgba) ?? ink
                value.addAttributes([.foregroundColor: style.textGradient == nil ? color : UIColor.white,
                                     .underlineStyle: style.underline == true ? NSUnderlineStyle.single.rawValue : 0,
                                     .strikethroughStyle: style.strikethrough == true ? NSUnderlineStyle.single.rawValue : 0], range: range)
                if let background = style.background, style.backgroundGradient == nil && style.backgroundImageID == nil {
                    value.addAttribute(.backgroundColor, value: ReviewCardRenderer.rgba(background), range: range)
                }
                if style.textGradient != nil || style.backgroundGradient != nil || style.backgroundImageID != nil {
                    value.addAttribute(ReaderSyntaxPaint.key, value: ReaderSyntaxPaint(range: range, style: style, image: style.backgroundImageID.flatMap { syntaxAssets.images[$0] }, ink: color), range: range)
                }
            }
        } catch { onSyntaxError(error.localizedDescription) }
    }
}

extension AnnotationLayoutManager {
    private func syntaxBounds(_ glyphs: NSRange, in container: NSTextContainer) -> [CGRect] {
        var rectangles: [CGRect] = []
        enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: container) { rect, _ in rectangles.append(rect) }
        return rectangles
    }
    private func syntaxRuns(_ glyphs: NSRange, perform: (ReaderSyntaxPaint?, NSRange) -> Void) {
        guard let storage = textStorage, glyphs.length > 0 else { return }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(ReaderSyntaxPaint.key, in: characters) { paint, range, _ in
            let range = NSIntersectionRange(glyphs, self.glyphRange(forCharacterRange: range, actualCharacterRange: nil))
            if range.length > 0 { perform(paint as? ReaderSyntaxPaint, range) }
        }
    }
    func drawSyntaxBackground(for glyphs: NSRange, at origin: CGPoint) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        syntaxRuns(glyphs) { paint, range in
            guard let paint, paint.style.backgroundGradient != nil || paint.image != nil else { return }
            self.enumerateLineFragments(forGlyphRange: range) { _, _, container, lineGlyphs, _ in
                let visible = NSIntersectionRange(range, lineGlyphs)
                let rectangles = self.syntaxBounds(visible, in: container)
                let whole = NSIntersectionRange(self.glyphRange(forCharacterRange: paint.range, actualCharacterRange: nil), self.glyphRange(for: container))
                let bounds = self.syntaxBounds(whole, in: container).reduce(CGRect.null) { $0.union($1) }
                guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return }
                context.saveGState(); context.translateBy(x: origin.x, y: origin.y)
                let path = CGMutablePath(); rectangles.forEach { path.addRect($0) }; context.addPath(path); context.clip()
                if let gradient = paint.style.backgroundGradient { ReviewCardRenderer.gradient(gradient, in: bounds, context: context) }
                if let image = paint.image, image.size.width > 0, image.size.height > 0 {
                    let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    image.draw(in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
                }
                context.restoreGState()
            }
        }
    }
    func drawSyntaxGlyphs(for glyphs: NSRange, at origin: CGPoint) {
        syntaxRuns(glyphs) { paint, range in
            guard let paint, let gradient = paint.style.textGradient else { self.drawBaseGlyphs(for: range, at: origin); return }
            self.enumerateLineFragments(forGlyphRange: range) { line, _, container, lineGlyphs, _ in
                autoreleasepool {
                    let visible = NSIntersectionRange(range, lineGlyphs)
                    let bounds = self.syntaxBounds(visible, in: container).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -2, dy: -2).integral
                    let whole = NSIntersectionRange(self.glyphRange(forCharacterRange: paint.range, actualCharacterRange: nil), self.glyphRange(for: container))
                    let anchor = self.syntaxBounds(whole, in: container).reduce(CGRect.null) { $0.union($1) }
                    guard !bounds.isNull, bounds.width > 0, bounds.height > 0, !anchor.isNull else { return }
                    let format = UIGraphicsImageRendererFormat(); format.opaque = false
                    let mask = UIGraphicsImageRenderer(size: bounds.size, format: format).image { layer in
                        layer.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
                        self.drawingSyntaxMask = true
                        self.drawBaseGlyphs(for: visible, at: .zero)
                        self.drawingSyntaxMask = false
                    }
                    let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { layer in
                        layer.cgContext.saveGState(); layer.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
                        ReviewCardRenderer.gradient(gradient, in: anchor, context: layer.cgContext)
                        layer.cgContext.restoreGState()
                        mask.draw(in: CGRect(origin: .zero, size: bounds.size), blendMode: .destinationIn, alpha: 1)
                    }
                    image.draw(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y))
                    self.drawSyntaxAnnotationLines(for: visible, in: container, line: line, at: origin)
                }
            }
        }
    }
    private func drawSyntaxAnnotationLines(for glyphs: NSRange, in container: NSTextContainer, line: CGRect, at origin: CGPoint) {
        guard let storage = textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(.underlineColor, in: characters) { color, range, _ in
            guard let color = color as? UIColor, (storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0) != 0 else { return }
            let run = NSIntersectionRange(glyphs, self.glyphRange(forCharacterRange: range, actualCharacterRange: nil))
            guard run.length > 0 else { return }
            let bounds = self.boundingRect(forGlyphRange: run, in: container)
            let start = bounds.minX + origin.x, end = bounds.maxX + origin.x
            let y = line.minY + self.location(forGlyphAt: run.location).y + origin.y + 3
            let path = UIBezierPath(); path.lineWidth = 1.25; path.move(to: CGPoint(x: start, y: y))
            if storage.attribute(Self.waveKey, at: range.location, effectiveRange: nil) as? Bool == true {
                var x = start
                while x <= end { path.addLine(to: CGPoint(x: x, y: y + sin((x - start) * .pi / 3) * 1.25)); x += 0.75 }
            } else { path.addLine(to: CGPoint(x: end, y: y)) }
            color.setStroke(); path.stroke()
        }
    }

}
