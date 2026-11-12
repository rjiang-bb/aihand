import AppKit
import QuartzCore

/// Recording chrome shown above the hint strip while video mode is active.
final class VideoToolbarPanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Stop control for the nonactivating recording panel — cursor rects don’t stick
    /// unless the window is key, so we re-assert the hand via an `activeAlways` area.
    private final class StopButton: NSButton {
        private var tracking: NSTrackingArea?
        private var hovering = false {
            didSet { refreshBackground() }
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

        func refreshBackground() {
            layer?.backgroundColor = (hovering
                ? VideoToolbarChrome.stopHoverFill
                : VideoToolbarChrome.stopFill).cgColor
        }
    }

    private var panel: Panel?
    private var timerLabel: NSTextField?
    private var dotView: NSView?
    private var stopButton: StopButton?
    private var blinkTimer: Timer?
    /// UI-side tick so the clock advances even if the recorder callback is late/missing.
    private var displayTimer: Timer?
    private var displayStartedAt: Date?
    private var showingRecording = false

    var onStop: (() -> Void)?
    var frame: CGRect { panel?.frame ?? .zero }

    func show(on screen: NSScreen, above hintFrame: CGRect, recording: Bool, docked: Bool = false) {
        // Reuse the live panel when chrome is re-shown in the same mode (avoids
        // resetting the timer label / tearing down the Stop button).
        if panel != nil, showingRecording == recording {
            reposition(on: screen, above: hintFrame, docked: docked)
            return
        }

        hide()
        showingRecording = recording
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let inset = VideoToolbarChrome.rowInsets
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
        p.acceptsMouseMovedEvents = true
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
            let stop = StopButton()
            Self.styleStopButton(stop)
            stop.target = self
            stop.action = #selector(stopTapped)
            stopButton = stop
            row.addArrangedSubview(stop)
        } else {
            let stopped = NSTextField(labelWithString: VideoToolbarChrome.stoppedTitle)
            stopped.font = .systemFont(ofSize: 12, weight: .medium)
            stopped.textColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.55)
            row.addArrangedSubview(stopped)
            stopButton = nil
        }

        card.addSubview(row)
        // Explicit card insets — NSStackView.edgeInsets is unreliable with Auto Layout here.
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset.left),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset.right),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: inset.top),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset.bottom),
        ])
        row.layoutSubtreeIfNeeded()
        let fitted = row.fittingSize
        p.setContentSize(NSSize(
            width: fitted.width + inset.left + inset.right,
            height: fitted.height + inset.top + inset.bottom
        ))

        place(p, on: screen, above: hintFrame, docked: docked)
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
        }
        panel = p

        if recording {
            startBlink()
            startDisplayTimer(from: 0)
        } else {
            stopBlink()
            stopDisplayTimer()
            dotView?.layer?.opacity = 1
            dotView?.layer?.backgroundColor = NSColor.systemOrange.cgColor
        }
    }

    func setElapsed(_ seconds: TimeInterval) {
        let total = max(0, seconds)
        // Keep the local clock aligned with the recorder when callbacks arrive.
        displayStartedAt = Date().addingTimeInterval(-total)
        applyElapsed(total)
    }

    func hide() {
        stopBlink()
        stopDisplayTimer()
        showingRecording = false
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

    func reposition(on screen: NSScreen, above hintFrame: CGRect, docked: Bool = false, animated: Bool = false) {
        guard let p = panel else { return }
        place(p, on: screen, above: hintFrame, docked: docked, animated: animated)
    }

    private func place(
        _ p: NSPanel,
        on screen: NSScreen,
        above hintFrame: CGRect,
        docked: Bool = false,
        animated: Bool = false
    ) {
        let visible = screen.visibleFrame
        let frame = NSRect(
            x: visible.midX - p.frame.width / 2,
            y: AnnotationChromeLayout.toolsOriginY(
                hintHeight: hintFrame.height,
                visibleMinY: visible.minY,
                docked: docked
            ),
            width: p.frame.width,
            height: p.frame.height
        )
        AnnotationHintPanel.move(p, to: frame, animated: animated)
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

    private func startDisplayTimer(from seconds: TimeInterval) {
        stopDisplayTimer()
        displayStartedAt = Date().addingTimeInterval(-max(0, seconds))
        applyElapsed(seconds)
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let started = self.displayStartedAt else { return }
            self.applyElapsed(Date().timeIntervalSince(started))
        }
        RunLoop.main.add(t, forMode: .common)
        displayTimer = t
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
        displayStartedAt = nil
    }

    private func applyElapsed(_ seconds: TimeInterval) {
        let total = max(0, Int(seconds.rounded(.down)))
        let m = total / 60
        let s = total % 60
        timerLabel?.stringValue = String(format: "%02d:%02d", m, s)
    }

    @objc private func stopTapped() {
        onStop?()
    }

    /// Red “[stop] Stop” control used while recording (compact; card insets provide margin).
    static func styleStopButton(_ stop: NSButton) {
        stop.isBordered = false
        stop.bezelStyle = .regularSquare
        stop.wantsLayer = true
        stop.layer?.cornerRadius = 10
        stop.layer?.cornerCurve = .continuous
        stop.layer?.backgroundColor = VideoToolbarChrome.stopFill.cgColor
        stop.title = VideoToolbarChrome.stopTitle
        stop.font = .systemFont(ofSize: 13, weight: .semibold)
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        stop.image = NSImage(systemSymbolName: VideoToolbarChrome.stopSymbol, accessibilityDescription: VideoToolbarChrome.stopTitle)?
            .withSymbolConfiguration(config)
        stop.imagePosition = .imageLeading
        stop.imageHugsTitle = true
        stop.contentTintColor = .white
        stop.setButtonType(.momentaryChange)
        stop.setContentHuggingPriority(.required, for: .horizontal)
        stop.heightAnchor.constraint(equalToConstant: VideoToolbarChrome.stopHeight).isActive = true
        stop.widthAnchor.constraint(greaterThanOrEqualToConstant: VideoToolbarChrome.stopMinWidth).isActive = true
        (stop as? StopButton)?.refreshBackground()
    }
}

/// Shared chrome metrics / copy for the video recording toolbar.
enum VideoToolbarChrome {
    static let stopTitle = "Stop"
    static let stoppedTitle = "Stopped"
    static let stopSymbol = "stop.fill"
    /// Match the pre-red Stop control size; room around it comes from `rowInsets`.
    static let stopHeight: CGFloat = 32
    static let stopMinWidth: CGFloat = 72
    /// Margin between the Stop control (and row) and the card edge.
    static let rowInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 12)
    static let stopFill = NSColor.systemRed
    /// Slightly darker red while the pointer is over Stop.
    static let stopHoverFill = NSColor.systemRed.blended(withFraction: 0.22, of: .black)
        ?? NSColor.systemRed.withAlphaComponent(0.85)
}
