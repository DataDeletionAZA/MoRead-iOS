import SwiftUI
import AVFoundation
import MoReadCore

struct SpeechControls: View {
    let book: Book
    @EnvironmentObject private var speech: SpeechPlayer
    @EnvironmentObject private var library: LibraryModel
    @State private var timerSheet = false
    @State private var seekValue: Double = 0
    @State private var seeking = false
    private var currentBook: Book { library.books.first { $0.id == book.id } ?? book }
    private var active: Bool { speech.bookID == book.id }
    private var progress: Double {
        guard active, currentBook.chapters.indices.contains(speech.position.chapter) else { return 0 }
        return min(1, Double(speech.position.offset) / Double(max(1, currentBook.chapters[speech.position.chapter].length)))
    }
    var body: some View {
        Form {
            Section("听书") {
                if active {
                    if currentBook.chapters.indices.contains(speech.position.chapter) {
                        Text(currentBook.chapters[speech.position.chapter].title).font(.headline)
                    }
                    Button(speech.isPreparing ? "正在准备…" : speech.isPlaying ? "暂停" : "继续", systemImage: speech.isPlaying ? "pause.fill" : "play.fill") { if speech.isPlaying { speech.pause() } else { speech.resume() } }.accessibilityIdentifier("speech-play-pause").disabled(speech.isPreparing)
                    HStack {
                        Button("上一章", systemImage: "backward.end") { speech.previousChapter() }.accessibilityIdentifier("speech-previous-chapter").disabled(speech.position.chapter == 0)
                        Spacer()
                        Button("下一章", systemImage: "forward.end") { speech.nextChapter() }.accessibilityIdentifier("speech-next-chapter").disabled(speech.position.chapter + 1 >= currentBook.chapters.count)
                    }.buttonStyle(.borderless)
                    Slider(value: Binding(get: { seeking ? seekValue : progress }, set: { seekValue = $0 }), in: 0...1) { editing in
                        seeking = editing
                        if editing { seekValue = progress } else { speech.seek(fraction: seekValue) }
                    }.accessibilityLabel("本章听书进度")
                    Button("结束听书", systemImage: "stop") { speech.stop() }
                } else {
                    if speech.stoppedBookID == book.id, let reason = speech.stopReason { Text(reason).foregroundStyle(.secondary).accessibilityIdentifier("speech-stop-reason") }
                    Button("从这里开始朗读", systemImage: "play.fill") { speech.play(currentBook, library: library) }.accessibilityIdentifier("speech-start")
                }
            }
            Section {
                Button { timerSheet = true } label: {
                    HStack { Text("睡眠定时"); Spacer(); Text(active ? timerLabel : "未开启").foregroundStyle(.secondary).monospacedDigit() }
                }.disabled(!active).accessibilityIdentifier("speech-timer")
            } footer: { Text("按播放时长或自然读完的章节数停止。暂停时，倒计时也暂停。手动跳章不会扣除章节数。") }
            Section("朗读方式") {
                NavigationLink { CloudSpeechView() } label: {
                    LabeledContent("声音来源", value: speech.cloudSettings.enabled ? speech.cloudSettings.service.label : "iPhone 系统声音")
                }
            }
            if !speech.cloudSettings.enabled {
            Section("声音") {
                NavigationLink {
                    SpeechVoicePicker()
                } label: { LabeledContent("系统声音", value: speech.voices.first { $0.identifier == speech.preferences.voiceIdentifier }?.name ?? "中文默认声音") }
                LabeledContent("语速", value: abs(speech.preferences.rate - 0.45) < 0.01 ? "标准" : speech.preferences.rate < 0.45 ? "偏慢" : "偏快")
                Slider(value: $speech.preferences.rate, in: 0...1, step: 0.05) { Text("语速") } minimumValueLabel: { Text("慢") } maximumValueLabel: { Text("快") }.accessibilityIdentifier("speech-rate")
                LabeledContent("音调", value: abs(speech.preferences.pitch - 1) < 0.01 ? "自然" : speech.preferences.pitch < 1 ? "低沉" : "明亮")
                Slider(value: $speech.preferences.pitch, in: 0.5...2, step: 0.05) { Text("音调") } minimumValueLabel: { Text("低") } maximumValueLabel: { Text("高") }.accessibilityIdentifier("speech-pitch")
                Button(speech.isPreviewing ? "停止试听" : "试听声音", systemImage: speech.isPreviewing ? "stop.circle" : "speaker.wave.2") {
                    if speech.isPreviewing { speech.stopPreview() } else { speech.preview() }
                }
                Button("恢复默认声音设置") { speech.preferences = SpeechPreferences() }
                if !speech.preferences.voiceIdentifier.isEmpty, !speech.voices.contains(where: { $0.identifier == speech.preferences.voiceIdentifier }) {
                    Text("这台设备暂时找不到已选声音，朗读会使用中文默认声音。可以在系统声音列表中重新选择。").font(.caption).foregroundStyle(.secondary)
                }
                Text("设置会保存在本机，并从下一句生效。试听时会暂停正在播放的书籍。").font(.caption).foregroundStyle(.secondary)
            }
            }
        }.navigationTitle("听书")
            .sheet(isPresented: $timerSheet) { SpeechTimerSheet() }
            .onDisappear { speech.stopPreview() }
    }
    private var timerLabel: String {
        guard let timer = speech.sleepTimer else { return "未开启" }
        if let seconds = timer.remainingSeconds {
            let value = Int(ceil(seconds)); return String(format: "%02d:%02d", value / 60, value % 60)
        }
        return "还剩 \(timer.remainingChapters ?? 0) 章"
    }
}

private struct SpeechTimerSheet: View {
    @EnvironmentObject private var speech: SpeechPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var byChapters = false
    @State private var amount = 15
    var body: some View {
        NavigationStack {
            Form {
                Picker("停止方式", selection: $byChapters) { Text("按时间").tag(false); Text("按章节").tag(true) }.pickerStyle(.segmented)
                    .onChange(of: byChapters) { _, value in amount = value ? 1 : 15 }
                Section(byChapters ? "读完再停" : "播放时长") {
                    ForEach(byChapters ? [1, 2, 3, 5] : [15, 30, 45, 60, 90], id: \.self) { value in
                        Button(byChapters ? (value == 1 ? "本章结束" : "读完 \(value) 章") : "\(value) 分钟") { select(value) }
                    }
                }
                Section("自定义") {
                    Stepper("\(amount) \(byChapters ? "章" : "分钟")", value: $amount, in: 1...(byChapters ? 999 : 1440))
                    Button("应用自定义定时") { select(amount) }
                }
                if speech.sleepTimer != nil { Button("取消定时", role: .destructive) { speech.setTimer(nil); dismiss() } }
            }.navigationTitle("睡眠定时")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() } } }
        }
    }
    private func select(_ value: Int) { speech.setTimer(byChapters ? ListeningTimer(chapters: value) : ListeningTimer(minutes: value)); dismiss() }
}

private struct SpeechVoicePicker: View {
    @EnvironmentObject private var speech: SpeechPlayer
    @State private var query = ""
    private var voices: [AVSpeechSynthesisVoice] {
        speech.voices.filter { query.isEmpty || "\($0.name) \($0.language) \(Locale.current.localizedString(forIdentifier: $0.language) ?? "")".localizedStandardContains(query) }
    }
    var body: some View {
        List {
            Button { speech.preferences.voiceIdentifier = "" } label: {
                HStack { Text("中文默认声音"); Spacer(); if speech.preferences.voiceIdentifier.isEmpty { Image(systemName: "checkmark") } }
            }
            ForEach(Array(Set(voices.map(\.language))).sorted(), id: \.self) { language in
                Section(Locale.current.localizedString(forIdentifier: language) ?? language) {
                    ForEach(voices.filter { $0.language == language }, id: \.identifier) { voice in
                        Button { speech.preferences.voiceIdentifier = voice.identifier } label: {
                            HStack { Text(voice.name); Spacer(); if speech.preferences.voiceIdentifier == voice.identifier { Image(systemName: "checkmark") } }
                        }
                    }
                }
            }
        }.navigationTitle("系统声音").searchable(text: $query, prompt: "搜索名称或语言")
            .toolbar { Button(speech.isPreviewing ? "停止试听" : "试听") { if speech.isPreviewing { speech.stopPreview() } else { speech.preview() } } }
            .onDisappear { speech.stopPreview() }
    }
}
