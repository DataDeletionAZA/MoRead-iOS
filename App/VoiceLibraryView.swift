import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import MoReadCore

struct VoiceLibraryView: View {
    var configuration: CloudSpeechSettings?
    var previewAllowed = true
    var select: ((SavedVoice) throws -> Void)?
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var speech: SpeechPlayer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var voices: [SavedVoice] = []
    @State private var query = ""
    @State private var tag = ""
    @State private var gender = ""
    @State private var pinned = false
    @State private var editing: SavedVoice?
    @State private var removing: SavedVoice?
    @State private var importing = false
    @State private var export: VoiceDocument?
    @State private var exporting = false
    @State private var message: String?
    @State private var catalogTask: Task<Void, Never>?
    @State private var catalogGeneration = UUID()
    @State private var catalogStatus: String?
    @StateObject private var preview = CloudVoicePreview()
    private var store: VoiceLibrary? { library.store.map { VoiceLibrary(root: $0.root) } }
    private var settings: CloudSpeechSettings { configuration ?? speech.cloudSettings }
    private var filtered: [SavedVoice] {
        voices.filter { v in
            (!pinned || v.pinned) && (gender.isEmpty || gender == v.gender) && (tag.isEmpty || v.tagList.contains(tag)) &&
            (query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || [v.displayName, v.voiceId, v.tags].contains { $0.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespacesAndNewlines)) })
        }
    }
    var body: some View {
        List {
            Section {
                Text("给服务商的声音 ID 起一个好记的名字，收藏后可以试听或选作听书声音。")
                LabeledContent("当前语音服务", value: settings.service.label)
                Toggle("只看置顶", isOn: $pinned).accessibilityIdentifier("voices-pinned-only")
                Picker("声音性别", selection: $gender) { Text("全部").tag(""); Text("男声").tag("MALE"); Text("女声").tag("FEMALE"); Text("未指定").tag("UNSPECIFIED") }
                Picker("标签", selection: $tag) { Text("全部").tag(""); ForEach(Set(voices.flatMap(\.tagList)).sorted(), id: \.self) { Text($0).tag($0) } }
            }
            if let message { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("voices-message") }
            Section("\(filtered.count) / \(voices.count) 个音色") {
                ForEach(filtered) { voice in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(voice.displayName).font(.headline)
                            if voice.pinned { Image(systemName: "pin.fill").accessibilityLabel("已置顶") }
                            Spacer()
                            Menu {
                                Button("编辑") { preview.stop(); editing = voice }
                                Button(voice.pinned ? "取消置顶" : "置顶") { run { var changed = voice; changed.pinned.toggle(); try store?.save(changed) } }
                                Button("复制声音 ID") { UIPasteboard.general.string = voice.voiceId }
                                Button("删除", role: .destructive) { removing = voice }
                            } label: { Image(systemName: "ellipsis.circle").padding(6) }.accessibilityIdentifier("voice-actions-" + voice.voiceId)
                        }
                        Text((voice.providerHint.isEmpty ? "自定义" : voice.providerHint) + " · " + voice.voiceId).font(.caption).foregroundStyle(.secondary)
                        if !voice.tags.isEmpty { Text(voice.tagList.joined(separator: " · ")).font(.caption) }
                        if voice.compatible(with: settings.service), settings.voice == voice.voiceId { Text("当前声音").font(.caption).foregroundStyle(.tint) }
                        HStack {
                            Button(preview.voiceID == voice.id ? "停止试听" : "试听") {
                                if preview.voiceID == voice.id { preview.stop() } else if !previewAllowed { message = "请先返回并保存云端声音设置，再试听。" } else { stopCatalog(); speech.pause(); speech.stopPreview(); preview.start(voice, settings: settings) }
                            }.buttonStyle(.bordered).accessibilityIdentifier("voice-preview-" + voice.voiceId)
                            Button(select == nil ? "设为听书声音" : "选择这个音色") {
                                run {
                                    preview.stop(); stopCatalog()
                                    if let select { try select(voice); dismiss() }
                                    else { try speech.selectCloudVoice(voice); message = "听书声音已设为「\(voice.displayName)」" }
                                }
                            }.buttonStyle(.bordered).accessibilityIdentifier("voice-select-" + voice.voiceId)
                        }
                    }.padding(.vertical, 4)
                }
                if filtered.isEmpty { Text("没有符合条件的音色。可添加声音 ID，或从右上角导入预设。").foregroundStyle(.secondary) }
            }
            Section { Text("试听会向当前配置的语音服务商发送固定示例文字，可能产生费用。音色资料随完整备份保存；导入相同服务和声音 ID 时保留已有资料。") }.font(.caption)
        }.navigationTitle("云端音色库").searchable(text: $query, prompt: "搜索名称、声音 ID 或标签")
            .disabled(library.maintenance)
            .safeAreaInset(edge: .bottom) {
                if catalogStatus != nil || preview.status != nil || preview.error != nil {
                    HStack {
                        if let catalogStatus { Text(catalogStatus).accessibilityIdentifier("voice-catalog-status") }
                        else if let error = preview.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("voice-preview-error") }
                        else if let status = preview.status { Text(status).accessibilityIdentifier("voice-preview-status") }
                        Spacer()
                        if catalogTask != nil { Button("停止") { stopCatalog(); catalogStatus = "已停止读取，已有音色保持不变。" }.accessibilityIdentifier("voice-catalog-stop") }
                        if catalogTask == nil && catalogStatus != nil { Button("关闭") { catalogStatus = nil } }
                        if preview.voiceID != nil { Button("停止") { preview.stop() }.accessibilityIdentifier("voice-preview-stop") }
                    }.font(.callout).padding().background(.regularMaterial)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("添加音色") { editing = SavedVoice(providerHint: SavedVoice.hint(for: settings.service)) }
                        Button("导入 Gemini 预设") { run { let count = try store?.merge(VoiceLibrary.geminiPresets) ?? 0; message = "新增 \(count) 个音色" } }
                        Button("读取 Gemini 在线音色") { loadCatalog() }.disabled(catalogTask != nil)
                        Button("导入 MiniMax 预设") { run { let count = try store?.merge(VoiceLibrary.miniMaxPresets) ?? 0; message = "新增 \(count) 个音色" } }
                        Button("从 JSON 文件导入") { importing = true }
                        Button("导出音色文件") { run { if let data = try store?.exportJSON() { export = VoiceDocument(data: data); exporting = true } } }.disabled(voices.isEmpty)
                    } label: { Image(systemName: "plus.circle") }.accessibilityIdentifier("voice-library-add")
                }
            }
            .task { run {} }
            .sheet(item: $editing) { voice in VoiceEditor(voice: voice) { value in guard !library.maintenance, let store else { throw MoReadError.invalid("书库正在处理，请稍后保存。") }; try store.save(value); voices = try store.voices() } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                run { let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let data = try CharacterCardImporter.read(url, limit: VoiceLibrary.maximumBytes)
                    message = "新增 \(try store?.importJSON(data) ?? 0) 个音色"
                }
            }
            .fileExporter(isPresented: $exporting, document: export, contentType: .json, defaultFilename: "MoRead-voices") { result in if case .failure(let error) = result { library.error = error.localizedDescription } }
            .alert("删除这个音色？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("取消", role: .cancel) { removing = nil }
                Button("删除", role: .destructive) { run { if let removing { preview.stop(); try store?.remove(removing.id) }; removing = nil } }
            } message: { Text("只删除音色库记录，当前听书设置保持不变。") }
            .onDisappear { preview.stop(); stopCatalog() }
            .onChange(of: settings) { _, _ in preview.stop(); stopCatalog() }
            .onChange(of: previewAllowed) { _, allowed in if !allowed { stopCatalog() } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { preview.stop(); stopCatalog() } }
            .onChange(of: library.maintenance) { _, busy in preview.stop(); stopCatalog(); if !busy { run {} } }
    }
    private func stopCatalog() {
        catalogGeneration = UUID(); catalogTask?.cancel(); catalogTask = nil; catalogStatus = nil
    }
    private func loadCatalog() {
        guard catalogTask == nil, !library.maintenance, let root = library.store?.root else { return }
        guard settings.service == .gemini, previewAllowed else { catalogStatus = "请先在云端声音中选择 Gemini，并保存地址和密钥。"; return }
        preview.stop(); preview.error = nil
        let snapshot = settings, token = UUID(); catalogGeneration = token
        catalogStatus = "正在读取 Gemini 在线音色…"
        catalogTask = Task {
            do {
                let result: [SavedVoice]
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--simulate-voice-catalog") {
                    result = try await GeminiVoiceCatalog.list(settings: snapshot, key: "catalog-fixture") { request in
                        try await Task.sleep(for: .milliseconds(ProcessInfo.processInfo.arguments.contains("--slow-voice-catalog") ? 10_000 : 300))
                        if ProcessInfo.processInfo.arguments.contains("--failed-voice-catalog") { throw MoReadError.invalid("在线音色服务暂不可用") }
                        if ProcessInfo.processInfo.arguments.contains("--empty-voice-catalog") { return Data("{}".utf8) }
                        let next = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "page_token" } == true
                        return Data((next ? #"{"voices":[{"id":"voice_second","display_name":"Online reader","gender":"male"}]}"# : #"{"voices":[{"id":"voice_first","display_name":"Online narrator","gender":"female","language_code":"zh-CN"}],"next_page_token":"next"}"#).utf8)
                    }
                } else {
                    result = try await GeminiVoiceCatalog.list(settings: snapshot, key: KeychainStore.readAsync(snapshot.id))
                }
                #else
                result = try await GeminiVoiceCatalog.list(settings: snapshot, key: KeychainStore.readAsync(snapshot.id))
                #endif
                try Task.checkCancellation()
                guard catalogGeneration == token, !library.maintenance, library.store?.root == root, settings == snapshot else { return }
                let count = try VoiceLibrary(root: root).merge(result)
                voices = try VoiceLibrary(root: root).voices()
                catalogStatus = result.isEmpty ? "服务未返回音色，可以导入预设或稍后重试。" : "已读取 \(result.count) 个在线音色，新增 \(count) 个。"
            } catch is CancellationError {} catch { if catalogGeneration == token { catalogStatus = error.localizedDescription } }
            if catalogGeneration == token { catalogTask = nil }
        }
    }
    private func run(_ action: () throws -> Void) {
        guard !library.maintenance else { return }
        do { try action(); voices = try store?.voices() ?? []; if !voices.flatMap(\.tagList).contains(tag) { tag = "" } }
        catch { library.error = error.localizedDescription }
    }
}

private struct VoiceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var voice: SavedVoice
    let save: (SavedVoice) throws -> Void
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("音色名称", text: $voice.displayName).accessibilityIdentifier("voice-name")
                TextField("声音 ID", text: $voice.voiceId).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("voice-id")
                Picker("语音服务", selection: $voice.providerHint) {
                    Text("未指定").tag("")
                    ForEach(SpeechService.allCases, id: \.self) { Text($0.label).tag(SavedVoice.hint(for: $0)) }
                    if !voice.providerHint.isEmpty && !SpeechService.allCases.map(SavedVoice.hint).contains(voice.providerHint) { Text(voice.providerHint).tag(voice.providerHint) }
                }
                TextField("标签，用逗号分隔", text: $voice.tags).accessibilityIdentifier("voice-tags")
                Picker("性别", selection: $voice.gender) { Text("未指定").tag("UNSPECIFIED"); Text("男声").tag("MALE"); Text("女声").tag("FEMALE") }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("音色资料").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { do { try save(voice); dismiss() } catch { self.error = error.localizedDescription } }.accessibilityIdentifier("voice-save") }
            }
        }
    }
}

private struct VoiceDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor private final class CloudVoicePreview: ObservableObject {
    @Published var voiceID: UUID?
    @Published var error: String?
    @Published var status: String?
    private var task: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var generation = UUID()
    func stop() { generation = UUID(); task?.cancel(); task = nil; player?.stop(); player = nil; voiceID = nil; status = nil }
    func start(_ voice: SavedVoice, settings: CloudSpeechSettings) {
        stop(); error = nil
        let token = generation; voiceID = voice.id; status = "正在生成试听…"
        task = Task {
            do {
                let value = try voice.applying(to: settings)
                let data: Data
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing"), let encoded = ProcessInfo.processInfo.environment["MOREAD_TEST_VOICE_AUDIO"] {
                    if voice.voiceId == "failure" { throw MoReadError.invalid("试听服务暂不可用") }
                    try await Task.sleep(for: .milliseconds(voice.voiceId == "slow" ? 10_000 : 300))
                    guard let sample = Data(base64Encoded: encoded) else { throw MoReadError.invalid("试听样本无效") }
                    data = try CloudSpeechClient.validateAudio(sample)
                } else {
                    data = try await CloudSpeechClient.synthesize(settings: value, key: KeychainStore.readAsync(value.id), text: "你好，这是墨知音色库的试听声音。")
                }
                #else
                data = try await CloudSpeechClient.synthesize(settings: value, key: KeychainStore.readAsync(value.id), text: "你好，这是墨知音色库的试听声音。")
                #endif
                try Task.checkCancellation(); guard token == generation else { return }
                let audio = try AVAudioPlayer(data: data)
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                guard audio.prepareToPlay(), audio.play() else { throw MoReadError.invalid("这个声音暂时无法播放。") }
                player = audio; status = "正在试听「\(voice.displayName)」"
                while audio.isPlaying { try await Task.sleep(for: .milliseconds(200)) }
            } catch is CancellationError {} catch { if token == generation { self.error = error.localizedDescription } }
            if token == generation { stop() }
        }
    }
}
