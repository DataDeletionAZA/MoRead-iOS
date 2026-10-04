import Foundation

enum FishSpeech {
    static func body(settings s: CloudSpeechSettings, text: String) -> [String: Any] {
        let legacy = s.model.lowercased() == "s1" || s.model.lowercased().hasPrefix("speech-")
        let aliases = ["calm": "neutral", "fearful": "scared", "开心": "happy", "悲伤": "sad", "愤怒": "angry", "恐惧": "scared", "厌恶": "disgusted", "惊讶": "surprised", "中性": "neutral", "低语": "whispering"]
        let emotions: Set<String> = ["neutral", "happy", "sad", "angry", "scared", "disgusted", "surprised", "whispering"]
        var tags: [String] = []
        for value in [aliases[s.emotion] ?? s.emotion, s.instructions] {
            let tag = value.components(separatedBy: CharacterSet(charactersIn: "[]()")).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !tag.isEmpty, !tags.contains(tag), !legacy || emotions.contains(tag) { tags.append(tag) }
        }
        let prefix = tags.map { legacy ? "(\($0))" : "[\($0)]" }.joined()
        var body: [String: Any] = ["text": prefix + text, "format": "mp3", "prosody": ["speed": s.speed, "volume": min(20, max(-20, 20 * log10(max(0.01, s.volume))))]]
        let voice = s.voice.trimmingCharacters(in: .whitespacesAndNewlines)
        if !voice.isEmpty { body["reference_id"] = voice }
        return body
    }
}
