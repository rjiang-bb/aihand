import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum WindowCapture {
    struct Outcome {
        let path: String
        let windowName: String?
    }

    enum CaptureError: Error, Equatable, LocalizedError {
        case noScreen
        case captureFailed
        case permissionDenied
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noScreen: return "Couldn’t find the screen that contains the drawing."
            case .captureFailed: return "Screen capture failed."
            case .permissionDenied:
                return "Allow Screen Recording for AiHand in System Settings, then try again."
            case .writeFailed(let msg): return "Couldn’t save screenshot: \(msg)"
            }
        }
    }

    /// Registers TinyHand with TCC and prompts if needed so it appears under
    /// System Settings → Privacy & Security → Screen Recording.
    @discardableResult
    static func ensureScreenRecordingAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    static func captureAnnotated(
        strokes: [StrokeResult],
        strokeScreenBounds: CGRect,
        overlayFrame: CGRect
    ) async throws -> Outcome {
        if !ensureScreenRecordingAccess() {
            throw CaptureError.permissionDenied
        }

        let folder = Preferences.ensureScreenshotsFolder()
        guard let screen = screenContaining(strokeScreenBounds) else {
            throw CaptureError.noScreen
        }

        let screenBounds = screen.frame
        let image: CGImage
        do {
            image = try await captureScreen(screen: screen)
        } catch let error as CaptureError {
            throw error
        } catch {
            if !CGPreflightScreenCaptureAccess() {
                throw CaptureError.permissionDenied
            }
            Log.write("ScreenCaptureKit failed: \(error.localizedDescription)")
            throw CaptureError.captureFailed
        }

        let annotated = composite(image: image, strokes: strokes, captureBounds: screenBounds, overlayFrame: overlayFrame)
            ?? image

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "\(formatter.string(from: Date())).png"
        let path = (folder as NSString).appendingPathComponent(name)
        try writePNG(annotated, to: path)
        return Outcome(path: path, windowName: findWindow(intersecting: strokeScreenBounds)?.name)
    }

    /// Full-screen capture excluding TinyHand’s own windows.
    /// Uses ScreenCaptureKit on macOS 14+ (required on current OS); CG fallback on 13.
    private static func captureScreen(screen: NSScreen) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            return try await captureWithScreenshotManager(screen: screen)
        }
        guard let image = captureScreenLegacy(screen: screen) else {
            throw CaptureError.captureFailed
        }
        return image
    }

    /// Pre–ScreenCaptureKit path for macOS 13. Obsolete on newer OS (returns nil).
    private static func captureScreenLegacy(screen: NSScreen) -> CGImage? {
        let ourPID = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else {
            return nil
        }
        var ids: [CGWindowID] = []
        for info in list.reversed() {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID != ourPID,
                  let number = info[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }
            ids.append(number)
        }
        guard !ids.isEmpty else { return nil }
        let bounds = appKitToCG(screen.frame)
        return CGImage(
            windowListFromArrayScreenBounds: bounds,
            windowArray: ids as CFArray,
            imageOption: [.bestResolution]
        )
    }

    @available(macOS 14.0, *)
    private static func captureWithScreenshotManager(screen: NSScreen) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = matchingDisplay(screen: screen, in: content.displays) else {
            throw CaptureError.noScreen
        }

        let ourPID = ProcessInfo.processInfo.processIdentifier
        let ourBundle = Bundle.main.bundleIdentifier
        let excludedApps = content.applications.filter { app in
            app.processID == ourPID || (ourBundle != nil && app.bundleIdentifier == ourBundle)
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let rect = filter.contentRect
        config.width = max(1, Int((rect.width * scale).rounded()))
        config.height = max(1, Int((rect.height * scale).rounded()))
        config.showsCursor = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    @available(macOS 14.0, *)
    private static func matchingDisplay(screen: NSScreen, in displays: [SCDisplay]) -> SCDisplay? {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        if let number, let match = displays.first(where: { $0.displayID == number }) {
            return match
        }
        // Fall back to largest overlap with the NSScreen frame.
        return displays
            .map { display -> (SCDisplay, CGFloat) in
                let overlap = cgToAppKit(display.frame).intersection(screen.frame)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                return (display, area)
            }
            .max(by: { $0.1 < $1.1 })?
            .0
            ?? displays.first
    }

    private static func screenContaining(_ rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let exact = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) {
            return exact
        }
        return NSScreen.screens
            .map { screen -> (NSScreen, CGFloat) in
                let overlap = screen.frame.intersection(rect)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                return (screen, area)
            }
            .filter { $0.1 > 0 }
            .max(by: { $0.1 < $1.1 })?
            .0
            ?? NSScreen.main
    }

    private struct TargetWindow {
        let windowID: CGWindowID
        let bounds: CGRect
        let name: String?
    }

    private static func findWindow(intersecting screenBounds: CGRect) -> TargetWindow? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            return nil
        }
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let minArea: CGFloat = 80 * 80

        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID != ourPID,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }
            let alpha = (info[kCGWindowAlpha as String] as? CGFloat) ?? 1
            if alpha < 0.05 { continue }
            let appKitRect = cgToAppKit(cgRect)
            if appKitRect.width * appKitRect.height < minArea { continue }
            let overlap = appKitRect.intersection(screenBounds)
            if overlap.isNull || overlap.width < 2 || overlap.height < 2 { continue }
            let name = info[kCGWindowName as String] as? String
                ?? info[kCGWindowOwnerName as String] as? String
            return TargetWindow(windowID: number, bounds: appKitRect, name: name)
        }
        return nil
    }

    private static func composite(
        image: CGImage,
        strokes: [StrokeResult],
        captureBounds: CGRect,
        overlayFrame: CGRect
    ) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: max(8, image.bitsPerComponent),
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let scaleX = CGFloat(width) / captureBounds.width
        let scaleY = CGFloat(height) / captureBounds.height

        func toBitmap(_ local: CGPoint) -> CGPoint {
            let screen = CGPoint(x: overlayFrame.origin.x + local.x, y: overlayFrame.origin.y + local.y)
            let x = (screen.x - captureBounds.minX) * scaleX
            let yFromTop = (captureBounds.maxY - screen.y) * scaleY
            let y = CGFloat(height) - yFromTop
            return CGPoint(x: x, y: y)
        }

        for stroke in strokes {
            guard let first = stroke.points.first else { continue }
            let path = CGMutablePath()
            let p0 = toBitmap(first)
            path.move(to: p0)
            if stroke.points.count == 1 {
                path.addLine(to: p0)
            }
            for i in 1..<stroke.points.count {
                let p = toBitmap(stroke.points[i])
                let prev = toBitmap(stroke.points[i - 1])
                let mid = CGPoint(x: (prev.x + p.x) / 2, y: (prev.y + p.y) / 2)
                path.addQuadCurve(to: mid, control: prev)
            }
            if stroke.points.count > 1, let last = stroke.points.last {
                path.addLine(to: toBitmap(last))
            }

            ctx.setStrokeColor(stroke.color)
            ctx.setLineWidth(max(2, stroke.width * ((scaleX + scaleY) / 2)))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()
        }
        return ctx.makeImage()
    }

    private static func writePNG(_ image: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.writeFailed("could not create file")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CaptureError.writeFailed("could not write PNG")
        }
    }

    private static func appKitToCG(_ r: CGRect) -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
    }

    private static func cgToAppKit(_ r: CGRect) -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
    }
}
