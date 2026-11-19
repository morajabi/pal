import SwiftUI

// MARK: - Models

struct ModelsPage: View {
    @ObservedObject var accounts: Accounts
    @ObservedObject var settings: PalSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Accounts", footer: "Pal uses AI you already have: your Claude Code and Codex sign-ins (Claude and ChatGPT subscriptions). Nothing is stored by Pal.") {
                accountRow(.claude, accounts.claude)
                accountRow(.codex, accounts.codex)
                SettingsRow(title: "") {
                    Button("Check Again") { accounts.detect() }
                }
            }
            SettingsSection(title: "Who does what", footer: "A fast model answers first. When a request needs real work, it hands off to a more capable agent that reports back. You can also ask for a specific model out loud (“use Astra for this”).") {
                SettingsRow(title: "Answers with") {
                    Picker("", selection: $settings.config.provider) {
                        ForEach(ProviderPreference.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                SettingsRow(title: "Agents run on", note: "Automatic uses the same one that answers.") {
                    Picker("", selection: $settings.config.agentProvider) {
                        ForEach(ProviderPreference.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }
            }
            SettingsSection(title: "Claude") {
                modelRow("Quick answers", $settings.config.claudeFast, Accounts.claudeModels)
                modelRow("Agents", $settings.config.claudeAgent, Accounts.claudeModels)
            }
            SettingsSection(title: "ChatGPT") {
                modelRow("Quick answers", $settings.config.codexFast, accounts.codexModels)
                modelRow("Agents", $settings.config.codexAgent, accounts.codexModels)
            }
        }
    }

    private func accountRow(_ p: ProviderID, _ s: Accounts.Status) -> some View {
        SettingsRow(title: "\(p.title) via \(p.via)", note: s.signedIn ? s.account : (s.installed ? "Installed, not signed in" : "Not installed")) {
            HStack {
                StatePill(text: s.signedIn ? "Connected" : (s.installed ? "Sign in needed" : "Missing"), good: s.signedIn)
                if !s.signedIn {
                    Button(s.installed ? (p == .claude ? "Sign In…" : "Connect ChatGPT…") : "Get \(p.via)…") {
                        if p == .claude { accounts.signInToClaude() } else { accounts.connectChatGPT() }
                    }
                }
            }
        }
    }

    private func modelRow(_ title: String, _ choice: Binding<ModelChoice>, _ options: [ModelOption]) -> some View {
        let opts = options.contains { $0.id == choice.wrappedValue.model } ? options
            : options + [ModelOption(id: choice.wrappedValue.model, title: choice.wrappedValue.model, detail: "", efforts: ["low", "medium", "high"])]
        let efforts = opts.first { $0.id == choice.wrappedValue.model }?.efforts ?? ["low", "medium", "high"]
        return SettingsRow(title: title) {
            HStack {
                Picker("", selection: choice.model) {
                    ForEach(opts) { o in Text(o.detail.isEmpty ? o.title : "\(o.title) · \(o.detail)").tag(o.id) }
                }.labelsHidden().fixedSize()
                Picker("", selection: choice.effort) {
                    ForEach(efforts, id: \.self) { Text($0.capitalized).tag($0) }
                }.labelsHidden().fixedSize()
            }
        }
    }
}

// MARK: - Agents

struct AgentsPage: View {
    @ObservedObject var accounts: Accounts
    @ObservedObject var settings: PalSettings
    @State private var userServers: [(String, String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "What agents can do", footer: "With full access, agents work like you at your Mac: run commands, edit files, use apps and the browser, without asking each time. They still check with you before sending messages, buying, or deleting your things.") {
                SettingsRow(title: "Full access", note: "Off: agents can read and edit only their workspace, and can't run commands without approval.") {
                    Toggle("", isOn: $settings.config.agentsFullAccess).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "At most working at once") {
                    Stepper("\(settings.config.maxConcurrentAgents)", value: $settings.config.maxConcurrentAgents, in: 1...10)
                }
                SettingsRow(title: "Tell me when an agent finishes") {
                    Toggle("", isOn: $settings.config.notifyWhenAgentsFinish).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Quick answers use my MCP servers", note: "Slower to start. Agents always get them.") {
                    Toggle("", isOn: $settings.config.quickAnswersUseUserMCP).toggleStyle(.switch).labelsHidden()
                }
            }
            SettingsSection(title: "Workspace", footer: "Agents work in the workspace folder. Memory and skills live next to it.") {
                SettingsRow(title: "Pal folder") {
                    HStack {
                        TextField("", text: $settings.config.homeFolder).frame(width: 200)
                        Button("Show") { NSWorkspace.shared.open(Paths.home) }
                    }
                }
            }
            SettingsSection(title: "Browser", footer: "OpenCode Browse (from Anomaly) lets agents work in the Chrome you already use, signed in. Playwright opens its own separate browser.") {
                SettingsRow(title: "Browser for agents") {
                    Picker("", selection: $settings.config.browserTool) {
                        ForEach(BrowserTool.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                switch settings.config.browserTool {
                case .opencodeBrowse:
                    SettingsRow(title: "OpenCode Browse", note: accounts.browsePath ?? "Install it with its Chrome extension, then click Check Again.") {
                        HStack {
                            StatePill(text: accounts.browsePath == nil ? "Not installed" : "Ready", good: accounts.browsePath != nil)
                            if accounts.browsePath == nil { Button("Install…") { NSWorkspace.shared.open(ExternalTools.browseInstallURL) } }
                            Button("Check Again") { accounts.detect() }
                        }
                    }
                case .playwright:
                    SettingsRow(title: "Playwright MCP", note: "Runs with npx @playwright/mcp.") {
                        StatePill(text: accounts.npxPath == nil ? "Needs Node.js" : "Ready", good: accounts.npxPath != nil)
                    }
                case .off:
                    EmptyView()
                }
            }
            SettingsSection(title: "Your own MCP servers", footer: "Agents load the MCP servers, skills and settings you set up in Claude Code and Codex, on top of Pal's tools.") {
                if userServers.isEmpty {
                    SettingsRow(title: "None found in ~/.claude.json or ~/.codex/config.toml") { EmptyView() }
                }
                ForEach(userServers, id: \.0) { name, source in
                    SettingsRow(title: name) { Text(source).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .onAppear { userServers = Self.userMCPServers() }
    }

    static func userMCPServers() -> [(String, String)] {
        var out: [(String, String)] = []
        let home = NSHomeDirectory()
        if let data = FileManager.default.contents(atPath: "\(home)/.claude.json"),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let servers = json["mcpServers"] as? [String: Any] {
            out += servers.keys.sorted().map { ($0, "Claude Code") }
        }
        if let toml = try? String(contentsOfFile: "\(home)/.codex/config.toml", encoding: .utf8) {
            for line in toml.components(separatedBy: "\n") {
                if let m = line.firstMatch(of: /^\[mcp_servers\.("?)([^\]".]+)\1\]/) {
                    let name = String(m.2)
                    if !out.contains(where: { $0.0 == name }) { out.append((name, "Codex")) }
                    else if let i = out.firstIndex(where: { $0.0 == name }) { out[i].1 = "Claude Code + Codex" }
                }
            }
        }
        return out
    }
}

// MARK: - Tools

struct ToolsPage: View {
    @ObservedObject var settings: PalSettings
    @ObservedObject var permissions: Permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pal's own tools, available to the quick answerer and to agents. Turn off anything you don't want used. Agents also get everything from Claude Code or Codex itself (shell, files, web) and your MCP servers.")
                .font(.callout).foregroundStyle(.secondary).padding(.bottom, 16)
            ForEach(ToolCategory.allCases) { cat in
                let tools = ToolRegistry.shared.tools(in: cat)
                if !tools.isEmpty {
                    SettingsSection(title: cat.title) {
                        if let perm = cat.permission {
                            let st = permissions.state(of: perm)
                            SettingsRow(title: "Needs \(perm.title)", note: perm.why) {
                                HStack {
                                    StatePill(text: st.title, good: st == .granted)
                                    if st != .granted { Button("Allow…") { permissions.request(perm) } }
                                }
                            }
                        }
                        ForEach(tools, id: \.name) { tool in
                            SettingsRow(title: tool.title, note: (tool.tiers == [.agent] ? "Agents only · " : "") + Self.firstSentence(tool.description)) {
                                Toggle("", isOn: Binding(
                                    get: { settings.config.isToolEnabled(tool.name) },
                                    set: { on in
                                        var d = Set(settings.config.disabledTools)
                                        if on { d.remove(tool.name) } else { d.insert(tool.name) }
                                        settings.config.disabledTools = d.sorted()
                                    })).toggleStyle(.switch).labelsHidden()
                            }
                        }
                    }
                }
            }
        }
        .onAppear { permissions.refresh() }
    }

    static func firstSentence(_ s: String) -> String {
        guard let r = s.range(of: ". ") else { return s }
        return String(s[..<r.lowerBound]) + "."
    }
}

// MARK: - Permissions

struct PermissionsPage: View {
    @ObservedObject var permissions: Permissions
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("macOS asks once for each of these. Everything Pal's agents do runs through Pal, so allowing it here covers them too.")
                .font(.callout).foregroundStyle(.secondary).padding(.bottom, 16)
            SettingsSection(title: "Permissions") {
                ForEach(PermissionKind.allCases) { k in
                    let st = permissions.state(of: k)
                    SettingsRow(title: k.title, note: k.why) {
                        HStack {
                            StatePill(text: st.title, good: st == .granted)
                            if st != .granted {
                                Button(st == .denied ? "Open Settings…" : "Allow…") { permissions.request(k) }
                            }
                        }
                    }
                }
            }
            Button("Check Again") { permissions.refresh() }
        }
        .onAppear { permissions.refresh() }
        .onReceive(timer) { _ in permissions.refresh() }
    }
}

// MARK: - Memory

struct MemoryPage: View {
    @ObservedObject var settings: PalSettings
    @ObservedObject var store: MemoryStore
    @State private var newTitle = ""
    @State private var newBody = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Memory", footer: "Pal keeps a small memory of lasting facts about you as plain markdown files in \(Paths.memory.path). Edit or delete them freely.") {
                SettingsRow(title: "Use memory") {
                    Toggle("", isOn: $settings.config.memoryEnabled).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Remember things on its own", note: "Off: Pal only saves when you say “remember…”.") {
                    Toggle("", isOn: $settings.config.autoRemember).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Folder") {
                    Button("Show in Finder") { NSWorkspace.shared.open(Paths.memory) }
                }
            }
            SettingsSection(title: "Add a memory") {
                TextField("Title, e.g. “Coffee order”", text: $newTitle).padding(.vertical, 6)
                TextField("What to remember", text: $newBody, axis: .vertical).lineLimit(2...4).padding(.vertical, 6)
                HStack {
                    Spacer()
                    Button("Save") {
                        store.save(title: newTitle, body: newBody)
                        newTitle = ""; newBody = ""
                    }.disabled(newTitle.isEmpty || newBody.isEmpty)
                }.padding(.vertical, 6)
            }
            SettingsSection(title: store.items.isEmpty ? "Nothing remembered yet" : "\(store.items.count) memories") {
                ForEach(store.items) { item in
                    SettingsRow(title: item.title, note: item.body) {
                        Button(role: .destructive) { store.delete(item.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .onAppear { store.reload() }
    }
}

// MARK: - Skills

struct SkillsPage: View {
    @ObservedObject var store: SkillStore
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Skills", footer: "A skill is a SKILL.md file with instructions for a kind of task (“how I like trip plans”, “our deploy checklist”). Pal reads the matching skill before doing that work. Agents also use your own Claude Code and Codex skills.") {
                SettingsRow(title: "Folder", note: Paths.skills.path) {
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.open(Paths.skills) }
                        Button("Reload") { store.reload() }
                    }
                }
                SettingsRow(title: "New skill") {
                    HStack {
                        TextField("Name", text: $newName).frame(width: 180)
                        Button("Create") {
                            let file = store.create(name: newName)
                            newName = ""
                            NSWorkspace.shared.open(file)
                        }.disabled(newName.isEmpty)
                    }
                }
            }
            SettingsSection(title: store.skills.isEmpty ? "No skills yet" : "\(store.skills.count) skills") {
                ForEach(store.skills) { s in
                    SettingsRow(title: s.name, note: s.summary) {
                        Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: s.path)) }
                    }
                }
            }
        }
        .onAppear { store.reload() }
    }
}

// MARK: - Schedules

struct SchedulesPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask Pal to schedule things: “every weekday at 9, brief me on my calendar”, “check the build every 30 minutes”, “remind me to stretch every hour”. Agents also use wake-ups to keep an eye on things while you're away.")
                .font(.callout).foregroundStyle(.secondary)
            SchedulePane(scheduler: Scheduler.shared, timers: TimerCenter.shared)
                .frame(minHeight: 360)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
