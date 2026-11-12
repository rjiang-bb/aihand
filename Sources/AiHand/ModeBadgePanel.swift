import AppKit
import QuartzCore

/// Black title pill (same look as the sessions “Ai Sessions” header) for Drawing / Video mode.
final class ModeBadgePanel {
    enum Mode: Equatable {
        case drawing
        case video

        var title: String {
            switch self {
            case .drawing: return "Drawing mode"
            case .video: return "Video mode"
            }
        }
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private var panel: Panel?
    private(set) var mode: Mode?

    var frame: CGRect { panel?.frame ?? .zero }

    /// Same cursor mark as the menu-bar / sessions title pill.
    private static let logoImage: NSImage = {
        let image = (Bundle.main.image(forResource: "menubar_on")?.copy() as? NSImage)
            ?? NSImage(systemSymbolName: "hand.point.up.left.fill", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 14, height: 14))
        image.size = NSSize(width: 14, height: 14)
        image.isTemplate = true
        return image
    }()

    func show(mode: Mode, on screen: NSScreen, above chromeFrame: CGRect, animated: Bool = false) {
        if panel != nil, self.mode == mode {
            reposition(on: screen, above: chromeFrame, animated: animated)
            return
        }
        hide(animated: false)
        self.mode = mode

        let p = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.alphaValue = animated ? 0 : 1

        let card = NSView(frame: .zero)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.black.cgColor
        card.layer?.cornerRadius = 17
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1.25
        card.layer?.borderColor = NSColor.white.cgColor
        p.contentView = card

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 15)
        row.translatesAutoresizingMaskIntoConstraints = false

        let logo = NSImageView(image: Self.logoImage)
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.contentTintColor = .white
        logo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 15),
            logo.heightAnchor.constraint(equalToConstant: 15),
        ])
        row.addArrangedSubview(logo)

        let label = NSTextField(labelWithString: mode.title)
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .white
        label.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(label)

        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            row.topAnchor.constraint(equalTo: card.topAnchor),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            card.heightAnchor.constraint(equalToConstant: 34),
        ])
        row.layoutSubtreeIfNeeded()
        let fitted = row.fittingSize
        p.setContentSize(NSSize(width: max(fitted.width, 120), height: 34))

        place(p, on: screen, above: chromeFrame)
        p.orderFrontRegardless()
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                p.animator().alphaValue = 1
            }
        }
        panel = p
    }

    func hide(animated: Bool = true) {
        guard let p = panel else { return }
        panel = nil
        mode = nil
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                p.animator().alphaValue = 0
            }, completionHandler: {
                p.orderOut(nil)
            })
        } else {
            p.orderOut(nil)
        }
    }

    func reposition(on screen: NSScreen, above chromeFrame: CGRect, animated: Bool = false) {
        guard let p = panel else { return }
        place(p, on: screen, above: chromeFrame, animated: animated)
    }

    private func place(_ p: NSPanel, on screen: NSScreen, above chromeFrame: CGRect, animated: Bool = false) {
        let visible = screen.visibleFrame
        let y = AnnotationChromeLayout.modeBadgeOriginY(belowChromeMaxY: chromeFrame.maxY)
        let frame = NSRect(
            x: visible.midX - p.frame.width / 2,
            y: y,
            width: p.frame.width,
            height: p.frame.height
        )
        AnnotationHintPanel.move(p, to: frame, animated: animated)
    }
}
