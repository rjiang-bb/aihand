#if DEBUG
import AppKit

/// Proves drawing mode keeps another app's hover tooltip up while the hand moves.
///
/// Spawns this binary again as `--tooltip-host`: a separate process with a button that has a
/// real AppKit `toolTip`, plus a tracking view that reports every mouse move / exit on stdout.
/// The probe hovers the button until the system tip window appears, enters drawing mode, moves
/// the hand the way real HID input does, and asserts the host saw no moves/exits and its tip
/// window is still on screen.
///
/// Run: `./scripts/tooltip-freeze-probe.sh`
/// Needs Accessibility. Moves the real cursor briefly — hands off.
enum TooltipFreezeProbe {
    private static var failures: [String] = []
    private static var checks = 0

    private static func expect(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        checks += 1
        print(ok ? "ok   \(label)" : "FAIL \(label)  \(detail())")
        if !ok { failures.append("\(label)  \(detail())") }
    }

    private static func pump(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if let e = NSApp.nextEvent(
                matching: .any,
                until: Date().addingTimeInterval(0.005),
                inMode: .default,
                dequeue: true
            ) {
                NSApp.sendEvent(e)
            }
        }
    }

    /// Host process stdout, parsed on a background thread.
    private final class HostLog {
        private let lock = NSLock()
        private var _moves = 0
        private var _exits = 0
        private var _buttonRect: CGRect?

        var moves: Int { lock.withLock { _moves } }
        var exits: Int { lock.withLock { _exits } }
        var buttonRect: CGRect? { lock.withLock { _buttonRect } }

        func consume(_ line: String) {
            let parts = line.split(separator: " ")
            lock.withLock {
                switch parts.first {
                case "moved": _moves += 1
                case "exited": _exits += 1
                case "ready" where parts.count == 5:
                    let n = parts.dropFirst().compactMap { Double($0) }
                    if n.count == 4 { _buttonRect = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) }
                default: break
                }
            }
        }
    }

    private static func hostWindowCount(pid: pid_t) -> Int {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }.count
    }

    static func run() -> Bool {
        setlinebuf(stdout)
        failures = []
        checks = 0

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        guard let screen = NSScreen.screens.first else {
            print("SKIPPED: no screen")
            return true
        }
        let primaryH = screen.frame.height

        let realDefaults = Preferences.defaults
        let suite = "aihand.tooltipprobe.\(UUID().uuidString)"
        Preferences.defaults = UserDefaults(suiteName: suite)!
        let savedMouse = CGEvent(source: nil)?.location ?? .zero

        // Spawn the host app (separate process — like a real app under the hand).
        let host = Process()
        host.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        host.arguments = ["--tooltip-host"]
        host.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        host.standardOutput = pipe
        let log = HostLog()
        var buffer = ""
        pipe.fileHandleForReading.readabilityHandler = { handle in
            guard let chunk = String(data: handle.availableData, encoding: .utf8) else { return }
            buffer += chunk
            while let nl = buffer.firstIndex(of: "\n") {
                log.consume(String(buffer[..<nl]))
                buffer.removeSubrange(...nl)
            }
        }
        defer {
            DrawingPointerPark.unpark(warpToLogical: false)
            pipe.fileHandleForReading.readabilityHandler = nil
            if host.isRunning { host.terminate() }
            Preferences.defaults.removePersistentDomain(forName: suite)
            Preferences.defaults = realDefaults
            CGWarpMouseCursorPosition(savedMouse)
        }
        do { try host.run() } catch {
            print("SKIPPED: could not spawn host (\(error))")
            return true
        }

        var waited = 0.0
        while log.buttonRect == nil && waited < 5 { pump(0.1); waited += 0.1 }
        guard let button = log.buttonRect else {
            expect("host: reported its button", false)
            return false
        }

        let source = CGEventSource(stateID: .hidSystemState)
        func postMove(to cg: CGPoint) {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: cg, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        /// What real HID input looks like while the cursor is parked: location stays put, deltas move.
        func postRelative(dx: Int64, dy: Int64) {
            let here = CGEvent(source: nil)?.location ?? .zero
            guard let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: here, mouseButton: .left) else { return }
            e.setIntegerValueField(.mouseEventDeltaX, value: dx)
            e.setIntegerValueField(.mouseEventDeltaY, value: dy)
            e.post(tap: .cghidEventTap)
        }

        // 1) Hover the button until AppKit shows its tooltip window.
        let center = CGPoint(x: button.midX, y: primaryH - button.midY)
        let baseWindows = hostWindowCount(pid: host.processIdentifier)
        CGWarpMouseCursorPosition(CGPoint(x: center.x - 40, y: center.y))
        pump(0.1)
        for k in 0...8 {
            postMove(to: CGPoint(x: center.x - 40 + CGFloat(k) * 5, y: center.y))
            pump(0.03)
        }
        print("info host moves while hovering: \(log.moves)  cursor=\(NSEvent.mouseLocation)")
        waited = 0
        while hostWindowCount(pid: host.processIdentifier) <= baseWindows && waited < 4 { pump(0.1); waited += 0.1 }
        let tipWindows = hostWindowCount(pid: host.processIdentifier)
        expect("host: native tooltip appeared on hover", tipWindows > baseWindows, "windows=\(tipWindows) base=\(baseWindows)")

        // 2) Enter drawing.
        let overlay = OverlayController()
        guard overlay.activate() else {
            print("SKIPPED: overlay could not activate (Accessibility?)")
            return true
        }
        pump(0.5)
        expect("drawing: overlay active", overlay.isActive)
        expect("drawing: pointer parked", overlay.isPointerParked)
        let movesBefore = log.moves
        let exitsBefore = log.exits

        // 3) Move the hand well away with relative HID-style motion.
        for _ in 0..<30 {
            postRelative(dx: 8, dy: 6)
            pump(0.016)
        }
        pump(0.6)

        let cursor = NSEvent.mouseLocation
        expect(
            "park: system cursor stayed on the button",
            button.insetBy(dx: -6, dy: -6).contains(cursor),
            "cursor=\(Int(cursor.x)),\(Int(cursor.y)) button=\(button)"
        )
        let logical = DrawingPointerPark.pointerLocation
        expect(
            "park: hand moved away from the button",
            hypot(logical.x - button.midX, logical.y - button.midY) > 150,
            "logical=\(Int(logical.x)),\(Int(logical.y))"
        )
        expect("host: received no mouse moves while drawing", log.moves == movesBefore, "moves=\(log.moves - movesBefore)")
        expect("host: received no mouse exits while drawing", log.exits == exitsBefore, "exits=\(log.exits - exitsBefore)")
        let windowsAfter = hostWindowCount(pid: host.processIdentifier)
        expect("host: native tooltip still on screen", windowsAfter >= tipWindows, "windows=\(windowsAfter) expected=\(tipWindows)")

        // 4) Exit restores the real cursor at the hand.
        overlay.deactivate()
        pump(0.3)
        expect("exit: park released", !overlay.isPointerParked)
        let after = NSEvent.mouseLocation
        expect(
            "exit: real cursor lands where the hand was",
            hypot(after.x - logical.x, after.y - logical.y) < 4,
            "cursor=\(Int(after.x)),\(Int(after.y)) hand=\(Int(logical.x)),\(Int(logical.y))"
        )

        print("checks: \(checks)  failures: \(failures.count)")
        print(failures.isEmpty ? "ALL PASS" : "HAS FAILURES")
        return failures.isEmpty
    }
}

/// Child process for `TooltipFreezeProbe`: a plain window with a native-tooltip button.
enum TooltipHost {
    private final class ReportingView: NSView {
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }
        override func mouseMoved(with event: NSEvent) { print("moved") }
        override func mouseExited(with event: NSEvent) { print("exited") }
    }

    static func run() -> Never {
        setlinebuf(stdout)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let size = CGSize(width: 260, height: 140)
        let screen = NSScreen.screens.first?.frame ?? .zero
        let frame = CGRect(x: screen.midX - size.width / 2 - 200, y: screen.midY - size.height / 2,
                           width: size.width, height: size.height)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Tooltip host"
        window.level = .floating
        let content = ReportingView(frame: NSRect(origin: .zero, size: size))
        let button = NSButton(title: "Hover me", target: nil, action: nil)
        button.toolTip = "Native tooltip"
        button.frame = NSRect(x: 60, y: 45, width: 140, height: 40)
        content.addSubview(button)
        window.contentView = content
        window.acceptsMouseMovedEvents = true
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let r = window.convertToScreen(button.convert(button.bounds, to: nil))
            print("ready \(r.minX) \(r.minY) \(r.width) \(r.height)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(0) }
        app.run()
        exit(0)
    }
}
#endif
