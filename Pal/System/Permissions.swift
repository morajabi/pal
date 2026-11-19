import AppKit
import AVFoundation
import EventKit
import Contacts
import ApplicationServices
import UserNotifications

enum PermissionState: Equatable {
    case granted, denied, notDetermined, unknown

    var title: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Not allowed"
        case .notDetermined: "Not asked yet"
        case .unknown: "Unknown"
        }
    }
}

enum PermissionKind: String, CaseIterable, Identifiable {
    case microphone, inputMonitoring, accessibility, screenRecording
    case reminders, calendars, contacts, notifications, automation
    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .inputMonitoring: "Input Monitoring"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .reminders: "Reminders"
        case .calendars: "Calendars"
        case .contacts: "Contacts"
        case .notifications: "Notifications"
        case .automation: "Automation"
        }
    }

    var why: String {
        switch self {
        case .microphone: "To hear you."
        case .inputMonitoring: "For hold-to-talk: Pal watches for the talk key, nothing else."
        case .accessibility: "For computer use: clicking, typing and reading on-screen controls."
        case .screenRecording: "For computer use: taking screenshots so agents can see the screen."
        case .reminders: "To read and add reminders."
        case .calendars: "To read and add calendar events."
        case .contacts: "To look people up."
        case .notifications: "To tell you when agents finish or need you."
        case .automation: "To control other apps with AppleScript (Music, System Events…)."
        }
    }

    var icon: String {
        switch self {
        case .microphone: "mic"
        case .inputMonitoring: "keyboard"
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .reminders: "checklist"
        case .calendars: "calendar"
        case .contacts: "person.crop.circle"
        case .notifications: "bell.badge"
        case .automation: "gearshape.2"
        }
    }

    var settingsURL: URL {
        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .reminders: anchor = "Privacy_Reminders"
        case .calendars: anchor = "Privacy_Calendars"
        case .contacts: anchor = "Privacy_Contacts"
        case .automation: anchor = "Privacy_Automation"
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

/// Checks and requests every permission Pal can use.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()
    @Published private(set) var states: [PermissionKind: PermissionState] = [:]
    let eventStore = EKEventStore()

    func refresh() {
        Task {
            var s: [PermissionKind: PermissionState] = [:]
            for k in PermissionKind.allCases { s[k] = await state(k) }
            states = s
        }
    }

    func state(of k: PermissionKind) -> PermissionState { states[k] ?? .unknown }

    func state(_ k: PermissionKind) async -> PermissionState {
        switch k {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .inputMonitoring:
            return CGPreflightListenEventAccess() ? .granted : .notDetermined
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .reminders:
            return Self.ek(EKEventStore.authorizationStatus(for: .reminder))
        case .calendars:
            return Self.ek(EKEventStore.authorizationStatus(for: .event))
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized, .limited: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .notifications:
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .automation:
            return Self.automationState(prompt: false)
        }
    }

    /// Shows the system prompt when macOS still allows one, otherwise opens the right Settings pane.
    func request(_ k: PermissionKind) {
        Task {
            let current = await state(k)
            if current == .denied { NSWorkspace.shared.open(k.settingsURL); return }
            switch k {
            case .microphone:
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            case .inputMonitoring:
                if !CGRequestListenEventAccess() { NSWorkspace.shared.open(k.settingsURL) }
            case .accessibility:
                let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                if !AXIsProcessTrustedWithOptions(opts) { NSWorkspace.shared.open(k.settingsURL) }
            case .screenRecording:
                if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(k.settingsURL) }
            case .reminders:
                _ = try? await eventStore.requestFullAccessToReminders()
            case .calendars:
                _ = try? await eventStore.requestFullAccessToEvents()
            case .contacts:
                _ = try? await CNContactStore().requestAccess(for: .contacts)
            case .notifications:
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            case .automation:
                if Self.automationState(prompt: true) != .granted { NSWorkspace.shared.open(k.settingsURL) }
            }
            refresh()
        }
    }

    /// Ensures a permission before a tool uses it.
    func require(_ k: PermissionKind) async throws {
        var s = await state(k)
        if s == .notDetermined {
            request(k)
            for _ in 0..<60 { // wait up to ~30s for the user to answer the prompt
                try await Task.sleep(for: .milliseconds(500))
                s = await state(k)
                if s != .notDetermined { break }
            }
        }
        guard s == .granted else {
            throw PalError("Pal doesn't have \(k.title) access yet. The user can allow it in Pal Settings › Permissions.")
        }
    }

    private static func ek(_ s: EKAuthorizationStatus) -> PermissionState {
        switch s {
        case .fullAccess, .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .writeOnly, .denied, .restricted: return .denied
        @unknown default: return .unknown
        }
    }

    private static func automationState(prompt: Bool) -> PermissionState {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
        guard let desc = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, prompt)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(procNotFound): return .notDetermined
        default: return .unknown
        }
    }
}
