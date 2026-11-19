import SwiftUI

/// Pal's window from the menu bar: the conversation, background agents, and what's scheduled.
struct HomeView: View {
    let pal: Pal
    @ObservedObject var state: StatusBar.State
    @ObservedObject var brain: Brain
    @ObservedObject var sessions: SessionManager
    @ObservedObject var scheduler: Scheduler
    @ObservedObject var timers: TimerCenter
    @ObservedObject var model: PalModel

    init(pal: Pal, state: StatusBar.State) {
        self.pal = pal
        self.state = state
        brain = pal.brain
        sessions = SessionManager.shared
        scheduler = Scheduler.shared
        timers = TimerCenter.shared
        model = pal.model
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $state.tab) {
                Text("Chat").tag(StatusBar.Tab.chat)
                Text(sessions.activeCount > 0 ? "Agents · \(sessions.activeCount)" : "Agents").tag(StatusBar.Tab.agents)
                Text("Scheduled").tag(StatusBar.Tab.schedules)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Divider()
            Group {
                switch state.tab {
                case .chat: ChatPane(pal: pal, brain: brain, model: model, state: state)
                case .agents:
                    if let id = state.openSession, let s = sessions.session(id) {
                        AgentDetail(session: s, onBack: { state.openSession = nil })
                    } else {
                        AgentList(sessions: sessions, state: state)
                    }
                case .schedules: SchedulePane(scheduler: scheduler, timers: timers)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 400, height: 560)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text("Pal").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { pal.newConversation() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless).help("New conversation")
            Button { pal.openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var statusColor: Color {
        let c = PalSettings.c
        switch model.phase {
        case .listening: return Color(hex: c.colorListening)
        case .thinking: return Color(hex: c.colorThinking)
        case .speaking: return Color(hex: c.colorSpeaking)
        case .error: return .red
        case .idle: return sessions.activeCount > 0 ? Color(hex: c.colorWorking) : .green
        }
    }

    private var subtitle: String {
        guard let p = pal.accounts.answeringProvider else { return "Connect an AI in Settings › Models" }
        let fast = PalSettings.c.fast(for: p)
        return "\(p.title) · \(fast.model) answers · \(sessions.activeCount) working"
    }
}

// MARK: - Chat

private struct ChatPane: View {
    let pal: Pal
    @ObservedObject var brain: Brain
    @ObservedObject var model: PalModel
    @ObservedObject var state: StatusBar.State
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if brain.messages.isEmpty {
                            Text("Ask anything: by voice, or type below.\nBigger jobs get handed to agents and show up under Agents.")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 60)
                        }
                        ForEach(brain.messages) { m in
                            MessageRow(message: m) { id in state.openSession = id; state.tab = .agents }
                                .id(m.id)
                        }
                        if model.phase == .thinking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(model.activity.isEmpty ? "Thinking…" : model.activity.capitalized + "…").font(.caption).foregroundStyle(.secondary)
                            }.id("thinking")
                        }
                    }
                    .padding(14)
                }
                .onAppear { proxy.scrollTo(brain.messages.last?.id, anchor: .bottom) }
                .onChange(of: brain.messages.count) { withAnimation { proxy.scrollTo(brain.messages.last?.id, anchor: .bottom) } }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Ask Pal…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(send)
                Button { pal.toggleListening() } label: {
                    Image(systemName: model.phase == .listening ? "stop.circle.fill" : "mic")
                }
                .buttonStyle(.borderless)
                .help("Talk")
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .onAppear { focused = true }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        pal.ask(text, typed: true)
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    var openAgent: (String) -> Void

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            }
        case .pal, .agent:
            VStack(alignment: .leading, spacing: 5) {
                if message.role == .agent {
                    Button { if let id = message.sessionID { openAgent(id) } } label: {
                        Label("Agent · \(message.source)", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
                Text(message.text).fontWeight(.medium).textSelection(.enabled)
                if !message.detail.isEmpty {
                    MarkdownBlock(text: message.detail, size: 12.5).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .notice:
            Text(message.source.isEmpty ? message.text : "\(message.source): \(message.text)")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Agents

private struct AgentList: View {
    @ObservedObject var sessions: SessionManager
    @ObservedObject var state: StatusBar.State

    var body: some View {
        if sessions.sessions.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.tertiary)
                Text("No agents yet").font(.headline)
                Text("Ask Pal for something bigger, like “research flights to Lisbon in March” or “watch my Claude Code sessions while I'm out”.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(30)
            .frame(maxHeight: .infinity)
        } else {
            List(sessions.sessions) { s in
                AgentRow(session: s).contentShape(Rectangle())
                    .onTapGesture { state.openSession = s.id; sessions.markRead(s.id) }
            }
            .listStyle(.inset)
        }
    }
}

private struct AgentRow: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(status: session.status, unread: session.unread).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(session.title).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    Text(session.updated, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                }
                Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    private var line: String {
        if session.status.isActive { return session.activity.isEmpty ? "Working…" : session.activity.capitalized + "…" }
        return session.summary.isEmpty ? session.status.title : session.summary
    }
}

struct StatusDot: View {
    var status: AgentSession.Status
    var unread: Bool

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: unread ? 2 : 0).frame(width: 12, height: 12))
    }

    private var color: Color {
        switch status {
        case .starting, .working: Color(hex: PalSettings.c.colorWorking)
        case .idle: .green
        case .failed: .red
        case .stopped, .ended: .gray
        }
    }
}

private struct AgentDetail: View {
    @ObservedObject var session: AgentSession
    var onBack: () -> Void
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onBack) { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).font(.headline).lineLimit(1)
                    Text("\(session.status.title) · \(session.provider.title) \(session.model.model) · \(session.model.effort)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if session.status.isActive {
                    Button("Stop") { SessionManager.shared.stop(session.id) }.controlSize(.small)
                }
                Menu {
                    if let id = session.harnessID {
                        Button("Copy \(session.provider.via) session id") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(id, forType: .string)
                        }
                    }
                    Button("Show workspace in Finder") { NSWorkspace.shared.open(Paths.workspace) }
                    Divider()
                    Button("Remove", role: .destructive) { SessionManager.shared.remove(session.id); onBack() }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(session.entries) { e in entry(e).id(e.id) }
                        if session.status.isActive {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(session.activity.isEmpty ? "Working…" : session.activity.capitalized + "…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                }
                .onAppear { proxy.scrollTo(session.entries.last?.id, anchor: .bottom) }
                .onChange(of: session.entries.count) { proxy.scrollTo(session.entries.last?.id, anchor: .bottom) }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Message this agent…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...4)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func entry(_ e: AgentSession.Entry) -> some View {
        switch e.role {
        case .user:
            Text(e.text).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .textSelection(.enabled)
        case .agent:
            let reply = ParsedReply.parse(e.text, final: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(reply.spoken).fontWeight(.medium)
                if !reply.detail.isEmpty { MarkdownBlock(text: reply.detail, size: 12.5) }
            }.textSelection(.enabled)
        case .tool:
            Label(e.text, systemImage: "wrench.and.screwdriver").font(.caption).foregroundStyle(.secondary)
        case .note:
            Text(e.text).font(.caption).foregroundStyle(.secondary).italic()
        }
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        draft = ""
        try? SessionManager.shared.send(session.id, t)
    }
}

// MARK: - Scheduled

struct SchedulePane: View {
    @ObservedObject var scheduler: Scheduler
    @ObservedObject var timers: TimerCenter

    var body: some View {
        if scheduler.jobs.isEmpty && timers.timers.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Nothing scheduled").font(.headline)
                Text("Try “set a 10 minute timer for the pasta” or “every weekday at 9, summarize my calendar”.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(30)
            .frame(maxHeight: .infinity)
        } else {
            List {
                if !timers.timers.isEmpty {
                    Section("Timers & alarms") {
                        ForEach(timers.timers) { t in
                            HStack {
                                Image(systemName: t.isAlarm ? "alarm" : "timer")
                                Text(t.label)
                                Spacer()
                                Text(t.fireDate, style: t.isAlarm ? .time : .timer).monospacedDigit().foregroundStyle(.secondary)
                                Button { timers.cancel(t.id) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                if !scheduler.jobs.isEmpty {
                    Section("Scheduled") {
                        ForEach(scheduler.jobs) { job in ScheduleRow(job: job, scheduler: scheduler) }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

struct ScheduleRow: View {
    let job: ScheduledJob
    let scheduler: Scheduler

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).fontWeight(.medium).lineLimit(1)
                Text("\(job.repeatRule.title) · next \(ToolDates.human(job.nextRun))").font(.caption).foregroundStyle(.secondary)
                Text(job.prompt).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { job.enabled }, set: { scheduler.setEnabled(job.id, $0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            Menu {
                Button("Run now") { scheduler.runNow(job.id) }
                Button("Delete", role: .destructive) { scheduler.remove(job.id) }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private var icon: String {
        switch job.target {
        case .notify: "bell"
        case .newAgent: "sparkles"
        case .session: "alarm"
        }
    }
}
