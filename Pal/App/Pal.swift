import AppKit
import Combine
import ServiceManagement

/// Wires it all together: keys → mic → brain → voice + card, and agent updates back to the user.
@MainActor
final class Pal: NSObject {
    private enum ListenMode { case hold, toggle }

    let model = PalModel()
    let accounts = Accounts()
    lazy var brain = Brain(accounts: accounts)
    let sessions = SessionManager.shared
    private let listener = Listener()
    let speaker = Speaker()
    private let hold = HoldToTalk()

    private var dot: DotPanel!
    private var card: CardPanel!
    private var statusBar: StatusBar!

    private var toggleHotKey: GlobalHotKey?
    private var escHotKey: GlobalHotKey?

    private var listenMode: ListenMode?
    private var startTask: Task<Void, Error>?
    private var silenceTimer: Timer?
    private var listenStarted = Date()
    private var lastTranscriptChange = Date()

    private var requestID = 0
    private var spokenThisTurn = false
    private var hideCardWork: DispatchWorkItem?
    private var autoHideWork: DispatchWorkItem?
    private var idleResetTimer: Timer?
    private var permissionPoll: Timer?
    private var alarmRepeats: Timer?
    private var bag = Set<AnyCancellable>()

    static private(set) weak var shared: Pal?

    // MARK: Lifecycle

    func start() {
        Pal.shared = self
        Paths.bootstrap()
        MemoryStore.shared.reload()
        SkillStore.shared.reload()
        registerTools()
        MCPServer.shared.start()

        dot = DotPanel(model: model)
        dot.onClick = { [weak self] in self?.toggleListening() }
        dot.onRightClick = { [weak self] event, view in self?.statusBar.popUpMenu(with: event, in: view) }
        card = CardPanel(model: model, actions: CardActions(
            close: { [weak self] in self?.dismiss() },
            play: { [weak self] in self?.toggleCardSpeech() },
            copy: { [weak self] in self?.copyCard() },
            open: { [weak self] in self?.openCardSession() }))
        statusBar = StatusBar(pal: self)
        if PalSettings.c.showDot { dot.orderFrontRegardless() }

        wireVoice()
        wireAgents()
        applyShortcuts()
        observeSettings()

        sessions.accounts = accounts
        sessions.load()
        Scheduler.shared.start()
        TimerCenter.shared.start()
        Permissions.shared.refresh()

        accounts.onChange = { [weak self] in self?.statusBar.refresh() }
        accounts.onCodexLogin = { [weak self] ok, error in
            guard let self else { return }
            if ok {
                self.showNotice("ChatGPT is connected.", detail: "Ask away. Pick models in Settings › Models.")
                self.brain.configChanged()
                self.brain.warmUp()
            } else {
                self.showError(error ?? "ChatGPT sign-in didn't finish.")
            }
        }
        accounts.detect { [weak self] in
            guard let self else { return }
            self.brain.warmUp()
            DebugSnapshots.runIfRequested(pal: self)
            if let q = UserDefaults.standard.string(forKey: "debugAsk"), !q.isEmpty {
                self.ask(q, typed: true)
                return
            }
            if !UserDefaults.standard.bool(forKey: "hasOnboarded") || self.accounts.answeringProvider == nil {
                UserDefaults.standard.set(true, forKey: "hasOnboarded")
                self.showWelcome()
            }
        }

        // Ask for the mic and fetch the speech model up front so the first question is instant.
        Task { @MainActor in
            if await Listener.requestMicAccess() { try? await self.listener.prepare() }
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.repositionPanels() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if PalSettings.c.dotScreen == .activeScreen { self?.repositionPanels() }
            }
        }
    }

    func shutdown() {
        listener.cancel()
        speaker.stop()
        brain.reset()
        sessions.shutdown()
    }

    private func registerTools() {
        let r = ToolRegistry.shared
        r.register(PalCoreTools.all)
        r.register(MemoryTools.all)
        r.register(SkillTools.all)
        r.register(MacDataTools.all)
        r.register(SystemTools.all)
        r.register(ComputerUse.tools)
        r.register(ShellTools.all)
    }

    private func wireVoice() {
        listener.onLevel = { [weak self] level in
            guard let self, self.listenMode != nil else { return }
            self.model.level = level
        }
        listener.onTranscript = { [weak self] text in
            guard let self else { return }
            if text != self.model.liveTranscript { self.lastTranscriptChange = Date() }
            self.model.liveTranscript = text
        }
        speaker.onSpeakingChanged = { [weak self] speaking in
            guard let self else { return }
            self.model.cardSpeaking = speaking
            if speaking, self.model.phase == .idle { self.model.phase = .speaking }
            if !speaking, self.model.phase == .speaking { self.model.phase = .idle }
            self.updateEscape()
            self.statusBar.refresh()
        }
        hold.onBegin = { [weak self] in self?.beginListening(.hold) }
        hold.onEnd = { [weak self] in
            guard let self, self.listenMode == .hold else { return }
            self.endListening()
        }
    }

    private func observeSettings() {
        PalSettings.shared.$config
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] c in
                guard let self else { return }
                self.applyShortcuts()
                if c.showDot { self.dot.orderFrontRegardless() } else { self.dot.orderOut(nil) }
                self.repositionPanels()
                self.brain.configChanged()
            }
            .store(in: &bag)
    }

    private func repositionPanels() {
        dot.reposition()
        card.reposition()
    }

    // MARK: Listening

    func toggleListening() {
        if listenMode != nil { endListening() } else { beginListening(.toggle) }
    }

    private func beginListening(_ mode: ListenMode) {
        guard listenMode == nil else { return }
        speaker.stop()
        stopAlarm()
        if model.phase == .thinking { cancelRequest() }
        listenMode = mode
        model.phase = .listening
        model.level = 0
        model.liveTranscript = ""
        listenStarted = Date()
        lastTranscriptChange = Date()
        Notifier.play(.start)
        updateEscape()
        statusBar.refresh()

        startTask = Task { @MainActor in
            do {
                try await self.listener.start()
            } catch {
                guard self.listenMode != nil else { return }
                self.listenMode = nil
                self.silenceTimer?.invalidate()
                self.showError(error.localizedDescription)
                throw error
            }
        }
        if mode == .toggle {
            silenceTimer?.invalidate()
            silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkSilence() }
            }
        }
    }

    /// Hands-free stop for the press-once shortcut: stop after a pause.
    private func checkSilence() {
        guard listenMode == .toggle else { silenceTimer?.invalidate(); return }
        let now = Date()
        let heard = !model.liveTranscript.isEmpty
        if !heard && now.timeIntervalSince(listenStarted) > 8 { cancelListening(); return }
        if heard && now.timeIntervalSince(lastTranscriptChange) > PalSettings.c.autoSendPause && model.level < 0.3 { endListening(); return }
        if now.timeIntervalSince(listenStarted) > 120 { endListening() }
    }

    private func endListening() {
        guard listenMode != nil else { return }
        listenMode = nil
        silenceTimer?.invalidate()
        model.level = 0
        model.phase = .thinking
        hideCard() // the previous answer goes away once you've finished asking
        statusBar.refresh()

        let startTask = self.startTask
        Task { @MainActor in
            _ = try? await startTask?.value
            let text = await self.listener.stop()
            guard self.model.phase == .thinking, self.listenMode == nil else { return }
            if text.isEmpty { self.blink() } else { self.ask(text, typed: false) }
        }
    }

    private func cancelListening() {
        guard listenMode != nil else { return }
        listenMode = nil
        silenceTimer?.invalidate()
        startTask?.cancel()
        listener.cancel()
        model.level = 0
        model.phase = .idle
        updateEscape()
        statusBar.refresh()
    }

    // MARK: Asking

    func ask(_ text: String, typed: Bool) {
        requestID += 1
        let rid = requestID
        spokenThisTurn = false
        speaker.stop()
        model.cardKind = .answer
        model.caption = "“\(text)”"
        model.headline = ""
        model.detail = ""
        model.footnote = ""
        model.activity = ""
        model.cardSessionID = nil
        model.phase = .thinking
        if typed { hideCard() }
        updateEscape()
        idleResetTimer?.invalidate()
        let started = Date()
        let provider = brain.providerID

        brain.ask(text, typed: typed, onText: { [weak self] reply in
            guard let self, rid == self.requestID else { return }
            self.model.headline = reply.spoken
            self.model.detail = reply.detail
            self.model.activity = ""
            if !reply.spoken.isEmpty { self.showCard() }
            if reply.spokenComplete { self.speakOnce(reply.spoken, auto: !typed) }
        }, onTool: { [weak self] name in
            guard let self, rid == self.requestID else { return }
            self.model.activity = name
            if self.model.cardVisible == false && self.model.headline.isEmpty {
                self.model.headline = ""
                self.showCard()
            }
        }, completion: { [weak self] result in
            guard let self, rid == self.requestID else { return }
            switch result {
            case .success(let reply):
                self.model.headline = reply.spoken
                self.model.detail = reply.detail
                self.model.activity = ""
                let secs = Date().timeIntervalSince(started)
                self.model.footnote = "\(provider?.title ?? "") · \(String(format: "%.1fs", secs))"
                self.showCard()
                self.speakOnce(reply.spoken, auto: !typed)
                self.model.phase = self.speaker.isSpeaking ? .speaking : .idle
                self.scheduleIdleReset()
                self.armAutoHide()
                log.notice("answer in \(secs, format: .fixed(precision: 1))s: \(reply.spoken, privacy: .public)")
            case .failure(let error):
                self.showError(error.localizedDescription)
            }
            self.updateEscape()
            self.statusBar.refresh()
        })
    }

    /// Speaks the short answer when spoken replies are on (only for spoken questions).
    private func speakOnce(_ text: String, auto: Bool) {
        guard !spokenThisTurn, auto, PalSettings.c.speakReplies else { return }
        spokenThisTurn = true
        if speaker.speak(text), model.phase == .thinking { model.phase = .speaking }
    }

    private func cancelRequest() {
        requestID += 1
        brain.cancel()
    }

    private func scheduleIdleReset() {
        idleResetTimer?.invalidate()
        let minutes = PalSettings.c.conversationResetMinutes
        guard minutes > 0 else { return }
        idleResetTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.phase == .idle, self.listenMode == nil else { return }
                self.brain.reset()
            }
        }
    }

    // MARK: Agents, timers, schedules → the user

    private func wireAgents() {
        sessions.onUpdate = { [weak self] s, update in
            guard let self else { return }
            let c = PalSettings.c
            switch update {
            case .finished(let reply):
                self.brain.append(ChatMessage(role: .agent, text: reply.spoken, detail: reply.detail, sessionID: s.id, source: s.title))
                guard c.notifyWhenAgentsFinish else { return }
                self.presentAgent(s, headline: reply.spoken, detail: reply.detail, urgent: false, kind: .agent)
            case .failed(let message):
                self.brain.append(ChatMessage(role: .agent, text: "Couldn't finish: \(message)", sessionID: s.id, source: s.title))
                self.presentAgent(s, headline: "“\(s.title)” stopped with a problem.", detail: message, urgent: false, kind: .error)
            case .notify(let message, let urgent):
                self.brain.append(ChatMessage(role: .agent, text: message, sessionID: s.id, source: s.title))
                self.presentAgent(s, headline: message, detail: "", urgent: urgent, kind: .agent)
                Notifier.post(title: "Pal · \(s.title)", body: message, sound: urgent)
            }
        }
        sessions.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.model.agentsWorking = self.sessions.activeCount
                    self.statusBar.refresh()
                }
            }
            .store(in: &bag)

        TimerCenter.shared.onFire = { [weak self] t in
            guard let self else { return }
            self.model.cardKind = .timer
            self.model.caption = t.isAlarm ? "Alarm" : "Timer"
            self.model.headline = t.isAlarm ? "\(t.label)" : "\(t.label) timer is done."
            self.model.detail = ""
            self.model.footnote = ToolDates.human(t.fireDate)
            self.model.activity = ""
            self.model.cardSessionID = nil
            self.showCard()
            self.ringAlarm()
            Notifier.post(title: t.isAlarm ? "Alarm" : "Timer done", body: t.label)
            if PalSettings.c.speakReplies { self.speaker.speak(self.model.headline) }
        }
        Scheduler.shared.onNotify = { [weak self] job in
            guard let self else { return }
            self.brain.append(ChatMessage(role: .notice, text: job.prompt, source: job.title))
            self.model.cardKind = .notice
            self.model.caption = "Reminder · \(job.title)"
            self.model.headline = job.prompt
            self.model.detail = ""
            self.model.footnote = job.repeatRule.title
            self.model.activity = ""
            self.model.cardSessionID = nil
            self.showCard()
            Notifier.play(.alert)
            Notifier.post(title: job.title, body: job.prompt)
            if PalSettings.c.speakReplies { self.speaker.speak(job.prompt) }
        }
    }

    private func presentAgent(_ s: AgentSession, headline: String, detail: String, urgent: Bool, kind: CardKind) {
        // Don't talk over the user.
        if listenMode != nil || model.phase == .thinking {
            model.attention = true
            if !urgent { Notifier.post(title: "Pal · \(s.title)", body: headline, sound: false) }
            return
        }
        model.cardKind = kind
        model.caption = "Agent · \(s.title)"
        model.headline = headline
        model.detail = detail
        model.footnote = "\(s.provider.title) · \(s.model.model)"
        model.activity = ""
        model.cardSessionID = s.id
        model.attention = true
        showCard()
        Notifier.play(urgent ? .alert : .done)
        if PalSettings.c.speakAgentUpdates || (urgent && PalSettings.c.speakReplies) { speaker.speak(headline) }
        armAutoHide()
    }

    private func ringAlarm() {
        alarmRepeats?.invalidate()
        var count = 0
        NSSound(named: "Glass")?.play()
        alarmRepeats = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { [weak self] t in
            count += 1
            NSSound(named: "Glass")?.play()
            if count >= 8 { t.invalidate(); self?.alarmRepeats = nil }
        }
    }

    private func stopAlarm() {
        alarmRepeats?.invalidate()
        alarmRepeats = nil
    }

    // MARK: Card

    private func showCard() {
        hideCardWork?.cancel()
        card.show()
        if !model.cardVisible { model.cardVisible = true }
        updateEscape()
    }

    private func hideCard() {
        autoHideWork?.cancel()
        guard model.cardVisible else { return }
        model.cardVisible = false
        speaker.stop()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.cardVisible else { return }
            self.card.orderOut(nil)
        }
        hideCardWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        updateEscape()
    }

    private func armAutoHide() {
        autoHideWork?.cancel()
        let secs = PalSettings.c.cardAutoHide.rawValue
        guard secs > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.phase == .idle, !self.speaker.isSpeaking else { return }
            self.hideCard()
        }
        autoHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(secs), execute: work)
    }

    /// Esc: stop whatever is happening and tidy away.
    func dismiss() {
        if listenMode != nil { cancelListening() }
        if model.phase == .thinking { cancelRequest() }
        speaker.stop()
        stopAlarm()
        if let id = model.cardSessionID { sessions.markRead(id) }
        model.attention = false
        if model.phase != .listening { model.phase = .idle }
        hideCard()
        updateEscape()
        statusBar.refresh()
    }

    private func toggleCardSpeech() {
        if speaker.isSpeaking { speaker.stop(); return }
        let text = model.detail.isEmpty ? model.headline : "\(model.headline). \(ParsedReply.plain(model.detail))"
        speaker.speak(text, force: true)
    }

    private func copyCard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.copyText, forType: .string)
    }

    private func openCardSession() {
        guard let id = model.cardSessionID else { return }
        sessions.markRead(id)
        statusBar.showPopover(tab: .agents, sessionID: id)
    }

    func showError(_ message: String) {
        log.error("error: \(message, privacy: .public)")
        requestID += 1
        model.phase = .error
        model.cardKind = .error
        model.caption = ""
        model.headline = message
        model.detail = ""
        model.footnote = ""
        model.activity = ""
        model.cardSessionID = nil
        showCard()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.model.phase == .error { self?.model.phase = .idle }
        }
        statusBar.refresh()
    }

    func showNotice(_ headline: String, detail: String) {
        model.cardKind = .notice
        model.caption = ""
        model.headline = headline
        model.detail = detail
        model.footnote = ""
        model.activity = ""
        model.cardSessionID = nil
        showCard()
    }

    private func blink() {
        model.phase = .error
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if self?.model.phase == .error { self?.model.phase = .idle }
            self?.updateEscape()
        }
    }

    func showWelcome() {
        let c = PalSettings.c
        var lines: [String] = []
        if c.holdKey != .off { lines.append("- **Hold \(c.holdKey.title)**, talk, let go") }
        if c.toggleShortcut != .off { lines.append("- Or press **\(c.toggleShortcut.title)**, talk, then pause") }
        lines.append("- Or click the dot, or type in the menu bar. **Esc** hides answers.")
        lines.append("- Ask quick things, or hand off bigger jobs: *“watch my Claude sessions for 2 hours”*.")
        if let id = accounts.answeringProvider {
            lines.append("\nAnswering with **\(id.title)**. Models, tools, voice and looks are in **Settings**.")
        } else {
            lines.append("\n**Connect an AI first:** Settings › Models.")
        }
        showNotice("Hi, I'm Pal.", detail: lines.joined(separator: "\n"))
    }

    // MARK: Keys

    func applyShortcuts() {
        let c = PalSettings.c
        toggleHotKey = nil
        if let k = c.toggleShortcut.carbon {
            toggleHotKey = GlobalHotKey(keyCode: k.keyCode, modifiers: k.modifiers) { [weak self] in
                MainActor.assumeIsolated { self?.toggleListening() }
            }
        }
        hold.key = c.holdKey
        guard c.holdKey != .off, !hold.isRunning else { return }
        if !hold.start() {
            HoldToTalk.requestPermission()
            permissionPoll?.invalidate()
            permissionPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self else { t.invalidate(); return }
                    if self.hold.start() { t.invalidate(); self.statusBar.refresh() }
                }
            }
        }
    }

    var holdToTalkNeedsPermission: Bool {
        PalSettings.c.holdKey != .off && !hold.isRunning
    }

    /// Esc is only captured while Pal has something on screen, so it never steals it from your apps.
    private func updateEscape() {
        let needed = listenMode != nil || model.cardVisible || model.phase == .thinking || model.phase == .speaking
        if needed && escHotKey == nil {
            escHotKey = GlobalHotKey(keyCode: 53, modifiers: 0) { [weak self] in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        } else if !needed {
            escHotKey = nil
        }
    }

    // MARK: Windows & actions

    func openSettings(_ page: SettingsPage? = nil) {
        SettingsWindow.show(pal: self, page: page)
    }

    func newConversation() {
        dismiss()
        brain.reset()
        brain.append(ChatMessage(role: .notice, text: "New conversation"))
    }

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            showError("Couldn't change Launch at Login: \(error.localizedDescription)")
        }
    }

    func popoverOpened() {
        model.attention = false
    }
}
