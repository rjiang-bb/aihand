import AppKit

/// Destinations offered after the user stops a screen recording.
enum VideoDestination: String, CaseIterable, Equatable {
    case comment
    case save
    case send
    case discard

    var title: String {
        switch self {
        case .comment: return "Save + comment"
        case .save: return "Save video"
        case .send: return "Attach to chat"
        case .discard: return "Discard"
        }
    }

    var shortcut: String {
        switch self {
        case .comment: return "⌘S"
        case .save: return "⌘⇧S"
        case .send: return "⌘↩"
        case .discard: return "Esc"
        }
    }

    var symbolName: String {
        switch self {
        case .comment: return "text.bubble"
        case .save: return "square.and.arrow.down"
        case .send: return "paperplane.fill"
        case .discard: return "trash"
        }
    }

    var isDestructive: Bool { self == .discard }
}

/// SoftChrome menu of post-stop video destinations (incl. discard).
final class VideoDestinationPicker {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Passes clicks through to the enclosing `RowButton`.
    private final class HitThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Hover matches chat session cards: inset white stroke, no fill.
    private final class RowButton: NSButton {
        var destination: VideoDestination = .save
        var dark = true
        private var tracking: NSTrackingArea?
        private let hoverBorder = CALayer()
        private var hovering = false {
            didSet { refreshChrome() }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = 8
            layer?.cornerCurve = .continuous
            hoverBorder.cornerRadius = 5.5
            hoverBorder.cornerCurve = .continuous
            hoverBorder.borderWidth = 1.25
            hoverBorder.opacity = 0
            layer?.addSublayer(hoverBorder)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            // Match SoftChrome softHoverInnerBorder inset (2.5).
            hoverBorder.frame = bounds.insetBy(dx: 2.5, dy: 2.5)
            hoverBorder.cornerRadius = max(0, (layer?.cornerRadius ?? 8) - 2.5)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
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
            hovering = true
            NSCursor.pointingHand.set()
        }

        override func mouseMoved(with event: NSEvent) {
            NSCursor.pointingHand.set()
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.pointingHand.set()
        }

        override func mouseExited(with event: NSEvent) {
            hovering = false
            NSCursor.arrow.set()
        }

        func refreshChrome() {
            layer?.backgroundColor = NSColor.clear.cgColor
            hoverBorder.borderColor = SoftChrome.hoverInnerBorderNSColor(dark: dark).cgColor
            hoverBorder.opacity = hovering ? 1 : 0
        }
    }

    private var panel: Panel?
    var onPick: ((VideoDestination) -> Void)?
    var frame: CGRect { panel?.frame ?? .zero }

    func show(on screen: NSScreen, above anchor: CGRect) {
        hide()
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let p = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = false
        p.acceptsMouseMovedEvents = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.alphaValue = 0

        let card = NSView(frame: .zero)
        card.wantsLayer = true
        card.layer?.backgroundColor = SoftChrome.cardNSColor(dark: dark).cgColor
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.08)).cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = Float(dark ? 0.5 : 0.16)
        card.layer?.shadowRadius = 14
        card.layer?.shadowOffset = CGSize(width: 0, height: -6)
        p.contentView = card

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        for dest in VideoDestination.allCases {
            if dest == .discard {
                let sep = NSView()
                sep.wantsLayer = true
                sep.layer?.backgroundColor = (dark ? NSColor.white : NSColor.black)
                    .withAlphaComponent(dark ? 0.12 : 0.08).cgColor
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
                let pad = NSView()
                pad.translatesAutoresizingMaskIntoConstraints = false
                pad.heightAnchor.constraint(equalToConstant: 4).isActive = true
                stack.addArrangedSubview(pad)
                stack.addArrangedSubview(sep)
                let pad2 = NSView()
                pad2.translatesAutoresizingMaskIntoConstraints = false
                pad2.heightAnchor.constraint(equalToConstant: 4).isActive = true
                stack.addArrangedSubview(pad2)
            }
            let row = makeRow(dest, dark: dark)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        card.addSubview(stack)
        let inset: CGFloat = 8
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),
        ])
        stack.layoutSubtreeIfNeeded()
        let fitted = stack.fittingSize
        p.setContentSize(NSSize(width: max(260, fitted.width + inset * 2), height: fitted.height + inset * 2))

        place(p, on: screen, above: anchor)
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 1
        }
        panel = p
    }

    func hide() {
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    func reposition(on screen: NSScreen, above anchor: CGRect) {
        guard let p = panel else { return }
        place(p, on: screen, above: anchor)
    }

    private func place(_ p: NSPanel, on screen: NSScreen, above anchor: CGRect) {
        let visible = screen.visibleFrame
        let gap: CGFloat = 10
        let y: CGFloat
        if anchor.height > 0 {
            y = anchor.maxY + gap
        } else {
            y = visible.minY + 230
        }
        var origin = CGPoint(x: visible.midX - p.frame.width / 2, y: y)
        // Keep on-screen if the menu would clip the top.
        if origin.y + p.frame.height > visible.maxY - 8 {
            origin.y = max(visible.minY + 8, (anchor.height > 0 ? anchor.minY : visible.midY) - gap - p.frame.height)
        }
        p.setFrameOrigin(origin)
    }

    private func makeRow(_ dest: VideoDestination, dark: Bool) -> RowButton {
        let row = RowButton()
        row.destination = dest
        row.dark = dark
        row.isBordered = false
        row.bezelStyle = .regularSquare
        row.setButtonType(.momentaryChange)
        row.target = self
        row.action = #selector(picked(_:))
        row.title = ""
        row.image = nil

        let titleColor: NSColor = dest.isDestructive
            ? .systemRed
            : (dark ? .white : .black)
        let muted = titleColor.withAlphaComponent(0.55)

        let content = HitThroughView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: dest.symbolName, accessibilityDescription: dest.title)?
            .withSymbolConfiguration(config)
        icon.contentTintColor = titleColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: dest.title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = titleColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false

        let shortcut = NSTextField(labelWithString: dest.shortcut)
        shortcut.font = .systemFont(ofSize: 12, weight: .medium)
        shortcut.textColor = muted
        shortcut.alignment = .right
        shortcut.setContentHuggingPriority(.required, for: .horizontal)
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcut.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(icon)
        content.addSubview(label)
        content.addSubview(shortcut)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -10),

            shortcut.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            shortcut.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            shortcut.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 10),

            content.heightAnchor.constraint(equalToConstant: 34),
        ])

        row.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            content.topAnchor.constraint(equalTo: row.topAnchor),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            row.heightAnchor.constraint(equalToConstant: 34),
        ])
        row.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.refreshChrome()
        return row
    }

    @objc private func picked(_ sender: Any?) {
        guard let row = sender as? RowButton else { return }
        let dest = row.destination
        hide()
        onPick?(dest)
    }
}
