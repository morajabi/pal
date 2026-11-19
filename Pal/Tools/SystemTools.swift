import AppKit

/// Apps, Shortcuts, AppleScript, volume, clipboard, media: the Siri-style odds and ends.
enum SystemTools {
    @MainActor
    static var all: [PalTool] {
        [
            PalTool("open_app", "Open an app", category: .apps,
                    description: "Open (or switch to) a Mac app by name.",
                    props: ["name": .string("App name, e.g. Safari, Notes, Spotify")], required: ["name"]) { a, _ in
                let name = try a.required("name")
                let (code, out) = await run("/usr/bin/open", ["-a", name])
                return code == 0 ? .text("Opened \(name).") : .error(out.isEmpty ? "Couldn't open \(name)." : out)
            },
            PalTool("open_url", "Open a link", category: .apps,
                    description: "Open a URL in the default browser (or the app that handles it).",
                    props: ["url": .string("The URL")], required: ["url"]) { a, _ in
                guard let url = URL(string: try a.required("url")) else { return .error("That isn't a valid URL.") }
                NSWorkspace.shared.open(url)
                return .text("Opened \(url.absoluteString).")
            },
            PalTool("list_shortcuts", "List Shortcuts", category: .apps,
                    description: "List the user's Shortcuts (Shortcuts app). They can do almost anything Siri can.") { _, _ in
                let (_, out) = await run("/usr/bin/shortcuts", ["list"])
                return .text(out.isEmpty ? "No shortcuts." : out)
            },
            PalTool("run_shortcut", "Run a Shortcut", category: .apps,
                    description: "Run one of the user's Shortcuts by name, optionally with text input. Returns its output.",
                    props: ["name": .string("Shortcut name"), "input": .string("Text input (optional)")], required: ["name"]) { a, _ in
                var args = ["run", try a.required("name")]
                if let input = a.string("input") {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("pal-shortcut-input.txt")
                    try input.write(to: file, atomically: true, encoding: .utf8)
                    args += ["--input-path", file.path]
                }
                let outFile = FileManager.default.temporaryDirectory.appendingPathComponent("pal-shortcut-\(UUID().uuidString).txt")
                args += ["--output-path", outFile.path]
                let (code, err) = await run("/usr/bin/shortcuts", args, timeout: 120)
                let output = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: outFile)
                return code == 0 ? .text(output.isEmpty ? "Done." : output) : .error(err.isEmpty ? "The shortcut failed." : err)
            },
            PalTool("run_applescript", "Run AppleScript", category: .apps, tiers: [.agent],
                    description: "Run AppleScript to control apps (Music, Notes, Mail, Finder, System Events…). Returns the result.",
                    props: ["script": .string("AppleScript source")], required: ["script"]) { a, _ in
                let (code, out) = await run("/usr/bin/osascript", ["-e", try a.required("script")], timeout: 60)
                return code == 0 ? .text(out.isEmpty ? "Done." : out) : .error(out)
            },
            PalTool("set_volume", "Set volume", category: .system,
                    description: "Set the output volume (0–100), or mute/unmute.",
                    props: ["level": .integer("0–100"), "muted": .boolean("Mute or unmute")]) { a, _ in
                if let muted = a.bool("muted") {
                    _ = await run("/usr/bin/osascript", ["-e", "set volume output muted \(muted)"])
                    if a.int("level") == nil { return .text(muted ? "Muted." : "Unmuted.") }
                }
                guard let level = a.int("level") else { return .error("Give a level 0–100.") }
                _ = await run("/usr/bin/osascript", ["-e", "set volume output volume \(min(max(level, 0), 100))"])
                return .text("Volume set to \(level)%.")
            },
            PalTool("media_control", "Control music", category: .system,
                    description: "Play, pause, skip or go back in Music or Spotify, or say what's playing.",
                    props: ["action": .oneOf(["play", "pause", "toggle", "next", "previous", "now_playing"], "What to do")],
                    required: ["action"]) { a, _ in
                let action = try a.required("action")
                let app = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" } ? "Spotify" : "Music"
                let script: String
                switch action {
                case "play": script = "tell application \"\(app)\" to play"
                case "pause": script = "tell application \"\(app)\" to pause"
                case "next": script = "tell application \"\(app)\" to next track"
                case "previous": script = "tell application \"\(app)\" to previous track"
                case "now_playing": script = "tell application \"\(app)\" to return (name of current track) & \" by \" & (artist of current track)"
                default: script = "tell application \"\(app)\" to playpause"
                }
                let (code, out) = await run("/usr/bin/osascript", ["-e", script])
                return code == 0 ? .text(out.isEmpty ? "Done (\(app))." : out) : .error(out)
            },
            PalTool("set_dark_mode", "Dark mode", category: .system,
                    description: "Turn dark mode on or off.",
                    props: ["on": .boolean("true for dark, false for light")], required: ["on"]) { a, _ in
                let on = a.bool("on") ?? true
                let (code, out) = await run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)"])
                return code == 0 ? .text("Dark mode \(on ? "on" : "off").") : .error(out)
            },
            PalTool("get_clipboard", "Read clipboard", category: .system,
                    description: "Read the text on the clipboard.") { _, _ in
                .text(NSPasteboard.general.string(forType: .string) ?? "(the clipboard has no text)")
            },
            PalTool("set_clipboard", "Copy to clipboard", category: .system,
                    description: "Put text on the clipboard.",
                    props: ["text": .string("Text to copy")], required: ["text"]) { a, _ in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(try a.required("text"), forType: .string)
                return .text("Copied.")
            },
            PalTool("frontmost_app", "Current app", category: .system,
                    description: "Which app and window the user is in right now.") { _, _ in
                let app = NSWorkspace.shared.frontmostApplication
                let window = ComputerUse.focusedWindowTitle(pid: app?.processIdentifier)
                return .text("\(app?.localizedName ?? "Unknown")\(window.map { " — \($0)" } ?? "")")
            },
        ]
    }

    /// Runs a command off the main thread.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 20) async -> (Int32, String) {
        let (code, out) = await Task.detached { ShellEnv.run(exe, args, timeout: timeout) }.value
        return (code, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
