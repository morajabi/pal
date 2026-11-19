import Foundation

struct PalError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Tier: String, Codable {
    /// The quick answerer: fast model, small toolset, read-only.
    case quick
    /// A full agent: capable model, the user's MCPs and skills, full access.
    case agent
}

/// A stdio MCP server to hand to the model's harness.
struct MCPServerSpec: Equatable {
    var command: String
    var args: [String]
    var env: [String: String] = [:]
}

/// How to start one conversation with Claude Code or Codex.
struct BackendSpec {
    var provider: ProviderID
    var tier: Tier
    var model: ModelChoice
    var instructions: String
    var cwd: URL
    var mcpServers: [String: MCPServerSpec]
    var fullAccess: Bool
    /// Load the user's own MCP servers / settings / skills.
    var useUserSetup: Bool
}

enum BackendEvent {
    /// The assistant message being written right now (whole text so far).
    case text(String)
    /// A finished assistant message (agents may write several per turn).
    case message(String)
    /// A tool started, e.g. "web search", "reminders · create".
    case tool(String)
    /// The turn is over: final text, or why it failed.
    case turnFinished(Result<String, Error>)
    /// The harness's own session/thread id (lets the user resume it in Claude Code / Codex).
    case sessionID(String)
}

/// One live conversation with a model harness. Events arrive on the main queue.
protocol Backend: AnyObject {
    var spec: BackendSpec { get }
    var onEvent: ((BackendEvent) -> Void)? { get set }
    var isBusy: Bool { get }
    /// Starts the process early. Safe to call repeatedly.
    func warmUp()
    /// Sends a user message, starting a turn (queued if one is running).
    func send(_ text: String)
    /// Stops the current turn; the conversation stays alive.
    func interrupt()
    /// Ends the conversation and its process.
    func stop()
}

enum Backends {
    static func make(_ spec: BackendSpec, accounts: Accounts) -> Backend? {
        switch spec.provider {
        case .claude:
            guard let path = accounts.claudePath else { return nil }
            return ClaudeBackend(executable: path, spec: spec)
        case .codex:
            guard let path = accounts.codexPath else { return nil }
            return CodexBackend(executable: path, spec: spec)
        }
    }
}
