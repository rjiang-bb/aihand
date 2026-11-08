import AppKit

/// Bottom-right floating thumbnail of a just-saved capture; click to open, drag into other apps.
final class ScreenshotSavePreview {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class DragImageView: NSImageView, NSDraggingSource {
        var fileURL: URL?
        var onInteract: (() -> Void)?
        var onClick: (() -> Void)?
        private var downPoint: NSPoint?
        private var dragging = false

        override func mouseDown(with event: NSEvent) {
            onInteract?()
            downPoint = event.locationInWindow
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let downPoint, let fileURL, let image else { return }
            let p = event.locationInWindow
            if !dragging {
                if hypot(p.x - downPoint.x, p.y - downPoint.y) < 4 { return }
                dragging = true
                let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
                item.setDraggingFrame(bounds, contents: image)
                beginDraggingSession(with: [item], event: event, source: self)
            }
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                downPoint = nil
                dragging = false
            }
            if !dragging {
                onClick?()
            }
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            onInteract?()
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            onInteract?()
        }
    }

    private var panel: Panel?
    private var hintPanel: Panel?
    private var fileURL: URL?
    private var dismissWork: DispatchWorkItem?
    private var hostScreen: NSScreen?

    var frame: CGRect {
        let p = panel?.frame ?? .zero
        let h = hintPanel?.frame ?? .zero
        return p.isEmpty ? h : p.union(h)
    }

    func show(fileURL: URL, image: NSImage, on screen: NSScreen) {
        hide(animated: false)
        self.fileURL = fileURL
        hostScreen = screen

        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let maxSide: CGFloat = 200
        let imgSize = image.size
        let scale = min(1, maxSide / max(imgSize.width, imgSize.height, 1))
        let thumb = CGSize(width: max(48, imgSize.width * scale), height: max(48, imgSize.height * scale))
        let pad: CGFloat = 8

        let closeBleed: CGFloat = 11
        let preview = Panel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: thumb.width + pad * 2 + closeBleed,
                height: thumb.height + pad * 2 + closeBleed
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        preview.isOpaque = false
        preview.backgroundColor = .clear
        preview.hasShadow = true
        preview.ignoresMouseEvents = false
        preview.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        preview.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        preview.isReleasedWhenClosed = false
        preview.alphaValue = 0

        let root = NSView(frame: .zero)
        root.wantsLayer = true
        preview.contentView = root

        let card = NSView(frame: .zero)
        card.wantsLayer = true
        card.layer?.backgroundColor = SoftChrome.cardNSColor(dark: dark).cgColor
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 3
        card.layer?.borderColor = NSColor.systemBlue.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)

        let imageView = DragImageView(frame: .zero)
        imageView.image = image
        imageView.fileURL = fileURL
        imageView.onInteract = { [weak self] in self?.bumpAutoDismiss() }
        imageView.onClick = { [weak self] in self?.openFile() }
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(imageView)

        let close = makeCloseButton(dark: dark)
        root.addSubview(close)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -closeBleed),
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: closeBleed),

            imageView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
            imageView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),
            imageView.topAnchor.constraint(equalTo: card.topAnchor, constant: pad),
            imageView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -pad),
            imageView.widthAnchor.constraint(equalToConstant: thumb.width),
            imageView.heightAnchor.constraint(equalToConstant: thumb.height),

            close.widthAnchor.constraint(equalToConstant: 22),
            close.heightAnchor.constraint(equalToConstant: 22),
            close.centerXAnchor.constraint(equalTo: card.trailingAnchor),
            close.centerYAnchor.constraint(equalTo: card.topAnchor),
        ])
        root.layoutSubtreeIfNeeded()
        preview.setContentSize(root.fittingSize)

        let isVideo = fileURL.pathExtension.lowercased() == "mov"
            || fileURL.pathExtension.lowercased() == "mp4"
        let hint = makeHint(dark: dark, isVideo: isVideo)
        place(preview: preview, hint: hint, on: screen)
        preview.orderFrontRegardless()
        hint.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            preview.animator().alphaValue = 1
            hint.animator().alphaValue = 1
        }
        panel = preview
        hintPanel = hint
        scheduleAutoDismiss()
    }

    func hide() {
        hide(animated: true)
    }

    private func hide(animated: Bool) {
        cancelAutoDismiss()
        let panels = [panel, hintPanel].compactMap { $0 }
        panel = nil
        hintPanel = nil
        fileURL = nil
        hostScreen = nil
        guard !panels.isEmpty else { return }
        if !animated {
            panels.forEach { $0.orderOut(nil); $0.alphaValue = 0 }
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            for p in panels {
                p.animator().alphaValue = 0
            }
        }, completionHandler: {
            panels.forEach { $0.orderOut(nil) }
        })
    }

    private func openFile() {
        guard let fileURL else { return }
        NSWorkspace.shared.open(fileURL)
        hide(animated: true)
    }

    private func scheduleAutoDismiss() {
        cancelAutoDismiss()
        let work = DispatchWorkItem { [weak self] in
            self?.slideOffAndHide()
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Cancel the current countdown and start a fresh 5s window (after click/drag).
    private func bumpAutoDismiss() {
        scheduleAutoDismiss()
    }

    private func cancelAutoDismiss() {
        dismissWork?.cancel()
        dismissWork = nil
    }

    private func slideOffAndHide() {
        guard let preview = panel, let hint = hintPanel else { return }
        dismissWork = nil
        let screen = hostScreen ?? preview.screen ?? NSScreen.main
        let offX = (screen?.frame.maxX ?? preview.frame.maxX) + 24
        let previewDest = CGPoint(x: offX, y: preview.frame.origin.y)
        let hintDest = CGPoint(x: offX, y: hint.frame.origin.y)
        panel = nil
        hintPanel = nil
        fileURL = nil
        hostScreen = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            preview.animator().setFrameOrigin(previewDest)
            hint.animator().setFrameOrigin(hintDest)
            preview.animator().alphaValue = 0
            hint.animator().alphaValue = 0
        }, completionHandler: {
            preview.orderOut(nil)
            hint.orderOut(nil)
        })
    }

    private func makeCloseButton(dark: Bool) -> NSButton {
        let b = NSButton(frame: .zero)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.wantsLayer = true
        b.layer?.backgroundColor = (dark ? NSColor.white : NSColor.black).cgColor
        b.layer?.cornerRadius = 11
        b.layer?.borderWidth = 1
        b.layer?.borderColor = (dark ? NSColor.black.withAlphaComponent(0.35) : NSColor.white.withAlphaComponent(0.55)).cgColor
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        b.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")?
            .withSymbolConfiguration(config)
        b.imagePosition = .imageOnly
        b.contentTintColor = dark ? .black : .white
        b.toolTip = "Dismiss"
        b.setAccessibilityLabel("Dismiss")
        b.translatesAutoresizingMaskIntoConstraints = false
        b.target = self
        b.action = #selector(closeTapped)
        return b
    }

    @objc private func closeTapped() {
        hide(animated: true)
    }

    private func makeHint(dark: Bool, isVideo: Bool) -> Panel {
        let p = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.alphaValue = 0

        let card = NSView(frame: .zero)
        card.wantsLayer = true
        card.layer?.backgroundColor = SoftChrome.cardNSColor(dark: dark).cgColor
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.08)).cgColor
        p.contentView = card

        let fg = dark ? NSColor.white : NSColor.black
        let text = NSMutableAttributedString(string: "Click", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: fg,
        ])
        text.append(NSAttributedString(
            string: isVideo ? "  to play · Drag into any app" : "  to open · Drag into any app",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: fg.withAlphaComponent(0.55),
            ]
        ))
        let label = NSTextField(labelWithAttributedString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        card.layoutSubtreeIfNeeded()
        p.setContentSize(card.fittingSize)
        return p
    }

    private func place(preview: NSPanel, hint: NSPanel, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let margin: CGFloat = 16
        let gap: CGFloat = 8
        let originY = visible.minY + margin
        let previewX = visible.maxX - preview.frame.width - margin
        let hintX = visible.maxX - hint.frame.width - margin
        hint.setFrameOrigin(CGPoint(x: hintX, y: originY))
        preview.setFrameOrigin(CGPoint(x: previewX, y: originY + hint.frame.height + gap))
    }
}
