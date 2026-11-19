import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Computer use, built into Pal so it runs with Pal's Accessibility + Screen Recording grants.
/// Accessibility-first (read controls, press them); screenshots and raw input as fallback.
/// Coordinates are global screen points, origin at the top-left of the main display.
@MainActor
enum ComputerUse {
    /// Elements from the last ui_snapshot, by id.
    private static var elements: [Int: AXUIElement] = [:]

    static var tools: [PalTool] {
        let agent: Set<Tier> = [.agent]
        return [
            PalTool("screenshot", "Take a screenshot", category: .computer, tiers: agent,
                    description: "See the screen. Returns an image where pixel coordinates equal screen points (origin top-left of the main display). Optionally a region.",
                    props: ["x": .number("Region left"), "y": .number("Region top"), "width": .number("Region width"), "height": .number("Region height"),
                            "display": .integer("Display index, 0 = main")]) { a, _ in
                try await Permissions.shared.require(.screenRecording)
                return try await screenshot(display: a.int("display") ?? 0,
                                            region: a.double("width").map { w in CGRect(x: a.double("x") ?? 0, y: a.double("y") ?? 0, width: w, height: a.double("height") ?? w) })
            },
            PalTool("ui_snapshot", "Read on-screen controls", category: .computer, tiers: agent,
                    description: "List the buttons, fields, text and other controls in an app's front window with ids and frames. Use the ids with click_element / set_value. Defaults to the frontmost app.",
                    props: ["app": .string("App name (default: frontmost)"), "max_items": .integer("Default 250")]) { a, _ in
                try await Permissions.shared.require(.accessibility)
                return .text(try snapshot(appName: a.string("app"), limit: a.int("max_items") ?? 250))
            },
            PalTool("click_element", "Press a control", category: .computer, tiers: agent,
                    description: "Press a control from the last ui_snapshot by id (uses its accessibility action, falls back to clicking its center).",
                    props: ["id": .integer("Element id from ui_snapshot")], required: ["id"]) { a, _ in
                try await Permissions.shared.require(.accessibility)
                guard let id = a.int("id"), let el = elements[id] else { return .error("Unknown element id; take a new ui_snapshot.") }
                if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success { return .text("Pressed \(id).") }
                guard let f = frame(el) else { return .error("That element can't be pressed.") }
                click(CGPoint(x: f.midX, y: f.midY), button: .left, count: 1)
                return .text("Clicked the center of \(id).")
            },
            PalTool("set_value", "Fill a field", category: .computer, tiers: agent,
                    description: "Set the text of a field from the last ui_snapshot.",
                    props: ["id": .integer("Element id"), "text": .string("Text to put in the field")], required: ["id", "text"]) { a, _ in
                try await Permissions.shared.require(.accessibility)
                guard let id = a.int("id"), let el = elements[id] else { return .error("Unknown element id; take a new ui_snapshot.") }
                AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                let r = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, try a.required("text") as CFString)
                return r == .success ? .text("Set.") : .error("Couldn't set that field (\(r.rawValue)); try clicking it and type_text.")
            },
            PalTool("click", "Click", category: .computer, tiers: agent,
                    description: "Click at screen coordinates (points).",
                    props: ["x": .number("X"), "y": .number("Y"), "button": .oneOf(["left", "right"], "Default left"), "count": .integer("1 or 2 (double-click)")],
                    required: ["x", "y"]) { a, _ in
                try await Permissions.shared.require(.accessibility)
                click(CGPoint(x: a.double("x") ?? 0, y: a.double("y") ?? 0), button: a.string("button") == "right" ? .right : .left, count: a.int("count") ?? 1)
                return .text("Clicked.")
            },
            PalTool("type_text", "Type", category: .computer, tiers: agent,
                    description: "Type text into whatever has keyboard focus.",
                    props: ["text": .string("Text to type")], required: ["text"]) { a, _ in
                try await Permissions.shared.require(.accessibility)
                try await type(try a.required("text"))
                return .text("Typed.")
            },
            PalTool("press_keys", "Press keys", category: .computer, tiers: agent,
                    description: "Press a key or shortcut, e.g. 'return', 'escape', 'cmd+t', 'cmd+shift+4', 'down', 'tab'.",
                    props: ["keys": .string("Key combo"), "repeat": .integer("Times to press (default 1)")], required: ["keys"]) { a, _ in
                try await Permissions.shared.require(.accessibility)
                let combo = try a.required("keys")
                for _ in 0..<max(1, min(a.int("repeat") ?? 1, 50)) { try press(combo) }
                return .text("Pressed \(combo).")
            },
            PalTool("scroll", "Scroll", category: .computer, tiers: agent,
                    description: "Scroll at a point. Positive dy scrolls down.",
                    props: ["x": .number("X"), "y": .number("Y"), "dx": .integer("Horizontal lines"), "dy": .integer("Vertical lines")]) { a, _ in
                try await Permissions.shared.require(.accessibility)
                if let x = a.double("x"), let y = a.double("y") { move(CGPoint(x: x, y: y)) }
                let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                wheel1: Int32(-(a.int("dy") ?? 0)), wheel2: Int32(-(a.int("dx") ?? 0)), wheel3: 0)
                e?.post(tap: .cghidEventTap)
                return .text("Scrolled.")
            },
            PalTool("drag", "Drag", category: .computer, tiers: agent,
                    description: "Drag from one point to another.",
                    props: ["from_x": .number(""), "from_y": .number(""), "to_x": .number(""), "to_y": .number("")],
                    required: ["from_x", "from_y", "to_x", "to_y"]) { a, _ in
                try await Permissions.shared.require(.accessibility)
                let from = CGPoint(x: a.double("from_x") ?? 0, y: a.double("from_y") ?? 0)
                let to = CGPoint(x: a.double("to_x") ?? 0, y: a.double("to_y") ?? 0)
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)?.post(tap: .cghidEventTap)
                for i in 1...12 {
                    let t = CGFloat(i) / 12
                    let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
                    try await Task.sleep(for: .milliseconds(12))
                }
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)?.post(tap: .cghidEventTap)
                return .text("Dragged.")
            },
            PalTool("list_windows", "List windows", category: .computer, tiers: agent,
                    description: "List visible windows with app, title and frame.") { _, _ in
                let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
                let lines = info.compactMap { w -> String? in
                    guard (w[kCGWindowLayer as String] as? Int) == 0, let owner = w[kCGWindowOwnerName as String] as? String,
                          let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
                    let title = w[kCGWindowName as String] as? String ?? ""
                    return "- \(owner)\(title.isEmpty ? "" : " — \(title)") (\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0))×\(Int(b["Height"] ?? 0)))"
                }
                return .text(lines.isEmpty ? "No windows (Screen Recording may be needed for titles)." : lines.joined(separator: "\n"))
            },
        ]
    }

    // MARK: Screenshot

    static func screenshot(display index: Int, region: CGRect?) async throws -> ToolOutput {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displays = content.displays.sorted { $0.displayID == CGMainDisplayID() && $1.displayID != CGMainDisplayID() }
        guard !displays.isEmpty else { throw PalError("No display to capture.") }
        let display = displays[min(max(index, 0), displays.count - 1)]
        // Leave Pal's own dot and card out of the picture.
        let mine = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: mine)
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = true
        if let region {
            config.sourceRect = region
            config.width = Int(region.width)
            config.height = Int(region.height)
        }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else { throw PalError("Couldn't encode the screenshot.") }
        let frame = CGDisplayBounds(display.displayID)
        let note = "Display \(index) at (\(Int(frame.minX)),\(Int(frame.minY))), \(display.width)×\(display.height) points. "
            + (region.map { "Region origin (\(Int($0.minX)),\(Int($0.minY))) — add it to coordinates in this image." } ?? "Image pixels = screen points.")
        return ToolOutput(content: [.text(note), .image(jpeg, mime: "image/jpeg")])
    }

    // MARK: Accessibility

    static func focusedWindowTitle(pid: pid_t?) -> String? {
        guard let pid, AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard let win: AXUIElement = attr(app, kAXFocusedWindowAttribute) else { return nil }
        return attr(win, kAXTitleAttribute)
    }

    static func snapshot(appName: String?, limit: Int) throws -> String {
        let running = NSWorkspace.shared.runningApplications
        let app: NSRunningApplication?
        if let appName {
            app = running.first { $0.localizedName?.localizedCaseInsensitiveCompare(appName) == .orderedSame }
                ?? running.first { $0.localizedName?.localizedCaseInsensitiveContains(appName) == true }
        } else {
            app = NSWorkspace.shared.frontmostApplication
        }
        guard let app else { throw PalError("That app isn't running.") }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let root: AXUIElement = attr(axApp, kAXFocusedWindowAttribute) ?? attr(axApp, kAXMainWindowAttribute) ?? axApp
        elements = [:]
        var lines: [String] = ["\(app.localizedName ?? "App") — \(attr(root, kAXTitleAttribute) as String? ?? "window")"]
        var nextID = 1
        func walk(_ el: AXUIElement, depth: Int) {
            guard nextID <= limit, depth < 30 else { return }
            let role: String = attr(el, kAXRoleAttribute) ?? ""
            let title: String = attr(el, kAXTitleAttribute) ?? ""
            let desc: String = attr(el, kAXDescriptionAttribute) ?? ""
            let help: String = attr(el, kAXHelpAttribute) ?? ""
            var value = ""
            if let v: String = attr(el, kAXValueAttribute) { value = v }
            else if let n: NSNumber = attr(el, kAXValueAttribute) { value = n.stringValue }
            let label = [title, desc, value.isEmpty ? help : ""].filter { !$0.isEmpty }.joined(separator: " · ")
            let interesting = Self.interactive.contains(role) || (!label.isEmpty && Self.textual.contains(role))
            if interesting, let f = frame(el), f.width > 1, f.height > 1 {
                let id = nextID
                nextID += 1
                elements[id] = el
                let enabled: Bool = attr(el, kAXEnabledAttribute) ?? true
                lines.append("\(String(repeating: " ", count: min(depth, 8)))[\(id)] \(role.replacingOccurrences(of: "AX", with: "")) \"\(label.prefix(120))\" at (\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)))\(enabled ? "" : " disabled")")
            }
            let children: [AXUIElement] = attr(el, kAXChildrenAttribute) ?? []
            for c in children { walk(c, depth: depth + 1) }
        }
        walk(root, depth: 0)
        if nextID > limit { lines.append("… (more; raise max_items)") }
        return lines.joined(separator: "\n")
    }

    private static let interactive: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXTextArea",
        "AXSearchField", "AXComboBox", "AXSlider", "AXLink", "AXMenuItem", "AXTab", "AXDisclosureTriangle", "AXCell", "AXRow", "AXIncrementor",
    ]
    private static let textual: Set<String> = ["AXStaticText", "AXHeading", "AXImage", "AXGroup", "AXWebArea"]

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    // MARK: Input

    static func move(_ p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    static func click(_ p: CGPoint, button: CGMouseButton, count: Int) {
        let down: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        move(p)
        for i in 1...max(1, min(count, 3)) {
            let d = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: p, mouseButton: button)
            d?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            d?.post(tap: .cghidEventTap)
            let u = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: p, mouseButton: button)
            u?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            u?.post(tap: .cghidEventTap)
        }
    }

    static func type(_ text: String) async throws {
        let chars = Array(text.utf16)
        var i = 0
        while i < chars.count {
            let chunk = Array(chars[i..<min(i + 20, chars.count)])
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up?.post(tap: .cghidEventTap)
            i += 20
            try await Task.sleep(for: .milliseconds(8))
        }
    }

    static func press(_ combo: String) throws {
        let parts = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for p in parts {
            switch p {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: key = keyCodes[p]
            }
        }
        guard let key else { throw PalError("Unknown key in “\(combo)”.") }
        let d = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)
        d?.flags = flags
        d?.post(tap: .cghidEventTap)
        let u = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
        u?.flags = flags
        u?.post(tap: .cghidEventTap)
    }

    private static let keyCodes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "-": 27, "=": 24, "[": 33, "]": 30, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "\\": 42, "`": 50,
        ]
        let letters: [(String, CGKeyCode)] = [("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
                                             ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("o", 31), ("u", 32),
                                             ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46)]
        let digits: [(String, CGKeyCode)] = [("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25), ("0", 29)]
        for (k, v) in letters + digits { m[k] = v }
        return m
    }()
}
