import AppKit

/// Tool + thickness strip shown above the annotation hint box while the hand is active.
final class DrawingToolsPanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class Button: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private var panel: Panel?
    private var toolButtons: [DrawTool: Button] = [:]
    private var toolBadges: [DrawTool: NSTextField] = [:]
    private var thicknessButtons: [StrokeThickness: Button] = [:]
    private var thicknessStrokes: [StrokeThickness: NSView] = [:]
    private var thicknessBadges: [StrokeThickness: NSTextField] = [:]
    private var actions: [Button: () -> Void] = [:]
    private var prefsObserver: NSObjectProtocol?

    var frame: CGRect { panel?.frame ?? .zero }

    func show(on screen: NSScreen, above hintFrame: CGRect) {
        hide()
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let p = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = false
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
        card.layer?.shadowRadius = 12
        card.layer?.shadowOffset = CGSize(width: 0, height: -6)
        p.contentView = card

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false

        let tools = NSStackView()
        tools.orientation = .horizontal
        tools.spacing = 4
        toolButtons = [:]
        toolBadges = [:]
        for tool in DrawTool.allCases {
            let b = makeToolButton(tool, dark: dark)
            toolButtons[tool] = b
            tools.addArrangedSubview(b)
        }
        row.addArrangedSubview(tools)
        row.addArrangedSubview(divider(dark: dark))

        let widths = NSStackView()
        widths.orientation = .horizontal
        widths.spacing = 4
        thicknessButtons = [:]
        thicknessStrokes = [:]
        thicknessBadges = [:]
        for thickness in StrokeThickness.allCases {
            let b = makeThicknessButton(thickness, dark: dark)
            thicknessButtons[thickness] = b
            widths.addArrangedSubview(b)
        }
        row.addArrangedSubview(widths)

        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            row.topAnchor.constraint(equalTo: card.topAnchor),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        row.layoutSubtreeIfNeeded()
        p.setContentSize(row.fittingSize)

        refreshSelection(dark: dark)
        place(p, on: screen, above: hintFrame)
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
        }
        panel = p

        prefsObserver = NotificationCenter.default.addObserver(
            forName: Preferences.changed, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshSelection(dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        }
    }

    func hide() {
        if let obs = prefsObserver {
            NotificationCenter.default.removeObserver(obs)
            prefsObserver = nil
        }
        guard let p = panel else { return }
        panel = nil
        toolButtons = [:]
        toolBadges = [:]
        thicknessButtons = [:]
        thicknessStrokes = [:]
        thicknessBadges = [:]
        actions = [:]
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

    private func refreshSelection(dark: Bool) {
        let fg = dark ? NSColor.white : NSColor.black
        let selectedFill = (dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? 0.18 : 0.1)
        let clear = NSColor.clear

        for (tool, button) in toolButtons {
            let on = tool == Preferences.drawTool
            button.layer?.backgroundColor = (on ? selectedFill : clear).cgColor
            button.contentTintColor = fg.withAlphaComponent(on ? 0.95 : 0.55)
            toolBadges[tool]?.textColor = fg.withAlphaComponent(on ? 0.85 : 0.4)
        }
        for (thickness, button) in thicknessButtons {
            let on = thickness == Preferences.strokeThickness
            button.layer?.backgroundColor = (on ? selectedFill : clear).cgColor
            thicknessStrokes[thickness]?.layer?.backgroundColor = fg.withAlphaComponent(on ? 0.9 : 0.35).cgColor
            thicknessBadges[thickness]?.textColor = fg.withAlphaComponent(on ? 0.85 : 0.4)
        }
    }

    private func makeToolButton(_ tool: DrawTool, dark: Bool) -> Button {
        let b = Button()
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.wantsLayer = true
        b.layer?.cornerRadius = 10
        b.toolTip = "\(tool.title) (\(tool.shortcut))"
        b.setAccessibilityLabel(tool.title)

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        b.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title)?
            .withSymbolConfiguration(config)
        b.imagePosition = .imageOnly
        b.contentTintColor = dark ? .white : .black

        let badge = NSTextField(labelWithString: tool.shortcut)
        badge.font = .systemFont(ofSize: 9, weight: .semibold)
        badge.textColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.45)
        badge.translatesAutoresizingMaskIntoConstraints = false
        b.addSubview(badge)
        toolBadges[tool] = badge

        b.widthAnchor.constraint(equalToConstant: 42).isActive = true
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        NSLayoutConstraint.activate([
            badge.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -4),
            badge.bottomAnchor.constraint(equalTo: b.bottomAnchor, constant: -3),
        ])

        b.target = self
        b.action = #selector(tapped(_:))
        actions[b] = {
            Preferences.drawTool = tool
        }
        return b
    }

    private func makeThicknessButton(_ thickness: StrokeThickness, dark: Bool) -> Button {
        let b = Button()
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.wantsLayer = true
        b.layer?.cornerRadius = 10
        b.toolTip = "\(thickness.title) stroke (\(thickness.shortcut))"
        b.setAccessibilityLabel(thickness.title)
        b.title = ""

        let lineHeight = 1.5 + CGFloat(thickness.rawValue - 1) * 1.35
        let stroke = NSView()
        stroke.wantsLayer = true
        stroke.layer?.backgroundColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.55).cgColor
        stroke.layer?.cornerRadius = lineHeight / 2
        stroke.translatesAutoresizingMaskIntoConstraints = false
        b.addSubview(stroke)
        thicknessStrokes[thickness] = stroke

        let badge = NSTextField(labelWithString: thickness.shortcut)
        badge.font = .systemFont(ofSize: 9, weight: .semibold)
        badge.textColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.45)
        badge.translatesAutoresizingMaskIntoConstraints = false
        b.addSubview(badge)
        thicknessBadges[thickness] = badge

        b.widthAnchor.constraint(equalToConstant: 38).isActive = true
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        NSLayoutConstraint.activate([
            stroke.centerXAnchor.constraint(equalTo: b.centerXAnchor),
            stroke.centerYAnchor.constraint(equalTo: b.centerYAnchor, constant: -2),
            stroke.widthAnchor.constraint(equalToConstant: 16),
            stroke.heightAnchor.constraint(equalToConstant: lineHeight),
            badge.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -4),
            badge.bottomAnchor.constraint(equalTo: b.bottomAnchor, constant: -3),
        ])

        b.target = self
        b.action = #selector(tapped(_:))
        actions[b] = {
            Preferences.strokeThickness = thickness
        }
        return b
    }

    private func divider(dark: Bool) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.14).cgColor
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return v
    }

    @objc private func tapped(_ sender: Button) {
        actions[sender]?()
    }
}
