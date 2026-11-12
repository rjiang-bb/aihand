import AppKit
import AVFoundation
import ScreenCaptureKit

/// Records a rectangular region of a display to a temporary `.mov` via ScreenCaptureKit.
final class RegionRecorder: NSObject, @unchecked Sendable {
    enum RecorderError: Error, Equatable, LocalizedError {
        case permissionDenied
        case noDisplay
        case startFailed(String)
        case notRecording
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Allow Screen Recording for AiHand in System Settings, then try again."
            case .noDisplay:
                return "Couldn’t find the display for that region."
            case .startFailed(let msg):
                return "Couldn’t start recording: \(msg)"
            case .notRecording:
                return "Nothing is being recorded."
            case .writeFailed(let msg):
                return "Couldn’t save video: \(msg)"
            }
        }
    }

    private let lock = NSLock()
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var tempURL: URL?
    private var startedSession = false
    private var firstTimestamp: CMTime?
    private var isStopping = false
    private let outputQueue = DispatchQueue(label: "aihand.region-recorder")

    private(set) var isRecording = false
    private(set) var startedAt: Date?
    var onElapsed: ((TimeInterval) -> Void)?
    private var elapsedTimer: Timer?

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    @MainActor
    func start(region appKitRegion: CGRect, on screen: NSScreen) async throws {
        guard !isRecording else { return }
        if !WindowCapture.ensureScreenRecordingAccess() {
            throw RecorderError.permissionDenied
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if !CGPreflightScreenCaptureAccess() {
                throw RecorderError.permissionDenied
            }
            throw RecorderError.startFailed(error.localizedDescription)
        }

        guard let display = Self.matchingDisplay(screen: screen, in: content.displays) else {
            throw RecorderError.noDisplay
        }

        let clipped = appKitRegion.intersection(screen.frame)
        guard !clipped.isNull, clipped.width >= 20, clipped.height >= 20 else {
            throw RecorderError.startFailed("selection too small")
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

        let scale: CGFloat
        if #available(macOS 14.0, *) {
            scale = CGFloat(filter.pointPixelScale)
        } else {
            scale = screen.backingScaleFactor
        }
        let sourceRect = CGRect(
            x: clipped.minX - screen.frame.minX,
            y: screen.frame.maxY - clipped.maxY,
            width: clipped.width,
            height: clipped.height
        )
        let pixelWidth = max(2, Int((clipped.width * scale).rounded()) / 2 * 2)
        let pixelHeight = max(2, Int((clipped.height * scale).rounded()) / 2 * 2)

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.sourceRect = sourceRect
        config.showsCursor = true
        config.queueDepth = 8
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aihand-video-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: url)

        let assetWriter: AVAssetWriter
        do {
            assetWriter = try AVAssetWriter(url: url, fileType: .mov)
        } catch {
            throw RecorderError.writeFailed(error.localizedDescription)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, pixelWidth * pixelHeight * 4),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: pixelWidth,
                kCVPixelBufferHeightKey as String: pixelHeight,
            ]
        )
        guard assetWriter.canAdd(input) else {
            throw RecorderError.writeFailed("cannot add video input")
        }
        assetWriter.add(input)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        } catch {
            throw RecorderError.startFailed(error.localizedDescription)
        }

        lock.withLock {
            self.stream = stream
            self.writer = assetWriter
            self.writerInput = input
            self.adaptor = pixelAdaptor
            self.tempURL = url
            self.startedSession = false
            self.firstTimestamp = nil
            self.isStopping = false
        }

        do {
            try await stream.startCapture()
        } catch {
            await teardownWriter(cancel: true)
            throw RecorderError.startFailed(error.localizedDescription)
        }

        isRecording = true
        startedAt = Date()
        startElapsedTimer()
        Log.write("video recording started \(Int(clipped.width))x\(Int(clipped.height)) → \(url.path)")
    }

    /// Stops capture and returns the temp movie URL.
    @MainActor
    func stop() async throws -> URL {
        guard isRecording else {
            throw RecorderError.notRecording
        }
        let (url, stream): (URL?, SCStream?) = lock.withLock {
            isStopping = true
            return (tempURL, self.stream)
        }

        guard let url else {
            throw RecorderError.notRecording
        }

        stopElapsedTimer()
        isRecording = false
        startedAt = nil

        if let stream {
            try? await stream.stopCapture()
        }

        let (didStart, status, error) = await finishWriter()
        lock.withLock {
            self.stream = nil
            self.writer = nil
            self.writerInput = nil
            self.adaptor = nil
            self.tempURL = nil
        }

        guard didStart, status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.writeFailed(error ?? "no frames captured")
        }
        Log.write("video recording stopped \(url.path)")
        return url
    }

    @MainActor
    func cancel() async {
        stopElapsedTimer()
        isRecording = false
        startedAt = nil
        let (stream, url): (SCStream?, URL?) = lock.withLock {
            isStopping = true
            return (self.stream, tempURL)
        }

        if let stream {
            try? await stream.stopCapture()
        }
        await teardownWriter(cancel: true)
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        lock.withLock {
            tempURL = nil
            self.stream = nil
        }
        Log.write("video recording cancelled")
    }

    /// Move a temp recording into the screenshots folder with a timestamped name.
    static func promoteToScreenshotsFolder(_ tempURL: URL) throws -> URL {
        let folder = Preferences.ensureScreenshotsFolder()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        var name = "\(formatter.string(from: Date())).mov"
        var dest = URL(fileURLWithPath: folder).appendingPathComponent(name)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            name = "\(formatter.string(from: Date()))-\(n).mov"
            dest = URL(fileURLWithPath: folder).appendingPathComponent(name)
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: tempURL, to: dest)
        } catch {
            // Fallback if move across volumes fails.
            try FileManager.default.copyItem(at: tempURL, to: dest)
            try? FileManager.default.removeItem(at: tempURL)
        }
        return dest
    }

    static func posterImage(for url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        do {
            let cg = try gen.copyCGImage(at: .zero, actualTime: nil)
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } catch {
            return nil
        }
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        // Fire on the main run loop (.common) so the toolbar clock keeps ticking
        // while other tracking / modal run-loop modes are active.
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let seconds = self.elapsed
            if Thread.isMainThread {
                self.onElapsed?(seconds)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.onElapsed?(seconds)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        elapsedTimer = t
        onElapsed?(0)
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func finishWriter() async -> (Bool, AVAssetWriter.Status, String?) {
        await withCheckedContinuation { cont in
            outputQueue.async {
                self.lock.lock()
                let writer = self.writer
                let input = self.writerInput
                let didStart = self.startedSession
                self.lock.unlock()

                guard let writer, let input else {
                    cont.resume(returning: (false, .unknown, "missing writer"))
                    return
                }
                if didStart {
                    input.markAsFinished()
                    writer.finishWriting {
                        cont.resume(returning: (
                            true,
                            writer.status,
                            writer.error?.localizedDescription
                        ))
                    }
                } else {
                    writer.cancelWriting()
                    cont.resume(returning: (false, writer.status, "no frames captured"))
                }
            }
        }
    }

    private func teardownWriter(cancel: Bool) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            outputQueue.async {
                self.lock.lock()
                let writer = self.writer
                let input = self.writerInput
                let didStart = self.startedSession
                self.writer = nil
                self.writerInput = nil
                self.adaptor = nil
                self.startedSession = false
                self.firstTimestamp = nil
                self.lock.unlock()

                guard let writer, let input else {
                    cont.resume()
                    return
                }
                if cancel || !didStart {
                    writer.cancelWriting()
                    cont.resume()
                } else {
                    input.markAsFinished()
                    writer.finishWriting { cont.resume() }
                }
            }
        }
    }

    private static func matchingDisplay(screen: NSScreen, in displays: [SCDisplay]) -> SCDisplay? {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        if let number, let match = displays.first(where: { $0.displayID == number }) {
            return match
        }
        return displays
            .map { display -> (SCDisplay, CGFloat) in
                let overlap = Self.cgToAppKit(display.frame).intersection(screen.frame)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                return (display, area)
            }
            .max(by: { $0.1 < $1.1 })?
            .0
            ?? displays.first
    }

    private static func cgToAppKit(_ r: CGRect) -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
    }
}

extension RegionRecorder: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        lock.lock()
        let stopping = isStopping
        let writer = self.writer
        let input = self.writerInput
        let adaptor = self.adaptor
        lock.unlock()
        guard !stopping, let writer, let input, let adaptor else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !startedSession {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: pts)
            lock.lock()
            startedSession = true
            firstTimestamp = pts
            lock.unlock()
        }
        guard input.isReadyForMoreMediaData else { return }
        let first = firstTimestamp ?? pts
        let relative = CMTimeSubtract(pts, first)
        adaptor.append(pixelBuffer, withPresentationTime: relative)
    }
}
