import Foundation

/// OpenAI speech: transcription and text-to-speech over the documented audio API, with an API key
/// from the Keychain. (Codex's app-server also exposes OpenAI realtime voice under a ChatGPT sign-in,
/// but only through experimental calls; that can become another engine later.)
enum OpenAIVoice {
    static let keyAccount = "openai-api-key"

    static var apiKey: String? {
        let k = Keychain.get(keyAccount)
        return (k?.isEmpty ?? true) ? nil : k
    }

    static var isConfigured: Bool { apiKey != nil }

    /// Voices for the speech models.
    static let voices = ["marin", "cedar", "coral", "sage", "alloy", "ash", "ballad", "echo", "fable", "nova", "onyx", "shimmer", "verse"]

    /// Transcribes a WAV clip. `language` is an ISO-639-1 code, or nil to detect.
    static func transcribe(wav: Data, model: String, language: String?) async throws -> String {
        guard let key = apiKey else { throw PalError("Add an OpenAI API key in Settings › Voice.") }
        let boundary = "pal-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", model)
        field("response_format", "json")
        if let language { field("language", language) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (json?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Speaks text with an OpenAI voice; returns MP3 audio.
    static func speech(_ text: String, model: String, voice: String, style: String) async throws -> Data {
        guard let key = apiKey else { throw PalError("Add an OpenAI API key in Settings › Voice.") }
        var payload: [String: Any] = ["model": model, "voice": voice, "input": text, "response_format": "mp3"]
        if !style.trimmingCharacters(in: .whitespaces).isEmpty { payload["instructions"] = style }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        return data
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw PalError("No response from OpenAI.") }
        guard http.statusCode == 200 else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let msg = (json?["error"] as? [String: Any])?["message"] as? String
            if http.statusCode == 401 { throw PalError("The OpenAI API key was rejected. Check it in Settings › Voice.") }
            throw PalError(msg ?? "OpenAI returned an error (\(http.statusCode)).")
        }
    }

    /// 16-bit mono PCM → WAV.
    static func wav(pcm16 pcm: Data, sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count))
        d.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}
