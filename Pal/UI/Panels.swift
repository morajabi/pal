import AppKit
import SwiftUI

/// A borderless panel that floats over everything (including full-screen apps)
/// and never steals focus from what you're doing.
class FloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Where the dot lives, from Settings › Appearance.
enum Anchor {
    static var screen: NSScreen {
        let c = PalSettings.c
        if c.dotScreen == .activeScreen, let s = NSScreen.main { return s }
        return NSScreen.screens.first ?? NSScreen.main!
    }

    /// Center of the dot, in screen coordinates.
    static var dotCenter: NSPoint {
        let c = PalSettings.c
        let f = screen.visibleFrame
        let x = c.dotCorner.isRight ? f.maxX - c.dotOffsetX : f.minX + c.dotOffsetX
        let y = c.dotCorner.isTop ? f.maxY - c.dotOffsetY : f.minY + c.dotOffsetY
        return NSPoint(x: x, y: y)
    }
}

final class DotPanel: FloatingPanel {
    static let size: CGFloat = 96
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent, NSView) -> Void)?
    private let host: DotHostingView

    init(model: PalModel) {
        host = DotHostingView(rootView: DotView(model: model, settings: PalSettings.shared))
        super.init(size: NSSize(width: Self.size, height: Self.size))
        host.onClick = { [weak self] in self?.onClick?() }
        host.onRightClick = { [weak self] e, v in self?.onRightClick?(e, v) }
        host.onHover = { hovering in model.dotHovered = hovering }
        contentView = host
        reposition()
    }

    func reposition() {
        let c = Anchor.dotCenter
        host.hitRadius = 9 * PalSettings.c.dotSize + 6
        setFrameOrigin(NSPoint(x: c.x - Self.size / 2, y: c.y - Self.size / 2))
        host.updateTrackingAreas()
    }
}

private final class DotHostingView: NSHostingView<DotView> {
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent, NSView) -> Void)?
    var onHover: ((Bool) -> Void)?
    var hitRadius: CGFloat = 15
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Only the dot itself is clickable; the rest of the square passes clicks through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return hypot(p.x - bounds.midX, p.y - bounds.midY) <= hitRadius ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event, self) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let r = hitRadius
        let rect = NSRect(x: bounds.midX - r, y: bounds.midY - r, width: r * 2, height: r * 2)
        let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

struct CardActions {
    var close: () -> Void
    var play: () -> Void
    var copy: () -> Void
    var open: () -> Void
}

/// The glass answer card next to the dot. Grows to fit its content.
final class CardPanel: FloatingPanel {
    private var contentHeight: CGFloat = 80

    init(model: PalModel, actions: CardActions) {
        super.init(size: NSSize(width: 400, height: 120))
        let host = NSHostingView(rootView: CardView(model: model, settings: PalSettings.shared, actions: actions, onHeight: { _ in }))
        contentView = host
        host.rootView = CardView(model: model, settings: PalSettings.shared, actions: actions, onHeight: { [weak self] h in
            self?.contentHeight = h
            self?.reposition()
        })
        reposition()
    }

    func reposition() {
        let c = PalSettings.c
        let dot = Anchor.dotCenter
        let screen = Anchor.screen.visibleFrame
        let m = CardView.margin
        let width = c.cardWidth + 2 * m
        let height = min(contentHeight, screen.height * 0.72) + 2 * m
        let reach = 12 * c.dotSize + 4
        let x = c.dotCorner.isRight ? dot.x + reach + m - width : dot.x - reach - m
        let y = c.dotCorner.isTop ? dot.y - reach - 6 + m - height : dot.y + reach + 6 - m
        setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    func show() {
        reposition()
        orderFrontRegardless()
    }
}
