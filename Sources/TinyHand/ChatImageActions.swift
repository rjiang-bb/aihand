import AppKit

/// Open / copy screenshot files attached to chat messages.
enum ChatImageActions {
    private static var retainedWindows: [NSWindow] = []
    private static var menuTarget: MenuTarget?

    static func open(path: String) {
        guard let image = NSImage(contentsOfFile: path),
              image.size.width > 0, image.size.height > 0 else { return }

        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 40, y: 40, width: 900, height: 700)
        // Cap the preview window at half the screen; scale the image to fit.
        let maxW = max(240, visible.width * 0.5)
        let maxH = max(180, visible.height * 0.5)
        let imgSize = image.size
        let scale = min(1, min(maxW / imgSize.width, maxH / imgSize.height))
        let displaySize = NSSize(width: max(1, imgSize.width * scale), height: max(1, imgSize.height * scale))

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: displaySize))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter

        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        scroll.documentView = imageView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: displaySize.width, height: displaySize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = (path as NSString).lastPathComponent
        window.contentView = scroll
        window.contentMinSize = NSSize(width: 200, height: 150)
        window.contentMaxSize = NSSize(width: maxW, height: maxH)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        retainedWindows.append(window)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { note in
            guard let closed = note.object as? NSWindow else { return }
            retainedWindows.removeAll { $0 === closed }
        }
    }

    static func copy(path: String) {
        guard let image = NSImage(contentsOfFile: path) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    /// Pop up Open / Copy Image at a point in `view`’s coordinates.
    static func showMenu(path: String, at pointInView: NSPoint, in view: NSView) {
        let target = MenuTarget(path: path)
        menuTarget = target

        let menu = NSMenu(title: "Image")
        let openItem = NSMenuItem(title: "Open", action: #selector(MenuTarget.open), keyEquivalent: "")
        openItem.target = target
        menu.addItem(openItem)
        let copyItem = NSMenuItem(title: "Copy Image", action: #selector(MenuTarget.copyImage), keyEquivalent: "")
        copyItem.target = target
        menu.addItem(copyItem)
        menu.popUp(positioning: nil, at: pointInView, in: view)
    }

    private final class MenuTarget: NSObject {
        let path: String
        init(path: String) { self.path = path }

        @objc func open() {
            ChatImageActions.open(path: path)
            ChatImageActions.menuTarget = nil
        }

        @objc func copyImage() {
            ChatImageActions.copy(path: path)
            ChatImageActions.menuTarget = nil
        }
    }
}
