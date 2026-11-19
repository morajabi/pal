import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, voice, models, agents, tools, permissions, memory, skills, schedules
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .voice: "Voice"
        case .models: "Models"
        case .agents: "Agents"
        case .tools: "Tools"
        case .permissions: "Permissions"
        case .memory: "Memory"
        case .skills: "Skills"
        case .schedules: "Schedules"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .voice: "waveform"
        case .models: "cpu"
        case .agents: "sparkles"
        case .tools: "wrench.and.screwdriver"
        case .permissions: "lock.shield"
        case .memory: "brain"
        case .skills: "book.closed"
        case .schedules: "clock"
        }
    }
}

/// Pal's settings window. While it's open Pal shows in the Dock and ⌘-Tab like a normal app.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static let selection = SettingsSelection()
    private static var closeObserver: Any?

    static func show(pal: Pal, page: SettingsPage?) {
        if let page { selection.page = page }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Pal Settings"
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 720, height: 480)
            w.contentView = NSHostingView(rootView: SettingsView(pal: pal, selection: selection))
            w.center()
            w.setFrameAutosaveName("PalSettings")
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                NSApp.setActivationPolicy(.accessory)
            }
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

final class SettingsSelection: ObservableObject {
    @Published var page: SettingsPage = .general
}

struct SettingsView: View {
    let pal: Pal
    @ObservedObject var selection: SettingsSelection
    @ObservedObject var settings = PalSettings.shared

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: Binding(get: { selection.page }, set: { if let p = $0 { selection.page = p } })) { page in
                Label(page.title, systemImage: page.icon).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            ScrollView {
                page
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .navigationTitle(selection.page.title)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch selection.page {
        case .general: GeneralPage(pal: pal, settings: settings)
        case .appearance: AppearancePage(settings: settings)
        case .voice: VoicePage(pal: pal, settings: settings)
        case .models: ModelsPage(accounts: pal.accounts, settings: settings)
        case .agents: AgentsPage(accounts: pal.accounts, settings: settings)
        case .tools: ToolsPage(settings: settings, permissions: Permissions.shared)
        case .permissions: PermissionsPage(permissions: Permissions.shared)
        case .memory: MemoryPage(settings: settings, store: MemoryStore.shared)
        case .skills: SkillsPage(store: SkillStore.shared)
        case .schedules: SchedulesPage()
        }
    }
}

// MARK: - Building blocks

/// A titled group of settings in a rounded box.
struct SettingsSection<Content: View>: View {
    var title: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            // Rows draw a divider above themselves; the first one hides under the box's border.
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 14)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.5)))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 18)
    }
}

/// One row: label (and optional note) on the left, control on the right.
struct SettingsRow<Control: View>: View {
    var title: String
    var note: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Divider().opacity(0.5).padding(.top, -0.5) }
    }
}

struct SliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0
    var format: (Double) -> String

    var body: some View {
        SettingsRow(title: title) {
            HStack {
                if step > 0 { Slider(value: $value, in: range, step: step).frame(width: 200) }
                else { Slider(value: $value, in: range).frame(width: 200) }
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 54, alignment: .trailing)
            }
        }
    }
}

struct StatePill: View {
    var text: String
    var good: Bool
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(good ? Color.green : Color.orange)
            .background((good ? Color.green : Color.orange).opacity(0.14), in: Capsule())
    }
}
