import AppKit

/// Recording chrome shown above the hint strip while video mode is active.
final class VideoToolbarPanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class Button: NSButton {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private var panel: Panel?
    private var timerLabel: NSTextField?
    private var dotView: NSView?
    private var stopButton: Button?
    private var blinkTimer: Timer?

    var onStop: (() -> Void)?
    var frame: CGRect { panel?.frame ?? .zero }

    func show(on screen: NSScreen, above hintFrame: CGRect, recording: Bool) {
        hide()
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let p = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
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
        card.layer?.shadowRadius = 12
        card.layer?.shadowOffset = CGSize(width: 0, height: -6)
        p.contentView = card

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
        ])
        dotView = dot
        row.addArrangedSubview(dot)

        let label = NSTextField(labelWithString: "00:00")
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        label.textColor = dark ? .white : .black
        label.setContentHuggingPriority(.required, for: .horizontal)
        timerLabel = label
        row.addArrangedSubview(label)

        if recording {
            let stop = Button()
            stop.isBordered = false
            stop.bezelStyle = .regularSquare
            stop.wantsLayer = true
            stop.layer?.cornerRadius = 10
            stop.layer?.backgroundColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? 0.14 : 0.08).cgColor
            stop.title = "Stop"
            stop.font = .systemFont(ofSize: 13, weight: .semibold)
            stop.contentTintColor = dark ? .white : .black
            stop.target = self
            stop.action = #selector(stopTapped)
            stop.setButtonType(.momentaryChange)
            stop.widthAnchor.constraint(equalToConstant: 64).isActive = true
            stop.heightAnchor.constraint(equalToConstant: 32).isActive = true
            stopButton = stop
            row.addArrangedSubview(stop)
        } else {
            let ready = NSTextField(labelWithString: "Ready")
            ready.font = .systemFont(ofSize: 12, weight: .medium)
            ready.textColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.55)
            row.addArrangedSubview(ready)
            stopButton = nil
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

        place(p, on: screen, above: hintFrame)
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
        }
        panel = p

        if recording {
            startBlink()
        } else {
            stopBlink()
            dotView?.layer?.opacity = 1
            dotView?.layer?.backgroundColor = NSColor.systemOrange.cgColor
        }
    }

    func setElapsed(_ seconds: TimeInterval) {
        let total = max(0, Int(seconds.rounded(.down)))
        let m = total / 60
        let s = total % 60
        timerLabel?.stringValue = String(format: "%02d:%02d", m, s)
    }

    func hide() {
        stopBlink()
        guard let p = panel else { return }
        panel = nil
        timerLabel = nil
        dotView = nil
        stopButton = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    func reposition(on screen: NSScreen, above hintFrame: CGRect) {
        guard let p = panel else { return }
        place(p, on: screen, above: hintFrame)
    }

    private func place(_ p: NSPanel, on screen: NSScreen, above hintFrame: CGRect) {
        let visible = screen.visibleFrame
        let gap: CGFloat = 10
        let y: CGFloat
        if hintFrame.height > 0 {
            y = hintFrame.maxY + gap
        } else {
            y = visible.minY + 178
        }
        p.setFrameOrigin(CGPoint(
            x: visible.midX - p.frame.width / 2,
            y: y
        ))
    }

    private func startBlink() {
        stopBlink()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let dot = self?.dotView?.layer else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            dot.opacity = dot.opacity < 0.5 ? 1 : 0.25
            CATransaction.commit()
        }
        if let blinkTimer {
            RunLoop.main.add(blinkTimer, forMode: .common)
        }
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
    }

    @objc private func stopTapped() {
        onStop?()
    }
}
