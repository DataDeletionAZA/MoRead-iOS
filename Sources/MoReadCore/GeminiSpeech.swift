import Foundation

public enum GeminiSpeech {
    public static let voices: [(id: String, style: String)] = [
        ("Zephyr", "明亮"), ("Puck", "轻快"), ("Charon", "解说"), ("Kore", "坚定"), ("Fenrir", "热情"),
        ("Leda", "年轻"), ("Orus", "坚定"), ("Aoede", "轻盈"), ("Callirrhoe", "随和"), ("Autonoe", "明亮"),
        ("Enceladus", "气声"), ("Iapetus", "清晰"), ("Umbriel", "随和"), ("Algieba", "顺滑"), ("Despina", "顺滑"),
        ("Erinome", "清晰"), ("Algenib", "沙哑"), ("Rasalgethi", "解说"), ("Laomedeia", "轻快"), ("Achernar", "柔和"),
        ("Alnilam", "坚定"), ("Schedar", "平稳"), ("Gacrux", "成熟"), ("Pulcherrima", "鲜明"), ("Achird", "亲切"),
        ("Zubenelgenubi", "随性"), ("Vindemiatrix", "温柔"), ("Sadachbia", "活泼"), ("Sadaltager", "博学"), ("Sulafat", "温暖")
    ]

    static func body(settings s: CloudSpeechSettings, text: String) -> [String: Any] {
        var part: [String: Any] = ["type": "text", "text": text]
        let instruction = s.speechStyle
        if !instruction.isEmpty { part["annotations"] = [["type": "speech_metadata", "style": instruction]] }
        return ["model": s.model.hasPrefix("models/") ? String(s.model.dropFirst(7)) : s.model,
                "store": false, "input": [["type": "user_input", "content": [part]]],
                "response_format": ["type": "audio"], "generation_config": ["speech_config": [["voice": s.voice]]]]
    }

    public static func decode(_ data: Data) throws -> Data {
        let limit = CloudSpeechClient.maximumAudioBytes
        guard data.count <= limit * 4 / 3 + 65536,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["error"] == nil, json["status"] as? String == "completed",
              let steps = json["steps"] as? [[String: Any]] else { throw MoReadError.invalid("Gemini 语音合成未完成。") }
        let parts = steps.filter { $0["type"] as? String == "model_output" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }.filter { $0["type"] as? String == "audio" }
        guard parts.count == 1 else { throw MoReadError.invalid("Gemini 未返回有效的单段语音。") }
        return try decodeAudio(parts[0])
    }

    static func decodeAudio(_ part: [String: Any]) throws -> Data {
        let limit = CloudSpeechClient.maximumAudioBytes
        guard let encoded = part["data"] as? String, encoded.utf8.count <= limit * 4 / 3 + 4,
              let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= limit,
              let mime = part["mime_type"] as? String else { throw MoReadError.invalid("Gemini 未返回有效的单段语音。") }
        let fields = mime.lowercased().split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let format = fields.first else { throw MoReadError.invalid("Gemini 未返回音频格式。") }
        if ["audio/wav", "audio/wave", "audio/x-wav"].contains(format) {
            guard bytes.count >= 44, bytes.prefix(4) == Data("RIFF".utf8), bytes[8..<12] == Data("WAVE".utf8) else { throw MoReadError.invalid("Gemini 返回的 WAV 音频无效。") }
            return try CloudSpeechClient.validateAudio(bytes)
        }
        guard ["audio/l16", "audio/pcm"].contains(format), bytes.count.isMultiple(of: 2), bytes.count <= limit - 44 else {
            throw MoReadError.invalid("Gemini 返回的音频格式无效。")
        }
        var rate = 24000
        for field in fields.dropFirst() {
            let pair = field.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.first == "rate" {
                guard pair.count == 2, let value = Int(pair[1]), (8000...96000).contains(value) else { throw MoReadError.invalid("Gemini 音频采样率无效。") }
                rate = value
            } else if pair.first == "channels", pair.count != 2 || pair[1] != "1" { throw MoReadError.invalid("Gemini 音频必须为单声道。") }
        }
        var wave = Data("RIFF".utf8)
        func word<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wave.append(contentsOf: $0) } }
        word(UInt32(bytes.count + 36)); wave.append(Data("WAVEfmt ".utf8)); word(UInt32(16)); word(UInt16(1)); word(UInt16(1))
        word(UInt32(rate)); word(UInt32(rate * 2)); word(UInt16(2)); word(UInt16(16))
        wave.append(Data("data".utf8)); word(UInt32(bytes.count)); wave.append(bytes)
        return wave
    }
}
