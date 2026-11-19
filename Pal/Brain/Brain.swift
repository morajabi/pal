import Foundation

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, pal, agent, notice }
    var id = UUID()
    var role: Role
    var text: String
    var detail = ""
    var date = Date()
    var sessionID: String?
    var source = ""
}

/// The quick tier: a fast model that answers right away, does small Mac tasks itself,
/// and hands bigger work to agents (via the `start_agent` tool). Keeps the chat history.
@MainActor
final class Brain: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []

    private let accounts: Accounts
    private var backend: Backend?
    private var backendKey = ""
    private var handler: ((BackendEvent) -> Void)?
    /// Turn results still to arrive for questions we abandoned.
    private var ignoreResults = 0

    init(accounts: Accounts) {
        self.accounts = accounts
        messages = Store.load([ChatMessage].self, "chat.json") ?? []
    }

    var providerID: ProviderID? { accounts.answeringProvider }

    func warmUp() { ensureBackend()?.warmUp() }

    /// Starts over with a fresh model conversation (chat history stays visible).
    func reset() {
        backend?.stop()
        backend = nil
        handler = nil
        ignoreResults = 0
        warmUp()
    }

    /// Rebuilds the backend if the provider/model settings changed.
    func configChanged() {
        guard let p = providerID else { return }
        if key(for: p) != backendKey, backend?.isBusy != true { reset() }
    }

    func ask(_ text: String, typed: Bool,
             onText: @escaping (ParsedReply) -> Void,
             onTool: @escaping (String) -> Void,
             completion: @escaping (Result<ParsedReply, Error>) -> Void) {
        guard let backend = ensureBackend() else {
            completion(.failure(PalError("Connect Claude or ChatGPT first: Pal Settings › Models.")))
            return
        }
        if handler != nil { cancel() }
        append(ChatMessage(role: .user, text: text, source: typed ? "typed" : "voice"))

        handler = { [weak self] event in
            guard let self else { return }
            switch event {
            case .text(let raw): onText(ParsedReply.parse(raw, final: false))
            case .tool(let name): onTool(name)
            case .turnFinished(let result):
                self.handler = nil
                switch result {
                case .success(let raw):
                    let reply = ParsedReply.parse(raw, final: true)
                    self.append(ChatMessage(role: .pal, text: reply.spoken, detail: reply.detail, source: self.providerID?.title ?? ""))
                    completion(.success(reply))
                case .failure(let error):
                    completion(.failure(error))
                }
            default: break
            }
        }
        backend.send(Prompts.quickUser(text, typed: typed))
    }

    func cancel() {
        guard handler != nil, let backend else { return }
        handler = nil
        if backend.isBusy {
            ignoreResults += 1
            backend.interrupt()
        }
    }

    /// Agent updates and notices show up in the same chat.
    func append(_ m: ChatMessage) {
        messages.append(m)
        if messages.count > 300 { messages.removeFirst(messages.count - 300) }
        Store.save(messages, "chat.json")
    }

    func clearHistory() {
        messages = []
        Store.save(messages, "chat.json")
    }

    // MARK: Backend

    private func key(for p: ProviderID) -> String {
        let c = PalSettings.c
        let m = c.fast(for: p)
        return "\(p.rawValue)|\(m.model)|\(m.effort)|\(c.quickAnswersUseUserMCP)|\(c.memoryEnabled)"
    }

    private func ensureBackend() -> Backend? {
        guard let p = providerID else { return nil }
        let k = key(for: p)
        if let backend, backendKey == k { return backend }
        backend?.stop()
        let c = PalSettings.c
        let agentP = accounts.agentProvider ?? p
        let agentModel = c.agent(for: agentP)
        let spec = BackendSpec(
            provider: p, tier: .quick, model: c.fast(for: p),
            instructions: Prompts.quick(agentDefault: "\(agentP.title) \(agentModel.model) (\(agentModel.effort) effort)"),
            cwd: Paths.quickWorkspace,
            mcpServers: ["pal": MCPBridge.spec(session: "main", tier: .quick)],
            fullAccess: false,
            useUserSetup: c.quickAnswersUseUserMCP)
        guard let b = Backends.make(spec, accounts: accounts) else { return nil }
        b.onEvent = { [weak self] event in
            guard let self else { return }
            // Swallow everything from abandoned turns, up to their final result.
            if self.ignoreResults > 0 {
                if case .turnFinished = event { self.ignoreResults -= 1 }
                return
            }
            self.handler?(event)
        }
        backend = b
        backendKey = k
        return b
    }
}
