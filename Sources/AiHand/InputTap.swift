import AppKit

final class InputTap {
    var onLeftMouseDown: (() -> Void)?
    var onLeftMouseUp: (() -> Void)?
    var onRightMouseDown: (() -> Void)?
    var onRightMouseUp: (() -> Void)?
    var onInteractDown: (() -> Void)?
    var onInteractUp: (() -> Void)?
    var onLeftDragged: (() -> Void)?
    var onRightDragged: (() -> Void)?
    var onPassThroughPress: ((CGPoint) -> Void)?

    private let lock = NSLock()
    private var _active = false
    private var _passThroughRects: [CGRect] = []
    private var _interactKey: CGEventFlags = []
    private var _interactPress = false

    var passThroughRects: [CGRect] {
        get { lock.withLock { _passThroughRects } }
        set { lock.withLock { _passThroughRects = newValue } }
    }

    private var active: Bool {
        lock.withLock { _active }
    }

    var interactKey: CGEventFlags {
        get { lock.withLock { _interactKey } }
        set { lock.withLock { _interactKey = newValue } }
    }

    var interactPressing: Bool {
        lock.withLock { _interactPress }
    }

    private var passingThrough = false
    private(set) var maxWaitMs: Double = 0
    private var tap: CFMachPort?
    private var thread: Thread?

    private(set) var isInstalled = false

    @discardableResult
    func install() -> Bool {
        guard tap == nil else {
            return true
        }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            // Drives DrawingPointerPark; swallowed only while the cursor is parked.
            (1 << CGEventType.mouseMoved.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let me = Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }
        CGEvent.tapEnable(tap: tap, enable: false)

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "AiHand event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        self.tap = tap
        self.thread = thread
        isInstalled = true
        return true
    }

    func setActive(_ value: Bool) {
        lock.withLock {
            _active = value
            _interactPress = false
        }
        guard let tap = tap else {
            return
        }
        CGEvent.tapEnable(tap: tap, enable: value)
    }

    func simulate(_ type: CGEventType) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left) else {
            return
        }
        let was = active
        lock.withLock { _active = true }
        _ = handle(type: type, event: event)
        lock.withLock { _active = was }
    }

    func resetWait() {
        maxWaitMs = 0
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.timestamp > 0 {
            let wait = Double(DispatchTime.now().uptimeNanoseconds &- event.timestamp) / 1_000_000
            if wait < 600_000 {
                maxWaitMs = max(maxWaitMs, wait)
            }
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if type == .tapDisabledByTimeout {
                Log.write("event tap was disabled by a timeout; re-enabled")
            }
            if active, let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard active else {
            return Unmanaged.passUnretained(event)
        }

        let isMotion = type == .mouseMoved || type == .leftMouseDragged
            || type == .rightMouseDragged || type == .otherMouseDragged
        if isMotion && DrawingPointerPark.isParked {
            DrawingPointerPark.track(event)
        }

        let key = interactKey
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if !key.isEmpty && (event.flags.contains(key) || CGEventSource.flagsState(.hidSystemState).contains(key)) {
                lock.withLock { _interactPress = true }
                Self.releaseParkForRealPress(event)
                DispatchQueue.main.async { [weak self] in self?.onInteractDown?() }
            }
        default:
            break
        }
        if lock.withLock({ _interactPress }) {
            event.flags.remove(key)
            if type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp {
                lock.withLock { _interactPress = false }
                DispatchQueue.main.async { [weak self] in self?.onInteractUp?() }
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let hit = DrawingPointerPark.isParked ? DrawingPointerPark.quartzPointerLocation : event.location
            passingThrough = passThroughRects.contains { $0.contains(hit) }
            if passingThrough {
                Self.releaseParkForRealPress(event)
                let location = event.location
                DispatchQueue.main.async { [weak self] in self?.onPassThroughPress?(location) }
            }
        default:
            break
        }
        if passingThrough {
            if type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp {
                passingThrough = false
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown, .otherMouseDown:
            DispatchQueue.main.async { [weak self] in self?.onLeftMouseDown?() }
            return nil
        case .rightMouseDown:
            DispatchQueue.main.async { [weak self] in self?.onRightMouseDown?() }
            return nil
        case .leftMouseUp, .otherMouseUp:
            DispatchQueue.main.async { [weak self] in self?.onLeftMouseUp?() }
            return nil
        case .rightMouseUp:
            DispatchQueue.main.async { [weak self] in self?.onRightMouseUp?() }
            return nil
        case .leftMouseDragged, .otherMouseDragged:
            DispatchQueue.main.async { [weak self] in self?.onLeftDragged?() }
            // Parked: the hand follows deltas; the app under the parked cursor must see nothing.
            if DrawingPointerPark.isParked { return nil }
            // Rewrite to mouseMoved so the cursor keeps tracking while we consume the click.
            event.type = .mouseMoved
            return Unmanaged.passUnretained(event)
        case .rightMouseDragged:
            DispatchQueue.main.async { [weak self] in self?.onRightDragged?() }
            if DrawingPointerPark.isParked { return nil }
            event.type = .mouseMoved
            return Unmanaged.passUnretained(event)
        case .mouseMoved:
            // Keeps hover/tooltips in the app under the parked cursor. Keys are never touched.
            return DrawingPointerPark.isParked ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// A press that must land for real (menu bar, our chrome, interact key): bring the real
    /// cursor to the hand first so the click hits what the hand is over.
    private static func releaseParkForRealPress(_ event: CGEvent) {
        guard DrawingPointerPark.isParked else { return }
        let target = DrawingPointerPark.quartzPointerLocation
        DrawingPointerPark.unpark(warpToLogical: true)
        event.location = target
    }
}
