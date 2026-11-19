import Foundation
import Combine

/// One background agent: a long-lived Claude Code / Codex conversation working on a task.
@MainActor
final class AgentSession: ObservableObject, Identifiable {
    enum Status: String, Codable {
        case starting, working, idle, failed, stopped, ended

        var isActive: Bool { self == .starting || self == .working }
        var title: String {
            switch self {
            case .starting: "Starting"
            case .working: "Working"
            case .idle: "Waiting"
            case .failed: "Failed"
            case .stopped: "Stopped"
            case .ended: "Ended"
            }
        }
    }

    struct Entry: Codable, Identifiable, Equatable {
        enum Role: String, Codable { case user, agent, tool, note }
        var id = UUID()
        var role: Role
        var text: String
        var date = Date()
    }

    struct Record: Codable {
        var id, title, task: String
        var provider: ProviderID
        var model: ModelChoice
        var status: Status
        var entries: [Entry]
        var summary: String
        var harnessID: String?
        var created, updated: Date
    }

    let id: String
    let created: Date
    @Published var title: String
    @Published var task: String
    @Published var provider: ProviderID
    @Published var model: ModelChoice
    @Published var status: Status
    @Published var activity = ""
    @Published var entries: [Entry] = []
    /// The latest reply's spoken line.
    @Published var summary = ""
    @Published var updated: Date
    @Published var unread = false
    var harnessID: String?
    var backend: Backend?
    /// Set while trying to resume natively; used to retry with a recap if that fails.
    var resumeRecap: String?

    init(id: String, title: String, task: String, provider: ProviderID, model: ModelChoice) {
        self.id = id
        self.title = title
        self.task = task
        self.provider = provider
        self.model = model
        status = .starting
        created = Date()
        updated = Date()
    }

    init(record r: Record) {
        id = r.id
        title = r.title
        task = r.task
        provider = r.provider
        model = r.model
        status = r.status.isActive || r.status == .idle ? .ended : r.status
        entries = r.entries
        summary = r.summary
        harnessID = r.harnessID
        created = r.created
        updated = r.updated
    }

    var record: Record {
        Record(id: id, title: title, task: task, provider: provider, model: model, status: status,
               entries: Array(entries.suffix(200)), summary: summary, harnessID: harnessID, created: created, updated: updated)
    }

    func add(_ role: Entry.Role, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if role == .tool, let last = entries.last, last.role == .tool, last.text == t { return }
        entries.append(Entry(role: role, text: t))
        updated = Date()
    }
}

/// Starts, tracks and talks to agent sessions. Persists their history.
@MainActor
final class SessionManager: ObservableObject {
    static let shared = SessionManager()

    enum Update {
        case finished(ParsedReply)
        case failed(String)
        case notify(String, urgent: Bool)
    }

    @Published private(set) var sessions: [AgentSession] = []
    var accounts: Accounts!
    /// Pal shows these on the card / as notifications.
    var onUpdate: ((AgentSession, Update) -> Void)?
    /// A session just started (origin: "user", "agent …", "scheduled task …").
    var onStarted: ((AgentSession, String) -> Void)?
    /// A short progress line while a session works ("searching the web", a brief note).
    var onProgress: ((AgentSession, String) -> Void)?

    private var idleTimers: [String: Timer] = [:]
    private var saveWork: DispatchWorkItem?
    private var bag: [String: AnyCancellable] = [:]

    var activeCount: Int { sessions.filter { $0.status.isActive }.count }
    var unreadCount: Int { sessions.filter(\.unread).count }

    func load() {
        let records = Store.load([AgentSession.Record].self, "sessions.json") ?? []
        sessions = records.map(AgentSession.init(record:))
    }

    func session(_ id: String) -> AgentSession? {
        sessions.first { $0.id == id || $0.id.hasPrefix(id) }
    }

    // MARK: Start / talk

    @discardableResult
    func start(task: String, title: String?, provider: ProviderID? = nil, model: String? = nil, effort: String? = nil,
               origin: String = "user") throws -> AgentSession {
        guard let p = provider.flatMap({ accounts.status(of: $0).signedIn ? $0 : nil }) ?? accounts.agentProvider else {
            throw PalError("No AI is connected for agents. Connect Claude or ChatGPT in Pal Settings › Models.")
        }
        let limit = PalSettings.c.maxConcurrentAgents
        guard activeCount < limit else {
            throw PalError("\(activeCount) agents are already working (limit \(limit)). Wait, or stop one first.")
        }
        var choice = PalSettings.c.agent(for: p)
        if let model { choice.model = model }
        if let effort { choice.effort = effort }
        let name = title ?? Self.shortTitle(task)
        let s = AgentSession(id: Self.newID(), title: name, task: task, provider: p, model: choice)
        sessions.insert(s, at: 0)
        observe(s)
        s.add(.user, task)
        launch(s, firstMessage: Self.firstMessage(task: task, origin: origin))
        onStarted?(s, origin)
        scheduleSave()
        return s
    }

    /// Send a message to a session. Revives ended sessions with a recap.
    func send(_ id: String, _ text: String, from origin: String = "user") throws {
        guard let s = session(id) else { throw PalError("No agent with id \(id).") }
        s.add(origin == "user" ? .user : .note, origin == "user" ? text : "\(origin): \(text)")
        let message = origin == "user" ? text : "[\(origin)] \(text)"
        if let backend = s.backend {
            s.status = .working
            s.activity = "thinking"
            backend.send(message)
        } else {
            let recap = """
            You are continuing an earlier task: \(s.task)
            Your last update was: \(s.summary.isEmpty ? "(none)" : s.summary)

            New message: \(message)
            """
            if let id = s.harnessID, s.provider != .claudeAPI {
                // Pick the real conversation back up in Claude Code / Codex; fall back to a recap if that fails.
                s.resumeRecap = recap
                launch(s, firstMessage: message, resumeID: id)
            } else {
                launch(s, firstMessage: recap)
            }
        }
        idleTimers[s.id]?.invalidate()
        scheduleSave()
    }

    func stop(_ id: String) {
        guard let s = session(id) else { return }
        s.backend?.stop()
        s.backend = nil
        s.status = .stopped
        s.activity = ""
        scheduleSave()
    }

    func remove(_ id: String) {
        stop(id)
        sessions.removeAll { $0.id == id }
        bag[id] = nil
        scheduleSave()
    }

    func markRead(_ id: String) {
        session(id)?.unread = false
    }

    func shutdown() {
        for s in sessions { s.backend?.stop(); s.backend = nil }
        save()
    }

    // MARK: Internals

    private func launch(_ s: AgentSession, firstMessage: String, resumeID: String? = nil) {
        var servers: [String: MCPServerSpec] = ["pal": MCPBridge.spec(session: s.id, tier: .agent)]
        if let browser = ExternalTools.browserServer(accounts: accounts) { servers[browser.name] = browser.spec }
        let spec = BackendSpec(provider: s.provider, tier: .agent, model: s.model,
                               instructions: Prompts.agent(title: s.title), cwd: Paths.workspace,
                               mcpServers: servers, fullAccess: PalSettings.c.agentsFullAccess, useUserSetup: true,
                               sessionID: s.id, resumeID: resumeID)
        guard let backend = Backends.make(spec, accounts: accounts) else {
            s.status = .failed
            s.add(.note, s.provider == .claudeAPI ? "No Claude API key." : "\(s.provider.via) isn't installed.")
            return
        }
        s.backend = backend
        s.status = .working
        s.activity = "starting"
        backend.onEvent = { [weak self, weak s] event in
            guard let self, let s else { return }
            self.handle(event, for: s)
        }
        backend.send(firstMessage)
    }

    private func handle(_ event: BackendEvent, for s: AgentSession) {
        switch event {
        case .text:
            s.activity = "writing"
        case .message(let text):
            // Intermediate messages are progress notes; the final one arrives with turnFinished.
            if s.backend?.isBusy == true {
                s.add(.agent, text)
                onProgress?(s, Self.progressLine(text))
            }
        case .tool(let name):
            s.activity = name
            s.add(.tool, name)
            onProgress?(s, name)
        case .sessionID(let id):
            s.harnessID = id
        case .turnFinished(let result):
            s.activity = ""
            switch result {
            case .success(let text):
                s.resumeRecap = nil
                if s.entries.last?.text != text.trimmingCharacters(in: .whitespacesAndNewlines) { s.add(.agent, text) }
                let reply = ParsedReply.parse(text, final: true)
                s.summary = reply.spoken
                s.status = s.backend?.isBusy == true ? .working : .idle
                s.unread = true
                onUpdate?(s, .finished(reply))
                armIdleTimer(s)
            case .failure(let error):
                let message = error.localizedDescription
                if let recap = s.resumeRecap, message != "Stopped." {
                    // Native resume didn't work (session gone, CLI changed…): start fresh with a recap.
                    s.resumeRecap = nil
                    s.backend?.stop()
                    s.backend = nil
                    s.add(.note, "Couldn't reopen the old session; continuing from a summary.")
                    launch(s, firstMessage: recap)
                    return
                }
                if message == "Stopped." {
                    s.status = .stopped
                } else {
                    s.status = .failed
                    s.add(.note, message)
                    s.unread = true
                    onUpdate?(s, .failed(message))
                }
            }
            scheduleSave()
        }
    }

    /// Agents that sit idle for an hour release their process. Messages revive them.
    private func armIdleTimer(_ s: AgentSession) {
        idleTimers[s.id]?.invalidate()
        idleTimers[s.id] = Timer.scheduledTimer(withTimeInterval: 3600, repeats: false) { [weak self, weak s] _ in
            Task { @MainActor in
                guard let self, let s, s.status == .idle else { return }
                if Scheduler.shared.jobs.contains(where: { $0.target == .session(s.id) && $0.enabled }) { return }
                s.backend?.stop()
                s.backend = nil
                s.status = .ended
                self.scheduleSave()
            }
        }
    }

    func notify(from sessionID: String, _ message: String, urgent: Bool) {
        let s = session(sessionID)
        s?.add(.note, "Notified you: \(message)")
        s?.unread = true
        if let s { onUpdate?(s, .notify(message, urgent: urgent)) }
    }

    private func observe(_ s: AgentSession) {
        bag[s.id] = s.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        objectWillChange.send()
    }

    private func save() {
        Store.save(Array(sessions.prefix(100)).map(\.record), "sessions.json")
    }

    private static func firstMessage(task: String, origin: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        return "[Task from \(origin == "user" ? "the user, via Pal" : origin) at \(f.string(from: Date()))]\n\(task)"
    }

    private static func newID() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(6))
    }

    /// First sentence of a note, trimmed for a one-line progress display.
    static func progressLine(_ text: String) -> String {
        let plain = ParsedReply.plain(text.components(separatedBy: "\n---").first ?? text)
        let first = plain.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).first ?? plain
        return first.count > 90 ? String(first.prefix(88)) + "…" : first
    }

    static func shortTitle(_ task: String) -> String {
        let words = task.split(separator: " ").prefix(6).joined(separator: " ")
        return words.count < task.count ? words + "…" : words
    }
}
