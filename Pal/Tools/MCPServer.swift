import Foundation

/// Serves Pal's tools over MCP on a Unix socket inside Pal's own process, so every tool
/// runs with the permissions the user granted Pal (mic, Accessibility, Reminders, …).
/// Claude Code / Codex reach it through `Pal --mcp-bridge` (see MCPBridge).
final class MCPServer {
    static let shared = MCPServer()
    private var listenFD: Int32 = -1
    private var connections: [ObjectIdentifier: MCPConnection] = [:]
    private let lock = NSLock()

    func start() {
        let path = Paths.socket
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { log.error("mcp: socket() failed"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = withUnsafeMutableBytes(of: &addr.sun_path) { buf -> Bool in
            let bytes = Array(path.utf8)
            guard bytes.count < buf.count else { return false }
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
            return true
        }
        guard ok else { log.error("mcp: socket path too long"); close(fd); return }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 32) == 0 else {
            log.error("mcp: bind/listen failed \(errno)")
            close(fd)
            return
        }
        chmod(path, 0o600)
        listenFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "pal.mcp.accept"
        thread.start()
        log.notice("mcp: listening")
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            let conn = MCPConnection(fd: client)
            conn.onClose = { [weak self, weak conn] in
                guard let self, let conn else { return }
                self.lock.lock(); self.connections[ObjectIdentifier(conn)] = nil; self.lock.unlock()
            }
            lock.lock(); connections[ObjectIdentifier(conn)] = conn; lock.unlock()
            conn.start()
        }
    }
}

final class MCPConnection {
    private let fd: Int32
    private let writeLock = NSLock()
    private var context: ToolContext?
    var onClose: (() -> Void)?

    init(fd: Int32) { self.fd = fd }

    func start() {
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "pal.mcp.conn"
        t.start()
    }

    private func readLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.handle(line) } }
                }
            }
        }
        close(fd)
        DispatchQueue.main.async { self.onClose?() }
    }

    private func send(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        writeLock.lock(); defer { writeLock.unlock() }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let w = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if w <= 0 { return }
                offset += w
            }
        }
    }

    @MainActor
    private func handle(_ line: String) {
        guard let msg = line.jsonObject else { return }
        if let hello = msg["pal_bridge"] as? [String: Any] {
            context = ToolContext(sessionID: hello["session"] as? String ?? "main",
                                  tier: Tier(rawValue: hello["tier"] as? String ?? "") ?? .quick)
            return
        }
        let ctx = context ?? ToolContext(sessionID: "main", tier: .quick)
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            reply(id, [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "pal", "title": "Pal", "version": "0.2.0"],
                "instructions": "Pal's tools for the user's Mac: reminders, calendar, contacts, timers, apps, Shortcuts, computer use, memory, skills, background agents and schedules.",
            ])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": ToolRegistry.shared.available(for: ctx.tier).map { $0.mcpDescriptor }])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            Task { @MainActor in
                let out = await ToolRegistry.shared.call(name, args: args, context: ctx)
                self.reply(id, Self.encode(out))
            }
        default:
            if id != nil {
                send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "Unknown method \(method)"]])
            }
        }
    }

    private func reply(_ id: Any?, _ result: [String: Any]) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func encode(_ out: ToolOutput) -> [String: Any] {
        let content: [[String: Any]] = out.content.map {
            switch $0 {
            case .text(let s): return ["type": "text", "text": s]
            case .image(let data, let mime): return ["type": "image", "data": data.base64EncodedString(), "mimeType": mime]
            }
        }
        return ["content": content, "isError": out.isError]
    }
}
