import AppKit

struct ModelOption: Identifiable, Hashable {
    var id: String
    var title: String
    var detail: String
    var efforts: [String]
}

/// What AI the user already has: installed CLIs, sign-ins, available models.
final class Accounts: ObservableObject {
    struct Status: Equatable {
        var installed = false
        var signedIn = false
        var account = ""
    }

    @Published private(set) var claude = Status()
    @Published private(set) var codex = Status()
    /// A Claude API key in the Keychain (for people without Claude Code or Codex).
    @Published private(set) var claudeAPI = Status()
    @Published private(set) var detected = false
    @Published private(set) var codexModels: [ModelOption] = Accounts.fallbackCodexModels
    @Published private(set) var browsePath: String?
    @Published private(set) var npxPath: String?

    private(set) var claudePath: String?
    private(set) var codexPath: String?
    private var loginRPC: CodexRPC?

    var onChange: (() -> Void)?
    var onCodexLogin: ((Bool, String?) -> Void)?

    static let claudeModels: [ModelOption] = [
        ModelOption(id: "haiku", title: "Haiku", detail: "Fastest", efforts: claudeEfforts),
        ModelOption(id: "sonnet", title: "Sonnet", detail: "Fast and smart", efforts: claudeEfforts),
        ModelOption(id: "opus", title: "Opus", detail: "Most capable", efforts: claudeEfforts),
        ModelOption(id: "claude-fable-5-2", title: "Fable 5.2", detail: "Frontier", efforts: claudeEfforts),
    ]
    static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]

    static let fallbackCodexModels: [ModelOption] = [
        ModelOption(id: "gpt-6.1-terra", title: "GPT-6.1 Terra", detail: "Efficient, great at computer use", efforts: ["low", "medium", "high", "xhigh"]),
        ModelOption(id: "gpt-6.2-sol", title: "GPT-6.2-Sol", detail: "Go-to model for everyday work", efforts: ["low", "medium", "high", "xhigh"]),
        ModelOption(id: "gpt-6.2-astra", title: "GPT-6.2-Astra", detail: "Most capable", efforts: ["low", "medium", "high", "xhigh"]),
    ]

    func models(for p: ProviderID) -> [ModelOption] { p == .codex ? codexModels : Self.claudeModels }

    func status(of p: ProviderID) -> Status {
        switch p {
        case .claude: claude
        case .codex: codex
        case .claudeAPI: claudeAPI
        }
    }

    func setClaudeAPIKey(_ key: String?) {
        if let key, !key.trimmingCharacters(in: .whitespaces).isEmpty {
            Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: Keychain.anthropicAccount)
        } else {
            Keychain.delete(Keychain.anthropicAccount)
        }
        refreshAPIKey()
        onChange?()
    }

    private func refreshAPIKey() {
        let key = Keychain.anthropicKey ?? ""
        claudeAPI = Status(installed: true, signedIn: !key.isEmpty, account: key.isEmpty ? "" : "Key ending in …\(key.suffix(4))")
    }

    /// The provider that answers: the user's pick if signed in, else whichever is (Claude first).
    var answeringProvider: ProviderID? {
        if let chosen = PalSettings.c.provider.provider, status(of: chosen).signedIn { return chosen }
        if claude.signedIn { return .claude }
        if codex.signedIn { return .codex }
        if claudeAPI.signedIn { return .claudeAPI }
        return nil
    }

    var agentProvider: ProviderID? {
        if let chosen = PalSettings.c.agentProvider.provider, status(of: chosen).signedIn { return chosen }
        return answeringProvider
    }

    // MARK: Detection

    func detect(completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let claudePath = ShellEnv.which("claude")
            let codexPath = ShellEnv.which("codex")
            let browsePath = ShellEnv.which("browse")
            let npxPath = ShellEnv.which("npx")
            var claude = Status(installed: claudePath != nil)
            var codex = Status(installed: codexPath != nil)
            if let claudePath {
                let (code, out) = ShellEnv.run(claudePath, ["auth", "status", "--json"])
                if code == 0, let json = out.jsonObject {
                    claude.signedIn = json["loggedIn"] as? Bool ?? false
                    claude.account = (json["email"] as? String) ?? (json["authMethod"] as? String ?? "")
                }
            }
            if let codexPath {
                let (code, out) = ShellEnv.run(codexPath, ["login", "status"])
                codex.signedIn = code == 0 && out.localizedCaseInsensitiveContains("logged in")
                    && !out.localizedCaseInsensitiveContains("not logged in")
                codex.account = codex.signedIn ? out.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
            DispatchQueue.main.async {
                self.claudePath = claudePath
                self.codexPath = codexPath
                self.browsePath = browsePath
                self.npxPath = npxPath
                self.claude = claude
                self.codex = codex
                self.refreshAPIKey()
                self.detected = true
                self.onChange?()
                completion?()
                if codex.signedIn { self.loadCodexModels() }
            }
        }
    }

    private func loadCodexModels() {
        guard let codexPath else { return }
        let rpc = CodexRPC(executable: codexPath, cwd: Paths.quickWorkspace)
        rpc.ensureStarted { [weak self] error in
            guard error == nil else { rpc.stop(); return }
            rpc.request("model/list", [:]) { result, _ in
                defer { rpc.stop() }
                let list = (result?["data"] as? [[String: Any]]) ?? (result?["models"] as? [[String: Any]]) ?? []
                let models: [ModelOption] = list.compactMap { m in
                    guard let id = (m["id"] as? String) ?? (m["model"] as? String) else { return nil }
                    let efforts = (m["supportedReasoningEfforts"] as? [[String: Any]])?.compactMap { $0["reasoningEffort"] as? String } ?? ["low", "medium", "high"]
                    return ModelOption(id: id, title: m["displayName"] as? String ?? id,
                                       detail: m["description"] as? String ?? "", efforts: efforts)
                }
                if !models.isEmpty { self?.codexModels = models }
            }
        }
    }

    // MARK: Sign-in

    func connectChatGPT() {
        guard let codexPath else {
            NSWorkspace.shared.open(URL(string: "https://developers.openai.com/codex/cli")!)
            return
        }
        let rpc = CodexRPC(executable: codexPath, cwd: Paths.quickWorkspace)
        loginRPC = rpc
        rpc.onNotification = { [weak self] method, params in
            guard let self, method == "account/login/completed" else { return }
            let ok = params["success"] as? Bool ?? false
            self.loginRPC?.stop()
            self.loginRPC = nil
            self.detect { self.onCodexLogin?(ok, params["error"] as? String) }
        }
        rpc.ensureStarted { [weak self] error in
            if let error { self?.onCodexLogin?(false, error); return }
            rpc.request("account/login/start", ["type": "chatgpt"]) { result, error in
                if let s = result?["authUrl"] as? String, let url = URL(string: s) {
                    NSWorkspace.shared.open(url)
                } else {
                    self?.onCodexLogin?(false, error ?? "Couldn't start ChatGPT sign-in.")
                }
            }
        }
    }

    /// Opens Terminal running `claude auth login`.
    func signInToClaude() {
        guard let claudePath else {
            NSWorkspace.shared.open(URL(string: "https://claude.com/claude-code")!)
            return
        }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("pal-claude-login.command")
        let body = "#!/bin/zsh\n'\(claudePath)' auth login\necho\necho 'Done. You can close this window and talk to Pal.'\n"
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.detect() }
    }
}
