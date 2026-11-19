import Foundation

/// A conversation with Claude straight over the Messages API (raw HTTPS + SSE), for people
/// without Claude Code or Codex. Pal runs the tool loop itself with its own tools, plus
/// Anthropic's hosted web search/fetch.
@MainActor
final class ClaudeAPIBackend: @preconcurrency Backend {
    let spec: BackendSpec
    var onEvent: ((BackendEvent) -> Void)?

    private var messages: [[String: Any]] = []
    private var queue: [String] = []
    private var task: Task<Void, Never>?
    private var running = false

    var isBusy: Bool { running || !queue.isEmpty }

    init(spec: BackendSpec) {
        self.spec = spec
    }

    func warmUp() {}

    func send(_ text: String) {
        queue.append(text)
        pump()
    }

    func interrupt() {
        queue.removeAll()
        task?.cancel()
    }

    func stop() { interrupt() }

    // MARK: Turn loop

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        let text = queue.removeFirst()
        running = true
        appendUserText(text)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.runTurn()
            self.running = false
            self.onEvent?(.turnFinished(result))
            self.pump()
        }
    }

    /// Keeps roles alternating: text joins a trailing user message (e.g. leftover tool results).
    private func appendUserText(_ text: String) {
        if var last = messages.last, last["role"] as? String == "user" {
            var content = last["content"] as? [[String: Any]] ?? []
            content.append(["type": "text", "text": text])
            last["content"] = content
            messages[messages.count - 1] = last
        } else {
            messages.append(["role": "user", "content": [["type": "text", "text": text]]])
        }
    }

    private func runTurn() async -> Result<String, Error> {
        guard let key = Keychain.anthropicKey, !key.isEmpty else {
            return .failure(PalError("Add a Claude API key in Pal Settings › Models."))
        }
        var continuations = 0
        for _ in 0..<60 { // tool round-trips per turn
            let response: StreamedMessage
            do {
                response = try await stream(key: key)
            } catch is CancellationError {
                dropDanglingUserMessage()
                return .failure(PalError("Stopped."))
            } catch let e as URLError where e.code == .cancelled {
                dropDanglingUserMessage()
                return .failure(PalError("Stopped."))
            } catch {
                dropDanglingUserMessage()
                return .failure(error)
            }

            messages.append(["role": "assistant", "content": Self.echoable(response.content)])
            let text = response.text
            if !text.isEmpty { onEvent?(.message(text)) }

            switch response.stopReason {
            case "tool_use":
                let calls = response.content.filter { $0["type"] as? String == "tool_use" }
                var results: [[String: Any]] = []
                for call in calls {
                    if Task.isCancelled { break }
                    results.append(await runTool(call))
                }
                if Task.isCancelled {
                    // Answer every call so the history stays valid, then stop.
                    let answered = Set(results.compactMap { $0["tool_use_id"] as? String })
                    for call in calls where !answered.contains(call["id"] as? String ?? "") {
                        results.append(["type": "tool_result", "tool_use_id": call["id"] as? String ?? "", "content": "Stopped by the user.", "is_error": true])
                    }
                    messages.append(["role": "user", "content": results])
                    return .failure(PalError("Stopped."))
                }
                messages.append(["role": "user", "content": results])
            case "pause_turn":
                // A long server-side tool loop paused; re-sending resumes it.
                continuations += 1
                if continuations > 5 { return .success(text) }
            case "refusal":
                return .failure(PalError("Claude declined to help with that."))
            case "max_tokens":
                return text.isEmpty ? .failure(PalError("The answer was cut off.")) : .success(text)
            default:
                return .success(text)
            }
        }
        return .failure(PalError("That took too many steps; stopped."))
    }

    private func dropDanglingUserMessage() {
        // A user message that never got an answer: remove it if it's only text, so the next turn starts clean.
        guard let last = messages.last, last["role"] as? String == "user",
              let content = last["content"] as? [[String: Any]],
              content.allSatisfy({ $0["type"] as? String == "text" }) else { return }
        messages.removeLast()
    }

    // MARK: Tools

    private func toolDefinitions() -> [[String: Any]] {
        var defs: [[String: Any]] = ToolRegistry.shared.available(for: spec.tier, includeHarnessNative: true).map { t in
            var d = t.mcpDescriptor
            d["input_schema"] = d.removeValue(forKey: "inputSchema")
            d["eager_input_streaming"] = true
            return d
        }
        // Hosted web tools: the dynamic-filtering versions where the model supports them.
        let modern = !spec.model.model.contains("haiku")
        defs.append(["type": modern ? "web_search_20260209" : "web_search_20250305", "name": "web_search"])
        defs.append(["type": modern ? "web_fetch_20260209" : "web_fetch_20250910", "name": "web_fetch"])
        return defs
    }

    private func runTool(_ call: [String: Any]) async -> [String: Any] {
        let id = call["id"] as? String ?? ""
        let name = call["name"] as? String ?? ""
        guard let input = call["input"] as? [String: Any] else {
            // Eager input streaming means the client validates: hand unparseable input back as an error.
            let raw = call["_raw"] as? String ?? ""
            let payload = (try? JSONSerialization.data(withJSONObject: ["INVALID_JSON": raw])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return ["type": "tool_result", "tool_use_id": id, "content": payload, "is_error": true]
        }
        onEvent?(.tool(name.replacingOccurrences(of: "_", with: " ")))
        let sessionID = spec.tier == .quick ? "main" : (spec.sessionID ?? "main")
        let out = await ToolRegistry.shared.call(name, args: input, context: ToolContext(sessionID: sessionID, tier: spec.tier),
                                                 includeHarnessNative: true)
        let content: [[String: Any]] = out.content.map {
            switch $0 {
            case .text(let s): return ["type": "text", "text": s]
            case .image(let data, let mime):
                return ["type": "image", "source": ["type": "base64", "media_type": mime, "data": data.base64EncodedString()]]
            }
        }
        var result: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": content]
        if out.isError { result["is_error"] = true }
        return result
    }

    // MARK: Streaming

    struct StreamedMessage {
        var content: [[String: Any]] = []
        var stopReason = ""
        var text: String {
            content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        }
    }

    static func apiModel(_ name: String) -> String {
        switch name {
        case "haiku": return "claude-haiku-5-5"
        case "sonnet": return "claude-sonnet-5-5"
        case "opus": return "claude-opus-5-5"
        default: return name
        }
    }

    private func stream(key: String) async throws -> StreamedMessage {
        let model = Self.apiModel(spec.model.model)
        var body: [String: Any] = [
            "model": model,
            "max_tokens": spec.tier == .quick ? 16000 : 64000,
            "stream": true,
            "system": [["type": "text", "text": spec.instructions, "cache_control": ["type": "ephemeral"]]],
            "messages": messages,
            "tools": toolDefinitions(),
            "output_config": ["effort": spec.model.effort],
        ]
        let base = Keychain.debugAPIBase ?? "https://api.anthropic.com"
        var request = URLRequest(url: URL(string: "\(base)/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // Server-side refusal fallback (not offered for Haiku).
        if !model.contains("haiku") {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PalError("No response from the Claude API.") }
        if http.statusCode != 200 {
            var data = Data()
            for try await b in bytes { data.append(b) }
            throw PalError(Self.errorMessage(status: http.statusCode, data: data))
        }

        var msg = StreamedMessage()
        var partialJSON: [Int: String] = [:]
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let event = payload.jsonObject, let type = event["type"] as? String else { continue }
            switch type {
            case "content_block_start":
                guard let index = event["index"] as? Int, var block = event["content_block"] as? [String: Any] else { continue }
                while msg.content.count <= index { msg.content.append([:]) }
                if block["type"] as? String == "tool_use" || block["type"] as? String == "server_tool_use" {
                    partialJSON[index] = ""
                    if let name = block["name"] as? String, block["type"] as? String == "server_tool_use" {
                        onEvent?(.tool(name == "web_search" ? "searching the web" : "reading a page"))
                    }
                }
                if block["type"] as? String == "text" { block["text"] = block["text"] as? String ?? "" }
                msg.content[index] = block
            case "content_block_delta":
                guard let index = event["index"] as? Int, index < msg.content.count,
                      let delta = event["delta"] as? [String: Any] else { continue }
                switch delta["type"] as? String {
                case "text_delta":
                    msg.content[index]["text"] = (msg.content[index]["text"] as? String ?? "") + (delta["text"] as? String ?? "")
                    onEvent?(.text(msg.text))
                case "thinking_delta":
                    msg.content[index]["thinking"] = (msg.content[index]["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                case "signature_delta":
                    msg.content[index]["signature"] = delta["signature"]
                case "input_json_delta":
                    partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
                case "citations_delta":
                    if let c = delta["citation"] {
                        var list = msg.content[index]["citations"] as? [Any] ?? []
                        list.append(c)
                        msg.content[index]["citations"] = list
                    }
                default: break
                }
            case "content_block_stop":
                guard let index = event["index"] as? Int, index < msg.content.count, let raw = partialJSON.removeValue(forKey: index) else { continue }
                // Strict parse; a tool_use we can't parse keeps its raw text so we can report it.
                if let obj = (raw.isEmpty ? "{}" : raw).jsonObject {
                    msg.content[index]["input"] = obj
                } else {
                    msg.content[index]["input"] = nil
                    msg.content[index]["_raw"] = raw
                }
            case "message_delta":
                if let d = event["delta"] as? [String: Any], let r = d["stop_reason"] as? String { msg.stopReason = r }
            case "error":
                let m = (event["error"] as? [String: Any])?["message"] as? String ?? "The Claude API stream failed."
                throw PalError(m)
            default:
                break
            }
        }
        msg.content.removeAll { $0.isEmpty }
        return msg
    }

    /// The assistant content to send back next time. After a mid-output fallback, blocks before the
    /// last `fallback` block that the new model can't validate are left out (the fallback block stays).
    static func echoable(_ content: [[String: Any]]) -> [[String: Any]] {
        var cleaned = content.map { block -> [String: Any] in
            var b = block
            b.removeValue(forKey: "_raw")
            if b["type"] as? String == "tool_use", b["input"] == nil { b["input"] = [String: Any]() }
            return b
        }
        guard let boundary = cleaned.lastIndex(where: { $0["type"] as? String == "fallback" }) else { return cleaned }
        let pairedServerIDs = Set(cleaned.compactMap { $0["tool_use_id"] as? String })
        let keepTypes: Set<String> = ["text", "fallback"]
        cleaned = cleaned.enumerated().compactMap { i, b in
            guard i < boundary else { return b }
            let type = b["type"] as? String ?? ""
            if keepTypes.contains(type) { return b }
            if type == "server_tool_use", let id = b["id"] as? String, pairedServerIDs.contains(id) { return b }
            if type.hasSuffix("_tool_result") { return b }
            return nil
        }
        return cleaned
    }

    private static func errorMessage(status: Int, data: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (json?["error"] as? [String: Any])?["message"] as? String
        switch status {
        case 401: return "The Claude API key was rejected. Check it in Pal Settings › Models."
        case 429: return "The Claude API is rate limiting right now. Try again in a moment."
        case 529: return "The Claude API is overloaded. Try again in a moment."
        default: return message ?? "The Claude API returned an error (\(status))."
        }
    }
}
