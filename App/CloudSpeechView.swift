import SwiftUI
import MoReadCore

struct CloudSpeechView: View {
    @EnvironmentObject private var speech: SpeechPlayer
    @EnvironmentObject private var library: LibraryModel
    @State private var settings = CloudSpeechSettings()
    @State private var key = ""
    @State private var loadingKey = true
    @State private var keyLoaded = false
    @State private var message: String?
    @State private var cacheBytes: Int64 = 0
    @State private var clearing = false
    @State private var confirmClear = false
    @FocusState private var focusedField: String?
    var body: some View {
        Form {
            Section {
                Toggle("使用云端声音", isOn: $settings.enabled).accessibilityIdentifier("cloud-speech-enabled")
            } footer: { Text("开启后，朗读的文字会发送到所选语音服务商，并按该服务商规则计费。生成的声音来自 AI，音频保存在本机供再次播放。") }
            Section("语音服务商") {
                Picker("接口类型", selection: Binding(get: { settings.service }, set: { settings.preset($0); key = ""; message = nil })) {
                    ForEach(SpeechService.allCases, id: \.self) { Text($0.label).tag($0) }
                }.accessibilityIdentifier("cloud-speech-service").disabled(loadingKey)
                field("服务地址", text: $settings.baseURL, id: "cloud-speech-url")
                if settings.service == .miniMax {
                    Button("使用 MiniMax 国内地址") { settings.baseURL = "https://api.minimaxi.com/v1" }
                    Button("使用 MiniMax 国际地址") { settings.baseURL = "https://api.minimax.io/v1" }
                    field("Group ID（可选）", text: $settings.groupID, id: "cloud-speech-group")
                }
                field("语音模型", text: $settings.model, id: "cloud-speech-model")
                field("声音 ID", text: $settings.voice, id: "cloud-speech-voice")
                SecureField("API 密钥", text: Binding(get: { key }, set: { key = $0; keyLoaded = true })).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focusedField, equals: "cloud-speech-key").accessibilityIdentifier("cloud-speech-key").disabled(loadingKey)
                Text("声音 ID 请填写服务商提供的名称。密钥保存在这台设备的系统钥匙串中。").font(.caption).foregroundStyle(.secondary)
            }
            Section("声音表现") {
                LabeledContent("语速", value: settings.speed.formatted(.number.precision(.fractionLength(2))) + " 倍")
                Slider(value: $settings.speed, in: settings.service == .openAI ? 0.25...4 : 0.5...2, step: 0.05).accessibilityLabel("云端语速")
                if settings.service == .openAI {
                    TextField("朗读要求（可选）", text: $settings.instructions, axis: .vertical).lineLimit(2...5).focused($focusedField, equals: "instructions")
                    Text("tts-1 和 tts-1-hd 只使用声音与语速；其他支持朗读要求的模型还会收到上面的描述。").font(.caption).foregroundStyle(.secondary)
                } else {
                    LabeledContent("音量", value: settings.volume.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $settings.volume, in: 0...10, step: 0.1).accessibilityLabel("云端音量")
                    Stepper("音调 \(settings.pitch)", value: $settings.pitch, in: -12...12)
                    Picker("情绪", selection: $settings.emotion) {
                        Text("自动").tag("")
                        ForEach([("calm", "平静"), ("happy", "开心"), ("sad", "悲伤"), ("angry", "生气"), ("fearful", "害怕"), ("disgusted", "厌恶"), ("surprised", "惊讶")], id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
                Stepper("每段最多 \(settings.maximumCharacters) 字", value: $settings.maximumCharacters, in: 80...2000, step: 80)
            }
            Section {
                Button("保存声音设置") {
                    focusedField = nil
                    do { try speech.saveCloudSettings(settings, key: key); settings = speech.cloudSettings; message = "已保存。可以打开一本书，点“听书”开始。" }
                    catch { library.error = error.localizedDescription }
                }.accessibilityIdentifier("save-cloud-speech").disabled(loadingKey || !keyLoaded)
                if let message { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("cloud-speech-saved") }
            }
            Section("已生成的音频") {
                LabeledContent("本机音频", value: ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)).accessibilityIdentifier("speech-cache-size")
                Stepper("最多保存 \(settings.cacheMegabytes) MB", value: $settings.cacheMegabytes, in: 50...2048, step: 50)
                Button("清空听书音频", role: .destructive) { confirmClear = true }.disabled(clearing || cacheBytes == 0)
                Text("空间达到上限后，会先清理最久没有播放的音频。完整备份包含已生成的音频。").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("云端声音与缓存")
            .disabled(library.maintenance || clearing)
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focusedField = nil } } }
            .task {
                settings = speech.cloudSettings; loadingKey = true; keyLoaded = false
                do { key = try await KeychainStore.readAsync(settings.id); keyLoaded = true }
                catch is CancellationError { return } catch { library.error = error.localizedDescription }
                loadingKey = false
                if let root = library.store?.root {
                    do {
                        let size = try await Task.detached(priority: .utility) { try SpeechAudioCache.size(root: root) }.value
                        try Task.checkCancellation(); if library.store?.root == root { cacheBytes = size }
                    } catch is CancellationError {} catch { library.error = error.localizedDescription }
                }
            }
            .alert("清空已生成的听书音频？", isPresented: $confirmClear) {
                Button("取消", role: .cancel) {}
                Button("清空音频", role: .destructive) {
                    clearing = true
                    Task {
                        await speech.stopAndWait()
                        library.perform { if let root = library.store?.root { try SpeechAudioCache.clear(root: root); cacheBytes = 0 } }
                        clearing = false
                    }
                }
            } message: { Text("再次使用云端声音朗读时，需要重新生成并可能产生费用。") }
    }
    private func field(_ label: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focusedField, equals: id).accessibilityIdentifier(id)
        }
    }
}
