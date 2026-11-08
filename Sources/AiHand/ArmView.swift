import AppKit

final class ArmView: NSView {
    private let group = CALayer()
    private let rodLayer = CALayer()
    private let handLayer = CALayer()
    private let dotLayer = CAShapeLayer()
    private let dotCore = CAShapeLayer()

    private(set) var style: PointerStyle = .lavender
    private var asset: HandAsset?

    private var handLenFrac: CGFloat = Preferences.pointerSize
    private var showShadow = Preferences.showShadow
    private let minRodFrac: CGFloat = 0.05
    private let gripLeanFrac: CGFloat = 0.30
    private let gripDepthFrac: CGFloat = 0.12
    /// Ease toward the cursor when moving slowly; larger deltas snap harder (see `aim`).
    private let gripFollow: CGFloat = 0.28
    private let liftFrac: CGFloat = 0.06

    let ink = Ink()
    private let captureOutline = CAShapeLayer()
    private let videoSelectionOutline = CAShapeLayer()
    private let videoRecordDot = CAShapeLayer()
    var held = false
    var inkWidth: CGFloat {
        let base = max(3, bounds.height * 0.0055)
        return max(1.5, base * Preferences.strokeThickness.multiplier)
    }

    private var pressAmount: CGFloat = 0
    private var gripX: CGFloat?
    private var lastPose: [CGFloat] = []
    private var lastLaserPose: [CGFloat] = []
    private var gripTarget: CGFloat?
    private var displayImageHeight = 0

    var isSettling: Bool {
        if pressAmount > 0.002 {
            return true
        }
        guard let gx = gripX, let target = gripTarget else {
            return false
        }
        return abs(target - gx) > 0.5
    }

    var pointerHidden = false {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            group.isHidden = pointerHidden || style == .laser
            dotLayer.isHidden = pointerHidden || style != .laser
            CATransaction.commit()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        root.masksToBounds = false
        layer = root
        wantsLayer = true
        root.addSublayer(ink.layer)
        root.addSublayer(group)

        root.addSublayer(dotLayer)

        captureOutline.fillColor = nil
        captureOutline.strokeColor = Ink.red
        captureOutline.lineWidth = 6
        captureOutline.lineJoin = .miter
        captureOutline.lineCap = .square
        captureOutline.isHidden = true
        root.addSublayer(captureOutline)

        videoSelectionOutline.fillColor = nil
        videoSelectionOutline.strokeColor = Ink.red
        videoSelectionOutline.lineWidth = 3
        videoSelectionOutline.lineJoin = .miter
        videoSelectionOutline.lineCap = .square
        videoSelectionOutline.lineDashPattern = [8, 6]
        videoSelectionOutline.isHidden = true
        root.addSublayer(videoSelectionOutline)

        videoRecordDot.fillColor = NSColor.systemRed.cgColor
        videoRecordDot.strokeColor = nil
        videoRecordDot.isHidden = true
        root.addSublayer(videoRecordDot)

        group.masksToBounds = false
        group.addSublayer(rodLayer)
        group.addSublayer(handLayer)
        for sub in [rodLayer, handLayer] {
            sub.contentsGravity = .resize
            sub.contentsScale = 2
            sub.anchorPoint = CGPoint(x: 0.5, y: 0)
            sub.shadowColor = NSColor.black.cgColor
            sub.shadowOpacity = 0.38
        }

        dotLayer.fillColor = Ink.red
        dotLayer.shadowColor = Ink.red
        dotLayer.shadowOpacity = 1
        dotLayer.shadowOffset = .zero
        dotCore.fillColor = CGColor(srgbRed: 1, green: 0.86, blue: 0.82, alpha: 0.95)
        dotLayer.addSublayer(dotCore)

        setStyle(PointerStyle.saved)
        NotificationCenter.default.addObserver(forName: Preferences.changed, object: nil, queue: .main) { [weak self] _ in
            self?.handLenFrac = Preferences.pointerSize
            self?.showShadow = Preferences.showShadow
        }
    }

    func updateInkColor() {
        ink.color = Preferences.inkChoice.resolved(for: style)
    }

    /// Thick red frame around the region that will be screenshotted (`local` overlay coords).
    func setCaptureOutline(localRect: CGRect?) {
        applyOutline(captureOutline, localRect: localRect, minSize: 2)
    }

    /// Dashed marquee for video-region selection (`local` overlay coords).
    func setVideoSelectionOutline(localRect: CGRect?) {
        stopVideoRecordingFlash()
        videoRecordDot.isHidden = true
        applyOutline(videoSelectionOutline, localRect: localRect, minSize: 2)
    }

    /// Recording frame: dashed rect + red dot in the top-left corner. Pass `flashing: true` while capturing.
    func setVideoRecordingIndicator(localRect: CGRect?, flashing: Bool) {
        stopVideoRecordingFlash()
        applyOutline(videoSelectionOutline, localRect: localRect, minSize: 2)
        guard let localRect, localRect.width > 8, localRect.height > 8 else {
            videoRecordDot.isHidden = true
            return
        }

        let radius: CGFloat = 6
        let inset: CGFloat = 10
        // AppKit: y grows up — top-left of the selection.
        let center = CGPoint(x: localRect.minX + inset + radius, y: localRect.maxY - inset - radius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoRecordDot.path = CGPath(
            ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2),
            transform: nil
        )
        videoRecordDot.position = center
        videoRecordDot.opacity = 1
        videoRecordDot.isHidden = false
        CATransaction.commit()

        if flashing {
            startVideoRecordingFlash()
        }
    }

    func clearVideoRecordingIndicator() {
        stopVideoRecordingFlash()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoSelectionOutline.isHidden = true
        videoSelectionOutline.path = nil
        videoRecordDot.isHidden = true
        videoRecordDot.path = nil
        CATransaction.commit()
    }

    private func startVideoRecordingFlash() {
        let dash = CABasicAnimation(keyPath: "lineDashPhase")
        dash.fromValue = 0
        dash.toValue = 14
        dash.duration = 0.45
        dash.repeatCount = .infinity
        videoSelectionOutline.add(dash, forKey: "videoDash")

        let outlinePulse = CABasicAnimation(keyPath: "opacity")
        outlinePulse.fromValue = 1
        outlinePulse.toValue = 0.35
        outlinePulse.duration = 0.7
        outlinePulse.autoreverses = true
        outlinePulse.repeatCount = .infinity
        videoSelectionOutline.add(outlinePulse, forKey: "videoOutlinePulse")

        let dotPulse = CABasicAnimation(keyPath: "opacity")
        dotPulse.fromValue = 1
        dotPulse.toValue = 0.2
        dotPulse.duration = 0.7
        dotPulse.autoreverses = true
        dotPulse.repeatCount = .infinity
        videoRecordDot.add(dotPulse, forKey: "videoDotPulse")
    }

    private func stopVideoRecordingFlash() {
        videoSelectionOutline.removeAnimation(forKey: "videoDash")
        videoSelectionOutline.removeAnimation(forKey: "videoOutlinePulse")
        videoRecordDot.removeAnimation(forKey: "videoDotPulse")
        videoSelectionOutline.opacity = 1
        videoRecordDot.opacity = 1
    }

    private func applyOutline(_ layer: CAShapeLayer, localRect: CGRect?, minSize: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let localRect, localRect.width > minSize, localRect.height > minSize else {
            layer.isHidden = true
            layer.path = nil
            return
        }
        let inset = layer.lineWidth / 2
        let stroked = localRect.insetBy(dx: inset, dy: inset)
        guard stroked.width > 1, stroked.height > 1 else {
            layer.isHidden = true
            layer.path = nil
            return
        }
        layer.path = CGPath(rect: stroked, transform: nil)
        layer.isHidden = false
    }

    func setStyle(_ newStyle: PointerStyle) {
        style = newStyle
        asset = newStyle.assetName.flatMap(HandAsset.load)
        if newStyle != .laser && asset == nil {
            style = .laser
        }
        updateInkColor()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let a = asset, style != .laser {
            group.anchorPoint = CGPoint(x: a.rodX, y: 0)
            displayImageHeight = 0
            updateDisplayImage(a)
            rodLayer.contentsRect = CGRect(x: 0, y: 1 - a.rodEnd, width: 1, height: a.rodEnd - a.wrist)
            handLayer.contentsRect = CGRect(x: 0, y: 1 - a.wrist, width: 1, height: a.wrist - a.handTop)
        }
        CATransaction.commit()
        let hidden = pointerHidden
        pointerHidden = hidden
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    func press() {
        pressAmount = 1
    }

    func aim(cursor: CGPoint) {
        let screenH = bounds.height
        let targetX = min(max(cursor.x + gripLeanFrac * bounds.width, bounds.width * 0.15), bounds.width * 1.05)
        let previous = gripX ?? targetX
        let delta = abs(targetX - previous)
        // Slow moves ease; fast flicks snap so the hand keeps up with the cursor.
        let follow: CGFloat
        if delta > 80 {
            follow = 1
        } else if delta > 28 {
            follow = 0.55
        } else {
            follow = gripFollow
        }
        let gx = previous + (targetX - previous) * follow
        gripX = gx
        gripTarget = targetX
        let grip = CGPoint(x: gx, y: -gripDepthFrac * screenH)

        if !held {
            pressAmount += (0 - pressAmount) * 0.18
        }

        if style == .laser {
            aimLaser(cursor: cursor)
            return
        }
        guard let a = asset else {
            return
        }
        updateDisplayImage(a)

        let dx = cursor.x - grip.x
        let dy = cursor.y - grip.y
        let reach = hypot(dx, dy)
        let aimAngle = atan2(dy, dx)

        let handPts = handLenFrac * screenH * (1 - 0.06 * pressAmount)
        let s = handPts / (a.wrist - a.handTop)
        let widthPts = s * a.aspect
        let handTipPts = (a.wrist - a.tip) * s
        let tipOffX = (a.tipX - a.rodX) * widthPts

        let along = sqrt(max(0, reach * reach - tipOffX * tipOffX))
        var rodLen = along - handTipPts
        rodLen = max(minRodFrac * screenH, rodLen)
        let tipAngle = atan2(rodLen + handTipPts, tipOffX)
        let rotation = aimAngle - tipAngle

        let lift = currentLift(screenH)
        let sx = lift * 0.6
        let sy = -lift
        let shadowOffset = CGSize(
            width: sx * cos(-rotation) - sy * sin(-rotation),
            height: sx * sin(-rotation) + sy * cos(-rotation)
        )

        let pose = [rotation, rodLen, handPts, widthPts, grip.x, lift, pressAmount, showShadow ? 1 : 0, a.aspect]
            .map { ($0 * 100).rounded() }
        guard pose != lastPose else {
            return
        }
        lastPose = pose

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for sub in [rodLayer, handLayer] {
            sub.shadowOffset = shadowOffset
            sub.shadowRadius = max(1, lift * 0.35) + 5 * pressAmount
            sub.shadowOpacity = showShadow ? Float(0.26 + 0.02 * pressAmount) : 0
        }

        rodLayer.bounds = CGRect(x: 0, y: 0, width: widthPts, height: rodLen)
        rodLayer.position = CGPoint(x: widthPts / 2, y: 0)
        handLayer.bounds = CGRect(x: 0, y: 0, width: widthPts, height: handPts)
        handLayer.position = CGPoint(x: widthPts / 2, y: rodLen)

        group.bounds = CGRect(x: 0, y: 0, width: widthPts, height: rodLen + handPts)
        group.position = grip
        group.transform = CATransform3DMakeRotation(rotation, 0, 0, 1)

        CATransaction.commit()
    }

    private func currentLift(_ screenH: CGFloat) -> CGFloat {
        liftFrac * screenH * (1 - 0.8 * pressAmount)
    }

    private func aimLaser(cursor: CGPoint) {
        let press = pressAmount
        let r = max(4, bounds.height * 0.0038 * handLenFrac / 0.13) * (1 + 0.2 * press)
        let laserPose = [r, cursor.x, cursor.y].map { ($0 * 100).rounded() }
        guard laserPose != lastLaserPose else {
            return
        }
        lastLaserPose = laserPose
        let core = r * 0.45
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let dot = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        dotLayer.path = dot
        dotLayer.shadowPath = dot
        dotCore.path = CGPath(ellipseIn: CGRect(x: -core, y: -core, width: 2 * core, height: 2 * core), transform: nil)
        dotLayer.position = cursor
        dotLayer.shadowRadius = r * (2.2 + 1.0 * press)
        CATransaction.commit()
    }

    private func updateDisplayImage(_ a: HandAsset) {
        let full = a.image
        let scale = window?.backingScaleFactor ?? 2
        let restPts = handLenFrac * bounds.height / (a.wrist - a.handTop)
        let step = 64
        let needed = (Int((restPts * scale).rounded(.up)) + step - 1) / step * step
        let height = needed >= full.height * 9 / 10 ? full.height : max(step, needed)
        guard height != displayImageHeight else {
            return
        }
        displayImageHeight = height
        let image = height == full.height ? full : HandAsset.resized(full, height: height) ?? full
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rodLayer.contents = image
        handLayer.contents = image
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        applyBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBackingScale()
    }

    private func applyBackingScale() {
        let scale = window?.backingScaleFactor ?? 2
        rodLayer.contentsScale = scale
        handLayer.contentsScale = scale
        ink.scale = scale
    }
}
