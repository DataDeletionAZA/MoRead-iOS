import XCTest
@testable import MoReadCore

final class GeminiVoiceDesignTests: XCTestCase {
    func testCreateRetrieveAndDeleteRequestsStayOnConfiguredService() throws {
        var settings = CloudSpeechSettings(); settings.preset(.gemini)
        settings.baseURL = "https://example.com/proxy/v1beta/interactions"; settings.model = "models/gemini-3.8-flash-tts"; settings.voice = ""
        let spec = VoiceDesignSpecification(name: " 夜读 ", description: " 温暖低沉，吐字清晰 ")
        let create = try GeminiVoiceDesign.createRequest(settings: settings, key: "fixture", specification: spec)
        XCTAssertEqual(create.url?.absoluteString, "https://example.com/proxy/v1beta/voices")
        XCTAssertEqual(create.httpMethod, "POST"); XCTAssertEqual(create.value(forHTTPHeaderField: "x-goog-api-key"), "fixture")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(create.httpBody)) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, true)
        let voice = try XCTUnwrap(body["voice"] as? [String: Any])
        XCTAssertEqual(voice["type"] as? String, "prompted"); XCTAssertEqual(voice["model"] as? String, "gemini-3.8-flash-tts")
        XCTAssertEqual(voice["display_name"] as? String, "夜读"); XCTAssertEqual(voice["language_code"] as? String, "zh-CN")
        XCTAssertEqual((voice["prompted"] as? [String: Any])?["input"] as? String, "温暖低沉，吐字清晰")
        for deleting in [false, true] {
            let request = try GeminiVoiceDesign.voiceRequest(settings: settings, key: "fixture", id: "voice_a-B_12", deleting: deleting)
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/proxy/v1beta/voices/voice_a-B_12")
            XCTAssertEqual(request.httpMethod, deleting ? "DELETE" : "GET"); XCTAssertNil(request.httpBody)
        }
        for id in ["Kore", "voice_", "voice_a/../Kore", "voice_abc?key=x", "voice_abc\n", String(repeating: "a", count: 513)] {
            XCTAssertThrowsError(try GeminiVoiceDesign.voiceRequest(settings: settings, key: "fixture", id: id, deleting: true))
        }
        settings.model = "models/"; XCTAssertThrowsError(try GeminiVoiceDesign.createRequest(settings: settings, key: "fixture", specification: spec))
        settings.preset(.openAI); XCTAssertThrowsError(try GeminiVoiceDesign.createRequest(settings: settings, key: "fixture", specification: spec))
    }
    func testSpecificationValidationAndSoundChangeDetection() throws {
        let spec = VoiceDesignSpecification(name: "旁白", description: "沉稳温暖")
        XCTAssertEqual(try spec.normalized(), spec)
        var renamed = spec; renamed.name = "新名字"; XCTAssertTrue(spec.matchesSound(renamed))
        renamed.description += "，轻声"; XCTAssertFalse(spec.matchesSound(renamed))
        for value in [VoiceDesignSpecification(name: "", description: "温暖"), .init(name: "旁白", description: ""),
                      .init(name: String(repeating: "字", count: 81), description: "温暖"),
                      .init(name: "旁白", description: String(repeating: "字", count: 2001)),
                      .init(name: "旁白", description: "温暖", gender: "other"),
                      .init(name: "旁白", description: "温暖", language: "zh-CN\n"),
                      .init(name: "旁白", description: "温暖", language: "../../en")] {
            XCTAssertThrowsError(try value.normalized())
        }
    }
    func testMissingOrDamagedSampleKeepsIdentityAndCanRecoverSameVoice() throws {
        let missing = try GeminiVoiceDesign.created(Data(#"{"id":"voice_valid"}"#.utf8))
        XCTAssertEqual(missing.id, "voice_valid"); XCTAssertNil(missing.preview)
        let damaged = try GeminiVoiceDesign.created(Data(#"{"id":"voice_valid","sample_audio":{"mime_type":"audio/wav","data":"bad"}}"#.utf8))
        XCTAssertEqual(damaged.id, "voice_valid"); XCTAssertNil(damaged.preview)
        let response = try JSONSerialization.data(withJSONObject: ["id": "voice_valid", "sample_audio": ["mime_type": "audio/pcm;rate=24000;channels=1", "data": Data(repeating: 0, count: 240).base64EncodedString()]])
        let recovered = try GeminiVoiceDesign.preview(response, id: missing.id)
        XCTAssertEqual(recovered.prefix(4), Data("RIFF".utf8)); XCTAssertEqual(recovered.count, 284)
        XCTAssertEqual(try GeminiVoiceDesign.created(response).preview, recovered)
        XCTAssertThrowsError(try GeminiVoiceDesign.preview(response, id: "voice_other"))
        XCTAssertThrowsError(try GeminiVoiceDesign.preview(Data(#"{"id":"voice_valid"}"#.utf8), id: "voice_valid"))
        for raw in ["{}", "[]", #"{"id":"Kore"}"#, #"{"id":"voice_valid","error":{"message":"private"}}"#] {
            XCTAssertThrowsError(try GeminiVoiceDesign.created(Data(raw.utf8)))
        }
    }
}
