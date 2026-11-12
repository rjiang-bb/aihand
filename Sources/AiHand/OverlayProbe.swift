#if DEBUG
import AppKit

/// Overlay / drawing end-to-end harness. Activates the real `OverlayController` and drives it
/// with real HID mouse events (CGEvent → event tap), asserting on strokes, tools, undo/clear,
/// toolbar clicks and click-swallowing.
///
/// Needs Accessibility permission for the built binary and a GUI session. It **moves the real
/// cursor** for a few seconds — don't touch the mouse while it runs. Without permission (event
/// tap can't install) it prints SKIPPED and exits 0 so it never blocks a machine that can't run it.
///
/// Run: `./scripts/overlay-probe.sh`
enum OverlayProbe {
    private final class CatcherView: NSView {
        var clicks = 0
        override func mouseDown(with event: NSEvent) { clicks += 1 }
    }

    static var failures: [String] = []
    static var checks = 0

    static func expect(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        checks += 1
        if !ok { failures.append("\(label)  \(detail())") }
    }

    static func pump(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005), inMode: .default, dequeue: true) {
                NSApp.sendEvent(e)
            }
        }
    }

    static func run() -> Bool {
        setlinebuf(stdout)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        guard let screen = NSScreen.screens.first else {
            print("SKIPPED: no screen")
            return true
        }

        // Sandbox prefs; the saved pointer style lives in UserDefaults.standard, so restore it.
        let realDefaults = Preferences.defaults
        let suite = "aihand.overlayprobe.\(UUID().uuidString)"
        Preferences.defaults = UserDefaults(suiteName: suite)!
        let savedStyle = PointerStyle.saved
        PointerStyle.saved = .lavender
        let savedMouse = CGEvent(source: nil)?.location ?? .zero
        defer {
            Preferences.defaults.removePersistentDomain(forName: suite)
            Preferences.defaults = realDefaults
            PointerStyle.saved = savedStyle
            CGWarpMouseCursorPosition(savedMouse)
        }

        // A window under the overlay that must never receive the drawing clicks.
        let size = CGSize(width: 700, height: 460)
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                           width: size.width, height: size.height)
        let catcher = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let catcherView = CatcherView(frame: CGRect(origin: .zero, size: size))
        catcher.contentView = catcherView
        catcher.level = .statusBar
        catcher.orderFrontRegardless()
        defer { catcher.orderOut(nil) }

        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ p: CGPoint) {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        func move(_ p: CGPoint) { post(.mouseMoved, p); pump(0.15) }
        func drag(from a: CGPoint, to b: CGPoint, steps: Int = 24) {
            move(a)
            post(.leftMouseDown, a)
            pump(0.1)
            for k in 1...steps {
                let t = CGFloat(k) / CGFloat(steps)
                post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                pump(0.016)
            }
            pump(0.05)
            post(.leftMouseUp, b)
            pump(0.3)
        }
        func click(_ p: CGPoint) {
            move(p)
            post(.leftMouseDown, p); pump(0.05)
            post(.leftMouseUp, p); pump(0.3)
        }

        let overlay = OverlayController()
        var completed: [StrokeResult] = []
        var cleared = 0
        var undone = 0
        overlay.onStrokeComplete = { result, _, _ in completed.append(result) }
        overlay.onInkCleared = { cleared += 1 }
        overlay.onStrokeUndone = { _ in undone += 1 }

        guard overlay.activate() else {
            print("SKIPPED: overlay could not activate (Accessibility permission for this binary?)")
            return true
        }
        pump(0.4)
        expect("overlay: active after activate()", overlay.isActive)
        expect("overlay: starts with no ink", overlay.inkStrokes == 0)
        expect("overlay: starts on the lavender hand", overlay.style == .lavender, overlay.style.rawValue)

        let start = CGPoint(x: screen.frame.midX - 200, y: screen.frame.height - screen.frame.midY - 40)
        let end = CGPoint(x: screen.frame.midX + 120, y: start.y + 70)

        // MARK: freehand (default tool)
        Preferences.drawTool = .freehand
        drag(from: start, to: end)
        expect("freehand: drag adds exactly one stroke", overlay.inkStrokes == 1, "strokes=\(overlay.inkStrokes) \(overlay.debugState)")
        expect("freehand: stroke-complete fires once", completed.count == 1, "n=\(completed.count)")
        if let r = completed.last {
            expect("freehand: result tool", r.tool == .freehand, "\(r.tool)")
            expect("freehand: result has many points", r.points.count > 5, "n=\(r.points.count)")
            expect("freehand: stroke is as wide as the drag", r.bounds.width > 250, "bounds=\(r.bounds)")
            expect("freehand: ink colour is the hand's", r.color == overlay.style.inkColor)
        }
        expect("freehand: has annotation ink afterwards", overlay.hasAnnotationInk)

        // A plain click must not leave a mark.
        let before = overlay.inkStrokes
        click(start)
        expect("click: plain click adds no stroke", overlay.inkStrokes == before, "before=\(before) after=\(overlay.inkStrokes)")

        // MARK: rectangle
        Preferences.drawTool = .rectangle
        let rectA = CGPoint(x: start.x, y: start.y - 100), rectB = CGPoint(x: start.x + 220, y: start.y - 20)
        drag(from: rectA, to: rectB)
        expect("rectangle: adds a stroke", overlay.inkStrokes == 2, "strokes=\(overlay.inkStrokes)")
        if let r = completed.last, completed.count == 2 {
            expect("rectangle: result tool", r.tool == .rectangle, "\(r.tool)")
            expect("rectangle: two anchor points", r.points.count == 2, "n=\(r.points.count)")
            expect("rectangle: size matches the drag", abs(r.bounds.width - 220) < 24 && abs(r.bounds.height - 80) < 24, "bounds=\(r.bounds)")
        } else {
            expect("rectangle: stroke-complete fired", false, "completed=\(completed.count)")
        }

        // MARK: arrow
        Preferences.drawTool = .arrow
        drag(from: CGPoint(x: end.x, y: end.y + 60), to: CGPoint(x: end.x - 150, y: end.y + 140))
        expect("arrow: adds a stroke", overlay.inkStrokes == 3, "strokes=\(overlay.inkStrokes)")
        expect("arrow: result tool", completed.last?.tool == .arrow, "\(String(describing: completed.last?.tool))")

        // MARK: text tool — dragging draws nothing, a click opens the editor
        Preferences.drawTool = .text
        let textStrokes = overlay.inkStrokes
        drag(from: CGPoint(x: start.x, y: start.y + 150), to: CGPoint(x: start.x + 100, y: start.y + 150))
        expect("text: drag draws no stroke", overlay.inkStrokes == textStrokes, "strokes=\(overlay.inkStrokes)")
        click(CGPoint(x: start.x + 40, y: start.y + 160))
        expect("text: click opens the text editor", overlay.isEditingText)
        overlay.undoLastStroke()
        pump(0.2)
        expect("text: undo cancels the editor", !overlay.isEditingText)
        expect("text: cancelling leaves strokes untouched", overlay.inkStrokes == textStrokes)

        // MARK: undo / clear
        Preferences.drawTool = .freehand
        overlay.undoLastStroke()
        expect("undo: removes the newest stroke", overlay.inkStrokes == 2, "strokes=\(overlay.inkStrokes)")
        expect("undo: notifies the host", undone == 1, "undone=\(undone)")
        overlay.undoLastStroke(); overlay.undoLastStroke()
        expect("undo: can remove everything", overlay.inkStrokes == 0)
        overlay.undoLastStroke()
        expect("undo: nothing left is a no-op", overlay.inkStrokes == 0 && undone == 3, "undone=\(undone)")

        drag(from: start, to: end)
        drag(from: rectA, to: rectB)
        expect("clear: two strokes before clearing", overlay.inkStrokes == 2, "strokes=\(overlay.inkStrokes)")
        overlay.clearInk()
        expect("clear: removes all ink", overlay.inkStrokes == 0)
        expect("clear: notifies the host", cleared == 1, "cleared=\(cleared)")
        expect("clear: no annotation ink left", !overlay.hasAnnotationInk)

        // MARK: toolbar click switches the hand
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        if let c = overlay.toolbarButtonCenter(.laser) {
            let p = CGPoint(x: c.x, y: primaryH - c.y)
            click(p)
            pump(0.3)
            expect("toolbar: clicking the laser button switches style", overlay.style == .laser, overlay.style.rawValue)
            expect("toolbar: a toolbar click draws nothing", overlay.inkStrokes == 0, "strokes=\(overlay.inkStrokes)")
        } else {
            expect("toolbar: laser button is on screen", false)
        }

        // MARK: nothing leaked to the window underneath
        expect("swallow: drawing clicks never reached the window below", catcherView.clicks == 0, "clicks=\(catcherView.clicks)")

        // MARK: Esc clears ink and exits
        drag(from: start, to: end)
        expect("esc: stroke is on screen before Esc", overlay.inkStrokes == 1, "strokes=\(overlay.inkStrokes)")
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 0x35, keyDown: down)?.post(tap: .cghidEventTap)
            pump(0.1)
        }
        pump(0.3)
        expect("esc: clears the drawing", overlay.inkStrokes == 0, "strokes=\(overlay.inkStrokes)")
        expect("esc: leaves the overlay", !overlay.isActive)

        overlay.deactivate()
        pump(0.1)

        print("checks: \(checks)  failures: \(failures.count)")
        for f in failures { print("FAIL \(f)") }
        print(failures.isEmpty ? "ALL PASS" : "HAS FAILURES")
        return failures.isEmpty
    }
}
#endif
