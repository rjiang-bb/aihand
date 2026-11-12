import AppKit
import CoreGraphics

/// Parks the system cursor where it is when drawing starts so apps underneath keep
/// hover/tooltip/dropdown state. The hand follows a separate logical pointer driven by
/// mouse deltas; `InputTap` swallows moves/drags while parked so the app under the parked
/// cursor never sees motion. Covering the screen with a window instead would fire
/// `mouseExited` and dismiss the tip.
enum DrawingPointerPark {
    private static let lock = NSLock()
    private static var _parked = false
    /// AppKit space (y up).
    private static var _logical = CGPoint.zero
    /// Quartz space (y down) — where the real cursor sits while parked.
    private static var _parkedAt = CGPoint.zero

    static var isParked: Bool {
        lock.withLock { _parked }
    }

    /// AppKit-space point the hand should follow while parked (or the real cursor when not).
    static var pointerLocation: CGPoint {
        lock.withLock {
            _parked ? _logical : NSEvent.mouseLocation
        }
    }

    /// Quartz-space logical pointer (for hit-testing event-tap locations).
    static var quartzPointerLocation: CGPoint {
        let p = pointerLocation
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    static func park(at point: CGPoint = NSEvent.mouseLocation) {
        let parkedAt = CGEvent(source: nil)?.location ?? CGPoint(x: point.x, y: primaryHeight - point.y)
        let fresh: Bool = lock.withLock {
            _logical = point
            _parkedAt = parkedAt
            guard !_parked else { return false }
            _parked = true
            return true
        }
        if fresh {
            CGAssociateMouseAndMouseCursorPosition(0)
        }
    }

    static func unpark(warpToLogical: Bool = false) {
        let target: CGPoint? = lock.withLock {
            guard _parked else { return nil }
            _parked = false
            return warpToLogical ? CGPoint(x: _logical.x, y: primaryHeight - _logical.y) : nil
        }
        CGAssociateMouseAndMouseCursorPosition(1)
        if let target {
            CGWarpMouseCursorPosition(target)
        }
    }

    /// Apply HID deltas (Quartz-style: +y is down) onto the logical pointer.
    static func applyDelta(dx: CGFloat, dy: CGFloat) {
        lock.withLock {
            guard _parked else { return }
            _logical.x += dx
            _logical.y -= dy
            clampLocked()
        }
    }

    /// Follow an absolute Quartz location (synthetic events that warp instead of carrying deltas).
    static func followCGEventLocation(_ cg: CGPoint) {
        let appKit = CGPoint(x: cg.x, y: primaryHeight - cg.y)
        lock.withLock {
            guard _parked else { return }
            _logical = appKit
            clampLocked()
        }
    }

    /// Event-tap hook for move/drag events while parked. Real HID motion keeps the parked
    /// location and carries deltas; posted absolute events carry a new location and no deltas.
    static func track(_ event: CGEvent) {
        let dx = CGFloat(event.getDoubleValueField(.mouseEventDeltaX))
        let dy = CGFloat(event.getDoubleValueField(.mouseEventDeltaY))
        if dx != 0 || dy != 0 {
            applyDelta(dx: dx, dy: dy)
            return
        }
        let location = event.location
        let parkedAt = lock.withLock { _parkedAt }
        if hypot(location.x - parkedAt.x, location.y - parkedAt.y) > 0.5 {
            followCGEventLocation(location)
        }
    }

    private static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    private static func clampLocked() {
        let frames = NSScreen.screens.map(\.frame)
        guard let union = frames.reduce(nil as CGRect?, { partial, next in
            partial.map { $0.union(next) } ?? next
        }) else { return }
        _logical.x = min(max(_logical.x, union.minX), union.maxX - 1)
        _logical.y = min(max(_logical.y, union.minY), union.maxY - 1)
    }
}
