import AppKit
import SwiftUI

/// AppKit control that shows the pointing-hand cursor (same as hyperlinks).
final class PointerCursorButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }
}

/// Nested hover count so soft-hover + button style can share one cursor without flicker.
enum PointerCursor {
    private static var depth = 0

    static func setHovering(_ hovering: Bool) {
        if hovering {
            depth += 1
            // `set()` (not push/pop) — AppKit cursor updates wipe a pushed cursor
            // on the next mouse move; this matches ChatResizeEdgeDrag / link hover.
            NSCursor.pointingHand.set()
        } else if depth > 0 {
            depth -= 1
            if depth == 0 {
                NSCursor.arrow.set()
            } else {
                NSCursor.pointingHand.set()
            }
        }
    }

    /// Test seam — nesting depth after balanced enter/leave pairs.
    static var nestingDepthForTests: Int { depth }

    static func resetForTests() {
        depth = 0
        NSCursor.arrow.set()
    }
}

extension View {
    /// Show the pointing-hand (link) cursor while the pointer is over this view.
    ///
    /// The sessions panel is a **nonactivating** `NSPanel`, so AppKit cursor rects
    /// (key-window only) never stick. We combine SwiftUI `onHover` with an
    /// `activeAlways` tracking area that re-asserts the hand on every move.
    func pointerCursor(enabled: Bool = true) -> some View {
        modifier(PointerCursorModifier(enabled: enabled))
    }
}

/// Plain buttons that use the pointing-hand cursor on hover (hyperlink-style).
struct PointerPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pointerCursor()
    }
}

extension ButtonStyle where Self == PointerPlainButtonStyle {
    static var pointerPlain: PointerPlainButtonStyle { PointerPlainButtonStyle() }
}

private struct PointerCursorModifier: ViewModifier {
    var enabled: Bool

    func body(content: Content) -> some View {
        content
            .background {
                if enabled {
                    PointerCursorTrackingRepresentable()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovering in
                guard enabled else { return }
                PointerCursor.setHovering(hovering)
            }
    }
}

/// Tracking-area host — works for nonactivating panels (`activeAlways`).
private struct PointerCursorTrackingRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> PointerCursorTrackingView {
        PointerCursorTrackingView()
    }

    func updateNSView(_ nsView: PointerCursorTrackingView, context: Context) {
        nsView.window?.acceptsMouseMovedEvents = true
        nsView.refreshTracking()
    }
}

private final class PointerCursorTrackingView: NSView {
    private var tracking: NSTrackingArea?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    /// Don't steal clicks from SwiftUI controls above/below.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        refreshTracking()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTracking()
    }

    override func layout() {
        super.layout()
        refreshTracking()
    }

    func refreshTracking() {
        if let tracking {
            removeTrackingArea(tracking)
            self.tracking = nil
        }
        guard !bounds.isEmpty else { return }
        // `activeAlways` — sessions UI is a nonactivating panel and is often not key.
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .activeAlways,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
                .cursorUpdate,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        // Leave restore to SwiftUI `onHover` / `PointerCursor` depth so nested
        // soft-hover + button-style hosts don't flicker back to the arrow early.
    }
}

// MARK: - Open hand (drag-to-reorder)

/// Open-hand cursor for drag-reorder surfaces (queue rows, etc.).
enum OpenHandCursor {
    private static var depth = 0

    static func setHovering(_ hovering: Bool) {
        if hovering {
            depth += 1
            NSCursor.openHand.set()
        } else if depth > 0 {
            depth -= 1
            if depth == 0 {
                NSCursor.arrow.set()
            } else {
                NSCursor.openHand.set()
            }
        }
    }

    static var nestingDepthForTests: Int { depth }

    static func resetForTests() {
        depth = 0
        NSCursor.arrow.set()
    }
}

extension View {
    /// Open-hand cursor for drag-to-reorder hit areas (nonactivating-panel safe).
    func openHandCursor(enabled: Bool = true) -> some View {
        modifier(OpenHandCursorModifier(enabled: enabled))
    }
}

private struct OpenHandCursorModifier: ViewModifier {
    var enabled: Bool

    func body(content: Content) -> some View {
        content
            .background {
                if enabled {
                    OpenHandCursorTrackingRepresentable()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovering in
                guard enabled else { return }
                OpenHandCursor.setHovering(hovering)
            }
    }
}

private struct OpenHandCursorTrackingRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> OpenHandCursorTrackingView {
        OpenHandCursorTrackingView()
    }

    func updateNSView(_ nsView: OpenHandCursorTrackingView, context: Context) {
        nsView.window?.acceptsMouseMovedEvents = true
        nsView.refreshTracking()
    }
}

private final class OpenHandCursorTrackingView: NSView {
    private var tracking: NSTrackingArea?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        refreshTracking()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTracking()
    }

    override func layout() {
        super.layout()
        refreshTracking()
    }

    func refreshTracking() {
        if let tracking {
            removeTrackingArea(tracking)
            self.tracking = nil
        }
        guard !bounds.isEmpty else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .activeAlways,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
                .cursorUpdate,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.openHand.set()
    }
}

// MARK: - Magnifier (attachment preview)

enum PreviewCursor {
    private static var depth = 0

    static var systemCursor: NSCursor {
        if #available(macOS 15.0, *) {
            return .zoomIn
        }
        return .pointingHand
    }

    static func setHovering(_ hovering: Bool) {
        if hovering {
            depth += 1
            systemCursor.set()
        } else if depth > 0 {
            depth -= 1
            if depth == 0 {
                NSCursor.arrow.set()
            } else {
                systemCursor.set()
            }
        }
    }

    static var nestingDepthForTests: Int { depth }

    static func resetForTests() {
        depth = 0
        NSCursor.arrow.set()
    }
}

extension View {
    /// Magnifying-glass cursor for click-to-preview media thumbs (nonactivating-panel safe).
    func previewCursor(enabled: Bool = true) -> some View {
        modifier(PreviewCursorModifier(enabled: enabled))
    }
}

private struct PreviewCursorModifier: ViewModifier {
    var enabled: Bool

    func body(content: Content) -> some View {
        content
            .background {
                if enabled {
                    PreviewCursorTrackingRepresentable()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovering in
                guard enabled else { return }
                PreviewCursor.setHovering(hovering)
            }
    }
}

private struct PreviewCursorTrackingRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> PreviewCursorTrackingView {
        PreviewCursorTrackingView()
    }

    func updateNSView(_ nsView: PreviewCursorTrackingView, context: Context) {
        nsView.window?.acceptsMouseMovedEvents = true
        nsView.refreshTracking()
    }
}

private final class PreviewCursorTrackingView: NSView {
    private var tracking: NSTrackingArea?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        refreshTracking()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTracking()
    }

    override func layout() {
        super.layout()
        refreshTracking()
    }

    func refreshTracking() {
        if let tracking {
            removeTrackingArea(tracking)
            self.tracking = nil
        }
        guard !bounds.isEmpty else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .activeAlways,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
                .cursorUpdate,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        PreviewCursor.systemCursor.set()
    }

    override func mouseMoved(with event: NSEvent) {
        PreviewCursor.systemCursor.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        PreviewCursor.systemCursor.set()
    }
}
