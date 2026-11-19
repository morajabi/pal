import Foundation

/// Shell and file tools for agents that run straight on the API (Claude Code and Codex agents
/// have their own, so these aren't offered to them).
enum ShellTools {
    @MainActor
    static var all: [PalTool] {
        let agent: Set<Tier> = [.agent]
        return [
            PalTool("run_shell", "Run a command", category: .files, tiers: agent, harnessNative: true,
                    description: "Run a zsh command on the Mac (login shell, working folder = the agent workspace). Returns stdout+stderr and the exit code.",
                    props: ["command": .string("The command line"), "timeout_seconds": .integer("Default 120, max 900")],
                    required: ["command"]) { a, _ in
                guard PalSettings.c.agentsFullAccess else {
                    return .error("Running commands needs Full access (Pal Settings › Agents).")
                }
                let cmd = try a.required("command")
                let timeout = TimeInterval(min(max(a.int("timeout_seconds") ?? 120, 1), 900))
                let (code, out) = await Task.detached {
                    ShellEnv.run("/bin/zsh", ["-lc", "cd \(shellQuote(Paths.workspace.path)) && \(cmd)"], timeout: timeout)
                }.value
                let trimmed = out.count > 20_000 ? String(out.prefix(10_000)) + "\n…(\(out.count - 20_000) chars cut)…\n" + String(out.suffix(10_000)) : out
                return ToolOutput(content: [.text("exit \(code)\n\(trimmed)")], isError: code != 0)
            },
            PalTool("read_file", "Read a file", category: .files, tiers: agent, harnessNative: true,
                    description: "Read a text file. Relative paths are inside the agent workspace.",
                    props: ["path": .string("File path"), "max_chars": .integer("Default 40000")], required: ["path"]) { a, _ in
                let url = resolve(try a.required("path"))
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .error("Couldn't read \(url.path).") }
                let limit = a.int("max_chars") ?? 40_000
                return .text(text.count > limit ? String(text.prefix(limit)) + "\n…(truncated)" : text)
            },
            PalTool("write_file", "Write a file", category: .files, tiers: agent, harnessNative: true,
                    description: "Create or overwrite a text file. Relative paths are inside the agent workspace.",
                    props: ["path": .string("File path"), "content": .string("Full file contents")], required: ["path", "content"]) { a, _ in
                let url = resolve(try a.required("path"))
                if url.path.hasPrefix(Paths.workspace.path) == false && !PalSettings.c.agentsFullAccess {
                    return .error("Writing outside the workspace needs Full access (Pal Settings › Agents).")
                }
                Paths.ensure(url.deletingLastPathComponent())
                try (a.string("content") ?? "").write(to: url, atomically: true, encoding: .utf8)
                return .text("Wrote \(url.path).")
            },
            PalTool("list_directory", "List a folder", category: .files, tiers: agent, harnessNative: true,
                    description: "List a folder's contents. Relative paths are inside the agent workspace.",
                    props: ["path": .string("Folder path (default: workspace)")]) { a, _ in
                let url = resolve(a.string("path") ?? ".")
                let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                let lines = items.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(300).map { u -> String in
                    let dir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    return dir ? u.lastPathComponent + "/" : u.lastPathComponent
                }
                return .text(lines.isEmpty ? "(empty)" : lines.joined(separator: "\n"))
            },
        ]
    }

    private static func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : Paths.workspace.appendingPathComponent(expanded)
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
