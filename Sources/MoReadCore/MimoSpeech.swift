import Foundation

public enum MimoSpeech {
    public static let voices = ["mimo_default", "冰糖", "茉莉", "苏打", "白桦", "Mia", "Chloe", "Milo", "Dean"]
    static func body(settings s: CloudSpeechSettings, text: String) throws -> [String: Any] {
        let style = s.speechStyle
        var audio: [String: Any] = ["format": "wav"]
        if s.model.lowercased().hasSuffix("-voicedesign") {
            guard !style.isEmpty else { throw MoReadError.invalid("请在朗读要求中描述想要的 MiMo 声音。") }
            audio["optimize_text_preview"] = false
        } else {
            let voice = s.voice.trimmingCharacters(in: .whitespacesAndNewlines)
            audio["voice"] = voice.isEmpty ? "mimo_default" : voice
        }
        var messages: [[String: String]] = []
        if !style.isEmpty { messages.append(["role": "user", "content": style]) }
        messages.append(["role": "assistant", "content": text])
        return ["model": s.model, "messages": messages, "audio": audio, "stream": false]
    }
    public static func decode(_ data: Data) throws -> Data {
        let limit = CloudSpeechClient.maximumAudioBytes
        guard data.count <= limit * 4 / 3 + 65536,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil,
              let choice = (root["choices"] as? [[String: Any]])?.first,
              !["length", "content_filter"].contains(choice["finish_reason"] as? String ?? ""),
              let message = choice["message"] as? [String: Any], let audio = message["audio"] as? [String: Any],
              let encoded = audio["data"] as? String, encoded.utf8.count <= limit * 4 / 3 + 4,
              let decoded = Data(base64Encoded: encoded) else { throw MoReadError.invalid("MiMo 未返回完整有效的语音，请检查模型、音色及账户额度。") }
        return try CloudSpeechClient.validateAudio(decoded)
    }
}
