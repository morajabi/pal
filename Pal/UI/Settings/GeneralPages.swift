import SwiftUI
import AVFoundation

// MARK: - General

struct GeneralPage: View {
    let pal: Pal
    @ObservedObject var settings: PalSettings
    @State private var launchAtLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Talking", footer: "Hold the talk key to speak and let go to send. Or press the shortcut, talk, and Pal sends when you pause. You can also click the dot or type in the menu bar window.") {
                SettingsRow(title: "Hold to talk") {
                    Picker("", selection: $settings.config.holdKey) {
                        ForEach(HoldKey.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                SettingsRow(title: "Press-to-talk shortcut") {
                    Picker("", selection: $settings.config.toggleShortcut) {
                        ForEach(ToggleShortcut.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                SliderRow(title: "Send after a pause of", value: $settings.config.autoSendPause, range: 0.8...3.0, step: 0.1) { String(format: "%.1fs", $0) }
            }
            SettingsSection(title: "Conversation", footer: "Pal remembers the conversation for follow-ups, and starts fresh after a quiet stretch.") {
                SettingsRow(title: "Start fresh after") {
                    Picker("", selection: $settings.config.conversationResetMinutes) {
                        Text("10 minutes").tag(10)
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                        Text("2 hours").tag(120)
                        Text("Never").tag(0)
                    }.labelsHidden().fixedSize()
                }
                SettingsRow(title: "Answer card stays") {
                    Picker("", selection: $settings.config.cardAutoHide) {
                        ForEach(CardAutoHide.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                SettingsRow(title: "History") {
                    HStack {
                        Button("New Conversation") { pal.newConversation() }
                        Button("Clear Chat History") { pal.brain.clearHistory() }
                    }
                }
            }
            UpdatesSection(updater: Updater.shared)
            SettingsSection(title: "App") {
                SettingsRow(title: "Launch at login") {
                    Toggle("", isOn: Binding(get: { launchAtLogin }, set: { pal.setLaunchAtLogin($0); launchAtLogin = pal.launchesAtLogin }))
                        .toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Sounds", note: "Small sounds when Pal starts listening and when agents finish.") {
                    Toggle("", isOn: $settings.config.sounds).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Welcome card") {
                    Button("Show") { pal.showWelcome() }
                }
            }
        }
        .onAppear { launchAtLogin = pal.launchesAtLogin }
    }
}

private struct UpdatesSection: View {
    @ObservedObject var updater: Updater

    var body: some View {
        SettingsSection(title: "Updates", footer: updater.isAvailable ? nil : "Updates are off in development builds.") {
            SettingsRow(title: "Version", note: updater.version) {
                if updater.isAvailable {
                    Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
                }
            }
            if updater.isAvailable {
                SettingsRow(title: "Check automatically") {
                    Toggle("", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Download and install automatically") {
                    Toggle("", isOn: Binding(get: { updater.automaticallyDownloads }, set: { updater.automaticallyDownloads = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }
}

// MARK: - Appearance

struct AppearancePage: View {
    @ObservedObject var settings: PalSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview.padding(.bottom, 18)
            SettingsSection(title: "Dot") {
                SettingsRow(title: "Show the floating dot", note: "Pal still works from the menu bar and shortcuts when it's hidden.") {
                    Toggle("", isOn: $settings.config.showDot).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Corner") {
                    Picker("", selection: $settings.config.dotCorner) {
                        ForEach(DotCorner.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                SettingsRow(title: "Display") {
                    Picker("", selection: $settings.config.dotScreen) {
                        ForEach(ScreenChoice.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                SliderRow(title: "Size", value: $settings.config.dotSize, range: 0.6...2.0, step: 0.05) { String(format: "%.0f%%", $0 * 100) }
                SliderRow(title: "From the side", value: $settings.config.dotOffsetX, range: 12...240, step: 1) { "\(Int($0)) pt" }
                SliderRow(title: "From the top/bottom", value: $settings.config.dotOffsetY, range: 12...240, step: 1) { "\(Int($0)) pt" }
                SliderRow(title: "Idle opacity", value: $settings.config.idleOpacity, range: 0.2...1.0, step: 0.05) { String(format: "%.0f%%", $0 * 100) }
            }
            SettingsSection(title: "Colors") {
                colorRow("Idle", $settings.config.colorIdle)
                colorRow("Listening", $settings.config.colorListening)
                colorRow("Thinking", $settings.config.colorThinking)
                colorRow("Speaking", $settings.config.colorSpeaking)
                colorRow("Agents working", $settings.config.colorWorking)
                colorRow("Needs you", $settings.config.colorAttention)
            }
            SettingsSection(title: "Answer card") {
                SliderRow(title: "Width", value: $settings.config.cardWidth, range: 300...560, step: 4) { "\(Int($0)) pt" }
                SliderRow(title: "Text size", value: $settings.config.cardTextSize, range: 11...18, step: 0.5) { String(format: "%.1f", $0) }
                SettingsRow(title: "Glass") {
                    Picker("", selection: $settings.config.cardTint) {
                        ForEach(CardTint.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }
            }
            Button("Restore Default Look") { resetLook() }
        }
    }

    private var preview: some View {
        HStack(spacing: 22) {
            ForEach([("Idle", settings.config.colorIdle), ("Listening", settings.config.colorListening),
                     ("Thinking", settings.config.colorThinking), ("Speaking", settings.config.colorSpeaking),
                     ("Working", settings.config.colorWorking), ("Needs you", settings.config.colorAttention)], id: \.0) { name, hex in
                VStack(spacing: 8) {
                    Circle()
                        .fill(Color(hex: hex))
                        .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.75))
                        .frame(width: 13 * settings.config.dotSize, height: 13 * settings.config.dotSize)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .frame(height: 30)
                    Text(name).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [.indigo.opacity(0.55), .teal.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private func colorRow(_ title: String, _ hex: Binding<String>) -> some View {
        SettingsRow(title: title) {
            ColorPicker("", selection: hex.color, supportsOpacity: false).labelsHidden()
        }
    }

    private func resetLook() {
        let d = PalConfig()
        var c = settings.config
        c.dotCorner = d.dotCorner; c.dotScreen = d.dotScreen; c.dotSize = d.dotSize
        c.dotOffsetX = d.dotOffsetX; c.dotOffsetY = d.dotOffsetY; c.idleOpacity = d.idleOpacity
        c.colorIdle = d.colorIdle; c.colorListening = d.colorListening; c.colorThinking = d.colorThinking
        c.colorSpeaking = d.colorSpeaking; c.colorWorking = d.colorWorking; c.colorAttention = d.colorAttention
        c.cardWidth = d.cardWidth; c.cardTint = d.cardTint; c.cardTextSize = d.cardTextSize
        settings.config = c
    }
}

// MARK: - Voice

struct VoicePage: View {
    let pal: Pal
    @ObservedObject var settings: PalSettings
    @State private var locales: [Locale] = []
    @State private var voices: [VoiceOption] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Listening", footer: "Speech is turned into text on your Mac. The first use of a language downloads its model.") {
                SettingsRow(title: "Speech to text") {
                    Picker("", selection: $settings.config.sttEngine) {
                        ForEach(STTEngine.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                SettingsRow(title: "Language") {
                    Picker("", selection: $settings.config.sttLocale) {
                        Text("Same as the Mac (\(Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier))").tag("auto")
                        ForEach(locales, id: \.identifier) { l in
                            Text(Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier).tag(l.identifier)
                        }
                    }.labelsHidden().fixedSize()
                }
            }
            SettingsSection(title: "Speaking", footer: "Off by default: every answer card has a speaker button to hear it. Better voices: download Premium or Enhanced voices in System Settings › Accessibility › Spoken Content.") {
                SettingsRow(title: "Speak answers automatically", note: "Reads the short answer aloud when you asked by voice. Skipped when the Mac is muted.") {
                    Toggle("", isOn: $settings.config.speakReplies).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Speak agent updates") {
                    Toggle("", isOn: $settings.config.speakAgentUpdates).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Voice") {
                    HStack {
                        Picker("", selection: $settings.config.ttsVoice) {
                            Text("Best available").tag("")
                            ForEach(voices) { v in Text("\(v.name) · \(v.quality) · \(v.language)").tag(v.id) }
                        }.labelsHidden().fixedSize()
                        Button("Preview") { pal.speaker.speak("Hi, I'm Pal. Your pasta has two minutes left.", force: true) }
                    }
                }
                SliderRow(title: "Speed", value: $settings.config.ttsRate, range: 0.35...0.65, step: 0.01) { String(format: "%.0f%%", ($0 / 0.5) * 100) }
                SettingsRow(title: "More voices") {
                    Button("Open Spoken Content…") { NSWorkspace.shared.open(Speaker.downloadVoicesURL) }
                }
            }
        }
        .task(id: settings.config.sttEngine) {
            locales = await Listener.supportedLocales(settings.config.sttEngine)
                .sorted { (Locale.current.localizedString(forIdentifier: $0.identifier) ?? "") < (Locale.current.localizedString(forIdentifier: $1.identifier) ?? "") }
        }
        .onAppear { voices = Speaker.voices() }
    }
}
