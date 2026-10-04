import SwiftUI
import MoReadCore

struct CompanionStatisticsView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var companion: CompanionModel
    @State private var scope = CompanionStatsScope.all
    @State private var period = CompanionStatsPeriod.all
    @State private var stats = CompanionStatistics(conversations: [], books: [])
    @State private var loading = true
    @State private var error: String?
    @State private var refresh = UUID()
    @State private var explanation = false
    @State private var visibleDays = 21
    private struct Request: Equatable {
        let scope: CompanionStatsScope; let period: CompanionStatsPeriod
        let conversations: [Conversation]; let books: [Book]; let revision: UUID; let refresh: UUID; let memoryRevision: UUID; let characters: [UUID]
    }
    private var request: Request { .init(scope: scope, period: period, conversations: companion.conversations, books: library.books, revision: library.recordsRevision, refresh: refresh, memoryRevision: companion.personaMemoryRevision, characters: companion.characters.map(\.id)) }
    var body: some View {
        List {
            Section {
                Picker("伴读范围", selection: $scope) {
                    ForEach(CompanionStatsScope.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("companion-stats-scope")
                Picker("统计周期", selection: $period) {
                    ForEach(CompanionStatsPeriod.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("companion-stats-period")
            }
            if loading { ProgressView("正在整理陪伴记录…") }
            else if let error {
                Section { Text(error).foregroundStyle(.red); Button("重新读取") { refresh = UUID() } }
            } else {
                Section {
                    if let days = stats.companionshipDays, let first = stats.firstChatDate {
                        Text("相伴第 \(days) 天").font(.title2.bold()).accessibilityIdentifier("companion-stats-days")
                        Text(first.formatted(date: .abbreviated, time: .omitted) + " — 今天").font(.caption).foregroundStyle(.secondary)
                    } else { Text("从第一次交流，留下陪伴的足迹。").foregroundStyle(.secondary) }
                    LabeledContent("一起读过", value: "\(stats.bookIDs.count) 本书").accessibilityIdentifier("companion-stats-books")
                    LabeledContent("读了", value: duration).accessibilityIdentifier("companion-stats-reading")
                    LabeledContent("聊了", value: characters).accessibilityIdentifier("companion-stats-words")
                }
                Section {
                    activity
                    LabeledContent("有交流的日子", value: "\(stats.activeDays) 天").accessibilityIdentifier("companion-stats-active")
                    LabeledContent("完整交流", value: "\(stats.rounds) 轮").accessibilityIdentifier("companion-stats-rounds")
                    LabeledContent("对话", value: "\(stats.conversations) 个").accessibilityIdentifier("companion-stats-conversations")
                    if stats.rounds == 0 { Text("这个范围还没有完整的交流记录。").font(.subheadline).foregroundStyle(.secondary) }
                } header: { Text(period == .all ? "最近 35 天" : period.label) }
                  footer: { Text("交流天数和轮数按所选周期汇总。阅读时长来自这些交流所涉及书籍的阅读记录。") }
                if !stats.story.isEmpty {
                    Section("陪伴的时刻") {
                        CompanionHourDial(hours: stats.roundsByHour)
                            .frame(height: 140).accessibilityIdentifier("companion-story-hours")
                        if let hour = stats.peakHour {
                            Text("最常在 \(hour):00—\(hour + 1):00 交流").accessibilityIdentifier("companion-story-peak")
                        }
                    }
                    ForEach(Array(stats.story.prefix(visibleDays))) { day in
                        Section {
                            HStack {
                                CompanionHourDial(hours: day.roundsByHour).frame(width: 52, height: 52)
                                Text("\(day.rounds) 轮交流 · 阅读 \(Int(day.readingSeconds / 60)) 分钟").font(.subheadline)
                            }
                            ForEach(day.events) { event in
                                CompanionStoryRow(event: event, characters: companion.characters, books: library.books)
                            }
                        } header: { Text(day.date.formatted(date: .complete, time: .omitted)) }
                    }
                    if visibleDays < stats.story.count {
                        Button("显示更早的记录（剩余 \(stats.story.count - visibleDays) 天）") { visibleDays += 30 }
                            .accessibilityIdentifier("companion-story-more")
                    }
                }
            }
        }.navigationTitle("陪伴足迹")
            .task(id: request) { await load() }
            .toolbar { Button("统计说明", systemImage: "info.circle") { explanation = true } }
            .alert("统计说明", isPresented: $explanation) { Button("知道了", role: .cancel) {} } message: {
                Text("一次提问得到完整回复，记为一轮交流；分支复制的历史只计一次。聊天字数统计保留的提问和回复正文，不含空格、制表符及换行。书籍数只计仍保留在书库中的关联书籍，阅读时长是这些书在所选周期内的阅读记录。删除对话或永久删除书籍会影响统计。相伴天数从所选伴读范围的首次完整交流算起，不随周期切换。")
            }
    }
    private var duration: String {
        let minutes = Int(stats.readingSeconds / 60)
        return minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分钟" : "\(minutes) 分钟"
    }
    private var characters: String {
        stats.chatCharacters >= 10_000 ? String(format: "%.1f 万字", Double(stats.chatCharacters) / 10_000) : "\(stats.chatCharacters) 字"
    }
    private var activity: some View {
        let count = period.days ?? 35
        let start = stats.calendar.date(byAdding: .day, value: 1 - count, to: stats.today)!
        return VStack(spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 12) {
                ForEach(0..<count, id: \.self) { index in
                    let date = stats.calendar.date(byAdding: .day, value: index, to: start)!
                    let rounds = stats.roundsByDay[date, default: 0]
                    Circle().fill(Color.accentColor.opacity(rounds > 0 ? min(1, 0.35 + Double(rounds) * 0.1) : 0.08))
                        .frame(width: 22, height: 22).accessibilityElement()
                        .accessibilityLabel(date.formatted(date: .abbreviated, time: .omitted) + "，\(rounds) 轮交流")
                }
            }
            HStack { Text(start.formatted(date: .abbreviated, time: .omitted)); Spacer(); Text("今天") }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
    }
    private func load() async {
        guard let store = library.store else { loading = false; error = "书库尚未打开。"; return }
        let query = request
        loading = true; error = nil; visibleDays = 21
        let work = Task.detached(priority: .userInitiated) {
            var records: [UUID: BookRecords] = [:]
            for book in query.books { try Task.checkCancellation(); records[book.id] = try store.records(for: book) }
            var memories: [PersonaMemory] = []
            if FileManager.default.fileExists(atPath: PersonaMemoryStore.url(in: store.root).path) {
                let memoryStore = try PersonaMemoryStore(root: store.root)
                for character in query.characters { try Task.checkCancellation(); memories += try memoryStore.list(character) }
            }
            try Task.checkCancellation()
            return CompanionStatistics(conversations: query.conversations, books: query.books, records: records, memories: memories, scope: query.scope, period: query.period)
        }
        do {
            let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            try Task.checkCancellation()
            guard library.store === store, request == query else { return }
            stats = value
        } catch is CancellationError {} catch { if request == query { self.error = error.localizedDescription } }
        if request == query { loading = false }
    }
}
