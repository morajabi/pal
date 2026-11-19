import AppKit
import SwiftUI

/// The menu bar icon. Left click opens Pal's window (chat, agents, schedules); right click shows quick actions.
@MainActor
final class StatusBar: NSObject, NSPopoverDelegate {
    enum Tab: String, CaseIterable { case chat, agents, schedules }

    final class State: ObservableObject {
        @Published var tab: Tab = .chat
        @Published var openSession: String?
    }

    private unowned let pal: Pal
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    let state = State()

    init(pal: Pal) {
        self.pal = pal
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 400, height: 560)
        popover.contentViewController = NSHostingController(rootView: HomeView(pal: pal, state: state))
        refresh()
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            guard let event = NSApp.currentEvent else { return }
            popUpMenu(with: event, in: sender)
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover(tab: nil, sessionID: nil) }
    }

    func showPopover(tab: Tab?, sessionID: String?) {
        if let tab { state.tab = tab }
        if let sessionID { state.openSession = sessionID; state.tab = .agents }
        guard let button = item.button else { return }
        NSApp.activate()
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        pal.popoverOpened()
    }

    func refresh() {
        let m = pal.model
        let name: String
        switch m.phase {
        case .listening: name = "waveform"
        case .thinking: name = "ellipsis"
        case .speaking: name = "speaker.wave.2.fill"
        case .error: name = "exclamationmark.circle"
        case .idle:
            if pal.accounts.detected && pal.accounts.answeringProvider == nil { name = "circle.dotted" }
            else if m.attention { name = "circle.badge.exclamationmark" }
            else if m.agentsWorking > 0 { name = "circle.circle" }
            else { name = "circle.fill" }
        }
        let small = m.phase == .idle && name == "circle.fill"
        let config = NSImage.SymbolConfiguration(pointSize: small ? 8 : 13, weight: .semibold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Pal")?.withSymbolConfiguration(config)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = m.agentsWorking > 0 ? "Pal · \(m.agentsWorking) agent\(m.agentsWorking == 1 ? "" : "s") working" : "Pal"
    }

    // MARK: Right-click menu (also used by the dot)

    func popUpMenu(with event: NSEvent, in view: NSView) {
        NSMenu.popUpContextMenu(buildMenu(), with: event, for: view)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let c = PalSettings.c
        add(menu, pal.model.phase == .listening ? "Send" : "Ask Pal", c.toggleShortcut == .off ? "" : c.toggleShortcut.title) { [weak self] in self?.pal.toggleListening() }
        add(menu, "Open Pal…") { [weak self] in self?.showPopover(tab: .chat, sessionID: nil) }
        add(menu, "New Conversation") { [weak self] in self?.pal.newConversation() }
        menu.addItem(.separator())

        let agents = SessionManager.shared.sessions.prefix(8)
        if !agents.isEmpty {
            let header = NSMenuItem.sectionHeader(title: "Agents")
            menu.addItem(header)
            for s in agents {
                let mi = add(menu, "\(s.title) — \(s.status.title)") { [weak self] in self?.showPopover(tab: .agents, sessionID: s.id) }
                mi.image = NSImage(systemSymbolName: s.status.isActive ? "circle.dotted" : (s.unread ? "circle.fill" : "circle"), accessibilityDescription: nil)
            }
            menu.addItem(.separator())
        }

        let speak = add(menu, "Speak Replies") { PalSettings.shared.config.speakReplies.toggle() }
        speak.state = c.speakReplies ? .on : .off
        let dot = add(menu, "Show Floating Dot") { PalSettings.shared.config.showDot.toggle() }
        dot.state = c.showDot ? .on : .off
        if pal.holdToTalkNeedsPermission {
            add(menu, "Allow Hold to Talk…") { HoldToTalk.openSettings() }
        }
        menu.addItem(.separator())
        add(menu, "Settings…", ",") { [weak self] in self?.pal.openSettings() }
        add(menu, "Quit Pal", "q") { NSApp.terminate(nil) }
        return menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ key: String = "", action: @escaping () -> Void) -> NSMenuItem {
        let mi = ClosureMenuItem(title: title, action: action)
        if key.count == 1 { mi.keyEquivalent = key } else if !key.isEmpty { mi.title += "    \(key)" }
        menu.addItem(mi)
        return mi
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}
