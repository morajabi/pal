import AppKit
import SwiftUI

/// Testing aid: `Pal.app --args -debugSnapshots /some/folder` renders the settings pages and the
/// menu bar window to PNGs without needing the screen (works while the Mac is locked).
@MainActor
enum DebugSnapshots {
    static func runIfRequested(pal: Pal) {
        guard let dir = UserDefaults.standard.string(forKey: "debugSnapshots") else { return }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let selection = SettingsSelection()
            let settingsView = NSHostingView(rootView: SettingsView(pal: pal, selection: selection))
            let w = offscreenWindow(settingsView, size: NSSize(width: 860, height: 640))
            for page in SettingsPage.allCases {
                selection.page = page
                try? await Task.sleep(for: .milliseconds(700))
                save(w.contentView!, to: out.appendingPathComponent("settings-\(page.rawValue).png"))
            }
            let state = StatusBar.State()
            let home = NSHostingView(rootView: HomeView(pal: pal, state: state))
            let hw = offscreenWindow(home, size: NSSize(width: 400, height: 560))
            for tab in StatusBar.Tab.allCases {
                state.tab = tab
                try? await Task.sleep(for: .milliseconds(600))
                save(hw.contentView!, to: out.appendingPathComponent("home-\(tab.rawValue).png"))
            }
            if let s = SessionManager.shared.sessions.first {
                state.tab = .agents
                state.openSession = s.id
                try? await Task.sleep(for: .milliseconds(600))
                save(hw.contentView!, to: out.appendingPathComponent("home-agent-detail.png"))
            }
            log.notice("snapshots written to \(out.path, privacy: .public)")
        }
    }

    private static func offscreenWindow(_ view: NSView, size: NSSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height),
                         styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.contentView = view
        w.isReleasedWhenClosed = false
        w.orderBack(nil)
        view.layoutSubtreeIfNeeded()
        return w
    }

    private static func save(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
