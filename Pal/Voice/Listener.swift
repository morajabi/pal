import AVFoundation
import Speech

/// Mic capture + on-device transcription (SpeechAnalyzer).
/// The mic starts instantly; audio is buffered while the analyzer spins up,
/// so the first words aren't lost.
final class Listener {
    /// 0…1, on the main queue.
    var onLevel: ((CGFloat) -> Void)?
    /// Full transcript so far, on the main queue.
    var onTranscript: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private let feed = AudioFeed()

    private var finalized = ""
    private var volatile = ""
    private(set) var isRunning = false

    private var locale: Locale?
    private var analyzerFormat: AVAudioFormat?
    /// Engine + language the cached format was prepared for.
    private var preparedKey = ""

    var transcript: String {
        (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolves the locale and downloads the speech model if needed. Re-runs when the engine or language changes.
    func prepare() async throws {
        let c = PalSettings.c
        let key = "\(c.sttEngine.rawValue)|\(c.sttLocale)"
        if analyzerFormat != nil, key == preparedKey { return }
        let wanted = c.sttLocale == "auto" ? Locale.current : Locale(identifier: c.sttLocale)
        let loc: Locale
        switch c.sttEngine {
        case .speechTranscriber: loc = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) ?? Locale(identifier: "en-US")
        case .dictation: loc = await DictationTranscriber.supportedLocale(equivalentTo: wanted) ?? Locale(identifier: "en-US")
        }
        let module: any SpeechModule = c.sttEngine == .dictation
            ? DictationTranscriber(locale: loc, preset: .shortDictation)
            : SpeechTranscriber(locale: loc, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        locale = loc
        analyzerFormat = format
        preparedKey = key
    }

    /// Languages the chosen engine can transcribe.
    static func supportedLocales(_ engine: STTEngine) async -> [Locale] {
        switch engine {
        case .speechTranscriber: return await SpeechTranscriber.supportedLocales
        case .dictation: return await DictationTranscriber.supportedLocales
        }
    }

    static func requestMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() async throws {
        guard !isRunning else { return }
        guard await Self.requestMicAccess() else {
            throw PalError("Pal needs the microphone. Turn it on in System Settings › Privacy & Security › Microphone.")
        }
        isRunning = true
        finalized = ""
        volatile = ""

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation

        // 1. Mic first.
        do {
            try startEngine(continuation: continuation)
        } catch {
            isRunning = false
            throw PalError("Couldn't start the microphone: \(error.localizedDescription)")
        }

        // 2. Then the recognizer, which drains whatever was buffered.
        do {
            try await prepare()
            guard isRunning, let locale, let analyzerFormat else { return }
            let (module, results) = Self.makeModule(PalSettings.c.sttEngine, locale)
            feed.setOutputFormat(analyzerFormat).forEach { continuation.yield($0) }
            let analyzer = SpeechAnalyzer(modules: [module])
            self.analyzer = analyzer
            resultsTask = Task { [weak self] in
                do {
                    for try await (text, isFinal) in results {
                        await MainActor.run {
                            guard let self else { return }
                            if isFinal { self.finalized += text; self.volatile = "" } else { self.volatile = text }
                            self.onTranscript?(self.transcript)
                        }
                    }
                } catch {}
            }
            try await analyzer.start(inputSequence: stream)
        } catch {
            cancel()
            throw PalError("Speech recognition isn't available: \(error.localizedDescription)")
        }
    }

    /// Stops listening and returns the final transcript.
    func stop() async -> String {
        guard isRunning else { return transcript }
        isRunning = false
        stopEngine()
        continuation?.finish()
        continuation = nil
        if let analyzer {
            try? await withTimeout(seconds: 3) { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        }
        if let resultsTask {
            _ = try? await withTimeout(seconds: 1.5) { await resultsTask.value }
        }
        cleanup()
        return transcript
    }

    func cancel() {
        guard isRunning || analyzer != nil else { return }
        isRunning = false
        stopEngine()
        continuation?.finish()
        continuation = nil
        let analyzer = self.analyzer
        Task { await analyzer?.cancelAndFinishNow() }
        resultsTask?.cancel()
        cleanup()
    }

    // MARK: Private

    /// The recognizer module plus its results as (text, isFinal).
    private static func makeModule(_ engine: STTEngine, _ locale: Locale) -> (module: any SpeechModule, results: AsyncThrowingStream<(String, Bool), Error>) {
        switch engine {
        case .speechTranscriber:
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
            return (t, AsyncThrowingStream { cont in
                Task {
                    do { for try await r in t.results { cont.yield((String(r.text.characters), r.isFinal)) }; cont.finish() }
                    catch { cont.finish(throwing: error) }
                }
            })
        case .dictation:
            let t = DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [.punctuation],
                                         reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
            return (t, AsyncThrowingStream { cont in
                Task {
                    do { for try await r in t.results { cont.yield((String(r.text.characters), r.isFinal)) }; cont.finish() }
                    catch { cont.finish(throwing: error) }
                }
            })
        }
    }

    private func startEngine(continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        feed.setInputFormat(format)
        var smoothed: Float = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self else { return }
            // Level for the dot.
            if let ch = buffer.floatChannelData?[0] {
                let n = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += ch[i] * ch[i] }
                let rms = sqrt(sum / Float(max(n, 1)))
                let db = 20 * log10(max(rms, 1e-6))
                let norm = min(max((db + 52) / 38, 0), 1)
                smoothed = norm > smoothed ? norm : smoothed * 0.8 + norm * 0.2
                let level = CGFloat(smoothed)
                DispatchQueue.main.async { self.onLevel?(level) }
            }
            // Audio for the recognizer (held back until it's ready).
            self.feed.feed(buffer).forEach { continuation.yield($0) }
        }
        engine.prepare()
        try engine.start()
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        DispatchQueue.main.async { self.onLevel?(0) }
    }

    private func cleanup() {
        analyzer = nil
        resultsTask = nil
        feed.clear()
    }
}

/// Converts mic buffers to the analyzer's format, holding them back until it's ready.
/// Touched from the audio thread and the main thread, so everything is locked.
final class AudioFeed: @unchecked Sendable {
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var pending: [AVAudioPCMBuffer] = []
    private let lock = NSLock()

    func setInputFormat(_ f: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        inputFormat = f
        converter = nil
    }

    func setOutputFormat(_ f: AVAudioFormat) -> [AnalyzerInput] {
        lock.lock(); defer { lock.unlock() }
        outputFormat = f
        converter = nil
        let out = pending.compactMap(convertLocked)
        pending = []
        return out
    }

    func feed(_ buffer: AVAudioPCMBuffer) -> [AnalyzerInput] {
        lock.lock(); defer { lock.unlock() }
        if outputFormat != nil { return convertLocked(buffer).map { [$0] } ?? [] }
        // The tap reuses its buffers, so keep a copy. ~9s cap.
        if pending.count < 400, let copy = buffer.copy() as? AVAudioPCMBuffer { pending.append(copy) }
        return []
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        outputFormat = nil
        converter = nil
        pending = []
    }

    private func convertLocked(_ buffer: AVAudioPCMBuffer) -> AnalyzerInput? {
        guard let outputFormat, buffer.frameLength > 0 else { return nil }
        if buffer.format == outputFormat {
            return (buffer.copy() as? AVAudioPCMBuffer).map { AnalyzerInput(buffer: $0) }
        }
        if converter == nil {
            converter = AVAudioConverter(from: inputFormat ?? buffer.format, to: outputFormat)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return AnalyzerInput(buffer: out)
    }
}

struct TimeoutError: Error {}

func withTimeout<T>(seconds: Double, _ work: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
