import AppKit

/// Bottom-center shortcut strip shown while the pointer is active for annotating.
final class AnnotationHintPanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private var panel: Panel?

    var frame: CGRect { panel?.frame ?? .zero }

    func show(on screen: NSScreen) {
        hide()
        let p = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        // Match drawing tools / toolbar — below the hand overlay.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.alphaValue = 0

        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let card = NSView(frame: .zero)
        card.wantsLayer = true
        card.layer?.backgroundColor = SoftChrome.cardNSColor(dark: dark).cgColor
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.08)).cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = Float(dark ? 0.5 : 0.16)
        card.layer?.shadowRadius = 10
        card.layer?.shadowOffset = CGSize(width: 0, height: -4)
        p.contentView = card

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false

        let fg = dark ? NSColor.white : NSColor.black
        let muted = fg.withAlphaComponent(0.55)
        let parts: [(String, String)] = [
            ("⌘Z", "undo"),
            (Preferences.clearShortcut.display, "clear drawing"),
            ("⌘⇧S", "save screenshot"),
            ("⌘/", "screen / window"),
            ("Enter", "comment"),
            ("⌘↩", "send to agent"),
            ("Esc", "exit"),
        ]
        for part in parts {
            let text = NSMutableAttributedString(string: part.0, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: fg,
            ])
            text.append(NSAttributedString(string: "  " + part.1, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: muted,
            ]))
            row.addArrangedSubview(NSTextField(labelWithAttributedString: text))
        }

        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            row.topAnchor.constraint(equalTo: card.topAnchor),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        row.layoutSubtreeIfNeeded()
        p.setContentSize(row.fittingSize)

        place(p, on: screen)
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
        }
        panel = p
    }

    func hide() {
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    func reposition(on screen: NSScreen) {
        guard let p = panel else { return }
        place(p, on: screen)
    }

    /// Sit above the hand toolbar and the ink/color tray that opens over it.
    private func place(_ p: NSPanel, on screen: NSScreen) {
        let visible = screen.visibleFrame
        p.setFrameOrigin(CGPoint(
            x: visible.midX - p.frame.width / 2,
            y: visible.minY + 128
        ))
    }
}
