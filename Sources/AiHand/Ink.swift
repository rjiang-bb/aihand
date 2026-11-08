import AppKit

struct StrokeResult {
    let points: [CGPoint]
    let bounds: CGRect
    let color: CGColor
    let width: CGFloat
    let tool: DrawTool
    /// Present when `tool == .text`.
    let text: String?
    let layer: CALayer
}

enum StrokePath {
    static func make(tool: DrawTool, points: [CGPoint], lineWidth: CGFloat = 4) -> CGPath {
        switch tool {
        case .freehand:
            return freehand(points)
        case .rectangle:
            return rectangle(points)
        case .arrow:
            return arrow(points, lineWidth: lineWidth)
        case .text:
            return CGMutablePath()
        }
    }

    private static func freehand(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first)
            return path
        }
        for i in 1..<points.count {
            let p = points[i]
            let prev = points[i - 1]
            let mid = CGPoint(x: (prev.x + p.x) / 2, y: (prev.y + p.y) / 2)
            path.addQuadCurve(to: mid, control: prev)
        }
        if let last = points.last {
            path.addLine(to: last)
        }
        return path
    }

    private static func rectangle(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let a = points.first else { return path }
        let b = points.count > 1 ? points[1] : a
        let rect = CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
        path.addRect(rect)
        return path
    }

    private static func arrow(_ points: [CGPoint], lineWidth: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard let origin = points.first else { return path }
        let tip = points.count > 1 ? points[1] : origin
        path.move(to: origin)
        path.addLine(to: tip)

        let dx = tip.x - origin.x
        let dy = tip.y - origin.y
        let len = hypot(dx, dy)
        guard len > 0.5 else { return path }

        let ux = dx / len
        let uy = dy / len
        let head = max(10, lineWidth * 3.2)
        let wing = head * 0.55
        let base = CGPoint(x: tip.x - ux * head, y: tip.y - uy * head)
        let left = CGPoint(x: base.x - uy * wing, y: base.y + ux * wing)
        let right = CGPoint(x: base.x + uy * wing, y: base.y - ux * wing)
        path.move(to: left)
        path.addLine(to: tip)
        path.addLine(to: right)
        return path
    }
}

enum InkTextStyle {
    static func fontSize(forStrokeWidth width: CGFloat) -> CGFloat {
        max(13, width * 3.0)
    }

    static func padding(forFontSize size: CGFloat) -> CGFloat {
        max(6, size * 0.35)
    }

    static func cornerRadius(forFontSize size: CGFloat) -> CGFloat {
        max(6, size * 0.28)
    }

    static func contrastingForeground(for background: CGColor) -> CGColor {
        let srgb = background.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            intent: .defaultIntent,
            options: nil
        ) ?? background
        guard let c = srgb.components, c.count >= 3 else {
            return CGColor(gray: 1, alpha: 1)
        }
        let lum = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
        return lum > 0.55
            ? CGColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)
            : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    }

    static func attributes(fontSize: CGFloat, foreground: CGColor) -> [NSAttributedString.Key: Any] {
        let color = NSColor(cgColor: foreground) ?? .white
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        // Hard line breaks only grow height; width hugs the longest line.
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .left
        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    }

    /// Intrinsic text size: width = longest line (capped), height = all lines.
    static func textSize(
        for text: String,
        fontSize: CGFloat,
        maxTextWidth: CGFloat = 520,
        attributes attrs: [NSAttributedString.Key: Any]? = nil
    ) -> CGSize {
        let resolved = attrs ?? attributes(fontSize: fontSize, foreground: CGColor(gray: 1, alpha: 1))
        let font = (resolved[.font] as? NSFont) ?? .systemFont(ofSize: fontSize, weight: .semibold)
        let lineHeight = ceil(max(font.boundingRectForFont.height, fontSize * 1.25))
        if text.isEmpty {
            return CGSize(width: ceil(fontSize * 0.7), height: lineHeight)
        }

        var width: CGFloat = 0
        var height: CGFloat = 0
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let lineStr = String(line)
            if lineStr.isEmpty {
                height += lineHeight
                continue
            }
            // Unconstrained first so short lines don't stretch to maxTextWidth.
            let natural = (lineStr as NSString).boundingRect(
                with: CGSize(width: .greatestFiniteMagnitude, height: lineHeight * 4),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: resolved
            )
            if natural.width <= maxTextWidth {
                width = max(width, ceil(natural.width))
                height += max(lineHeight, ceil(natural.height))
            } else {
                let wrapped = (lineStr as NSString).boundingRect(
                    with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: resolved
                )
                width = max(width, maxTextWidth)
                height += ceil(wrapped.height)
            }
        }
        return CGSize(width: max(ceil(fontSize * 0.7), width), height: max(lineHeight, height))
    }

    /// Size of the opaque text chip for `text` at `fontSize`.
    static func boxSize(for text: String, fontSize: CGFloat, maxTextWidth: CGFloat = 520) -> CGSize {
        let pad = padding(forFontSize: fontSize)
        let textBounds = textSize(for: text, fontSize: fontSize, maxTextWidth: maxTextWidth)
        return CGSize(
            width: textBounds.width + pad * 2,
            height: textBounds.height + pad * 2
        )
    }

    static func renderImage(
        text: String,
        background: CGColor,
        fontSize: CGFloat,
        maxTextWidth: CGFloat = 520
    ) -> NSImage {
        let fg = contrastingForeground(for: background)
        let pad = padding(forFontSize: fontSize)
        let radius = cornerRadius(forFontSize: fontSize)
        let attrs = attributes(fontSize: fontSize, foreground: fg)
        let size = boxSize(for: text, fontSize: fontSize, maxTextWidth: maxTextWidth)
        return NSImage(size: size, flipped: true) { rect in
            let bg = NSColor(cgColor: background) ?? .systemPurple
            bg.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            (text as NSString).draw(in: rect.insetBy(dx: pad, dy: pad), withAttributes: attrs)
            return true
        }
    }
}

final class Ink {
    let layer = CALayer()
    /// Strokes always fade; clear early with the clear-drawing shortcut.
    var keep: Bool { false }

    static let purple = CGColor(srgbRed: 0.53, green: 0.33, blue: 0.95, alpha: 1)
    static let red = CGColor(srgbRed: 1.0, green: 0.16, blue: 0.12, alpha: 1)

    static func hex(_ v: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    var color = Ink.purple
    var scale: CGFloat = 2
    private let fadeDelay: CFTimeInterval = 3
    private let fadeDuration: CFTimeInterval = 0.6

    private var stroke: CAShapeLayer?
    private var points: [CGPoint] = []
    private var tool: DrawTool = .freehand
    private var heldLayers: Set<ObjectIdentifier> = []

    var isDrawing: Bool { stroke != nil }

    init() {
        layer.masksToBounds = false
    }

    func begin(at point: CGPoint, width: CGFloat, tool: DrawTool = .freehand) {
        guard tool != .text else { return }
        let s = CAShapeLayer()
        s.strokeColor = color
        s.fillColor = nil
        s.lineWidth = width
        s.lineCap = .round
        s.lineJoin = .round
        s.shadowColor = NSColor.black.cgColor
        s.shadowOpacity = 0.18
        s.shadowRadius = 1.5
        s.shadowOffset = CGSize(width: 1, height: -1.5)
        layer.addSublayer(s)
        stroke = s
        self.tool = tool
        points = [point]
        redraw()
    }

    func extend(to point: CGPoint) {
        guard stroke != nil, let last = points.first else {
            return
        }
        switch tool {
        case .freehand:
            guard let prev = points.last else { return }
            if hypot(point.x - prev.x, point.y - prev.y) < 1.5 {
                return
            }
            points.append(point)
        case .rectangle, .arrow:
            if hypot(point.x - last.x, point.y - last.y) < 1.5, points.count == 1 {
                return
            }
            if points.count == 1 {
                points.append(point)
            } else {
                points[1] = point
            }
        case .text:
            return
        }
        redraw()
    }

    @discardableResult
    func end(holdFade: Bool = false) -> StrokeResult? {
        guard let s = stroke else {
            return nil
        }
        let snapshotPoints = points
        let snapshotTool = tool
        let color = s.strokeColor ?? self.color
        let width = s.lineWidth
        stroke = nil
        points = []
        tool = .freehand
        freeze(s)
        let pad = width / 2 + 4
        let bounds = s.path.map { $0.boundingBoxOfPath.insetBy(dx: -pad, dy: -pad) } ?? s.bounds
        let result = StrokeResult(
            points: snapshotPoints,
            bounds: bounds,
            color: color,
            width: width,
            tool: snapshotTool,
            text: nil,
            layer: s
        )
        if holdFade || keep {
            heldLayers.insert(ObjectIdentifier(s))
            return result
        }
        fade(s, after: fadeDelay, over: fadeDuration)
        return result
    }

    /// Place a finished text annotation. `topLeft` is the visual top-left in overlay coords.
    @discardableResult
    func addText(
        _ string: String,
        topLeft: CGPoint,
        fontSize: CGFloat,
        holdFade: Bool = false
    ) -> StrokeResult? {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let image = InkTextStyle.renderImage(text: text, background: color, fontSize: fontSize)
        let boxSize = image.size
        // AppKit y grows up — keep the clicked top edge fixed.
        let frame = CGRect(
            x: topLeft.x,
            y: topLeft.y - boxSize.height,
            width: boxSize.width,
            height: boxSize.height
        )

        let s = CALayer()
        s.frame = frame
        s.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        s.contentsScale = scale
        s.shadowColor = NSColor.black.cgColor
        s.shadowOpacity = 0.18
        s.shadowRadius = 1.5
        s.shadowOffset = CGSize(width: 1, height: -1.5)
        layer.addSublayer(s)

        let result = StrokeResult(
            points: [topLeft],
            bounds: frame.insetBy(dx: -2, dy: -2),
            color: color,
            width: fontSize,
            tool: .text,
            text: text,
            layer: s
        )
        if holdFade || keep {
            heldLayers.insert(ObjectIdentifier(s))
            return result
        }
        fade(s, after: fadeDelay, over: fadeDuration)
        return result
    }

    func releaseHold(_ result: StrokeResult, fadeNow: Bool = true) {
        let id = ObjectIdentifier(result.layer)
        heldLayers.remove(id)
        guard fadeNow, !keep else {
            return
        }
        fade(result.layer, after: 0.15, over: fadeDuration)
    }

    func clear() {
        stroke = nil
        points = []
        tool = .freehand
        heldLayers.removeAll()
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    /// Cancel an in-progress drag, or remove the most recently finished stroke.
    /// Returns the removed finished layer (nil when cancelling a live stroke or nothing to undo).
    @discardableResult
    func undoLast() -> CALayer? {
        if let s = stroke {
            s.removeAllAnimations()
            s.removeFromSuperlayer()
            stroke = nil
            points = []
            tool = .freehand
            return nil
        }
        guard let last = layer.sublayers?.last else {
            return nil
        }
        heldLayers.remove(ObjectIdentifier(last))
        last.removeAllAnimations()
        last.removeFromSuperlayer()
        return last
    }

    private func freeze(_ s: CAShapeLayer) {
        guard let path = s.path else {
            return
        }
        let pad = s.lineWidth / 2 + s.shadowRadius * 3 + max(abs(s.shadowOffset.width), abs(s.shadowOffset.height)) + 2
        let box = path.boundingBoxOfPath.insetBy(dx: -pad, dy: -pad).integral
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        s.bounds = box
        s.position = CGPoint(x: box.midX, y: box.midY)
        s.rasterizationScale = scale
        s.shouldRasterize = true
        CATransaction.commit()
    }

    private func fade(_ s: CALayer, after delay: CFTimeInterval, over duration: CFTimeInterval) {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1
        anim.toValue = 0
        anim.beginTime = CACurrentMediaTime() + delay
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        s.add(anim, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + duration) { [weak s] in
            s?.removeFromSuperlayer()
        }
    }

    private func redraw() {
        guard let s = stroke else {
            return
        }
        let path = StrokePath.make(tool: tool, points: points, lineWidth: s.lineWidth)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        s.path = path
        CATransaction.commit()
    }
}
