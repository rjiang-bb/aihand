import AppKit
import SwiftUI

extension View {
    /// App-wide hover tip (floating tip window). Prefer this over SwiftUI `.help`,
    /// which is unreliable on floating / nonactivating panels.
    /// Pass an empty string to disable.
    ///
    /// Icon-only controls should include a short function label; append a shortcut
    /// when one exists (`HoverTooltipLabel.icon("Settings", shortcut: "⌘,")`).
    func hoverTooltip(_ text: String) -> some View {
        background(alignment: .center) {
            if !text.isEmpty {
                AppKitHoverTooltip(text: text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

enum HoverTooltipLabel {
    /// `"Settings (⌘,)"` or `"Remove"` when there is no shortcut.
    static func icon(_ title: String, shortcut: String? = nil) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return shortcut?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        guard let shortcut, !shortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return name
        }
        return "\(name) (\(shortcut))"
    }
}

enum HoverTooltipLevel {
    /// Above sessions (+2) and Settings (+4).
    static let base = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 5)

    /// Clear the hovered window *and* an NSMenu opened from it.
    /// Menus from high-level panels (annotate = screenSaver+3) sit at about owner+1;
    /// tips use owner+2 so "Cycle model (⌘/)" isn't trapped under the favorites menu.
    static func above(_ ownerLevel: NSWindow.Level) -> NSWindow.Level {
        let aboveOwnerAndMenu = ownerLevel.rawValue + 2
        let abovePopUp = NSWindow.Level.popUpMenu.rawValue + 1
        return NSWindow.Level(rawValue: max(base.rawValue, aboveOwnerAndMenu, abovePopUp))
    }
}

enum HoverTooltipPlacement {
    static let gap: CGFloat = 6
    static let screenPad: CGFloat = 4

    /// Prefer above the control (composer / annotate sit near the bottom); fall back below.
    static func origin(
        tipSize: NSSize,
        controlOnScreen: CGRect,
        visibleFrame: CGRect
    ) -> NSPoint {
        var origin = NSPoint(
            x: controlOnScreen.midX - tipSize.width / 2,
            y: controlOnScreen.maxY + gap
        )
        origin.x = min(
            max(origin.x, visibleFrame.minX + screenPad),
            visibleFrame.maxX - tipSize.width - screenPad
        )
        if origin.y + tipSize.height > visibleFrame.maxY - screenPad {
            origin.y = controlOnScreen.minY - tipSize.height - gap
        }
        return origin
    }
}

/// Hosts an always-active tracking area and shows a small tip window on hover.
private struct AppKitHoverTooltip: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> AppKitHoverTooltipView {
        let view = AppKitHoverTooltipView()
        view.tooltipText = text
        return view
    }

    func updateNSView(_ nsView: AppKitHoverTooltipView, context: Context) {
        nsView.tooltipText = text
    }
}

private final class AppKitHoverTooltipView: NSView {
    var tooltipText: String = "" {
        didSet {
            if !tooltipText.isEmpty, tipVisible {
                HoverTooltipWindow.shared.show(text: tooltipText, relativeTo: self)
            }
        }
    }

    private var tipVisible = false
    private var showWork: DispatchWorkItem?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        if window == nil {
            cancelTip()
        }
        updateTrackingAreas()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelTip()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        guard !bounds.isEmpty else { return }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        scheduleShow()
    }

    override func mouseExited(with event: NSEvent) {
        cancelTip()
    }

    private func scheduleShow() {
        showWork?.cancel()
        let text = tooltipText
        guard !text.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window != nil else { return }
            self.tipVisible = true
            HoverTooltipWindow.shared.show(text: text, relativeTo: self)
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func cancelTip() {
        showWork?.cancel()
        showWork = nil
        tipVisible = false
        HoverTooltipWindow.shared.hide(for: self)
    }
}

/// Tiny floating tip — rises above the hovered control's window (sessions, Settings, annotate…).
private final class HoverTooltipWindow {
    static let shared = HoverTooltipWindow()

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private weak var owner: NSView?

    private init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 24),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = HoverTooltipLevel.base
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.isBezeled = false
        label.drawsBackground = false
        label.lineBreakMode = .byClipping

        let chrome = NSVisualEffectView(frame: .zero)
        chrome.material = .toolTip
        chrome.blendingMode = .withinWindow
        chrome.state = .active
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 5
        chrome.layer?.masksToBounds = true

        let container = NSView(frame: .zero)
        container.addSubview(chrome)
        container.addSubview(label)
        chrome.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: container.topAnchor),
            chrome.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        panel.contentView = container
    }

    func show(text: String, relativeTo view: NSView) {
        owner = view
        label.stringValue = text
        label.sizeToFit()
        let size = NSSize(
            width: ceil(label.fittingSize.width) + 16,
            height: ceil(label.fittingSize.height) + 8
        )
        panel.setContentSize(size)

        guard let window = view.window else { return }
        panel.level = HoverTooltipLevel.above(window.level)
        let rectInWindow = view.convert(view.bounds, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: rectOnScreen.minX, y: rectOnScreen.minY, width: 2000, height: 2000)
        let origin = HoverTooltipPlacement.origin(
            tipSize: size,
            controlOnScreen: rectOnScreen,
            visibleFrame: visible
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func hide(for view: NSView) {
        guard owner === view || owner == nil else { return }
        owner = nil
        panel.orderOut(nil)
    }
}
