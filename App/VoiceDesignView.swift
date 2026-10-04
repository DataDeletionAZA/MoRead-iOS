import SwiftUI
import AVFoundation
import MoReadCore

struct VoiceDesignView: View {
    @StateObject private var model: VoiceDesignModel
    private enum Input: Hashable { case name, description, language }
    @FocusState private var input: Input?
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var speech: SpeechPlayer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    init(settings: CloudSpeechSettings, root: URL) {
        _model = StateObject(wrappedValue: VoiceDesignModel(settings: settings, root: root))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("声音设定") {
                    TextField("音色名称", text: $model.specification.name).focused($input, equals: .name).accessibilityIdentifier("design-name")
                    TextField("描述年龄感、音高、音色、口音与表达方式", text: $model.specification.description, axis: .vertical)
                        .lineLimit(4...10).focused($input, equals: .description).accessibilityIdentifier("design-description")
                    Picker("声音类型", selection: $model.specification.gender) {
                        Text("女声").tag("female"); Text("男声").tag("male"); Text("中性").tag("neutral")
                    }
                    TextField("语言代码，如 zh-CN", text: $model.specification.language)
                        .focused($input, equals: .language).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("design-language")
                }.disabled(model.busy || model.saved)
                Section {
                    Button(model.candidate == nil ? "生成音色与试听" : "按当前设定重新生成") {
                        speech.pause(); speech.stopPreview(); model.generate()
                    }.disabled(model.busy || model.saved).accessibilityIdentifier("design-generate")
                    Text("通过已保存的 Gemini 服务创建音色。生成会调用服务商；满意后点击入库，随后可在音色库选择为听书声音。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let candidate = model.candidate {
                    Section("试听候选") {
                        Text(candidate.id).font(.caption).textSelection(.enabled)
                        if !model.specification.matchesSound(candidate.specification) {
                            Text("声音设定已修改，请重新生成后再入库。").foregroundStyle(.orange).accessibilityIdentifier("design-changed")
                        }
                        if candidate.audio != nil {
                            Button(model.playing ? "停止试听" : "播放试听") { speech.pause(); speech.stopPreview(); model.togglePreview() }
                                .disabled(model.busy).accessibilityIdentifier("design-preview")
                        } else {
                            Button("重新获取试听") { model.fetchPreview() }.disabled(model.busy).accessibilityIdentifier("design-fetch")
                        }
                        Button(model.saved ? "已保存到音色库" : "满意，入库") { model.save() }
                            .disabled(!model.canSave || library.maintenance).accessibilityIdentifier("design-save")
                    }
                }
                if let message = model.message { Section { Text(message).accessibilityIdentifier("design-status") } }
                if model.busy { Button("停止") { model.stop() }.accessibilityIdentifier("design-stop") }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("声音设计")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer(); Button("收起键盘") { input = nil }.accessibilityIdentifier("design-keyboard-done")
                }
            }
            .onDisappear { model.close() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { model.stop() } }
            .onChange(of: speech.cloudSettings) { _, settings in if settings != model.settings { model.close(); dismiss() } }
            .onChange(of: library.maintenance) { _, busy in if busy { model.close(); dismiss() } }
        }
    }
}

@MainActor private final class VoiceDesignModel: ObservableObject {
    struct Candidate {
        let id: String
        let specification: VoiceDesignSpecification
        var audio: Data?
    }
    @Published var specification = VoiceDesignSpecification()
    @Published var candidate: Candidate?
    @Published var busy = false
    @Published var playing = false
    @Published var saved = false
    @Published var message: String?
    let settings: CloudSpeechSettings
    private let root: URL
    private var key: String?
    private var owned: Set<String> = []
    private var generation = UUID()
    private var closed = false
    private var task: Task<Void, Never>?
    private var playback: Task<Void, Never>?
    private var player: AVAudioPlayer?
    init(settings: CloudSpeechSettings, root: URL) { self.settings = settings; self.root = root }
    var canSave: Bool {
        !closed && !busy && !saved && candidate?.audio != nil && candidate.map { specification.matchesSound($0.specification) } == true && (try? specification.normalized()) != nil
    }
    private func credential() async throws -> String {
        if let key { return key }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--simulate-voice-design") { key = "voice-design-fixture"; return key! }
        #endif
        let value = try await KeychainStore.readAsync(settings.id); key = value; return value
    }
    private func perform(_ action: @escaping (UUID) async throws -> Void) {
        guard !closed, !busy, !saved else { return }
        stopPreview(); generation = UUID(); let token = generation; busy = true; message = nil
        task = Task {
            do { try await action(token) }
            catch is CancellationError {} catch { if generation == token && !closed { message = error.localizedDescription } }
            if generation == token { busy = false; task = nil }
        }
    }
    func generate() {
        perform { [self] token in
            let spec = try specification.normalized()
            let request = try GeminiVoiceDesign.createRequest(settings: settings, key: await credential(), specification: spec)
            message = "正在生成音色…"
            let result = try GeminiVoiceDesign.created(await fetch(request))
            // Never take cleanup ownership of a voice already present in the library.
            guard try !VoiceLibrary(root: root).voices().contains(where: { $0.providerHint == "GEMINI" && $0.voiceId.lowercased() == result.id.lowercased() }) else {
                throw MoReadError.invalid("服务返回的音色已经在音色库中，已保留原有音色。")
            }
            owned.insert(result.id)
            guard token == generation, !closed, !Task.isCancelled else { cleanLater(result.id); return }
            let previous = candidate
            candidate = Candidate(id: result.id, specification: spec, audio: result.preview)
            if let previous, previous.id != result.id { cleanLater(previous.id) }
            message = result.preview == nil ? "音色已生成；可以重新获取试听，无需再次生成。" : "音色已生成，听听是否满意。"
        }
    }
    func fetchPreview() {
        guard let current = candidate, owned.contains(current.id) else { return }
        perform { [self] token in
            message = "正在获取试听…"
            let request = try GeminiVoiceDesign.voiceRequest(settings: settings, key: await credential(), id: current.id)
            let audio = try GeminiVoiceDesign.preview(await fetch(request), id: current.id)
            try Task.checkCancellation()
            guard token == generation, !closed, candidate?.id == current.id else { return }
            candidate?.audio = audio; message = "试听已就绪。"
        }
    }
    func save() {
        guard canSave, let candidate else { return }
        do {
            let spec = try specification.normalized()
            var voice = SavedVoice(voiceId: candidate.id, displayName: spec.name, providerHint: "GEMINI", tags: "Gemini,自定义," + spec.language, gender: spec.gender == "female" ? "FEMALE" : spec.gender == "male" ? "MALE" : "UNSPECIFIED")
            let endpoint = try GeminiVoiceDesign.voiceRequest(settings: settings, key: "metadata", id: candidate.id).url!.deletingLastPathComponent().deletingLastPathComponent().absoluteString
            let extra = try JSONSerialization.data(withJSONObject: ["voice_design": ["description": candidate.specification.description, "language": spec.language, "source_base_url": endpoint, "created_at": Int64(Date().timeIntervalSince1970 * 1000)]])
            voice.extraJson = String(decoding: extra, as: UTF8.self)
            try VoiceLibrary(root: root).merge([voice])
            owned.remove(candidate.id); saved = true; stopPreview(); message = "已保存到音色库。"
        } catch { message = error.localizedDescription }
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; busy = false; stopPreview()
        if !closed { message = "已停止，已完成的试听仍保留。" }
    }
    func close() {
        guard !closed else { return }; closed = true; stop()
        for id in owned { cleanLater(id) }
    }
    private func cleanLater(_ id: String) {
        Task { [self] in
            guard owned.contains(id), let key else { return }
            do {
                if try VoiceLibrary(root: root).voices().contains(where: { $0.providerHint == "GEMINI" && $0.voiceId.lowercased() == id.lowercased() }) { owned.remove(id); return }
                let request = try GeminiVoiceDesign.voiceRequest(settings: settings, key: key, id: id, deleting: true)
                _ = try await fetch(request); owned.remove(id)
            } catch { if !closed { message = "未保存的云端草稿清理未成功；退出时会再次尝试。" } }
        }
    }
    private func stopPreview() { playback?.cancel(); playback = nil; player?.stop(); player = nil; playing = false }
    func togglePreview() {
        if playing { stopPreview(); return }
        guard !busy, let data = candidate?.audio else { return }
        do {
            let audio = try AVAudioPlayer(data: data)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            guard audio.prepareToPlay(), audio.play() else { throw MoReadError.invalid("试听音频暂时无法播放。") }
            player = audio; playing = true
            playback = Task { [weak self] in
                do { while audio.isPlaying { try await Task.sleep(for: .milliseconds(200)) } } catch { return }
                self?.stopPreview()
            }
        } catch { message = error.localizedDescription }
    }
    private func fetch(_ request: URLRequest) async throws -> Data {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--simulate-voice-design") {
            let flags = ProcessInfo.processInfo.arguments
            try await Task.sleep(for: .milliseconds(flags.contains("--slow-voice-design") ? 10_000 : 300))
            if flags.contains("--failed-voice-design") { throw MoReadError.invalid("声音设计服务暂不可用") }
            let id = request.httpMethod == "POST" ? "voice_" + UUID().uuidString : request.url!.lastPathComponent
            if request.httpMethod == "DELETE" { return Data() }
            var value: [String: Any] = ["id": id]
            if request.httpMethod != "POST" || !flags.contains("--missing-design-preview") {
                let bytes = Data(repeating: 0, count: 24000 * 2 * 8)
                value["sample_audio"] = ["mime_type": "audio/pcm;rate=24000", "data": bytes.base64EncodedString()]
            }
            return try JSONSerialization.data(withJSONObject: value)
        }
        #endif
        return try await GeminiVoiceDesign.fetch(request)
    }
}
