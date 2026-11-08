import AppKit

struct StrokeResult {
    let points: [CGPoint]
    let bounds: CGRect
    let color: CGColor
    let width: CGFloat
    let tool: DrawTool
    let layer: CAShapeLayer
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
    func undoLast() -> CAShapeLayer? {
        if let s = stroke {
            s.removeAllAnimations()
            s.removeFromSuperlayer()
            stroke = nil
            points = []
            tool = .freehand
            return nil
        }
        guard let last = layer.sublayers?.last as? CAShapeLayer else {
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

    private func fade(_ s: CAShapeLayer, after delay: CFTimeInterval, over duration: CFTimeInterval) {
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
