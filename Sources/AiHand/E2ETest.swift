import AppKit

enum E2ETest {
    private final class CatcherView: NSView {
        var clicks = 0
        var scrolls = 0
        override func mouseDown(with event: NSEvent) {
            clicks += 1
        }
        override func scrollWheel(with event: NSEvent) {
            scrolls += 1
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 0.95, alpha: 1).setFill()
            dirtyRect.fill()
        }
    }

    static func run() {
        setlinebuf(stdout)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        guard let screen = NSScreen.screens.first else {
            print("no screen")
            return
        }
        let size = CGSize(width: 520, height: 360)
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                           width: size.width, height: size.height)
        let catcher = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let catcherView = CatcherView(frame: CGRect(origin: .zero, size: size))
        catcher.contentView = catcherView
        catcher.level = .statusBar
        catcher.orderFrontRegardless()

        let saved = CGEvent(source: nil)?.location ?? .zero
        let source = CGEventSource(stateID: .hidSystemState)
        let start = CGPoint(x: screen.frame.midX - 150, y: screen.frame.height - screen.frame.midY)

        func pump(_ seconds: Double) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until {
                if let e = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005), inMode: .default, dequeue: true) {
                    app.sendEvent(e)
                }
            }
        }
        func post(_ type: CGEventType, _ p: CGPoint) {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        func state(_ label: String, _ overlay: OverlayController) {
            let m = NSEvent.mouseLocation
            let down = CGEventSource.buttonState(.hidSystemState, button: .left)
            print(String(format: "%-14@ mouse=(%.0f,%.0f) hidDown=%@ %@", label as NSString, m.x, m.y,
                         down ? "yes" : "no", overlay.debugState))
        }

        let savedStyle = PointerStyle.saved
        PointerStyle.saved = .lavender
        let overlay = OverlayController()
        let installed = overlay.activate()
        print("tap installed:", installed)
        pump(0.3)

        post(.mouseMoved, start)
        pump(0.2)
        state("before press", overlay)

        post(.leftMouseDown, start)
        pump(0.1)
        state("pressed", overlay)

        for k in 1...40 {
            let p = CGPoint(x: start.x + CGFloat(k) * 6, y: start.y + 30 * sin(CGFloat(k) / 6))
            post(.leftMouseDragged, p)
            pump(0.016)
        }
        state("dragged", overlay)

        post(.leftMouseUp, CGPoint(x: start.x + 240, y: start.y))
        pump(0.2)
        state("released", overlay)

        for _ in 0..<5 {
            CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: -2, wheel2: 0, wheel3: 0)?
                .post(tap: .cghidEventTap)
            pump(0.03)
        }
        pump(0.1)
        print("scroll ticks right after drawing that reached the app (of 5):", catcherView.scrolls)

        let before = overlay.inkStrokes
        post(.leftMouseDown, start)
        pump(0.05)
        post(.leftMouseUp, start)
        pump(0.2)
        state("plain click", overlay)
        print("plain click added strokes:", overlay.inkStrokes - before)

        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        if let c = overlay.toolbarButtonCenter(.laser) {
            let p = CGPoint(x: c.x, y: primaryH - c.y)
            post(.mouseMoved, p)
            pump(0.2)
            post(.leftMouseDown, p)
            post(.leftMouseUp, p)
            pump(0.4)
        }
        print("style after clicking the toolbar's laser button:", overlay.style.rawValue)
        print("clicks that leaked to the catcher window:", catcherView.clicks)

        let clickPoint = start
        overlay.resetTapWait()
        Thread.detachNewThread {
            for _ in 0..<3 {
                usleep(400_000)
                post(.leftMouseDown, clickPoint)
                usleep(30_000)
                post(.leftMouseUp, clickPoint)
            }
        }
        Thread.sleep(forTimeInterval: 2)
        pump(0.3)
        var count: UInt32 = 0
        CGGetEventTapList(0, nil, &count)
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        CGGetEventTapList(count, &taps, &count)
        if let mine = taps.first(where: { $0.tappingProcess == getpid() && $0.enabled }) {
            print(String(format: "tap latency while the main thread was frozen: avg %.1f ms, max %.1f ms",
                         mine.avgUsecLatency / 1000, mine.maxUsecLatency / 1000))
        }
        print(String(format: "longest a click waited to reach the tap during the stall: %.1f ms", overlay.tapMaxWaitMs))
        print("clicks that leaked during the stall:", catcherView.clicks)

        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 0x35, keyDown: down)?.post(tap: .cghidEventTap)
            pump(0.1)
        }
        pump(0.2)
        print("active after Esc:", overlay.isActive)

        overlay.deactivate()
        PointerStyle.saved = savedStyle
        catcher.orderOut(nil)
        CGWarpMouseCursorPosition(saved)
        pump(0.1)
    }
}
