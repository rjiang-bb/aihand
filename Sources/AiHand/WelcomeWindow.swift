import AppKit
import ApplicationServices

final class WelcomeWindow: NSObject {
    var onTryIt: (() -> Void)?
    var simulateUntrusted = false

    private final class Card: NSWindow {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) {
            orderOut(nil)
        }
    }

    private var window: Card?
    private var timer: Timer?
    private var askedAt: Date?
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let button = PointerCursorButton(title: "", target: nil, action: nil)
    private let tip = NSTextField(labelWithString: "Still blocked? Remove old AiHand rows, enable the Applications one, relaunch.")

    static let shownKey = "welcomeShown"

    func show() {
        if window == nil {
            build()
        }
        refresh()
        UserDefaults.standard.set(true, forKey: WelcomeWindow.shownKey)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.invalidateShadow()
        window?.makeFirstResponder(nil)
        timer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var granted: Bool {
        AXIsProcessTrusted() && !simulateUntrusted
    }

    private func refresh() {
        title.stringValue = granted ? "You're all set" : "Allow Accessibility"
        subtitle.stringValue = granted ? "Press \(Preferences.toggleShortcut.display) any time to start." : "So your clicks become taps, not real clicks."
        button.title = granted ? "Start" : "Open Settings"
        tip.isHidden = granted || askedAt.map { Date().timeIntervalSince($0) < 10 } ?? true
    }

    @objc private func buttonPressed() {
        if granted {
            close()
            onTryIt?()
            return
        }
        askedAt = Date()
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func close() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
    }

    private func build() {
        let size = CGSize(width: 340, height: 300)
        let w = Card(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.level = .normal

        let card = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        card.material = .popover
        card.blendingMode = .behindWindow
        card.state = .active
        card.roundCorners(20)
        w.contentView = card

        let icon = NSImageView()
        icon.image = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 76).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 76).isActive = true

        title.font = NSFont.systemFont(ofSize: 19, weight: .semibold)
        title.alignment = .center
        subtitle.font = NSFont.systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        button.target = self
        button.action = #selector(buttonPressed)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        button.widthAnchor.constraint(equalToConstant: 180).isActive = true

        tip.font = NSFont.systemFont(ofSize: 11)
        tip.textColor = .secondaryLabelColor
        tip.alignment = .center
        tip.maximumNumberOfLines = 0
        tip.lineBreakMode = .byWordWrapping
        tip.usesSingleLineMode = false
        tip.cell?.wraps = true
        tip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [icon, title, subtitle, button, tip])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(16, after: icon)
        stack.setCustomSpacing(22, after: subtitle)
        stack.setCustomSpacing(12, after: button)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let closeButton = PointerCursorButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!,
            target: self,
            action: #selector(close)
        )
        closeButton.isBordered = false
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(closeButton)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: card.centerYAnchor, constant: 4),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -24),
            tip.widthAnchor.constraint(equalTo: stack.widthAnchor),
            closeButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            closeButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])
        card.removeFocusRings()
        window = w
    }

    func snapshot() -> NSBitmapImageRep? {
        if window == nil {
            build()
        }
        if simulateUntrusted {
            askedAt = Date().addingTimeInterval(-20)
        }
        refresh()
        guard let view = window?.contentView else {
            return nil
        }
        window?.appearance = NSAppearance(named: .aqua)
        view.layer?.backgroundColor = NSColor(white: 0.96, alpha: 1).cgColor
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}
