import SwiftUI
import MoReadCore

struct CompanionHourDial: View {
    let hours: [Int]
    var body: some View {
        Canvas { context, size in
            let large = min(size.width, size.height) >= 100
            let center = CGPoint(x: size.width / 2, y: size.height / 2), radius = min(size.width, size.height) / 2 - (large ? 15 : 5)
            let maximum = max(1, hours.max() ?? 1)
            func point(_ hour: Double, _ distance: Double) -> CGPoint {
                let angle = hour * .pi / 12 - .pi / 2
                return CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
            }
            for hour in 0..<24 {
                var tick = Path(); tick.move(to: point(Double(hour), radius)); tick.addLine(to: point(Double(hour), radius - (hour % 6 == 0 ? 6 : 3)))
                context.stroke(tick, with: .color(.secondary.opacity(0.4)), lineWidth: 1)
                if hour < hours.count, hours[hour] > 0 {
                    var bar = Path(); bar.move(to: point(Double(hour) + 0.5, radius * 0.25))
                    bar.addLine(to: point(Double(hour) + 0.5, radius * (0.35 + 0.45 * Double(hours[hour]) / Double(maximum))))
                    context.stroke(bar, with: .color(.accentColor), style: StrokeStyle(lineWidth: max(2, radius / 14), lineCap: .round))
                }
            }
            if large {
                for hour in [0, 6, 12, 18] {
                    context.draw(Text("\(hour)").font(.caption2).foregroundStyle(.secondary), at: point(Double(hour), radius + 10))
                }
            }
            context.fill(Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)), with: .color(.accentColor))
        }.accessibilityElement().accessibilityLabel("24 小时交流分布")
            .accessibilityValue(hours.enumerated().filter { $0.element > 0 }.map { "\($0.offset) 点，\($0.element) 轮" }.joined(separator: "；"))
    }
}

struct CompanionStoryRow: View {
    let event: CompanionStoryEvent
    let characters: [CharacterCard]
    let books: [Book]
    private var character: CharacterCard? { characters.first { $0.id == event.characterID } }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let data = character?.avatar, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill().frame(width: 32, height: 32).clipShape(Circle()).accessibilityHidden(true)
            } else { Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 32).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.bold())
                switch event.kind {
                case .session:
                    Text("\(event.library ? "书库伴读" : "书内伴读") · \(event.rounds) 轮交流")
                    let titles = books.filter { event.bookIDs.contains($0.id) }.map(\.title)
                    if !titles.isEmpty { Text(titles.joined(separator: "、")).foregroundStyle(.secondary) }
                    if event.firstMeeting { Label("初次共读", systemImage: "book").foregroundStyle(Color.accentColor) }
                case .memory(let text): Text(text).textSelection(.enabled)
                default: EmptyView()
                }
                Text(event.at.formatted(date: .omitted, time: .shortened) + (event.end > event.at ? " — " + event.end.formatted(date: .omitted, time: .shortened) : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.subheadline)
        }.padding(.vertical, 4).accessibilityElement(children: .combine).accessibilityIdentifier("companion-story-\(event.id)")
    }
    private var title: String {
        switch event.kind {
        case .firstWords: "第一次交流"
        case .session: "与\(character?.name ?? "伴读角色")的交流"
        case .milestone(let count): "第 \(count) 轮交流"
        case .memory: "\(character?.name ?? "伴读角色")记住了"
        }
    }
    private var symbol: String { switch event.kind { case .firstWords: "sparkles"; case .session: "bubble.left.and.bubble.right"; case .milestone: "flag"; case .memory: "star" } }
}
