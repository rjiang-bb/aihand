import AppKit
import SwiftUI

/// Notification-style glass: `NSVisualEffectView` with a soft mask that fades
/// the blur to transparent toward the panel edges.
final class SoftGlassEffectView: NSVisualEffectView {
    init(fadeWidth: CGFloat = 64, cornerRadius: CGFloat = 32) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        maskImage = SoftGlassMask.make(fade: fadeWidth, cornerRadius: cornerRadius)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

enum SoftGlassMask {
    /// Stretchable soft-edge mask: opaque center, fades on edges/corners.
    static func make(fade: CGFloat, cornerRadius: CGFloat) -> NSImage {
        let edge = max(fade, cornerRadius + 8)
        let size = NSSize(width: edge * 2 + 8, height: edge * 2 + 8)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.clear(rect)

            let inset = edge
            let inner = rect.insetBy(dx: inset, dy: inset)

            // Opaque core (center stretches via capInsets).
            NSColor.black.setFill()
            NSBezierPath(
                roundedRect: inner,
                xRadius: max(0, cornerRadius - 8),
                yRadius: max(0, cornerRadius - 8)
            ).fill()

            // Edge strips: black at inner → clear at outer.
            fillVerticalFade(
                rect: NSRect(x: inner.minX, y: inner.maxY, width: inner.width, height: inset),
                opaqueAtBottom: true
            )
            fillVerticalFade(
                rect: NSRect(x: inner.minX, y: rect.minY, width: inner.width, height: inset),
                opaqueAtBottom: false
            )
            fillHorizontalFade(
                rect: NSRect(x: rect.minX, y: inner.minY, width: inset, height: inner.height),
                opaqueAtLeading: false
            )
            fillHorizontalFade(
                rect: NSRect(x: inner.maxX, y: inner.minY, width: inset, height: inner.height),
                opaqueAtLeading: true
            )

            // Corners.
            fillCorner(center: NSPoint(x: inner.minX, y: inner.minY), radius: inset, start: .pi, end: .pi * 1.5)
            fillCorner(center: NSPoint(x: inner.maxX, y: inner.minY), radius: inset, start: .pi * 1.5, end: .pi * 2)
            fillCorner(center: NSPoint(x: inner.maxX, y: inner.maxY), radius: inset, start: 0, end: .pi * 0.5)
            fillCorner(center: NSPoint(x: inner.minX, y: inner.maxY), radius: inset, start: .pi * 0.5, end: .pi)

            return true
        }
        image.capInsets = NSEdgeInsets(top: edge, left: edge, bottom: edge, right: edge)
        image.resizingMode = .stretch
        return image
    }

    private static func softGradient() -> NSGradient? {
        NSGradient(colorsAndLocations:
            (NSColor.black, 0),
            (NSColor.black.withAlphaComponent(0.65), 0.28),
            (NSColor.black.withAlphaComponent(0.22), 0.62),
            (NSColor.black.withAlphaComponent(0.04), 0.88),
            (NSColor.clear, 1)
        )
    }

    private static func fillVerticalFade(rect: NSRect, opaqueAtBottom: Bool) {
        guard let gradient = softGradient(), let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        let start = opaqueAtBottom
            ? NSPoint(x: rect.midX, y: rect.minY)
            : NSPoint(x: rect.midX, y: rect.maxY)
        let end = opaqueAtBottom
            ? NSPoint(x: rect.midX, y: rect.maxY)
            : NSPoint(x: rect.midX, y: rect.minY)
        gradient.draw(from: start, to: end, options: [])
        ctx.restoreGState()
    }

    private static func fillHorizontalFade(rect: NSRect, opaqueAtLeading: Bool) {
        guard let gradient = softGradient(), let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        let start = opaqueAtLeading
            ? NSPoint(x: rect.minX, y: rect.midY)
            : NSPoint(x: rect.maxX, y: rect.midY)
        let end = opaqueAtLeading
            ? NSPoint(x: rect.maxX, y: rect.midY)
            : NSPoint(x: rect.minX, y: rect.midY)
        gradient.draw(from: start, to: end, options: [])
        ctx.restoreGState()
    }

    private static func fillCorner(center: NSPoint, radius: CGFloat, start: CGFloat, end: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        let colors = [
            NSColor.black.cgColor,
            NSColor.black.withAlphaComponent(0.55).cgColor,
            NSColor.black.withAlphaComponent(0.12).cgColor,
            NSColor.clear.cgColor
        ] as CFArray
        let locations: [CGFloat] = [0, 0.35, 0.75, 1]
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space, colors: colors, locations: locations) else {
            ctx.restoreGState()
            return
        }
        let path = CGMutablePath()
        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        path.closeSubpath()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: []
        )
        ctx.restoreGState()
    }
}

struct SoftGlassBackdrop: NSViewRepresentable {
    var fadeWidth: CGFloat = 64
    var cornerRadius: CGFloat = 32

    func makeNSView(context: Context) -> SoftGlassEffectView {
        SoftGlassEffectView(fadeWidth: fadeWidth, cornerRadius: cornerRadius)
    }

    func updateNSView(_ nsView: SoftGlassEffectView, context: Context) {}
}
