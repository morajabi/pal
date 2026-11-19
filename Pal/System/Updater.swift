import AppKit
import Combine
import Sparkle

/// Auto-updates via Sparkle. The feed is the appcast attached to the latest GitHub release.
/// Off in dev builds, so a dev build never replaces itself with a release.
@MainActor
final class Updater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    @Published private(set) var canCheck = false
    /// Shown on Pal's own card when Sparkle has an update but Pal isn't in front.
    var onUpdateAvailable: ((String) -> Void)?

    private var controller: SPUStandardUpdaterController?
    private var bag = Set<AnyCancellable>()

    static var isDevBuild: Bool { Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? true }

    var isAvailable: Bool { controller != nil }

    var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    func start() {
        guard !Self.isDevBuild, controller == nil else { return }
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.isEmpty, !key.contains("PLACEHOLDER") else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        controller = c
        c.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheck = $0 }
            .store(in: &bag)
    }

    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    var automaticallyDownloads: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue; objectWillChange.send() }
    }

    // MARK: Gentle reminders (Pal lives in the background; don't steal focus)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        Task { @MainActor in Updater.shared.onUpdateAvailable?(version) }
    }
}
