import AppKit

@main
enum PalMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN) // a dead CLI must not take the app down

        // The same binary doubles as the stdio MCP bridge that Claude Code / Codex launch.
        if CommandLine.arguments.contains("--mcp-bridge") {
            MCPBridge.run(arguments: CommandLine.arguments)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pal: Pal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        pal = Pal()
        pal?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pal?.shutdown()
    }

    /// pal://ask?q=…  (also handy from Raycast, Shortcuts, scripts)
    func application(_ application: NSApplication, open urls: [URL]) {
        let schemes = ((Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]])?.first?["CFBundleURLSchemes"] as? [String]) ?? ["pal"]
        for url in urls where schemes.contains(url.scheme ?? "") {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let q = items.first { $0.name == "q" || $0.name == "text" }?.value ?? ""
            switch url.host {
            case "ask" where !q.isEmpty: pal?.ask(q, typed: true)
            case "listen": pal?.toggleListening()
            case "settings": pal?.openSettings()
            default: break
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        pal?.openSettings()
        return false
    }
}
