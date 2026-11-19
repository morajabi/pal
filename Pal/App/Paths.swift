import Foundation
import os

let log = Logger(subsystem: "app.pal.mac", category: "pal")

/// Where Pal keeps things.
/// - `~/Pal` (user-visible): agent workspace, memory, skills.
/// - Application Support: app state (sessions, schedules, chat) and the tool socket.
enum Paths {
    static var home: URL {
        let raw = PalSettings.c.homeFolder
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    static var workspace: URL { ensure(home.appendingPathComponent("workspace", isDirectory: true)) }
    static var memory: URL { ensure(home.appendingPathComponent("memory", isDirectory: true)) }
    static var skills: URL { ensure(home.appendingPathComponent("skills", isDirectory: true)) }

    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Dev builds ("Pal Dev") keep their own state and tool socket.
        let name = Bundle.main.bundleIdentifier == "app.pal.mac.dev" ? "Pal Dev" : "Pal"
        return ensure(base.appendingPathComponent(name, isDirectory: true))
    }()

    /// The quick-answer model runs here: an empty folder, nothing to touch.
    static var quickWorkspace: URL { ensure(support.appendingPathComponent("quick", isDirectory: true)) }
    static var state: URL { ensure(support.appendingPathComponent("state", isDirectory: true)) }
    static var socket: String { support.appendingPathComponent("tools.sock").path }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Sets up ~/Pal on first run, and lets Claude Code find Pal's skills natively.
    static func bootstrap() {
        _ = workspace
        let skillsURL = skills
        let readme = home.appendingPathComponent("README.md")
        if !FileManager.default.fileExists(atPath: readme.path) {
            try? """
            # Pal

            Pal's agents work in `workspace/`. Things Pal remembers live in `memory/` (plain markdown, edit freely).
            Add skills as `skills/<name>/SKILL.md` with a `name:` and `description:` in the front matter.
            """.write(to: readme, atomically: true, encoding: .utf8)
        }
        let claudeSkills = workspace.appendingPathComponent(".claude", isDirectory: true)
        ensure(claudeSkills)
        let link = claudeSkills.appendingPathComponent("skills")
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil {
            try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: skillsURL)
        }
    }
}

/// Tiny JSON file persistence for app state.
enum Store {
    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let url = Paths.state.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let url = Paths.state.appendingPathComponent(name)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? e.encode(value) { try? data.write(to: url, options: .atomic) }
    }
}
