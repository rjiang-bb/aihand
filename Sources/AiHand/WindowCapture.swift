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

    /// Registers AiHand with TCC and prompts if needed so it appears under
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
        overlayFrame: CGRect,
        scope: CaptureScope = Preferences.captureScope
    ) async throws -> Outcome {
        if !ensureScreenRecordingAccess() {
            throw CaptureError.permissionDenied
        }

        let folder = Preferences.ensureScreenshotsFolder()
        guard let screen = screenContaining(strokeScreenBounds) else {
            throw CaptureError.noScreen
        }

        let screenBounds = screen.frame
        let target = resolveCaptureRegion(scope: scope, screen: screen, strokeScreenBounds: strokeScreenBounds)
        let captureBounds = target.bounds

        let full: CGImage
        do {
            full = try await captureScreen(screen: screen)
        } catch let error as CaptureError {
            throw error
        } catch {
            if !CGPreflightScreenCaptureAccess() {
                throw CaptureError.permissionDenied
            }
            Log.write("ScreenCaptureKit failed: \(error.localizedDescription)")
            throw CaptureError.captureFailed
        }

        let image = crop(full, screenFrame: screenBounds, region: captureBounds) ?? full
        let annotated = composite(image: image, strokes: strokes, captureBounds: captureBounds, overlayFrame: overlayFrame)
            ?? image

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "\(formatter.string(from: Date())).png"
        let path = (folder as NSString).appendingPathComponent(name)
        try writePNG(annotated, to: path)
        return Outcome(path: path, windowName: target.name)
    }

    /// AppKit bounds of whatever the current capture scope targets on `screen`.
    static func captureRegion(on screen: NSScreen, scope: CaptureScope = Preferences.captureScope) -> CGRect {
        resolveCaptureRegion(scope: scope, screen: screen, strokeScreenBounds: screen.frame).bounds
    }

    private struct CaptureTarget {
        let bounds: CGRect
        let name: String?
    }

    private static func resolveCaptureRegion(
        scope: CaptureScope,
        screen: NSScreen,
        strokeScreenBounds: CGRect
    ) -> CaptureTarget {
        switch scope {
        case .screen:
            return CaptureTarget(bounds: screen.frame, name: nil)
        case .window:
            if let win = frontmostWindow(on: screen) ?? findWindow(intersecting: strokeScreenBounds) {
                let clipped = win.bounds.intersection(screen.frame)
                if !clipped.isNull, clipped.width > 8, clipped.height > 8 {
                    return CaptureTarget(bounds: clipped, name: win.name)
                }
            }
            return CaptureTarget(bounds: screen.frame, name: nil)
        }
    }

    /// Frontmost normal window that isn’t AiHand, preferably on `screen`.
    static func frontmostWindow(on screen: NSScreen? = nil) -> TargetWindow? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            return nil
        }
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let minArea: CGFloat = 80 * 80
        var bestOnScreen: TargetWindow?
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
            let name = info[kCGWindowName as String] as? String
                ?? info[kCGWindowOwnerName as String] as? String
            let window = TargetWindow(windowID: number, bounds: appKitRect, name: name)
            if let screen {
                let overlap = appKitRect.intersection(screen.frame)
                if !overlap.isNull, overlap.width > 8, overlap.height > 8 {
                    return window
                }
                if bestOnScreen == nil { bestOnScreen = window }
            } else {
                return window
            }
        }
        return bestOnScreen
    }

    private static func crop(_ image: CGImage, screenFrame: CGRect, region: CGRect) -> CGImage? {
        let clipped = region.intersection(screenFrame)
        guard !clipped.isNull, clipped.width > 1, clipped.height > 1 else { return nil }
        if clipped == screenFrame { return image }
        let scaleX = CGFloat(image.width) / screenFrame.width
        let scaleY = CGFloat(image.height) / screenFrame.height
        let cropRect = CGRect(
            x: (clipped.minX - screenFrame.minX) * scaleX,
            y: (screenFrame.maxY - clipped.maxY) * scaleY,
            width: clipped.width * scaleX,
            height: clipped.height * scaleY
        ).integral
        guard cropRect.width > 1, cropRect.height > 1 else { return nil }
        return image.cropping(to: cropRect)
    }

    /// Full-screen capture excluding AiHand’s own windows.
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

    struct TargetWindow {
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
            guard !stroke.points.isEmpty else { continue }
            let scale = (scaleX + scaleY) / 2

            if stroke.tool == .text, let text = stroke.text, !text.isEmpty {
                let topLeft = toBitmap(stroke.points[0])
                let fontSize = max(10, stroke.width * scale)
                let image = InkTextStyle.renderImage(
                    text: text,
                    background: stroke.color,
                    fontSize: fontSize,
                    maxTextWidth: 520 * scale
                )
                let box = CGRect(
                    x: topLeft.x,
                    y: topLeft.y - image.size.height,
                    width: image.size.width,
                    height: image.size.height
                )
                if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    ctx.draw(cg, in: box)
                }
                continue
            }

            let mapped = stroke.points.map(toBitmap)
            let width = max(2, stroke.width * scale)
            let path = StrokePath.make(tool: stroke.tool, points: mapped, lineWidth: width)

            ctx.setStrokeColor(stroke.color)
            ctx.setLineWidth(width)
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
