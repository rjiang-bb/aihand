import AppKit

extension NSView {
    func removeFocusRings() {
        focusRingType = .none
        subviews.forEach { $0.removeFocusRings() }
    }
}

extension NSVisualEffectView {
    static func darkGlass(radius: CGFloat) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        view.roundCorners(radius)
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(white: 0.07, alpha: 0.62).cgColor
        tint.layer?.cornerRadius = radius
        tint.layer?.borderWidth = 1
        tint.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tint)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tint.topAnchor.constraint(equalTo: view.topAnchor),
            tint.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        return view
    }

    func roundCorners(_ radius: CGFloat) {
        let side = radius * 2 + 1
        let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        maskImage = mask
    }
}
