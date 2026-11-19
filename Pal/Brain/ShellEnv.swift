import Foundation

/// GUI apps launch with a bare PATH, so CLIs installed via Homebrew, npm, bun, etc.
/// aren't found. We borrow the user's login-shell PATH once and add common bins.
enum ShellEnv {
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        var paths = (loginShellPATH() ?? env["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let extras = [
            "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.bun/bin",
            "\(home)/.npm-global/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        for e in extras where !paths.contains(e) { paths.append(e) }
        env["PATH"] = paths.joined(separator: ":")
        env["NO_COLOR"] = "1"
        return env
    }()

    static func which(_ name: String) -> String? {
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Runs a short command and returns (exit status, stdout). Blocking; call off the main thread.
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 10) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.environment = environment
        p.currentDirectoryURL = Paths.quickWorkspace
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        let reader = DispatchQueue(label: "pal.shell.read")
        let group = DispatchGroup()
        group.enter()
        reader.async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return (-1, "timed out") }
        _ = group.wait(timeout: .now() + 1)
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func loginShellPATH() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", "printf '__PAL_PATH__%s' \"$PATH\""]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(4)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return nil }
        let out = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        guard let r = out.range(of: "__PAL_PATH__") else { return nil }
        let path = out[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
