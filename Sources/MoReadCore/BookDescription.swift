import Foundation

public enum BookDescription {
    public static func extract(_ chapters: [Chapter], maximum: Int = 2_000) -> String {
        guard maximum > 0 else { return "" }
        let preferred = ["内容简介", "作品简介", "书籍简介", "简介", "导读"]
        func hasTitle(_ chapter: Chapter, _ titles: [String]) -> Bool {
            let title = chapter.title.replacingOccurrences(of: " ", with: "")
            return titles.contains { title.contains($0) }
        }
        func lines(_ text: String) -> [String] { text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
        func normalized(_ values: [String]) -> String {
            let text = values.filter { !$0.isEmpty && $0.range(of: #"^(书名|作者|版权|目录|封面|制作|校对|整理)\s*[:：]"#, options: .regularExpression) == nil }
                .joined(separator: "\n\n").replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            return text.count <= maximum ? text : String(text.prefix(maximum)).trimmingCharacters(in: CharacterSet(charactersIn: "，。；、 ")) + "…"
        }
        if let chapter = chapters.first(where: { hasTitle($0, preferred) }) { return normalized(lines(chapter.text)) }
        for chapter in chapters {
            let rows = lines(chapter.text)
            for (index, line) in rows.enumerated() {
                guard let heading = line.range(of: #"^(内容简介|作品简介|书籍简介|简介)\s*[:：]?\s*"#, options: .regularExpression) else { continue }
                var collected = [String(line[heading.upperBound...])].filter { !$0.isEmpty }
                for next in rows.dropFirst(index + 1) {
                    if !collected.isEmpty, next.replacingOccurrences(of: " ", with: "").range(of: #"^(第[一二三四五六七八九十百千万0-9]+[章节回卷部]|序章|正文|目录)$"#, options: .regularExpression) != nil { break }
                    if !next.isEmpty { collected.append(next) }
                }
                let text = normalized(collected)
                if !text.isEmpty { return text }
            }
        }
        return normalized(lines((chapters.first { hasTitle($0, ["序言", "前言", "楔子", "引言"]) } ?? chapters.first)?.text ?? ""))
    }
}
