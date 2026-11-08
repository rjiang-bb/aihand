import AppKit
import Carbon.HIToolbox
import CoreVideo

final class OverlayController {
    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let window: OverlayWindow
    private let armView: ArmView
    private let inputTap = InputTap()
    private let tapSound = TapSound()
    private var interactHeld = false
    private var menuHover = false
    private var guardCursorUntil = Date.distantPast
    private var timer: Timer?
    private var displayLink: CVDisplayLink?
    /// Coalesces display-link → main hops; guarded by `aimLock` (callback is off-main).
    private var aimQueued = false
    private let aimLock = NSLock()
    private var currentFrame: CGRect?
    private var downPoint: CGPoint?
    private var buttonSeenDown = false
    private var dragEvents = 0

    private let toolbar = Toolbar()
    private var revealUntil = Date.distantPast
    private var normalCursor = false
    private var ownMenuOpen = false
    private var menuRects: [CGRect] = []
    private var lastMenuScan = Date.distantPast
    private var menuOpeningUntil = Date.distantPast
    private var escHotKey: UInt32?
    private var enterHotKey: UInt32?
    private var sendHotKey: UInt32?
    private var undoHotKey: UInt32?
    private var toolHotKeys: [UInt32] = []
    private let annotationHints = AnnotationHintPanel()
    private let drawingTools = DrawingToolsPanel()
    private var lastPermissionCheck = Date.distantPast

    /// Zones / cursor / menus — not used for hand pose (display link + mouse events drive that).
    private static let serviceInterval: TimeInterval = 1.0 / 30.0
    private static let menuScanFast: TimeInterval = 0.05
    private static let menuScanSlow: TimeInterval = 0.25
    private var mouseAimMonitors: [Any] = []
    private var lastMouse: CGPoint?
    private var lastButtonEvent = Date.distantPast

    private(set) var isActive = false
    private var activity: NSObjectProtocol?
    var onActiveChanged: (() -> Void)?
    var onNeedsPermission: (() -> Void)?
    /// Fired after a real ink stroke ends. Coordinates are in AppKit screen space.
    var onStrokeComplete: ((StrokeResult, CGRect, NSScreen) -> Void)?
    /// Enter while ink is on screen — open the comment box.
    var onRequestComment: (() -> Void)?
    /// ⌘↩ while ink is on screen — send the annotated screenshot immediately.
    var onRequestSend: (() -> Void)?
    var onInkCleared: (() -> Void)?
    /// Fired after undoing a finished stroke (layer removed from the overlay).
    var onStrokeUndone: ((CAShapeLayer) -> Void)?

    init() {
        let frame = (NSScreen.main ?? NSScreen.screens.first).map { $0.frame }
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        armView = ArmView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = armView

        inputTap.onMouseDown = { [weak self] in
            guard let self = self else {
                return
            }
            self.armView.press()
            self.armView.held = true
            self.tapSound.play()
            self.toolbar.hideHint()
            self.downPoint = self.localMouse()
            self.dragEvents = 0
            Log.write("press at \(self.downPoint.map { "\(Int($0.x)),\(Int($0.y))" } ?? "?")")
            self.noteButtonEvent()
        }
        inputTap.onLeftDragged = { [weak self] in
            self?.dragEvents += 1
            self?.drag()
            self?.aimFrame()
        }
        inputTap.onMouseUp = { [weak self] in
            self?.release()
            self?.noteButtonEvent()
        }
        inputTap.onInteractDown = { [weak self] in
            self?.armView.press()
            self?.armView.held = true
            self?.noteButtonEvent()
        }
        inputTap.onInteractUp = { [weak self] in
            self?.armView.held = false
            self?.guardCursorUntil = Date().addingTimeInterval(2)
            CursorHider.reassert(urgent: true)
            self?.noteButtonEvent()
        }
        inputTap.onPassThroughPress = { [weak self] location in
            guard let screen = self?.currentScreen() else {
                return
            }
            let bar = OverlayController.cgRect(OverlayController.menuBarRect(screen))
            if bar.contains(location) {
                self?.menuOpeningUntil = Date().addingTimeInterval(1)
            }
            self?.noteButtonEvent()
        }

        toolbar.onPick = { [weak self] style in
            self?.pick(style)
        }
        toolbar.onToggleSound = { [weak self] in
            self?.soundOn.toggle()
        }
        toolbar.onExit = { [weak self] in
            self?.exit()
        }
        toolbar.onFixPermission = { [weak self] in
            self?.exit()
            self?.onNeedsPermission?()
        }
        toolbar.select(armView.style)
        tapSound.enabled = soundOn
        toolbar.setSoundOn(soundOn)
        NotificationCenter.default.addObserver(forName: Preferences.changed, object: nil, queue: .main) { [weak self] _ in
            self?.syncSound()
            self?.inputTap.interactKey = Preferences.interactKey.cgFlags
            self?.armView.updateInkColor()
            self?.tapSound.load(Preferences.tapSound)
            if let self = self, self.armView.style != PointerStyle.saved {
                self.pick(PointerStyle.saved)
            }
        }
    }

    var soundOn: Bool {
        get { armView.style == .laser ? Preferences.laserSound : Preferences.handSound }
        set {
            if armView.style == .laser {
                Preferences.laserSound = newValue
            } else {
                Preferences.handSound = newValue
            }
        }
    }
    var onSoundChanged: (() -> Void)?

    func pick(_ style: PointerStyle) {
        armView.setStyle(style)
        PointerStyle.saved = armView.style
        toolbar.select(armView.style)
        syncSound()
    }

    private func syncSound() {
        tapSound.enabled = soundOn
        toolbar.setSoundOn(soundOn)
        onSoundChanged?()
    }

    var extraPassThrough: (() -> [CGRect])?

    func suspendInput(_ suspended: Bool) {
        guard isActive, inputTap.isInstalled else {
            return
        }
        ownMenuOpen = suspended
        inputTap.setActive(!suspended)
        // Drop Enter / ⌘↩ while the comment box is key so the field can use them.
        setAnnotationHotKeysEnabled(!suspended)
        if let screen = currentScreen() {
            updateZones(mouse: NSEvent.mouseLocation, screen: screen)
        }
    }

    func exit() {
        clearInk()
        deactivate()
    }

    private func release() {
        if let start = downPoint {
            let moved = localMouse().map { Int(hypot($0.x - start.x, $0.y - start.y)) } ?? -1
            Log.write("release, drag events=\(dragEvents) moved=\(moved)pt stroke drawn=\(armView.ink.isDrawing)")
        }
        buttonSeenDown = false
        armView.held = false
        downPoint = nil
        let wasDrawing = armView.ink.isDrawing
        let result = armView.ink.end(holdFade: wasDrawing && onStrokeComplete != nil)
        if wasDrawing, let result, let frame = currentFrame, let screen = currentScreen() {
            let screenBounds = CGRect(
                x: frame.origin.x + result.bounds.minX,
                y: frame.origin.y + result.bounds.minY,
                width: result.bounds.width,
                height: result.bounds.height
            )
            onStrokeComplete?(result, screenBounds, screen)
        }
    }

    func releaseStrokeHold(_ result: StrokeResult, fadeNow: Bool = true) {
        armView.ink.releaseHold(result, fadeNow: fadeNow)
    }

    var overlayFrame: CGRect? { currentFrame }

    func screenToLocal(_ screenPoint: CGPoint) -> CGPoint? {
        guard let frame = currentFrame else { return nil }
        return CGPoint(x: screenPoint.x - frame.origin.x, y: screenPoint.y - frame.origin.y)
    }

    func localToScreen(_ local: CGPoint) -> CGPoint? {
        guard let frame = currentFrame else { return nil }
        return CGPoint(x: frame.origin.x + local.x, y: frame.origin.y + local.y)
    }

    var style: PointerStyle { armView.style }

    var tapMaxWaitMs: Double { inputTap.maxWaitMs }

    func resetTapWait() {
        inputTap.resetWait()
    }

    func toolbarButtonCenter(_ style: PointerStyle) -> CGPoint? {
        toolbar.center(of: style)
    }

    var inkStrokes: Int { armView.ink.layer.sublayers?.count ?? 0 }

    var debugState: String {
        "held=\(armView.held) downPoint=\(downPoint != nil) drawing=\(armView.ink.isDrawing) strokes=\(inkStrokes)"
    }

    func clearInk() {
        armView.ink.clear()
        onInkCleared?()
    }

    /// Undo the current drag or the last finished stroke (⌘Z).
    func undoLastStroke() {
        if let layer = armView.ink.undoLast() {
            onStrokeUndone?(layer)
        }
    }

    /// Finished strokes on the overlay (not including an in-progress drag).
    var hasAnnotationInk: Bool {
        !armView.ink.isDrawing && inkStrokes > 0
    }

    func setAnnotationHintsVisible(_ visible: Bool) {
        guard visible, isActive, let screen = currentScreen() else {
            annotationHints.hide()
            drawingTools.hide()
            return
        }
        annotationHints.show(on: screen)
        drawingTools.show(on: screen, above: annotationHints.frame)
    }

    private func drag() {
        guard let start = downPoint, let p = localMouse() else {
            return
        }
        let ink = armView.ink
        if !ink.isDrawing {
            if hypot(p.x - start.x, p.y - start.y) < 4 {
                return
            }
            ink.begin(at: start, width: armView.inkWidth, tool: Preferences.drawTool)
        }
        ink.extend(to: p)
    }

    private func localMouse() -> CGPoint? {
        guard let frame = currentFrame else {
            return nil
        }
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - frame.origin.x, y: mouse.y - frame.origin.y)
    }

    func toggle() {
        if isActive {
            deactivate()
            return
        }
        activate()
    }

    static let hintShownKey = "firstRunHintShown"

    @discardableResult
    func activate() -> Bool {
        guard !isActive else {
            return inputTap.isInstalled
        }
        guard AXIsProcessTrusted() else {
            Log.write("activate skipped: not trusted")
            onNeedsPermission?()
            return false
        }
        isActive = true
        currentFrame = nil
        tapSound.warm()

        CursorHider.hide()
        window.orderFrontRegardless()

        startDisplayLink()
        installMouseAimMonitors()
        runServiceTimer()
        aimFrame()
        serviceTick()

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "AiHand pointer is on")
        let installed = inputTap.install()
        inputTap.interactKey = Preferences.interactKey.cgFlags
        inputTap.setActive(installed)
        Log.write("activate trusted=\(AXIsProcessTrusted()) tapInstalled=\(installed)")

        if let screen = currentScreen() {
            toolbar.place(on: screen)
            annotationHints.show(on: screen)
            drawingTools.show(on: screen, above: annotationHints.frame)
        }
        toolbar.setNeedsPermission(!installed)
        toolbar.show()
        revealUntil = Date().addingTimeInterval(3)
        if installed && !UserDefaults.standard.bool(forKey: OverlayController.hintShownKey) {
            UserDefaults.standard.set(true, forKey: OverlayController.hintShownKey)
            var parts: [(key: String, text: String)] = [("Click", "to tap"), ("Drag", "to draw")]
            if Preferences.interactKey != .off {
                parts.append(("Hold \(Preferences.interactKey.symbol)", "to click for real"))
            }
            parts.append(("Esc", "to exit"))
            toolbar.showHint(parts)
            revealUntil = Date().addingTimeInterval(10)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.toolbar.hideHint()
            }
        }
        setEscEnabled(true)
        setAnnotationHotKeysEnabled(true)
        onActiveChanged?()
        return installed
    }

    func deactivate() {
        guard isActive else {
            return
        }
        isActive = false

        stopDisplayLink()
        timer?.invalidate()
        timer = nil
        removeMouseAimMonitors()
        inputTap.setActive(false)
        if let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
        armView.held = false
        downPoint = nil
        armView.ink.clear()
        onInkCleared?()
        window.ignoresMouseEvents = true
        window.orderOut(nil)
        toolbar.hide()
        annotationHints.hide()
        drawingTools.hide()
        normalCursor = false
        armView.pointerHidden = false
        inputTap.passThroughRects = []
        setEscEnabled(false)
        setAnnotationHotKeysEnabled(false)
        ownMenuOpen = false
        CursorHider.show()
        onActiveChanged?()
    }

    private func updateZones(mouse: CGPoint, screen: NSScreen) {
        let f = toolbar.frame
        let near = f.insetBy(dx: -80, dy: 0).union(f.offsetBy(dx: 0, dy: 90)).insetBy(dx: 0, dy: -10).contains(mouse)
        let needsPermission = !inputTap.isInstalled
        let drawing = armView.ink.isDrawing
        toolbar.setRevealed(!drawing && (near || Date() < revealUntil || needsPermission))

        let menuLikely = !menuRects.isEmpty || ownMenuOpen || Date() < menuOpeningUntil
            || Date().timeIntervalSince(lastButtonEvent) < 2
            || OverlayController.menuBarRect(screen).insetBy(dx: 0, dy: -40).contains(mouse)
        let scanEvery = menuLikely ? OverlayController.menuScanFast : OverlayController.menuScanSlow
        if Date().timeIntervalSince(lastMenuScan) > scanEvery {
            lastMenuScan = Date()
            menuRects = OverlayController.openMenus()
        }
        let menuBar = OverlayController.menuBarRect(screen)
        let cgMouse = OverlayController.cgPoint(mouse)
        let overMenu = menuBar.contains(mouse) || menuRects.contains { $0.contains(cgMouse) }
            || Date() < menuOpeningUntil
        let key = Preferences.interactKey.cgFlags
        let interacting = (!key.isEmpty && CGEventSource.flagsState(.hidSystemState).contains(key)) || inputTap.interactPressing
        interactHeld = interacting
        menuHover = overMenu
        let normal = !drawing && !Preferences.interactKeepsHand && (interacting || overMenu || ownMenuOpen)
        setEscEnabled(menuRects.isEmpty && !ownMenuOpen)

        if normal != normalCursor {
            let at = "at \(Int(mouse.x)),\(Int(mouse.y))"
            let why = interacting ? "interact key" : menuBar.contains(mouse) ? "menu bar" : "menu"
            Log.write(normal ? "real cursor (\(why)) \(at)" : "pointer back \(at)")
            normalCursor = normal
            armView.pointerHidden = normal
            if normal {
                CursorHider.show()
            } else {
                CursorHider.hide()
            }
        }

        var rects = (extraPassThrough?() ?? []).map(OverlayController.cgRect)
        rects.append(OverlayController.cgRect(menuBar))
        rects.append(contentsOf: menuRects)
        if toolbar.revealed {
            rects.append(OverlayController.cgRect(f))
        }
        let toolsFrame = drawingTools.frame
        if toolsFrame.width > 0 {
            rects.append(OverlayController.cgRect(toolsFrame))
        }
        inputTap.passThroughRects = rects
    }

    private func setEscEnabled(_ enabled: Bool) {
        if enabled && isActive && escHotKey == nil {
            escHotKey = HotKeyCenter.shared.register(keyCode: UInt32(kVK_Escape), modifiers: 0) { [weak self] in
                self?.exit()
            }
        }
        if !enabled, let id = escHotKey {
            HotKeyCenter.shared.unregister(id)
            escHotKey = nil
        }
    }

    private func setAnnotationHotKeysEnabled(_ enabled: Bool) {
        if enabled && isActive {
            if enterHotKey == nil {
                enterHotKey = HotKeyCenter.shared.register(keyCode: UInt32(kVK_Return), modifiers: 0) { [weak self] in
                    guard let self, self.hasAnnotationInk else { return }
                    self.onRequestComment?()
                }
            }
            if sendHotKey == nil {
                sendHotKey = HotKeyCenter.shared.register(
                    keyCode: UInt32(kVK_Return),
                    modifiers: UInt32(cmdKey)
                ) { [weak self] in
                    guard let self, self.hasAnnotationInk else { return }
                    self.onRequestSend?()
                }
            }
            if undoHotKey == nil {
                undoHotKey = HotKeyCenter.shared.register(
                    keyCode: UInt32(kVK_ANSI_Z),
                    modifiers: UInt32(cmdKey)
                ) { [weak self] in
                    self?.undoLastStroke()
                }
            }
            if toolHotKeys.isEmpty {
                let toolKeys: [(DrawTool, Int)] = [
                    (.freehand, kVK_ANSI_F),
                    (.rectangle, kVK_ANSI_R),
                    (.arrow, kVK_ANSI_A),
                ]
                for (tool, code) in toolKeys {
                    if let id = HotKeyCenter.shared.register(keyCode: UInt32(code), modifiers: 0, action: {
                        Preferences.drawTool = tool
                    }) {
                        toolHotKeys.append(id)
                    }
                }
                for thickness in StrokeThickness.allCases {
                    let code: Int
                    switch thickness.rawValue {
                    case 1: code = kVK_ANSI_1
                    case 2: code = kVK_ANSI_2
                    case 3: code = kVK_ANSI_3
                    case 4: code = kVK_ANSI_4
                    default: code = kVK_ANSI_5
                    }
                    if let id = HotKeyCenter.shared.register(keyCode: UInt32(code), modifiers: 0, action: {
                        Preferences.strokeThickness = thickness
                    }) {
                        toolHotKeys.append(id)
                    }
                }
            }
            return
        }
        if let id = enterHotKey {
            HotKeyCenter.shared.unregister(id)
            enterHotKey = nil
        }
        if let id = sendHotKey {
            HotKeyCenter.shared.unregister(id)
            sendHotKey = nil
        }
        if let id = undoHotKey {
            HotKeyCenter.shared.unregister(id)
            undoHotKey = nil
        }
        for id in toolHotKeys {
            HotKeyCenter.shared.unregister(id)
        }
        toolHotKeys = []
    }

    private static func menuBarRect(_ screen: NSScreen) -> CGRect {
        let height = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return CGRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
    }

    private static func openMenus() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            return []
        }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == menuLevel,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                return nil
            }
            return rect
        }
    }

    private static func cgPoint(_ p: CGPoint) -> CGPoint {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryH - p.y)
    }

    private func checkPermission() {
        guard !inputTap.isInstalled, Date().timeIntervalSince(lastPermissionCheck) > 1 else {
            return
        }
        lastPermissionCheck = Date()
        guard AXIsProcessTrusted(), inputTap.install() else {
            return
        }
        Log.write("permission granted while running; tap installed")
        inputTap.setActive(true)
        toolbar.setNeedsPermission(false)
    }

    private static func cgRect(_ r: CGRect) -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
    }

    func runClickTest() {
        func time(_ label: String, _ body: () -> Void) {
            let t = CFAbsoluteTimeGetCurrent()
            body()
            print(String(format: "%@: %.1f ms", label, (CFAbsoluteTimeGetCurrent() - t) * 1000))
        }
        func spin(_ seconds: Double) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        aimFrame()
        serviceTick()
        time("aimFrame") { aimFrame() }
        time("serviceTick") { serviceTick() }
        time("mouseDown (tap callback)") { inputTap.simulate(.leftMouseDown) }
        time("mouseDown (deferred work)") { spin(0.01) }
        time("10 aim frames while held") { for _ in 0..<10 { aimFrame() } }
        time("mouseUp (tap callback)") { inputTap.simulate(.leftMouseUp) }
        spin(0.01)
        spin(0.3)
        time("second click (tap callbacks)") {
            inputTap.simulate(.leftMouseDown)
            inputTap.simulate(.leftMouseUp)
        }
        spin(0.05)
        time("drag x50 (tap callbacks)") {
            inputTap.simulate(.leftMouseDown)
            for _ in 0..<50 { inputTap.simulate(.leftMouseDragged) }
            inputTap.simulate(.leftMouseUp)
        }
        spin(0.05)
        time("aim frames after up") { for _ in 0..<20 { aimFrame() } }
        print("held after up:", armView.held, "drawing:", armView.ink.isDrawing)
    }

    private func currentScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func runServiceTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: OverlayController.serviceInterval, repeats: true) { [weak self] _ in
            self?.serviceTick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func noteButtonEvent() {
        lastButtonEvent = Date()
        aimFrame()
    }

    private func startDisplayLink() {
        stopDisplayLink()
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else {
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, context in
            guard let context else { return kCVReturnSuccess }
            let overlay = Unmanaged<OverlayController>.fromOpaque(context).takeUnretainedValue()
            overlay.queueAimFrame()
            return kCVReturnSuccess
        }, context)
        if let screen = currentScreen(),
           let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            CVDisplayLinkSetCurrentCGDisplay(link, CGDirectDisplayID(num.uint32Value))
        }
        CVDisplayLinkStart(link)
        displayLink = link
    }

    private func stopDisplayLink() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
        displayLink = nil
        aimLock.lock()
        aimQueued = false
        aimLock.unlock()
    }

    private func queueAimFrame() {
        // Coalesce display-link callbacks onto the main queue so we never pile frames up.
        aimLock.lock()
        let alreadyQueued = aimQueued
        if !alreadyQueued { aimQueued = true }
        aimLock.unlock()
        guard !alreadyQueued else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.aimLock.lock()
            self.aimQueued = false
            self.aimLock.unlock()
            self.aimFrame()
        }
    }

    private func installMouseAimMonitors() {
        removeMouseAimMonitors()
        let events: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            self?.aimFrame()
        }) {
            mouseAimMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.aimFrame()
            return event
        }) {
            mouseAimMonitors.append(local)
        }
    }

    private func removeMouseAimMonitors() {
        mouseAimMonitors.forEach(NSEvent.removeMonitor)
        mouseAimMonitors = []
    }

    /// Vsync / mouse-driven: keep the hand on the cursor with minimal latency.
    private func aimFrame() {
        guard isActive else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = currentScreen() else { return }

        if currentFrame != screen.frame {
            let moving = currentFrame != nil
            currentFrame = screen.frame
            if moving {
                release()
                revealUntil = Date().addingTimeInterval(1.5)
            }
            armView.ink.clear()
            onInkCleared?()
            window.setFrame(screen.frame, display: false)
            armView.frame = NSRect(origin: .zero, size: screen.frame.size)
            toolbar.place(on: screen)
            annotationHints.reposition(on: screen)
            drawingTools.reposition(on: screen, above: annotationHints.frame)
            if let link = displayLink,
               let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                CVDisplayLinkSetCurrentCGDisplay(link, CGDirectDisplayID(num.uint32Value))
            }
        }

        lastMouse = mouse
        let local = CGPoint(x: mouse.x - screen.frame.origin.x, y: mouse.y - screen.frame.origin.y)
        armView.aim(cursor: local)

        guard downPoint != nil else { return }
        let down = CGEventSource.buttonState(.hidSystemState, button: .left)
        if down {
            buttonSeenDown = true
        }
        if buttonSeenDown && !down {
            release()
            return
        }
        drag()
    }

    /// Lower-rate maintenance: menus, toolbar, system cursor fighting.
    private func serviceTick() {
        guard isActive else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = currentScreen() else { return }

        updateZones(mouse: mouse, screen: screen)
        let overDock = DockArea.contains(OverlayController.cgPoint(mouse))
        let catchMouse = overDock && inputTap.isInstalled && !normalCursor && !interactHeld
        if window.ignoresMouseEvents == catchMouse {
            window.ignoresMouseEvents = !catchMouse
        }
        let urgent = interactHeld || menuHover || Date() < guardCursorUntil
        if !normalCursor {
            CursorHider.reassert(fighting: overDock, urgent: urgent)
        }
        checkPermission()
    }
}
