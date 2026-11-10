import AppKit

/// A pending file attached to the chat composer (media thumb or inline file chip).
struct ComposerAttachment: Identifiable, Equatable {
    let id: UUID
    let path: String
    /// When true, removing/clearing deletes the file (paste-imported media temps).
    let ownsFile: Bool
    /// Folder chip (from `@` directory picks); otherwise treated as a file.
    let isDirectory: Bool

    init(id: UUID = UUID(), path: String, ownsFile: Bool, isDirectory: Bool = false) {
        self.id = id
        self.path = path
        self.ownsFile = ownsFile
        self.isDirectory = isDirectory
    }

    var fileName: String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    var isVideo: Bool {
        switch (path as NSString).pathExtension.lowercased() {
        case "mov", "mp4", "m4v", "webm": return true
        default: return false
        }
    }

    var isImage: Bool {
        switch (path as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "heic": return true
        default: return false
        }
    }

    var isMedia: Bool { isImage || isVideo }
}

enum ComposerMediaImport {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "heic"
    ]
    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "webm"
    ]

    static func isSupportedMedia(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    /// Import files / images from the general pasteboard.
    /// Returns `nil` when there's nothing to attach (caller falls through to text paste).
    static func attachmentsFromPasteboard(_ pasteboard: NSPasteboard = .general) -> [ComposerAttachment]? {
        // Prefer real file URLs when they import; don't let a stale/promised URL
        // short-circuit bitmap paste (⌃⌘⇧4 and many “Copy Image” boards ship both).
        if let urls = fileURLs(from: pasteboard), !urls.isEmpty {
            let imported = urls.compactMap { importURL($0) }
            if !imported.isEmpty { return imported }
        }

        if let path = writeImage(from: pasteboard) {
            return [ComposerAttachment(path: path, ownsFile: true)]
        }

        return nil
    }

    /// Import dropped / listed file URLs (any file; media gets durable copies).
    static func attachments(fromFileURLs urls: [URL]) -> [ComposerAttachment] {
        urls.compactMap { importURL($0) }
    }

    /// Sync check against the active drag pasteboard (Finder / app drag).
    static func dragHasFiles() -> Bool {
        !(fileURLs(from: NSPasteboard(name: .drag)) ?? []).isEmpty
            || nsImage(from: NSPasteboard(name: .drag)) != nil
    }

    /// Import from the drag pasteboard — more reliable than NSItemProvider URL loading on macOS.
    static func attachmentsFromDragPasteboard() -> [ComposerAttachment] {
        let pb = NSPasteboard(name: .drag)
        if let urls = fileURLs(from: pb), !urls.isEmpty {
            let imported = attachments(fromFileURLs: urls)
            if !imported.isEmpty { return imported }
        }
        if let path = writeImage(from: pb) {
            return [ComposerAttachment(path: path, ownsFile: true)]
        }
        return []
    }

    static func discard(_ attachments: [ComposerAttachment]) {
        let fm = FileManager.default
        for item in attachments where item.ownsFile {
            try? fm.removeItem(atPath: item.path)
        }
    }

    // MARK: - Private

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL]
    }

    private static func importURL(_ url: URL) -> ComposerAttachment? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return nil
        }
        // Folders aren't attachable as a single prompt file.
        if isDir.boolValue { return nil }

        if isSupportedMedia(path: url.path) {
            return importMediaFile(from: url)
        }
        // Non-media: keep the original path so the agent can open the real file.
        return ComposerAttachment(path: url.path, ownsFile: false)
    }

    private static func importMediaFile(from url: URL) -> ComposerAttachment? {
        let folder = Preferences.ensureScreenshotsFolder()
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let dest = uniqueDestination(in: folder, ext: ext)
        do {
            if url.path == dest {
                return ComposerAttachment(path: dest, ownsFile: false)
            }
            // Prefer copy so Finder originals stay put.
            try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: dest))
            return ComposerAttachment(path: dest, ownsFile: true)
        } catch {
            Log.write("composer media import failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Persist pasteboard image bytes (prefer raw PNG/JPEG/HEIC; TIFF last because AppKit
    /// often synthesizes it from other flavors and we'd save the wrong container).
    private static func writeImage(from pasteboard: NSPasteboard) -> String? {
        let rawTypes: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "png"),
            (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
            (NSPasteboard.PasteboardType("public.heic"), "heic"),
            (.tiff, "tiff"),
        ]
        // Stick to types the board declared — `data(forType:)` can otherwise invent flavors.
        let declared = Set(pasteboard.types ?? [])
        for (type, ext) in rawTypes where declared.contains(type) {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                if let path = writeData(data, ext: ext) { return path }
            }
        }
        if let image = nsImage(from: pasteboard), let path = writePNG(image) {
            return path
        }
        return nil
    }

    private static func nsImage(from pasteboard: NSPasteboard) -> NSImage? {
        if let image = NSImage(pasteboard: pasteboard),
           image.size.width > 0, image.size.height > 0 {
            return image
        }
        for type in [
            NSPasteboard.PasteboardType.png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
        ] {
            if let data = pasteboard.data(forType: type),
               let image = NSImage(data: data),
               image.size.width > 0 {
                return image
            }
        }
        return nil
    }

    private static func writePNG(_ image: NSImage) -> String? {
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return writeData(png, ext: "png")
        }
        // Some pasteboard images have no TIFF rep but still expose a CGImage.
        var rect = CGRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            let rep = NSBitmapImageRep(cgImage: cg)
            if let png = rep.representation(using: .png, properties: [:]) {
                return writeData(png, ext: "png")
            }
        }
        Log.write("composer paste png encode failed (\(Int(image.size.width))×\(Int(image.size.height)))")
        return nil
    }

    private static func writeData(_ data: Data, ext: String) -> String? {
        let folder = Preferences.ensureScreenshotsFolder()
        let path = uniqueDestination(in: folder, ext: ext)
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return path
        } catch {
            Log.write("composer paste \(ext) write failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func uniqueDestination(in folder: String, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = formatter.string(from: Date())
        var name = "\(stamp)-paste.\(ext)"
        var path = (folder as NSString).appendingPathComponent(name)
        var n = 1
        while FileManager.default.fileExists(atPath: path) {
            name = "\(stamp)-paste-\(n).\(ext)"
            path = (folder as NSString).appendingPathComponent(name)
            n += 1
        }
        return path
    }
}
