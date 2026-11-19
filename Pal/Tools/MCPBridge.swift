import Foundation

/// `Pal --mcp-bridge --session <id> --tier quick|agent`
/// A tiny stdio ⇄ socket pipe so Claude Code / Codex can use the tools served by the running Pal app.
enum MCPBridge {
    /// The MCP server entry to give a model harness.
    static func spec(session: String, tier: Tier) -> MCPServerSpec {
        MCPServerSpec(command: Bundle.main.executablePath ?? CommandLine.arguments[0],
                      args: ["--mcp-bridge", "--session", session, "--tier", tier.rawValue])
    }

    static func run(arguments: [String]) -> Never {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        let session = value("--session") ?? "main"
        let tier = value("--tier") ?? "quick"

        guard let fd = connect(to: Paths.socket) else {
            FileHandle.standardError.write("Pal isn't running, so its tools aren't available.\n".data(using: .utf8)!)
            exit(1)
        }
        let hello = "{\"pal_bridge\":{\"session\":\"\(session)\",\"tier\":\"\(tier)\"}}\n"
        _ = hello.withCString { write(fd, $0, strlen($0)) }

        // stdin → socket
        let up = Thread {
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(STDIN_FILENO, &buf, buf.count)
                if n <= 0 { break }
                var off = 0
                while off < n {
                    let w = buf.withUnsafeBytes { write(fd, $0.baseAddress! + off, n - off) }
                    if w <= 0 { exit(0) }
                    off += w
                }
            }
            exit(0)
        }
        up.start()

        // socket → stdout
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            var off = 0
            while off < n {
                let w = buf.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress! + off, n - off) }
                if w <= 0 { exit(0) }
                off += w
            }
        }
        exit(0)
    }

    private static func connect(to path: String) -> Int32? {
        for attempt in 0..<25 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                let bytes = Array(path.utf8.prefix(buf.count - 1))
                buf.copyBytes(from: bytes)
                buf[bytes.count] = 0
            }
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if r == 0 { return fd }
            close(fd)
            if attempt < 24 { usleep(200_000) }
        }
        return nil
    }
}
