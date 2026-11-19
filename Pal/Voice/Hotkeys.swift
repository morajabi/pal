import AppKit
import Carbon.HIToolbox

/// System-wide shortcut via Carbon. Needs no permissions.
final class GlobalHotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1

    private var ref: EventHotKeyRef?
    private let id: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        Self.installHandler()
        id = Self.nextID
        Self.nextID += 1
        let hkID = EventHotKeyID(signature: OSType(0x50414C21), id: id) // 'PAL!'
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        Self.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let id = hkID.id
            DispatchQueue.main.async { GlobalHotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Hold-a-modifier-to-talk. Uses a listen-only event tap, which needs Input Monitoring.
/// A short hold delay keeps normal ⌥/⌘ shortcuts working: pressing another key cancels it.
final class HoldToTalk {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?

    var key: HoldKey = .rightOption {
        didSet { reset() }
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false
    private var active = false
    private var pendingWork: DispatchWorkItem?
    private let holdDelay: TimeInterval = 0.2

    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    /// Shows the system prompt (macOS only shows it once).
    static func requestPermission() {
        _ = CGRequestListenEventAccess()
    }

    /// For when the prompt was dismissed: take the user to the right settings pane.
    static func openSettings() {
        if !CGRequestListenEventAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent")!)
        }
    }

    /// Returns false if permission is missing.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.hasPermission else { return false }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HoldToTalk>.fromOpaque(refcon).takeUnretainedValue()
            me.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: CGEventMask(mask), callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    var isRunning: Bool { tap != nil }

    private func reset() {
        pendingWork?.cancel()
        pendingWork = nil
        if active { active = false; onEnd?() }
        isDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard let code = key.keyCode else { return }

        if type == .keyDown {
            // Used as a modifier for a shortcut: not a talk.
            if isDown && !active { pendingWork?.cancel(); pendingWork = nil }
            return
        }
        guard type == .flagsChanged else { return }
        let flags = event.flags.rawValue
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if keyCode == code {
            let down = flags & key.flagMask != 0
            if down && !isDown {
                isDown = true
                // Only a bare press counts (no other modifiers held).
                let others: CGEventFlags = [.maskShift, .maskControl, .maskCommand, .maskAlternate]
                let otherHeld = event.flags.intersection(others).subtracting(key == .rightOption ? .maskAlternate : key == .rightCommand ? .maskCommand : []).isEmpty == false
                guard !otherHeld else { return }
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isDown else { return }
                    self.active = true
                    self.onBegin?()
                }
                pendingWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
            } else if !down && isDown {
                isDown = false
                pendingWork?.cancel()
                pendingWork = nil
                if active { active = false; onEnd?() }
            }
        } else if isDown && !active {
            // Another modifier joined in: it's a chord, not a talk.
            pendingWork?.cancel()
            pendingWork = nil
        }
    }
}
