import Foundation

/// A long-lived child process that speaks newline-delimited JSON over stdio.
/// All callbacks arrive on the main queue.
final class LineProcess {
    var onLine: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var buffer = Data()
    private var stderrTail = ""

    var isRunning: Bool { process.isRunning }

    init(executable: String, arguments: [String], cwd: URL, extraEnv: [String: String] = [:]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ShellEnv.environment.merging(extraEnv) { _, new in new }
        process.currentDirectoryURL = cwd
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + text).suffix(2000))
            }
        }
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            DispatchQueue.main.async {
                guard let self else { return }
                self.onExit?(status, self.stderrTail)
            }
        }
        try process.run()
    }

    func send(_ object: [String: Any]) {
        guard process.isRunning,
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    func stop() {
        onLine = nil
        onExit = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                onLine?(line)
            }
        }
    }
}

extension String {
    var jsonObject: [String: Any]? {
        guard let data = data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
