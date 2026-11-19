import Foundation

/// A conversation with the user's Claude Code (`claude -p` in streaming JSON mode).
/// One process per conversation keeps context and skips startup on follow-ups.
final class ClaudeBackend: Backend {
    let spec: BackendSpec
    var onEvent: ((BackendEvent) -> Void)?
    private let executable: String
    private var proc: LineProcess?
    private var pendingTurns = 0
    private var current = ""
    private var controlCounter = 0

    var isBusy: Bool { pendingTurns > 0 }

    init(executable: String, spec: BackendSpec) {
        self.executable = executable
        self.spec = spec
    }

    func warmUp() { _ = ensureProcess() }

    func send(_ text: String) {
        guard let proc = ensureProcess() else {
            onEvent?(.turnFinished(.failure(PalError("Couldn't start Claude Code."))))
            return
        }
        pendingTurns += 1
        proc.send(["type": "user", "message": ["role": "user", "content": text]])
    }

    func interrupt() {
        guard isBusy else { return }
        controlCounter += 1
        proc?.send(["type": "control_request", "request_id": "pal-\(controlCounter)", "request": ["subtype": "interrupt"]])
    }

    func stop() {
        proc?.stop()
        proc = nil
        if pendingTurns > 0 {
            pendingTurns = 0
            onEvent?(.turnFinished(.failure(PalError("Stopped."))))
        }
    }

    // MARK: Process

    private func arguments() -> [String] {
        var a = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", spec.model.model,
            "--effort", spec.model.effort,
        ]
        if !spec.mcpServers.isEmpty, let json = mcpConfigJSON() {
            a += ["--mcp-config", json]
        }
        if !spec.useUserSetup { a.append("--strict-mcp-config") }

        switch spec.tier {
        case .quick:
            a += [
                "--no-session-persistence",
                "--system-prompt", spec.instructions,
                "--tools", "WebSearch,WebFetch",
                "--allowedTools", "WebSearch,WebFetch,mcp__pal",
            ]
        case .agent:
            a += ["--append-system-prompt", spec.instructions]
            if let r = spec.resumeID { a += ["--resume", r] }
            if spec.fullAccess {
                a += ["--permission-mode", "bypassPermissions"]
            } else {
                a += ["--permission-mode", "acceptEdits", "--allowedTools", "mcp__pal,WebSearch,WebFetch,Read,Glob,Grep"]
            }
        }
        return a
    }

    private func mcpConfigJSON() -> String? {
        var servers: [String: Any] = [:]
        for (name, s) in spec.mcpServers {
            var entry: [String: Any] = ["type": "stdio", "command": s.command, "args": s.args]
            if !s.env.isEmpty { entry["env"] = s.env }
            servers[name] = entry
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": servers]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func ensureProcess() -> LineProcess? {
        if let proc, proc.isRunning { return proc }
        let p = LineProcess(executable: executable, arguments: arguments(), cwd: spec.cwd)
        p.onLine = { [weak self] line in self?.handle(line) }
        p.onExit = { [weak self, weak p] status, stderr in
            guard let self, self.proc === p else { return }
            self.proc = nil
            if self.pendingTurns > 0 {
                self.pendingTurns = 0
                let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                self.onEvent?(.turnFinished(.failure(PalError(msg.isEmpty ? "Claude Code stopped (exit \(status))." : String(msg.suffix(300))))))
            }
        }
        do {
            try p.start()
            proc = p
            return p
        } catch {
            log.error("claude start failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Stream

    private func handle(_ line: String) {
        guard let json = line.jsonObject, let type = json["type"] as? String else { return }
        switch type {
        case "system":
            if json["subtype"] as? String == "init", let id = json["session_id"] as? String {
                onEvent?(.sessionID(id))
            }
        case "stream_event":
            guard let event = json["event"] as? [String: Any] else { return }
            switch event["type"] as? String {
            case "message_start":
                current = ""
            case "content_block_start":
                if let block = event["content_block"] as? [String: Any], block["type"] as? String == "tool_use",
                   let name = block["name"] as? String {
                    onEvent?(.tool(Self.prettyTool(name)))
                }
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    current += text
                    onEvent?(.text(current))
                }
            default: break
            }
        case "assistant":
            let blocks = ((json["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            if !text.isEmpty { onEvent?(.message(text)) }
        case "result":
            pendingTurns = max(0, pendingTurns - 1)
            let isError = (json["is_error"] as? Bool) ?? (json["subtype"] as? String != "success")
            let text = (json["result"] as? String) ?? current
            if isError {
                let errors = (json["errors"] as? [String])?.joined(separator: " ")
                let message = text.isEmpty ? (errors ?? "Claude couldn't finish.") : text
                onEvent?(.turnFinished(.failure(PalError(Self.friendly(message)))))
            } else {
                onEvent?(.turnFinished(.success(text.isEmpty ? current : text)))
            }
        default:
            break
        }
    }

    static func prettyTool(_ name: String) -> String {
        if name.hasPrefix("mcp__") {
            let parts = name.split(separator: "_", omittingEmptySubsequences: true)
            // mcp, server, tool...
            let server = parts.count > 1 ? String(parts[1]) : ""
            let tool = parts.dropFirst(2).joined(separator: " ")
            return server == "pal" ? tool : "\(server) · \(tool)"
        }
        switch name {
        case "WebSearch": return "searching the web"
        case "WebFetch": return "reading a page"
        case "Bash": return "running a command"
        case "Read", "Glob", "Grep": return "reading files"
        case "Edit", "Write", "MultiEdit": return "editing files"
        case "Task", "Agent": return "starting a helper"
        default: return name
        }
    }

    private static func friendly(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("/login") || lower.contains("invalid api key") || lower.contains("not logged in") {
            return "Claude isn't signed in. Open Pal Settings › Models to sign in."
        }
        return message
    }
}
