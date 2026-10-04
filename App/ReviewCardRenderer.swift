import UIKit
import MoReadCore

struct ReviewCardOptions: Equatable {
    var thought = true
    var book = true
    var date = true
    var watermark = true
}

enum ReviewCardRenderer {
    static func image(entry: ReadingReviewEntry, template: ReviewCardTemplate, options: ReviewCardOptions,
                      font: UIFont?, background: UIImage?, cover: Bool) throws -> UIImage {
        try template.validate()
        let css = try ReviewCardCSS.parse(template.css ?? "")
        let width: CGFloat = 1080, gutter = CGFloat(min(432, max(12, (css.padding ?? template.padding) + (css.inset ?? 0)))), textWidth = width - gutter * 2
        let fontSize = css.size ?? template.fontSize, lineHeight = css.lineHeight ?? template.lineHeight
        let radius = css.radius ?? template.cornerRadius, borderWidth = css.borderWidth ?? template.borderWidth
        let extraTop = css.top ?? 0, extraBottom = css.bottom ?? 0
        func color(_ rgb: Int) -> UIColor { UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1) }
        func rgba(_ color: ReviewCardColor) -> UIColor {
            let value = color.rgba
            return UIColor(red: CGFloat((value >> 24) & 255) / 255, green: CGFloat((value >> 16) & 255) / 255, blue: CGFloat((value >> 8) & 255) / 255, alpha: CGFloat(value & 255) / 255)
        }
        func gradient(_ gradient: ReviewCardGradient, in bounds: CGRect, context: CGContext) {
            guard let colors = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: gradient.colors.map { rgba($0).cgColor } as CFArray, locations: gradient.stops.map { CGFloat($0) }) else { return }
            let radians = gradient.angle * .pi / 180, dx = sin(radians), dy = -cos(radians)
            let length = abs(bounds.width * dx) + abs(bounds.height * dy)
            let start = CGPoint(x: bounds.midX - dx * length / 2, y: bounds.midY - dy * length / 2)
            let end = CGPoint(x: bounds.midX + dx * length / 2, y: bounds.midY + dy * length / 2)
            context.drawLinearGradient(colors, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let foreground = css.color.map(rgba) ?? color(template.foreground), accent = color(template.accent)
        var quoteFont = font ?? UIFont.systemFont(ofSize: fontSize)
        if font == nil {
            let design: UIFontDescriptor.SystemDesign = (css.font ?? template.font) == .serif ? .serif : (css.font ?? template.font) == .monospace ? .monospaced : .default
            quoteFont = UIFont(descriptor: quoteFont.fontDescriptor.withDesign(design) ?? quoteFont.fontDescriptor, size: fontSize)
        }
        var traits = quoteFont.fontDescriptor.symbolicTraits
        if css.bold ?? template.bold { traits.insert(.traitBold) } else { traits.remove(.traitBold) }
        if css.italic ?? template.italic { traits.insert(.traitItalic) } else { traits.remove(.traitItalic) }
        quoteFont = UIFont(descriptor: quoteFont.fontDescriptor.withSymbolicTraits(traits) ?? quoteFont.fontDescriptor, size: fontSize)
        func block(_ text: String, font: UIFont, styled: Bool = false) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = font.pointSize * ((styled ? lineHeight : 1.55) - 1)
            if styled { paragraph.alignment = (css.alignment ?? template.alignment) == "center" ? .center : (css.alignment ?? template.alignment) == "right" ? .right : .left }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground, .paragraphStyle: paragraph]
            if styled {
                if let color = css.quoteColor { attributes[.foregroundColor] = rgba(color) }
                attributes[.kern] = (css.letterSpacing ?? template.letterSpacing) * font.pointSize
                if css.underline ?? template.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if css.strikethrough ?? template.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            return NSAttributedString(string: text, attributes: attributes)
        }
        let quote = block(entry.quote.isEmpty ? entry.title : entry.quote, font: quoteFont, styled: true)
        let plain = (try? AttributedString(markdown: entry.body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? entry.body
        let thought = options.thought && !plain.isEmpty ? block(plain, font: .systemFont(ofSize: 32)) : nil
        var metadata: [String] = []
        if options.book {
            metadata.append(entry.book.title)
            if let passage = entry.passage, let chapter = entry.book.chapters.first(where: { $0.id == passage.chapter }) { metadata.append(chapter.title) }
            if case .note(let note) = entry.content, let from = note.fromChapter, let to = note.toChapter { metadata.append("第 \(from)–\(to) 章") }
        }
        if entry.characterID != nil { metadata.append(entry.author) }
        if options.date { let formatter = DateFormatter(); formatter.dateFormat = "yyyy.MM.dd"; metadata.append(formatter.string(from: entry.date)) }
        let footer = block(metadata.joined(separator: " · "), font: .systemFont(ofSize: 26))
        func height(_ value: NSAttributedString) -> CGFloat {
            guard value.length > 0 else { return 0 }
            return ceil(value.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
        }
        let quoteHeight = height(quote), thoughtHeight = thought.map(height) ?? 0, footerHeight = height(footer)
        let footerBottom: CGFloat = options.watermark ? 144 : 80
        let contentHeight = 216 + extraTop + extraBottom + quoteHeight + (thought == nil ? 0 : 100 + thoughtHeight) + 96 + footerHeight + footerBottom
        guard contentHeight.isFinite, contentHeight <= 8192 else { throw MoReadError.invalid("这条内容较长，请使用文字分享以保留全文。") }
        let cardHeight = max(920, ceil(contentHeight)), bounds = CGRect(x: 0, y: 0, width: width, height: cardHeight)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { renderer in
            let context = renderer.cgContext
            UIBezierPath(roundedRect: bounds, cornerRadius: radius).addClip()
            (css.background.map(rgba) ?? color(template.background)).setFill(); context.fill(bounds)
            if let paint = css.backgroundGradient { gradient(paint, in: bounds, context: context) }
            else if !css.backgroundSpecified, let end = template.gradientEnd, let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(template.background).cgColor, color(end).cgColor] as CFArray, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: cardHeight), options: [])
            }
            if let background, background.size.width > 0, background.size.height > 0 {
                let scale = max(width / background.size.width, cardHeight / background.size.height)
                let size = CGSize(width: background.size.width * scale, height: background.size.height * scale)
                background.draw(in: CGRect(x: (width - size.width) / 2, y: (cardHeight - size.height) / 2, width: size.width, height: size.height))
                if cover { UIColor(white: 0, alpha: 0.68).setFill(); context.fill(bounds) }
            }
            let breathingRoom = (cardHeight - contentHeight) * 0.42
            ("“" as NSString).draw(at: CGPoint(x: gutter - 8, y: 32 + breathingRoom), withAttributes: [.font: UIFont.systemFont(ofSize: 150), .foregroundColor: accent])
            var y = 216 + extraTop + breathingRoom
            let quoteBounds = CGRect(x: 0, y: 0, width: textWidth, height: quoteHeight)
            if let paint = css.textGradient, quoteHeight > 0 {
                let mask = UIGraphicsImageRenderer(size: quoteBounds.size, format: format).image { _ in
                    let text = NSMutableAttributedString(attributedString: quote)
                    text.addAttribute(.foregroundColor, value: UIColor.white, range: NSRange(location: 0, length: text.length))
                    text.draw(with: quoteBounds, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                }
                let painted = UIGraphicsImageRenderer(size: quoteBounds.size, format: format).image { layer in
                    gradient(paint, in: quoteBounds, context: layer.cgContext)
                    mask.draw(in: quoteBounds, blendMode: .destinationIn, alpha: 1)
                }
                painted.draw(at: CGPoint(x: gutter, y: y))
            } else { quote.draw(with: quoteBounds.offsetBy(dx: gutter, dy: y), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil) }
            y += quoteHeight + extraBottom
            if let thought {
                y += 60; accent.setStroke(); context.setLineWidth(3); context.move(to: CGPoint(x: gutter, y: y)); context.addLine(to: CGPoint(x: gutter + 80, y: y)); context.strokePath()
                y += 40; thought.draw(with: CGRect(x: gutter, y: y, width: textWidth, height: thoughtHeight), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }
            footer.draw(with: CGRect(x: gutter, y: cardHeight - footerHeight - footerBottom, width: textWidth, height: footerHeight), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            if options.watermark { ("墨知 MoRead" as NSString).draw(at: CGPoint(x: gutter, y: cardHeight - 88), withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: accent]) }
            if borderWidth > 0 {
                let border = UIBezierPath(roundedRect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2), cornerRadius: max(0, radius - borderWidth / 2))
                border.lineWidth = borderWidth; (css.borderColor.map(rgba) ?? accent).setStroke(); border.stroke()
            }
        }
    }
}
