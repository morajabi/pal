import SwiftUI
import Combine
import Carbon.HIToolbox

// MARK: - Option types

enum HoldKey: String, Codable, CaseIterable, Identifiable {
    case rightOption, rightCommand, fn, off
    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: "Right Option ⌥"
        case .rightCommand: "Right Command ⌘"
        case .fn: "Fn / Globe"
        case .off: "Off"
        }
    }

    var keyCode: Int64? {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .fn: 63
        case .off: nil
        }
    }

    /// Device-specific modifier bit, so the left-hand key keeps working normally.
    var flagMask: UInt64 {
        switch self {
        case .rightOption: 0x40        // NX_DEVICERALTKEYMASK
        case .rightCommand: 0x10       // NX_DEVICERCMDKEYMASK
        case .fn: CGEventFlags.maskSecondaryFn.rawValue
        case .off: 0
        }
    }
}

enum ToggleShortcut: String, Codable, CaseIterable, Identifiable {
    case optionSpace, controlOptionSpace, commandShiftSpace, off
    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .controlOptionSpace: "⌃⌥ Space"
        case .commandShiftSpace: "⇧⌘ Space"
        case .off: "Off"
        }
    }

    var carbon: (keyCode: UInt32, modifiers: UInt32)? {
        let space = UInt32(kVK_Space)
        switch self {
        case .optionSpace: return (space, UInt32(optionKey))
        case .controlOptionSpace: return (space, UInt32(controlKey | optionKey))
        case .commandShiftSpace: return (space, UInt32(cmdKey | shiftKey))
        case .off: return nil
        }
    }
}

enum ProviderID: String, Codable, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "ChatGPT"
        }
    }

    var via: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

enum ProviderPreference: String, Codable, CaseIterable, Identifiable {
    case automatic, claude, codex
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .claude: "Claude"
        case .codex: "ChatGPT"
        }
    }
    var provider: ProviderID? { ProviderID(rawValue: rawValue) }
}

enum DotCorner: String, Codable, CaseIterable, Identifiable {
    case topRight, topLeft, bottomRight, bottomLeft
    var id: String { rawValue }
    var title: String {
        switch self {
        case .topRight: "Top right"
        case .topLeft: "Top left"
        case .bottomRight: "Bottom right"
        case .bottomLeft: "Bottom left"
        }
    }
    var isTop: Bool { self == .topRight || self == .topLeft }
    var isRight: Bool { self == .topRight || self == .bottomRight }
}

enum ScreenChoice: String, Codable, CaseIterable, Identifiable {
    case menuBarScreen, activeScreen
    var id: String { rawValue }
    var title: String { self == .menuBarScreen ? "Main display" : "Display with the active window" }
}

enum CardTint: String, Codable, CaseIterable, Identifiable {
    case clear, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clear: "Clear glass"
        case .light: "Light glass"
        case .dark: "Dark glass"
        }
    }
}

enum CardAutoHide: Int, Codable, CaseIterable, Identifiable {
    case never = 0, s30 = 30, m1 = 60, m5 = 300
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .never: "Until Esc or next question"
        case .s30: "After 30 seconds"
        case .m1: "After 1 minute"
        case .m5: "After 5 minutes"
        }
    }
}

enum STTEngine: String, Codable, CaseIterable, Identifiable {
    case speechTranscriber, dictation
    var id: String { rawValue }
    var title: String {
        switch self {
        case .speechTranscriber: "Apple Speech (on-device, best for questions)"
        case .dictation: "Apple Dictation (on-device, adds punctuation)"
        }
    }
}

enum BrowserTool: String, Codable, CaseIterable, Identifiable {
    case opencodeBrowse, playwright, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .opencodeBrowse: "OpenCode Browse (your Chrome, signed in)"
        case .playwright: "Playwright (separate browser)"
        case .off: "Off"
        }
    }
}

/// A model choice for one tier on one provider.
struct ModelChoice: Codable, Equatable {
    var model: String
    var effort: String
}

// MARK: - Config

/// Everything the user can change. Saved as one JSON blob; fields missing from an
/// older save fall back to these defaults, so adding settings never breaks anything.
struct PalConfig: Codable, Equatable {
    // General
    var holdKey: HoldKey = .rightOption
    var toggleShortcut: ToggleShortcut = .optionSpace
    var autoSendPause: Double = 1.4
    var conversationResetMinutes: Int = 30

    // Appearance
    var showDot = true
    var dotCorner: DotCorner = .topRight
    var dotScreen: ScreenChoice = .menuBarScreen
    var dotOffsetX: Double = 22
    var dotOffsetY: Double = 20
    var dotSize: Double = 1.0
    var idleOpacity: Double = 0.8
    var colorIdle = "#FFFFFF"
    var colorListening = "#FF6B52"
    var colorThinking = "#8C8CFF"
    var colorSpeaking = "#59D9BF"
    var colorWorking = "#F5B83D"
    var colorAttention = "#FF4FA3"
    var cardWidth: Double = 372
    var cardTint: CardTint = .light
    var cardTextSize: Double = 13.5
    var cardAutoHide: CardAutoHide = .never

    // Voice
    var sttEngine: STTEngine = .speechTranscriber
    var sttLocale = "auto"
    var speakReplies = false
    var ttsVoice = ""            // empty = best installed voice
    var ttsRate: Double = 0.52
    var speakAgentUpdates = false
    var sounds = true

    // Models
    var provider: ProviderPreference = .automatic
    var claudeFast = ModelChoice(model: "sonnet", effort: "low")
    var claudeAgent = ModelChoice(model: "opus", effort: "medium")
    var codexFast = ModelChoice(model: "gpt-6.1-terra", effort: "low")
    var codexAgent = ModelChoice(model: "gpt-6.2-sol", effort: "medium")
    /// Which provider runs agents. Automatic = the same one that answers.
    var agentProvider: ProviderPreference = .automatic

    // Agents
    var agentsFullAccess = true
    var maxConcurrentAgents = 4
    var quickAnswersUseUserMCP = false
    var notifyWhenAgentsFinish = true

    // Tools
    var disabledTools: [String] = []
    var browserTool: BrowserTool = .opencodeBrowse

    // Memory & skills
    var memoryEnabled = true
    var autoRemember = true
    var homeFolder = "~/Pal"

    init() {}

    func fast(for p: ProviderID) -> ModelChoice { p == .claude ? claudeFast : codexFast }
    func agent(for p: ProviderID) -> ModelChoice { p == .claude ? claudeAgent : codexAgent }
    func isToolEnabled(_ name: String) -> Bool { !disabledTools.contains(name) }
}

/// The live, observable settings. Views bind to `$settings.config.x`.
final class PalSettings: ObservableObject {
    static let shared = PalSettings()
    @Published var config: PalConfig
    private var saver: AnyCancellable?
    private static let key = "palConfig.v1"

    private init() {
        config = Self.load()
        saver = $config
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { Self.save($0) }
    }

    static var c: PalConfig { shared.config }

    func reset<T>(_ keyPath: WritableKeyPath<PalConfig, T>) {
        config[keyPath: keyPath] = PalConfig()[keyPath: keyPath]
    }

    private static func load() -> PalConfig {
        let defaults = PalConfig()
        guard let saved = UserDefaults.standard.data(forKey: key),
              let savedDict = (try? JSONSerialization.jsonObject(with: saved)) as? [String: Any],
              let baseData = try? JSONEncoder().encode(defaults),
              var merged = (try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any]
        else { return defaults }
        merged.merge(savedDict) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let config = try? JSONDecoder().decode(PalConfig.self, from: data) else { return defaults }
        return config
    }

    private static func save(_ c: PalConfig) {
        if let data = try? JSONEncoder().encode(c) { UserDefaults.standard.set(data, forKey: key) }
    }
}

// MARK: - Colors

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        if s.count == 6 { s += "FF" }
        let v = UInt64(s, radix: 16) ?? 0xFFFFFFFF
        self.init(.sRGB,
                  red: Double((v >> 24) & 0xFF) / 255,
                  green: Double((v >> 16) & 0xFF) / 255,
                  blue: Double((v >> 8) & 0xFF) / 255,
                  opacity: Double(v & 0xFF) / 255)
    }

    var hex: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#FFFFFF" }
        let r = Int(round(c.redComponent * 255)), g = Int(round(c.greenComponent * 255)), b = Int(round(c.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

extension Binding where Value == String {
    /// Bridges a stored hex string to a ColorPicker.
    var color: Binding<Color> {
        Binding<Color>(get: { Color(hex: wrappedValue) }, set: { wrappedValue = $0.hex })
    }
}
