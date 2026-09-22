import SwiftUI
import Charts
import MoReadCore

struct StatisticsView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var companion: CompanionModel
    @AppStorage("stats.widgets") private var widgetData = Data()
    @State private var period = ReadingPeriod.month
    @State private var anchor = Date()
    @State private var stats = ReadingStatistics(books: [], records: [:])
    @State private var loading = false
    @State private var error: String?
    @State private var refresh = UUID()
    @State private var settings = false
    @State private var calendarDay: ReadingDayStat?
    private var widgets: StatisticsWidgets { StatisticsWidgets(data: widgetData) }
    private struct Request: Equatable {
        let period: ReadingPeriod; let anchor: Date; let books: [Book]; let organization: ShelfOrganization; let revision: UUID; let refresh: UUID
    }
    private var request: Request { .init(period: period, anchor: anchor, books: library.books, organization: library.organization, revision: library.recordsRevision, refresh: refresh) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("统计周期", selection: $period) {
                        ForEach(ReadingPeriod.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("stats-period")
                    HStack {
                        Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                            .disabled(period == .total).accessibilityLabel("上一周期").accessibilityIdentifier("stats-previous")
                        DatePicker("日期", selection: $anchor, in: ...Date(), displayedComponents: .date).labelsHidden().disabled(period == .total)
                            .frame(maxWidth: .infinity).accessibilityIdentifier("stats-date")
                        Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                            .disabled(!stats.canGoNext || loading).accessibilityLabel("下一周期").accessibilityIdentifier("stats-next")
                    }.buttonStyle(.borderless)
                    Text(periodTitle).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("stats-range")
                    if loading { ProgressView("正在整理阅读记录…") }
                    if let error { Text(error).foregroundStyle(.red); Button("重新读取") { refresh = UUID() } }
                }
                Section("阅读足迹") {
                    LabeledContent("阅读时长", value: duration(stats.totalSeconds)).accessibilityIdentifier("stats-total")
                    if period != .total { LabeledContent("上一周期", value: duration(stats.previousSeconds)) }
                    LabeledContent("阅读天数", value: "\(stats.periodDays.count) 天")
                    LabeledContent("连续阅读", value: "\(stats.streak) 天 · 最长 \(stats.longestStreak) 天")
                    LabeledContent("藏书与完读", value: "\(library.books.filter { !$0.removed }.count) 本 · 已读 \(stats.finishedBooks) 本")
                    LabeledContent("笔记与批注", value: "\(stats.noteCount) 条")
                    LabeledContent("伴读提问", value: "\(companion.conversations.reduce(0) { $0 + $1.messages.filter { $0.role == "user" }.count }) 次")
                }
                ForEach(widgets.visible, id: \.rawValue) { widget in
                    Section(widget.title) { widgetContent(widget) }
                }
            }.navigationTitle("足迹")
                .toolbar { ToolbarItem(placement: .primaryAction) { Button("调整统计组件", systemImage: "slider.horizontal.3") { settings = true } } }
                .task(id: request) { await load() }
                .onChange(of: period) { _, value in if value == .total { anchor = Date() } }
                .sheet(isPresented: $settings) { NavigationStack { widgetSettings } }
                .sheet(item: $calendarDay) { day in
                    NavigationStack {
                        List { Section(day.date.formatted(date: .abbreviated, time: .omitted)) {
                            if day.books.isEmpty { Text("这一天还没有阅读记录。").foregroundStyle(.secondary) }
                            ForEach(day.books) { bookRow($0) }
                        } }
                            .navigationTitle(duration(day.seconds)).toolbar { Button("完成") { calendarDay = nil } }
                    }
                }
        }
    }
    private var periodTitle: String {
        guard let range = stats.interval else { return "全部阅读记录" }
        if period == .day { return range.start.formatted(date: .complete, time: .omitted) }
        return range.start.formatted(date: .abbreviated, time: .omitted) + " — " + range.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted)
    }
    private func shift(_ amount: Int) { anchor = min(Date(), period.shifted(anchor, by: amount, calendar: stats.calendar)) }
    private func duration(_ seconds: Double) -> String {
        let seconds = max(0, Int(seconds))
        if seconds < 60 { return "\(seconds) 秒" }
        return seconds < 3600 ? "\(seconds / 60) 分钟" : "\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分钟"
    }
    private func load() async {
        guard let store = library.store else { return }
        let query = request
        loading = true; error = nil
        let work = Task.detached(priority: .userInitiated) {
            var records: [UUID: BookRecords] = [:]
            for book in query.books { try Task.checkCancellation(); records[book.id] = try store.records(for: book) }
            try Task.checkCancellation()
            return ReadingStatistics(books: query.books, records: records, organization: query.organization, period: query.period, anchor: query.anchor)
        }
        do {
            let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            try Task.checkCancellation()
            guard library.store === store, request == query else { return }
            stats = value
        } catch is CancellationError {} catch { if request == query { self.error = error.localizedDescription } }
        if request == query { loading = false }
    }
    @ViewBuilder private func widgetContent(_ widget: ReadingWidget) -> some View {
        switch widget {
        case .heatmap: heatmap
        case .calendar: calendar
        case .trend: bars(stats.trend)
        case .hours:
            bars(stats.hourlySeconds.enumerated().map { ReadingBar(label: String($0.offset), seconds: $0.element) })
            ForEach(0..<4) { band in
                LabeledContent(["凌晨 00–06", "上午 06–12", "下午 12–18", "夜晚 18–24"][band], value: duration(stats.hourlySeconds[(band * 6)..<(band * 6 + 6)].reduce(0, +)))
            }
            if stats.unassignedHourlySeconds > 0 { Text("另有 \(duration(stats.unassignedHourlySeconds)) 历史时长未记录小时。").font(.caption).foregroundStyle(.secondary) }
        case .timeline:
            timeline(full: false)
            if !stats.periodDays.isEmpty { NavigationLink("完整时间线") { List { timeline(full: true) }.navigationTitle("阅读时间线") } }
        case .books:
            if stats.books.isEmpty { empty }
            ForEach(Array(stats.books.prefix(5))) { bookRow($0) }
            if stats.books.count > 5 { NavigationLink("全部 \(stats.books.count) 本") { List(stats.books) { bookRow($0) }.navigationTitle("阅读排行") } }
        case .tags: cloud(stats.tags)
        case .authors: cloud(stats.authors)
        }
    }
    private var empty: some View { Text("这个周期还没有阅读记录。").font(.subheadline).foregroundStyle(.secondary) }
    private func bars(_ values: [ReadingBar]) -> some View {
        let step = max(1, Int(ceil(Double(values.count) / 6)))
        let ticks = values.indices.filter { $0 % step == 0 || $0 == values.count - 1 }
        return Chart(Array(values.enumerated()), id: \.offset) { item in
            BarMark(x: .value("时间", item.offset), y: .value("分钟", item.element.seconds / 60)).foregroundStyle(Color.accentColor)
                .accessibilityLabel(item.element.label).accessibilityValue(duration(item.element.seconds))
        }.chartXScale(domain: -1...max(1, values.count)).chartXAxis {
            AxisMarks(preset: .aligned, values: ticks) { value in
                if let index = value.as(Int.self), values.indices.contains(index) {
                    AxisGridLine(); AxisTick()
                    AxisValueLabel(centered: false, anchor: .top) { Text(values[index].label).fixedSize() }
                }
            }
        }.chartYAxisLabel("分钟").frame(height: 180)
    }
    private var heatmap: some View {
        let today = stats.calendar.startOfDay(for: Date())
        let start = stats.calendar.dateInterval(of: .weekOfYear, for: stats.calendar.date(byAdding: .day, value: -364, to: today)!)!.start
        let days = Dictionary(uniqueKeysWithValues: stats.days.map { ($0.date, $0.seconds) })
        return VStack(alignment: .leading, spacing: 8) {
            Text("最近一年 · 点选一天查看").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(22), spacing: 3), count: 7), spacing: 3) {
                    ForEach(0..<371) { offset in
                        let day = stats.calendar.date(byAdding: .day, value: offset, to: start)!, seconds = days[day, default: 0]
                        Button { anchor = day; period = .day } label: {
                            RoundedRectangle(cornerRadius: 3).fill(day > today ? Color.clear : Color.accentColor.opacity(seconds > 0 ? min(1, 0.3 + seconds / 7200) : 0.08)).frame(width: 22, height: 22)
                        }.buttonStyle(.plain).disabled(day > today)
                            .accessibilityLabel(day.formatted(date: .abbreviated, time: .omitted) + "，" + duration(seconds))
                    }
                }
            }.defaultScrollAnchor(.trailing)
        }
    }
    private var calendar: some View {
        let range = stats.calendar.dateInterval(of: .month, for: anchor)!
        let count = stats.calendar.range(of: .day, in: .month, for: anchor)!.count
        let padding = (stats.calendar.component(.weekday, from: range.start) + 5) % 7
        let days = Dictionary(uniqueKeysWithValues: stats.monthDays.map { ($0.date, $0) })
        return VStack(alignment: .leading) {
            HStack {
                Button { anchor = ReadingPeriod.month.shifted(range.start, by: -1, calendar: stats.calendar) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .accessibilityLabel("月历上一月").accessibilityIdentifier("stats-calendar-previous")
                Text(anchor.formatted(.dateTime.year().month())).font(.subheadline).frame(maxWidth: .infinity)
                Button { anchor = ReadingPeriod.month.shifted(range.start, by: 1, calendar: stats.calendar) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .disabled(range.contains(Date()) || loading).accessibilityLabel("月历下一月").accessibilityIdentifier("stats-calendar-next")
            }.buttonStyle(.borderless)
            Text("\(days.count) 个阅读日 · \(Set(stats.monthDays.flatMap(\.books).map(\.id)).count) 本书 · \(duration(stats.monthDays.reduce(0) { $0 + $1.seconds }))")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 8) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                ForEach(0..<(padding + count), id: \.self) { cell in
                    if cell < padding { Color.clear.frame(height: 80) }
                    else {
                        let date = stats.calendar.date(byAdding: .day, value: cell - padding, to: range.start)!, day = days[date]
                        Button { calendarDay = day ?? .init(date: date, books: []) } label: {
                            VStack(spacing: 3) {
                                Text("\(cell - padding + 1)").font(.caption)
                                if let book = day?.books.first?.book { StatisticsCover(book: book).frame(width: 30, height: 42) }
                                else { RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.06)).frame(width: 30, height: 42) }
                                Text(day.map { "\(Int($0.seconds / 60))分" } ?? " ").font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.7)
                            }.frame(maxWidth: .infinity, minHeight: 80)
                        }.buttonStyle(.plain).disabled(date > stats.calendar.startOfDay(for: Date()))
                            .accessibilityLabel(date.formatted(date: .abbreviated, time: .omitted) + "，" + duration(day?.seconds ?? 0) + "，\(day?.books.count ?? 0) 本书")
                            .accessibilityIdentifier("stats-calendar-day-" + ReadingCalendar.key(date, calendar: stats.calendar))
                    }
                }
            }
        }
    }
    private func bookRow(_ row: ReadingBookStat) -> some View {
        HStack {
            StatisticsCover(book: row.book).frame(width: 36, height: 54)
            VStack(alignment: .leading, spacing: 4) { Text(row.book.title); Text(row.book.author.isEmpty ? "未注明作者" : row.book.author).font(.caption).foregroundStyle(.secondary) }
            Spacer(); Text(duration(row.seconds)).font(.subheadline).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
    @ViewBuilder private func cloud(_ values: [ReadingLabelStat]) -> some View {
        if values.isEmpty { empty }
        else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 12) {
                ForEach(Array(values.prefix(40))) { item in
                    VStack(spacing: 4) {
                        Text(item.label).font(.system(size: 14 + 8 * item.seconds / max(1, values.first?.seconds ?? 1))).lineLimit(2)
                        Text("\(item.books) 本 · \(duration(item.seconds))").font(.caption2).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
    @ViewBuilder private func timeline(full: Bool) -> some View {
        let weeks = Dictionary(grouping: stats.periodDays, by: { stats.calendar.dateInterval(of: .weekOfYear, for: $0.date)!.start })
        if weeks.isEmpty { empty }
        ForEach(Array(weeks.keys.sorted(by: >).prefix(full ? weeks.count : 4)), id: \.self) { start in
            let days = weeks[start, default: []]
            let books = Dictionary(days.flatMap(\.books).map { ($0.id, $0.book) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.title < $1.title }
            VStack(alignment: .leading, spacing: 10) {
                Text(start.formatted(date: .abbreviated, time: .omitted) + " 起的一周").font(.caption).foregroundStyle(.secondary)
                HStack { Text("书籍").frame(width: 90, alignment: .leading); ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).frame(maxWidth: .infinity) } }.font(.caption2)
                ForEach(books) { book in
                    HStack(spacing: 3) {
                        Text(book.title).font(.caption).lineLimit(2).frame(width: 90, alignment: .leading)
                        ForEach(0..<7) { offset in
                            let date = stats.calendar.date(byAdding: .day, value: offset, to: start)!
                            let seconds = days.first { $0.date == date }?.books.first { $0.id == book.id }?.seconds ?? 0
                            RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(seconds > 0 ? 0.7 : 0.08)).frame(maxWidth: .infinity).frame(height: 22)
                                .accessibilityLabel(book.title + "，" + date.formatted(date: .abbreviated, time: .omitted) + "，" + duration(seconds))
                        }
                    }
                }
            }.padding(.vertical, 6)
        }
    }
    private var widgetSettings: some View {
        List {
            Section("显示与顺序") {
                ForEach(widgets.order, id: \.self) { name in
                    Toggle(ReadingWidget(rawValue: name)?.title ?? name, isOn: Binding(get: { !widgets.hidden.contains(name) }, set: { enabled in
                        var value = widgets; if enabled { value.hidden.remove(name) } else { value.hidden.insert(name) }; widgetData = value.encoded()
                    })).accessibilityIdentifier("stats-visible-" + name)
                }.onMove { source, destination in var value = widgets; value.order.move(fromOffsets: source, toOffset: destination); widgetData = value.encoded() }
            }
            Button("恢复默认组件") { widgetData = StatisticsWidgets().encoded() }
        }.navigationTitle("统计组件")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { settings = false } }; ToolbarItem(placement: .primaryAction) { EditButton() } }
    }
}

private struct StatisticsCover: View {
    let book: Book
    @EnvironmentObject private var library: LibraryModel
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Color.accentColor.opacity(0.12); Text(String(book.title.prefix(2))).font(.caption2).padding(2) }
        }.clipped().clipShape(RoundedRectangle(cornerRadius: 3)).accessibilityHidden(true)
            .task(id: library.coverRevision) {
                guard let store = library.store else { return }; let id = book.id
                let data = await Task.detached(priority: .utility) { try? store.coverData(for: id) }.value
                guard !Task.isCancelled else { return }; image = data.flatMap { try? ReaderImage.thumbnail($0, maximum: 160) }
            }
    }
}
