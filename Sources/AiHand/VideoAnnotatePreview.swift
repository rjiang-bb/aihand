import AppKit
import AVFoundation
import AVKit

/// Frameless video preview for annotate-after-save, positioned on the capture rect.
final class VideoAnnotatePreview {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class PlayButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// Transparent hit target over the picture; leaves the bottom control bar free.
    private final class PauseCatcherView: NSView {
        var onClick: (() -> Void)?
        /// Height reserved for AVPlayerView inline controls.
        var controlsReserve: CGFloat = 44

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Pass clicks in the bottom control strip through to AVPlayerView.
            if point.y < controlsReserve { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            onClick?()
        }
    }

    private var panel: Panel?
    private var player: AVPlayer?
    private var playOverlay: NSView?
    private var pauseCatcher: PauseCatcherView?
    private var endObserver: NSObjectProtocol?
    private var rateObserver: NSKeyValueObservation?
    private var hostScreen: NSScreen?

    var frame: CGRect { panel?.frame ?? .zero }

    func show(fileURL: URL, region: CGRect, on screen: NSScreen) {
        hide()
        hostScreen = screen

        let clipped = region.intersection(screen.frame)
        guard !clipped.isNull, clipped.width > 8, clipped.height > 8 else { return }

        let p = Panel(
            contentRect: clipped,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = true
        p.backgroundColor = .black
        p.hasShadow = true
        p.ignoresMouseEvents = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.setFrame(clipped, display: true)

        let root = NSView(frame: NSRect(origin: .zero, size: clipped.size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        p.contentView = root

        let item = AVPlayerItem(url: fileURL)
        let player = AVPlayer(playerItem: item)
        player.isMuted = false
        player.actionAtItemEnd = .pause
        self.player = player

        let playerView = AVPlayerView(frame: root.bounds)
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        playerView.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) {
            playerView.showsFullScreenToggleButton = false
            playerView.showsSharingServiceButton = false
        }
        root.addSubview(playerView)

        let catcher = PauseCatcherView(frame: root.bounds)
        catcher.autoresizingMask = [.width, .height]
        catcher.onClick = { [weak self] in
            self?.pauseFromClick()
        }
        catcher.isHidden = true
        root.addSubview(catcher)
        pauseCatcher = catcher

        let overlay = makePlayOverlay(size: root.bounds.size)
        root.addSubview(overlay)
        playOverlay = overlay

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak player] _ in
            player?.seek(to: .zero)
            self?.updateChrome(playing: false)
        }

        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                self?.updateChrome(playing: player.rate != 0)
            }
        }

        // Prime the first frame without starting playback.
        player.seek(to: .zero)
        updateChrome(playing: false)
        p.orderFrontRegardless()
        panel = p
    }

    func hide() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        rateObserver?.invalidate()
        rateObserver = nil
        player?.pause()
        player = nil
        playOverlay = nil
        pauseCatcher = nil
        panel?.orderOut(nil)
        panel = nil
        hostScreen = nil
    }

    private func makePlayOverlay(size: NSSize) -> NSView {
        let overlay = NSView(frame: NSRect(origin: .zero, size: size))
        overlay.wantsLayer = true
        overlay.autoresizingMask = [.width, .height]

        let buttonSize: CGFloat = 64
        let button = PlayButton(frame: NSRect(
            x: (size.width - buttonSize) / 2,
            y: (size.height - buttonSize) / 2,
            width: buttonSize,
            height: buttonSize
        ))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        button.layer?.cornerRadius = buttonSize / 2
        button.layer?.borderWidth = 1.5
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        button.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .bold)
        button.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")?
            .withSymbolConfiguration(config)
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.toolTip = "Play"
        button.setAccessibilityLabel("Play")
        button.target = self
        button.action = #selector(playTapped)
        overlay.addSubview(button)
        return overlay
    }

    private func updateChrome(playing: Bool) {
        playOverlay?.isHidden = playing
        pauseCatcher?.isHidden = !playing
    }

    private func pauseFromClick() {
        player?.pause()
        updateChrome(playing: false)
    }

    @objc private func playTapped() {
        updateChrome(playing: true)
        player?.play()
    }
}
