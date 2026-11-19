import Foundation

// MARK: - Memory

struct MemoryItem: Identifiable, Equatable {
    var id: String          // file name without .md
    var title: String
    var body: String
    var updated: Date
}

/// A plain-markdown memory folder (~/Pal/memory). One file per memory; the user can edit them.
@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()
    @Published private(set) var items: [MemoryItem] = []

    func reload() {
        let fm = FileManager.default
        let dir = Paths.memory
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        items = files.filter { $0.pathExtension == "md" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            var lines = text.components(separatedBy: "\n")
            var title = url.deletingPathExtension().lastPathComponent
            if let first = lines.first, first.hasPrefix("# ") {
                title = String(first.dropFirst(2))
                lines.removeFirst()
            }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return MemoryItem(id: url.deletingPathExtension().lastPathComponent, title: title,
                              body: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), updated: date)
        }.sorted { $0.updated > $1.updated }
    }

    @discardableResult
    func save(title: String, body: String) -> MemoryItem {
        let id = Self.slug(title)
        let text = "# \(title)\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        try? text.write(to: Paths.memory.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
        reload()
        return items.first { $0.id == id } ?? MemoryItem(id: id, title: title, body: body, updated: Date())
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: Paths.memory.appendingPathComponent("\(id).md"))
        reload()
    }

    func search(_ query: String) -> [MemoryItem] {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
        guard !words.isEmpty else { return items }
        return items.map { item -> (MemoryItem, Int) in
            let hay = (item.title + " " + item.body).lowercased()
            let score = words.reduce(0) { $0 + (hay.contains($1) ? (item.title.lowercased().contains($1) ? 3 : 1) : 0) }
            return (item, score)
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// A compact list for the system prompt.
    var promptIndex: String {
        var out = ""
        for item in items {
            let first = item.body.components(separatedBy: "\n").first ?? ""
            let line = "- \(item.title): \(first.prefix(140))\n"
            if out.count + line.count > 2500 { out += "- (\(items.count) memories in total; use recall for more)\n"; break }
            out += line
        }
        return out.trimmingCharacters(in: .newlines)
    }

    static func slug(_ s: String) -> String {
        let allowed = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(allowed).split(separator: "-").joined(separator: "-")
        return String(collapsed.prefix(60)).isEmpty ? "memory-\(Int(Date().timeIntervalSince1970))" : String(collapsed.prefix(60))
    }
}

// MARK: - Skills

struct Skill: Identifiable, Equatable {
    var id: String { path }
    var name: String
    var summary: String
    var path: String
}

/// Skill files: `~/Pal/skills/<name>/SKILL.md` with `name:` / `description:` front matter.
/// Claude agents also discover these natively (they're linked into the workspace).
@MainActor
final class SkillStore: ObservableObject {
    static let shared = SkillStore()
    @Published private(set) var skills: [Skill] = []

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Paths.skills, includingPropertiesForKeys: nil)) ?? []
        skills = dirs.compactMap { dir in
            let file = dir.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let meta = Self.frontMatter(text)
            return Skill(name: meta["name"] ?? dir.lastPathComponent,
                         summary: meta["description"] ?? "",
                         path: file.path)
        }.sorted { $0.name < $1.name }
    }

    func read(_ name: String) -> String? {
        guard let s = skills.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        return try? String(contentsOfFile: s.path, encoding: .utf8)
    }

    func create(name: String) -> URL {
        let dir = Paths.ensure(Paths.skills.appendingPathComponent(MemoryStore.slug(name), isDirectory: true))
        let file = dir.appendingPathComponent("SKILL.md")
        if !FileManager.default.fileExists(atPath: file.path) {
            try? """
            ---
            name: \(name)
            description: When to use this skill, in one sentence.
            ---

            # \(name)

            Steps, tips and examples for the agent.
            """.write(to: file, atomically: true, encoding: .utf8)
        }
        reload()
        return file
    }

    static func frontMatter(_ text: String) -> [String: String] {
        guard text.hasPrefix("---") else { return [:] }
        let lines = text.components(separatedBy: "\n").dropFirst()
        var out: [String: String] = [:]
        for line in lines {
            if line.hasPrefix("---") { break }
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { out[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        }
        return out
    }
}

// MARK: - Tools

enum MemoryTools {
    @MainActor
    static var all: [PalTool] {
        [
            PalTool("remember", "Remember something", category: .memory,
                    description: "Save a lasting fact or preference about the user to long-term memory. Re-using a title updates that memory.",
                    props: ["title": .string("Short title, e.g. 'Coffee order' or 'Partner's name'"),
                            "content": .string("What to remember, in a sentence or two")],
                    required: ["title", "content"]) { a, _ in
                let item = MemoryStore.shared.save(title: try a.required("title"), body: try a.required("content"))
                return .text("Saved memory “\(item.title)”.")
            },
            PalTool("recall", "Search memory", category: .memory,
                    description: "Search long-term memory for anything relevant to a query.",
                    props: ["query": .string("What to look for")], required: ["query"]) { a, _ in
                let hits = MemoryStore.shared.search(try a.required("query")).prefix(8)
                guard !hits.isEmpty else { return .text("Nothing in memory about that.") }
                return .text(hits.map { "## \($0.title)\n\($0.body)" }.joined(separator: "\n\n"))
            },
            PalTool("forget", "Forget something", category: .memory,
                    description: "Delete a memory by its title.",
                    props: ["title": .string("Title of the memory to delete")], required: ["title"]) { a, _ in
                let title = try a.required("title")
                guard let item = MemoryStore.shared.items.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame })
                        ?? MemoryStore.shared.search(title).first else { return .error("No memory called “\(title)”.") }
                MemoryStore.shared.delete(item.id)
                return .text("Forgot “\(item.title)”.")
            },
        ]
    }
}

enum SkillTools {
    @MainActor
    static var all: [PalTool] {
        [
            PalTool("list_skills", "List skills", category: .skills,
                    description: "List the skills (reusable instructions) the user has given Pal.") { _, _ in
                let s = SkillStore.shared.skills
                return .text(s.isEmpty ? "No skills yet." : s.map { "- \($0.name): \($0.summary)" }.joined(separator: "\n"))
            },
            PalTool("read_skill", "Read a skill", category: .skills,
                    description: "Read a skill's full instructions before doing that kind of task.",
                    props: ["name": .string("Skill name")], required: ["name"]) { a, _ in
                guard let text = SkillStore.shared.read(try a.required("name")) else { return .error("No such skill.") }
                return .text(text)
            },
        ]
    }
}
