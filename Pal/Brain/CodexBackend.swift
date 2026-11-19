import Foundation

/// A conversation with the user's Codex over `codex app-server` (JSON-RPC on stdio).
/// Uses their ChatGPT sign-in.
final class CodexBackend: Backend {
    let spec: BackendSpec
    var onEvent: ((BackendEvent) -> Void)?
    private let executable: String
    private let rpc: CodexRPC

    private var threadID: String?
    private var ready = false
    private var startingThread = false
    private var waitingForThread: [() -> Void] = []
    private var queue: [String] = []

    private var activeTurnID: String?
    private var turnRunning = false
    private var current = ""
    private var currentIsCommentary = false
    private var lastAnswer: String?
    private var lastError: String?

    var isBusy: Bool { turnRunning || !queue.isEmpty }

    init(executable: String, spec: BackendSpec) {
        self.executable = executable
        self.spec = spec
        rpc = CodexRPC(executable: executable, cwd: spec.cwd)
        rpc.onNotification = { [weak self] method, params in self?.handle(method, params) }
        rpc.onServerRequest = { [weak self] method, params in self?.answerServerRequest(method, params) ?? [:] }
        rpc.onExit = { [weak self] message in
            guard let self else { return }
            self.threadID = nil
            self.ready = false
            self.startingThread = false
            if self.turnRunning {
                self.turnRunning = false
                self.onEvent?(.turnFinished(.failure(PalError(message))))
            }
        }
    }

    func warmUp() { ensureThread {} }

    func send(_ text: String) {
        queue.append(text)
        pump()
    }

    func interrupt() {
        queue.removeAll()
        guard let threadID, let activeTurnID else { return }
        rpc.request("turn/interrupt", ["threadId": threadID, "turnId": activeTurnID]) { _, _ in }
    }

    func stop() {
        queue.removeAll()
        rpc.stop()
        threadID = nil
        ready = false
        if turnRunning {
            turnRunning = false
            onEvent?(.turnFinished(.failure(PalError("Stopped."))))
        }
    }

    // MARK: Turns

    private func pump() {
        guard !turnRunning, !queue.isEmpty else { return }
        ensureThread { [weak self] in
            guard let self, !self.turnRunning, let threadID = self.threadID, !self.queue.isEmpty else { return }
            let text = self.queue.removeFirst()
            self.turnRunning = true
            self.current = ""
            self.lastAnswer = nil
            self.lastError = nil
            self.rpc.request("turn/start", [
                "threadId": threadID,
                "input": [["type": "text", "text": text, "text_elements": []]],
                "effort": self.spec.model.effort,
            ]) { [weak self] result, error in
                guard let self else { return }
                if let error {
                    self.turnRunning = false
                    self.onEvent?(.turnFinished(.failure(PalError(Self.friendly(error)))))
                    self.pump()
                    return
                }
                self.activeTurnID = (result?["turn"] as? [String: Any])?["id"] as? String
            }
        }
    }

    private func ensureThread(_ then: @escaping () -> Void) {
        if ready { then(); return }
        waitingForThread.append(then)
        guard !startingThread else { return }
        startingThread = true
        rpc.ensureStarted { [weak self] error in
            guard let self else { return }
            if let error { self.failStart(error); return }
            self.rpc.request("thread/start", self.threadParams()) { [weak self] result, error in
                guard let self else { return }
                self.startingThread = false
                if let error { self.failStart(Self.friendly(error)); return }
                guard let thread = result?["thread"] as? [String: Any], let id = thread["id"] as? String else {
                    self.failStart("Codex didn't start a conversation.")
                    return
                }
                self.threadID = id
                self.ready = true
                self.onEvent?(.sessionID(id))
                let waiting = self.waitingForThread
                self.waitingForThread = []
                waiting.forEach { $0() }
            }
        }
    }

    private func failStart(_ message: String) {
        startingThread = false
        waitingForThread = []
        queue.removeAll()
        onEvent?(.turnFinished(.failure(PalError(message))))
    }

    private func threadParams() -> [String: Any] {
        var config: [String: Any] = [:]
        var servers: [String: Any] = [:]
        for (name, s) in spec.mcpServers {
            var entry: [String: Any] = ["command": s.command, "args": s.args]
            if !s.env.isEmpty { entry["env"] = s.env }
            // Pal's own tools never need a per-call approval; other servers follow the access setting.
            if name == "pal" || (spec.tier == .agent && spec.fullAccess) { entry["default_tools_approval_mode"] = "approve" }
            servers[name] = entry
        }
        if spec.useUserSetup {
            for (name, entry) in servers { config["mcp_servers.\(name)"] = entry }
        } else {
            config["mcp_servers"] = servers // replaces the user's list for quick answers
        }
        let agent = spec.tier == .agent
        return [
            "model": spec.model.model,
            "cwd": spec.cwd.path,
            "sandbox": agent ? (spec.fullAccess ? "danger-full-access" : "workspace-write") : "read-only",
            "approvalPolicy": "never",
            "ephemeral": !agent,
            "developerInstructions": spec.instructions,
            "config": config,
        ]
    }

    // MARK: Events

    private func handle(_ method: String, _ params: [String: Any]) {
        if let turnID = params["turnId"] as? String, let active = activeTurnID, turnID != active, method != "turn/completed" {
            return
        }
        switch method {
        case "item/started":
            guard let item = params["item"] as? [String: Any] else { return }
            switch item["type"] as? String {
            case "agentMessage":
                current = ""
                currentIsCommentary = (item["phase"] as? String) == "commentary"
            case "mcpToolCall":
                let server = item["server"] as? String ?? ""
                let tool = (item["tool"] as? String ?? "").replacingOccurrences(of: "_", with: " ")
                onEvent?(.tool(server == "pal" ? tool : "\(server) · \(tool)"))
            case "webSearch": onEvent?(.tool("searching the web"))
            case "commandExecution": onEvent?(.tool("running a command"))
            case "fileChange": onEvent?(.tool("editing files"))
            default: break
            }
        case "item/agentMessage/delta":
            guard !currentIsCommentary, let delta = params["delta"] as? String else { return }
            current += delta
            onEvent?(.text(current))
        case "item/completed":
            if let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
               let text = item["text"] as? String {
                onEvent?(.message(text))
                if (item["phase"] as? String) != "commentary" { lastAnswer = text }
            }
        case "error":
            if let err = params["error"] as? [String: Any], let m = err["message"] as? String,
               (params["willRetry"] as? Bool) != true {
                lastError = m
            }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            if let id = turn?["id"] as? String, let active = activeTurnID, id != active { return }
            turnRunning = false
            activeTurnID = nil
            switch turn?["status"] as? String {
            case "failed":
                let m = (turn?["error"] as? [String: Any])?["message"] as? String ?? lastError ?? "ChatGPT couldn't finish."
                onEvent?(.turnFinished(.failure(PalError(Self.friendly(m)))))
            case "interrupted":
                onEvent?(.turnFinished(.failure(PalError("Stopped."))))
            default:
                let text = lastAnswer ?? current
                if text.isEmpty, let lastError {
                    onEvent?(.turnFinished(.failure(PalError(Self.friendly(lastError)))))
                } else {
                    onEvent?(.turnFinished(.success(text)))
                }
            }
            pump()
        default:
            break
        }
    }

    /// Approvals and MCP elicitations. With full access the agent may proceed; otherwise decline.
    private func answerServerRequest(_ method: String, _ params: [String: Any]) -> [String: Any] {
        let allow = spec.tier == .agent && spec.fullAccess
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "execCommandApproval", "applyPatchApproval":
            return ["decision": allow ? "accept" : "decline"]
        case "mcpServer/elicitation/request":
            // Pal's own tools are always allowed; others follow the access setting.
            let server = params["serverName"] as? String ?? params["server"] as? String
            return ["action": (allow || server == "pal") ? "accept" : "decline", "content": NSNull(), "_meta": NSNull()]
        default:
            return [:]
        }
    }

    static func friendly(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("401") || lower.contains("unauthorized") || lower.contains("not logged in") {
            return "ChatGPT isn't connected. Open Pal Settings › Models to connect it."
        }
        return message
    }
}

/// The JSON-RPC plumbing for `codex app-server`.
final class CodexRPC {
    var onNotification: ((String, [String: Any]) -> Void)?
    /// Return the result for a server → client request. Empty dict = unsupported.
    var onServerRequest: ((String, [String: Any]) -> [String: Any])?
    var onExit: ((String) -> Void)?

    private let executable: String
    private let cwd: URL
    private var proc: LineProcess?
    private var nextID = 0
    private var pending: [Int: ([String: Any]?, String?) -> Void] = [:]
    private var initialized = false
    private var initWaiters: [(String?) -> Void] = []

    init(executable: String, cwd: URL) {
        self.executable = executable
        self.cwd = cwd
    }

    func ensureStarted(_ done: @escaping (String?) -> Void) {
        if initialized, proc?.isRunning == true { done(nil); return }
        initWaiters.append(done)
        guard proc == nil || proc?.isRunning == false else { return }
        let p = LineProcess(executable: executable, arguments: ["app-server"], cwd: cwd)
        p.onLine = { [weak self] line in self?.handle(line) }
        p.onExit = { [weak self, weak p] status, stderr in
            guard let self, self.proc === p else { return }
            self.reset()
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            self.onExit?(msg.isEmpty ? "Codex stopped (exit \(status))." : String(msg.suffix(300)))
        }
        do { try p.start() } catch {
            finishInit("Couldn't start Codex: \(error.localizedDescription)")
            return
        }
        proc = p
        request("initialize", [
            "clientInfo": ["name": "pal", "title": "Pal", "version": "0.2.0"],
            "capabilities": NSNull(),
        ]) { [weak self] _, error in
            guard let self else { return }
            if let error { self.finishInit(error); return }
            self.proc?.send(["jsonrpc": "2.0", "method": "initialized"])
            self.initialized = true
            self.finishInit(nil)
        }
    }

    func request(_ method: String, _ params: [String: Any], _ done: @escaping ([String: Any]?, String?) -> Void) {
        nextID += 1
        pending[nextID] = done
        proc?.send(["jsonrpc": "2.0", "id": nextID, "method": method, "params": params])
    }

    func stop() {
        proc?.stop()
        reset()
    }

    private func reset() {
        proc = nil
        initialized = false
        let p = pending
        pending = [:]
        p.values.forEach { $0(nil, "Codex stopped.") }
    }

    private func finishInit(_ error: String?) {
        let w = initWaiters
        initWaiters = []
        w.forEach { $0(error) }
    }

    private func handle(_ line: String) {
        guard let msg = line.jsonObject else { return }
        let method = msg["method"] as? String
        if method == nil, let id = msg["id"] as? Int, let done = pending.removeValue(forKey: id) {
            let error = (msg["error"] as? [String: Any])?["message"] as? String
            done(msg["result"] as? [String: Any], error)
            return
        }
        let params = msg["params"] as? [String: Any] ?? [:]
        if let method, let id = msg["id"] {
            let result = onServerRequest?(method, params) ?? [:]
            if result.isEmpty {
                proc?.send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Pal doesn't handle \(method)"]])
            } else {
                proc?.send(["jsonrpc": "2.0", "id": id, "result": result])
            }
            return
        }
        if let method { onNotification?(method, params) }
    }
}
