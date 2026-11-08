import AppKit
import Carbon.HIToolbox

/// In-place text annotation editor: opaque ink-colored box with a caret.
final class InkTextEditor: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onFrameChanged: (() -> Void)?

    private let panel: Panel
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private var keyMonitor: Any?
    private var fontSize: CGFloat = 16
    private var pad: CGFloat = 8
    private var topLeftScreen = CGPoint.zero
    private var resizing = false

    var isEditing: Bool { panel.isVisible }
    var frame: CGRect { panel.frame }

    /// Visual top-left of the box in screen coordinates (AppKit).
    var topLeftScreenPoint: CGPoint { topLeftScreen }

    override init() {
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isOpaque = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = self
        textView.font = .systemFont(ofSize: fontSize, weight: .semibold)
        scroll.documentView = textView

        let root = NSView(frame: .zero)
        root.wantsLayer = true
        root.layer?.cornerRadius = 8
        root.layer?.cornerCurve = .continuous
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        panel.contentView = root

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
        ])
    }

    func begin(
        topLeftScreen: CGPoint,
        background: CGColor,
        fontSize: CGFloat,
        on screen: NSScreen
    ) {
        cancelWithoutNotify()
        self.fontSize = fontSize
        self.pad = InkTextStyle.padding(forFontSize: fontSize)
        self.topLeftScreen = topLeftScreen

        let fg = InkTextStyle.contrastingForeground(for: background)
        let bg = NSColor(cgColor: background) ?? .systemPurple
        let fgColor = NSColor(cgColor: fg) ?? .white
        let radius = InkTextStyle.cornerRadius(forFontSize: fontSize)

        panel.backgroundColor = bg
        if let root = panel.contentView {
            root.wantsLayer = true
            root.layer?.backgroundColor = background
            root.layer?.cornerRadius = radius
            root.layer?.cornerCurve = .continuous
        }
        // Re-pin scroll insets for the new padding.
        if let root = panel.contentView {
            root.constraints.filter { $0.firstItem === scroll || $0.secondItem === scroll }.forEach {
                root.removeConstraint($0)
            }
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
                scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
                scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
                scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
            ])
        }

        textView.string = ""
        textView.font = .systemFont(ofSize: fontSize, weight: .semibold)
        textView.textColor = fgColor
        textView.insertionPointColor = fgColor
        textView.typingAttributes = InkTextStyle.attributes(fontSize: fontSize, foreground: fg)

        resizeToFit(on: screen)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        installKeyMonitor()
    }

    /// Save current text (empty → cancel/discard).
    func commit() {
        guard isEditing else { return }
        let value = textView.string
        // Capture the visual top-left before tearing down (may differ after screen clamping).
        topLeftScreen = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        tearDown()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            onCancel?()
        } else {
            onCommit?(value)
        }
    }

    func cancel() {
        guard isEditing else { return }
        tearDown()
        onCancel?()
    }

    private func cancelWithoutNotify() {
        guard isEditing else { return }
        tearDown()
    }

    private func tearDown() {
        removeKeyMonitor()
        panel.orderOut(nil)
        textView.string = ""
    }

    func windowDidResignKey(_ notification: Notification) {
        // Click-away is handled by the overlay; keep the editor up if something else briefly steals key.
    }

    func textDidChange(_ notification: Notification) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        resizeToFit(on: screen)
    }

    private func resizeToFit(on screen: NSScreen) {
        guard !resizing else { return }
        resizing = true
        defer { resizing = false }

        let maxTextWidth: CGFloat = min(520, screen.visibleFrame.width * 0.55)
        let measured = InkTextStyle.textSize(
            for: textView.string,
            fontSize: fontSize,
            maxTextWidth: maxTextWidth,
            attributes: textView.typingAttributes
        )
        // Container matches content width so Enter grows height only, not a wide empty column.
        let containerWidth = max(measured.width, fontSize)
        textView.textContainer?.containerSize = NSSize(width: containerWidth, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.frame.size = NSSize(width: containerWidth, height: measured.height)

        let size = NSSize(
            width: measured.width + pad * 2,
            height: measured.height + pad * 2
        )

        // Keep the top-left (click) edge fixed as the box grows downward.
        var origin = CGPoint(x: topLeftScreen.x, y: topLeftScreen.y - size.height)
        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        topLeftScreen = CGPoint(x: origin.x, y: origin.y + size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        onFrameChanged?()
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, self.panel.isKeyWindow else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let code = Int(event.keyCode)

            if code == kVK_Escape {
                DispatchQueue.main.async { self.cancel() }
                return nil
            }

            // ⌘↩ saves the text annotation.
            if (code == kVK_Return || code == kVK_ANSI_KeypadEnter),
               flags.contains(.command),
               !flags.contains(.shift),
               !flags.contains(.option),
               !flags.contains(.control) {
                DispatchQueue.main.async { self.commit() }
                return nil
            }

            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }
}
