import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = OverlayController()
    private let settings = SettingsWindow()
    private let updater = Updater()
    private let welcome = WelcomeWindow()
    private var permissionItem: NSMenuItem?
    private let menu = NSMenu()
    private var toggleItem: NSMenuItem?
    private var clearItem: NSMenuItem?
    private var soundItem: NSMenuItem?
    private var sessionsItem: NSMenuItem?
    private var toggleHotKey: UInt32?
    private var clearHotKey: UInt32?
    private var sessionsHotKey: UInt32?

    private let sessionStore = SessionStore()
    private lazy var sessionManager = AgentSessionManager(store: sessionStore)
    private lazy var sessionsPanel = SessionsSidePanel(store: sessionStore)
    private let annotatePanel = AnnotatePromptPanel()
    private let videoAnnotatePreview = VideoAnnotatePreview()
    private var pendingStrokes: [StrokeResult] = []
    /// Video waiting for an annotate comment (`⌘S` in video mode).
    private var pendingVideoPath: String?
    private var sessionIconBag: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = editingMenu()
        Preferences.applyTheme()
        Preferences.ensureScreenshotsFolder()
        HandAsset.preloadThumbnails(PointerStyle.allCases.compactMap(\.assetName))
        Log.write("launch \(Bundle.main.bundlePath) trusted=\(AXIsProcessTrusted())")
        CursorHider.enableBackgroundHiding()
        overlay.onActiveChanged = { [weak self] in
            guard let self else { return }
            self.updateIcon()
            // Drawing mode owns the screen — keep sessions/chat out of the way.
            if self.overlay.isActive {
                self.sessionsPanel.hide()
            }
        }
        overlay.onSoundChanged = { [weak self] in
            self?.refreshMenu()
        }
        overlay.extraPassThrough = { [weak self] in
            var frames: [CGRect] = []
            if let frame = self?.statusItem.button?.window?.frame {
                frames.append(frame)
            }
            if let panel = self, panel.annotatePanel.isVisible {
                // Annotate panel is key; input already suspended.
            }
            return frames
        }
        wireAgentFlow()
        Preferences.ensureAgentFavorites()
        enableLaunchAtLoginOnFirstRun()
        updater.start()
        setupStatusItem()
        setupSettings()
        registerHotKeys()
        setupSessionNotifications()
        ChatImageActions.setPreviewClosedHandler { [weak self] in
            self?.sessionsPanel.focus()
        }
        sessionIconBag = sessionStore.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // objectWillChange fires before the value updates — refresh after.
                DispatchQueue.main.async { self?.updateIcon() }
            }

        overlay.onNeedsPermission = { [weak self] in
            self?.welcome.show()
        }
        welcome.onTryIt = { [weak self] in
            self?.startPointerWithSessions()
        }
        if !UserDefaults.standard.bool(forKey: WelcomeWindow.shownKey) || !AXIsProcessTrusted() {
            welcome.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay.deactivate()
        sessionStore.saveNow()
    }

    private func wireAgentFlow() {
        sessionsPanel.onFollowUp = { [weak self] id, text, submit in
            self?.sessionManager.followUp(sessionID: id, text: text, submit: submit)
        }
        sessionsPanel.onStop = { [weak self] id in
            self?.sessionManager.stop(sessionID: id)
        }
        sessionsPanel.onNew = { [weak self] in
            self?.startBlankSession()
        }
        sessionsPanel.onManageWorkspaces = { [weak self] in
            self?.settings.show(.agent)
        }
        sessionManager.onSessionCompleted = { session in
            SessionNotifier.notifyCompleted(session: session)
        }

        annotatePanel.onOpenChanged = { [weak self] open in
            self?.overlay.suspendInput(open)
            self?.overlay.setAnnotationHintsVisible(!open)
        }
        annotatePanel.onCancel = { [weak self] in
            // Keep drawings — Esc only closes the comment box.
            // Discarding a video comment also deletes the just-saved recording.
            guard let self else { return }
            let videoPath = self.pendingVideoPath
            self.pendingVideoPath = nil
            self.videoAnnotatePreview.hide()
            if let videoPath {
                try? FileManager.default.removeItem(atPath: videoPath)
                Log.write("video discarded \(videoPath)")
            }
            self.overlay.setAnnotationHintsVisible(true)
        }
        annotatePanel.onSubmit = { [weak self] prompt in
            guard let self else { return }
            if self.pendingVideoPath != nil {
                self.submitPendingVideo(prompt: prompt)
            } else {
                self.submitAnnotation(prompt: prompt)
            }
        }

        overlay.onStrokeComplete = { [weak self] result, _, _ in
            guard let self else { return }
            self.pendingStrokes.append(result)
        }
        overlay.onRequestComment = { [weak self] in
            self?.openAnnotationComment()
        }
        overlay.onRequestSend = { [weak self] in
            guard let self, !self.annotatePanel.isVisible else { return }
            self.submitAnnotation(prompt: "")
        }
        overlay.onRequestSave = { [weak self] in
            guard let self, !self.annotatePanel.isVisible else { return }
            self.saveScreenshot()
        }
        overlay.onRequestVideoAnnotate = { [weak self] url, region in
            self?.openVideoComment(path: url.path, region: region)
        }
        overlay.onRequestVideoSave = { [weak self] url in
            self?.saveVideoPreview(url: url)
        }
        overlay.onRequestVideoSend = { [weak self] url in
            self?.sendVideo(path: url.path, prompt: "")
        }
        overlay.onVideoCaptureFailed = { [weak self] error in
            self?.presentCaptureFailure(error, kind: .video)
        }
        overlay.onInkCleared = { [weak self] in
            self?.pendingStrokes = []
            self?.annotatePanel.hide()
        }
        overlay.onStrokeUndone = { [weak self] layer in
            guard let self else { return }
            if let idx = self.pendingStrokes.lastIndex(where: { $0.layer === layer }) {
                self.pendingStrokes.remove(at: idx)
            }
            if self.pendingStrokes.isEmpty {
                self.annotatePanel.hide()
            }
        }
    }

    private func startBlankSession() {
        let workspace = Preferences.agentWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty else {
            settings.show(.agent)
            return
        }
        if !sessionsPanel.isVisible {
            sessionsPanel.show()
        }
        if let session = sessionManager.createBlankSession() {
            sessionsPanel.openChat(for: session.id)
        }
    }

    private func openAnnotationComment() {
        guard !annotatePanel.isVisible, !pendingStrokes.isEmpty else { return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main else { return }
        let missing = Preferences.agentWorkspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let near = inkScreenBounds() {
            annotatePanel.show(on: screen, placement: .near(near), workspaceMissing: missing, requirePrompt: false)
        } else {
            annotatePanel.show(on: screen, placement: .bottom, workspaceMissing: missing, requirePrompt: false)
        }
    }

    private func openVideoComment(path: String, region: CGRect) {
        pendingVideoPath = path
        overlay.exit()
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(region) })
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let screen else { return }
        let missing = Preferences.agentWorkspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if region.width > 8, region.height > 8 {
            videoAnnotatePreview.show(fileURL: URL(fileURLWithPath: path), region: region, on: screen)
            annotatePanel.show(
                on: screen,
                placement: .near(videoAnnotatePreview.frame),
                workspaceMissing: missing,
                requirePrompt: false
            )
        } else {
            videoAnnotatePreview.hide()
            annotatePanel.show(on: screen, placement: .bottom, workspaceMissing: missing, requirePrompt: false)
        }
    }

    private func submitPendingVideo(prompt: String) {
        guard let path = pendingVideoPath else { return }
        pendingVideoPath = nil
        videoAnnotatePreview.hide()
        sendVideo(path: path, prompt: prompt)
    }

    private func saveVideoPreview(url: URL) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        overlay.exit()
        let image = RegionRecorder.posterImage(for: url)
            ?? NSImage(systemSymbolName: "video", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 120, height: 80))
        if let screen {
            overlay.showSavePreview(fileURL: url, image: image, on: screen)
        }
        ScreenshotNotifier.notifySaved(path: url.path)
        Log.write("video saved \(url.path)")
    }

    private func sendVideo(path: String, prompt: String) {
        let workspace = Preferences.agentWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty else {
            pendingVideoPath = path
            videoAnnotatePreview.hide()
            overlay.exit()
            settings.show(.agent)
            return
        }
        annotatePanel.hide()
        videoAnnotatePreview.hide()
        overlay.exit()
        if let session = sessionManager.startFromAnnotation(prompt: prompt, screenshotPath: path) {
            sessionsPanel.openChat(for: session.id)
        }
    }

    private func inkScreenBounds() -> CGRect? {
        guard let overlayFrame = overlay.overlayFrame, !pendingStrokes.isEmpty else { return nil }
        let union = pendingStrokes.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull, !union.isInfinite else { return nil }
        return CGRect(
            x: overlayFrame.origin.x + union.minX,
            y: overlayFrame.origin.y + union.minY,
            width: union.width,
            height: union.height
        )
    }

    private func submitAnnotation(prompt: String) {
        let workspace = Preferences.agentWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty else {
            overlay.exit()
            settings.show(.agent)
            return
        }

        guard !pendingStrokes.isEmpty else { return }

        let strokes = pendingStrokes
        pendingStrokes = []

        guard let overlayFrame = overlay.overlayFrame else {
            overlay.exit()
            return
        }

        let strokeScreen = Self.strokeScreenBounds(strokes: strokes, overlayFrame: overlayFrame)

        // Keep stroke geometry; hide interactive UI so ScreenCaptureKit exclusion is clean.
        annotatePanel.hide()
        overlay.setAnnotationHintsVisible(false)
        for stroke in strokes {
            overlay.releaseStrokeHold(stroke, fadeNow: false)
        }

        Task { @MainActor in
            do {
                let outcome = try await WindowCapture.captureAnnotated(
                    strokes: strokes,
                    strokeScreenBounds: strokeScreen,
                    overlayFrame: overlayFrame
                )
                for stroke in strokes {
                    self.overlay.releaseStrokeHold(stroke, fadeNow: false)
                }
                self.overlay.exit()
                if let session = self.sessionManager.startFromAnnotation(prompt: prompt, screenshotPath: outcome.path) {
                    self.sessionsPanel.openChat(for: session.id)
                }
            } catch {
                for stroke in strokes {
                    self.overlay.releaseStrokeHold(stroke, fadeNow: false)
                }
                self.overlay.exit()
                self.presentCaptureFailure(error, kind: .screenshot)
            }
        }
    }

    /// ⌘⇧S — write an annotated capture to the screenshots folder without starting an agent.
    private func saveScreenshot() {
        guard overlay.isActive, let overlayFrame = overlay.overlayFrame else { return }
        let screen = overlay.activeScreen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(overlayFrame) })
            ?? NSScreen.main
        guard let screen else { return }

        let strokes = pendingStrokes
        let strokeScreen = strokes.isEmpty
            ? WindowCapture.captureRegion(on: screen)
            : Self.strokeScreenBounds(strokes: strokes, overlayFrame: overlayFrame)

        annotatePanel.hide()
        overlay.setAnnotationHintsVisible(false)
        for stroke in strokes {
            overlay.releaseStrokeHold(stroke, fadeNow: false)
        }

        Task { @MainActor in
            do {
                let outcome = try await WindowCapture.captureAnnotated(
                    strokes: strokes,
                    strokeScreenBounds: strokeScreen,
                    overlayFrame: overlayFrame
                )
                let url = URL(fileURLWithPath: outcome.path)
                let image = NSImage(contentsOf: url)
                self.pendingStrokes = []
                self.overlay.clearInk()
                self.overlay.exit()
                if let image {
                    self.overlay.showSavePreview(fileURL: url, image: image, on: screen)
                }
                ScreenshotNotifier.notifySaved(path: outcome.path)
                Log.write("screenshot saved \(outcome.path)")
            } catch {
                for stroke in strokes {
                    self.overlay.releaseStrokeHold(stroke, fadeNow: false)
                }
                if self.overlay.isActive {
                    self.overlay.setAnnotationHintsVisible(true)
                }
                self.presentCaptureFailure(error, kind: .screenshot)
            }
        }
    }

    private static func strokeScreenBounds(strokes: [StrokeResult], overlayFrame: CGRect) -> CGRect {
        let pad: CGFloat = 8
        let union = strokes.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        return CGRect(
            x: overlayFrame.origin.x + union.minX - pad,
            y: overlayFrame.origin.y + union.minY - pad,
            width: union.width + pad * 2,
            height: union.height + pad * 2
        )
    }

    private enum CaptureKind {
        case screenshot
        case video
    }

    private func presentCaptureFailure(_ error: Error, kind: CaptureKind) {
        Log.write("capture failed: \(error.localizedDescription)")
        let needsScreenRecording = (error as? WindowCapture.CaptureError) == .permissionDenied
            || (error as? RegionRecorder.RecorderError) == .permissionDenied
            || error.localizedDescription.localizedCaseInsensitiveContains("Screen Recording")
        if needsScreenRecording {
            _ = WindowCapture.ensureScreenRecordingAccess()
        }
        let alert = NSAlert()
        alert.messageText = kind == .video ? "Couldn’t record video" : "Couldn’t capture screenshot"
        alert.informativeText = needsScreenRecording
            ? "Turn on AiHand under Privacy & Security → Screen Recording, then try again."
            : error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if needsScreenRecording {
            alert.addButton(withTitle: "Open Settings")
        }
        let response = alert.runModal()
        if needsScreenRecording, response == .alertSecondButtonReturn {
            WindowCapture.openScreenRecordingSettings()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let permission = NSMenuItem(title: "Allow Accessibility…", action: #selector(showWelcome), keyEquivalent: "")
        permissionItem = permission
        menu.addItem(permission)
        let toggle = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")
        let clear = NSMenuItem(title: "", action: #selector(clearInk), keyEquivalent: "")
        let sound = NSMenuItem(title: "Tap Sound", action: #selector(toggleSound), keyEquivalent: "")
        let sessions = NSMenuItem(title: "Agent Sessions", action: #selector(showSessions), keyEquivalent: "")
        toggleItem = toggle
        clearItem = clear
        soundItem = sound
        sessionsItem = sessions
        menu.addItem(toggle)
        menu.addItem(clear)
        menu.addItem(sound)
        menu.addItem(sessions)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        if Updater.isAvailable {
            menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit AiHand", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        menu.delegate = self
    }

    private func setupSettings() {
        settings.applyToggleShortcut = { [weak self] s in
            self?.apply(s, kind: .toggle) ?? false
        }
        settings.applyClearShortcut = { [weak self] s in
            self?.apply(s, kind: .clear) ?? false
        }
        settings.applySessionsShortcut = { [weak self] s in
            self?.apply(s, kind: .sessions) ?? false
        }
        settings.updater = Updater.isAvailable ? updater : nil
        settings.onRecording = { [weak self] recording in
            if recording {
                self?.unregisterHotKeys()
            } else {
                self?.registerHotKeys()
            }
        }
    }

    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        guard wantsMenu else {
            togglePointerWithSessions()
            return
        }
        refreshMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        overlay.suspendInput(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        overlay.suspendInput(false)
    }

    private func refreshMenu() {
        let on = overlay.isActive
        toggleItem?.title = "\(on ? "Turn Pointer Off" : "Turn Pointer On")    \(Preferences.toggleShortcut.display)"
        clearItem?.title = "Clear Drawing    \(Preferences.clearShortcut.display)"
        sessionsItem?.title = "AI sessions panel    \(Preferences.sessionsShortcut.display)"
        soundItem?.state = overlay.soundOn ? .on : .off
        permissionItem?.isHidden = AXIsProcessTrusted()
    }

    private enum HotKeyKind {
        case toggle, clear, sessions
    }

    private func apply(_ s: Shortcut, kind: HotKeyKind) -> Bool {
        unregisterHotKeys()
        let old: Shortcut
        switch kind {
        case .toggle:
            old = Preferences.toggleShortcut
            Preferences.toggleShortcut = s
        case .clear:
            old = Preferences.clearShortcut
            Preferences.clearShortcut = s
        case .sessions:
            old = Preferences.sessionsShortcut
            Preferences.sessionsShortcut = s
        }
        let ok = registerHotKeys()
        if ok {
            return true
        }
        unregisterHotKeys()
        switch kind {
        case .toggle: Preferences.toggleShortcut = old
        case .clear: Preferences.clearShortcut = old
        case .sessions: Preferences.sessionsShortcut = old
        }
        registerHotKeys()
        return false
    }

    @discardableResult
    private func registerHotKeys() -> Bool {
        guard toggleHotKey == nil, clearHotKey == nil, sessionsHotKey == nil else {
            return true
        }
        let t = Preferences.toggleShortcut
        let c = Preferences.clearShortcut
        let s = Preferences.sessionsShortcut
        toggleHotKey = HotKeyCenter.shared.register(keyCode: t.keyCode, modifiers: t.modifiers) { [weak self] in
            self?.togglePointerWithSessions()
        }
        clearHotKey = HotKeyCenter.shared.register(keyCode: c.keyCode, modifiers: c.modifiers) { [weak self] in
            self?.overlay.clearInk()
        }
        sessionsHotKey = HotKeyCenter.shared.register(keyCode: s.keyCode, modifiers: s.modifiers) { [weak self] in
            self?.showSessions()
        }
        return toggleHotKey != nil && clearHotKey != nil && sessionsHotKey != nil
    }

    private func unregisterHotKeys() {
        if let id = toggleHotKey {
            HotKeyCenter.shared.unregister(id)
        }
        if let id = clearHotKey {
            HotKeyCenter.shared.unregister(id)
        }
        if let id = sessionsHotKey {
            HotKeyCenter.shared.unregister(id)
        }
        toggleHotKey = nil
        clearHotKey = nil
        sessionsHotKey = nil
    }

    /// Menu bar click / toggle shortcut: turn the pointer (drawing mode) on/off.
    private func togglePointerWithSessions() {
        if overlay.isActive {
            overlay.toggle()
            return
        }
        startPointerWithSessions()
    }

    private func startPointerWithSessions() {
        // onActiveChanged hides sessions once the overlay is actually active.
        _ = overlay.activate()
    }

    @objc private func toggle() {
        togglePointerWithSessions()
    }

    @objc private func clearInk() {
        overlay.clearInk()
    }

    @objc private func toggleSound() {
        overlay.soundOn.toggle()
    }

    @objc private func showSessions() {
        // Sessions/chat stay hidden while drawing.
        guard !overlay.isActive else { return }
        sessionsPanel.toggle()
    }

    private func setupSessionNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        SessionNotifier.requestAuthorization()
    }

    /// Bring the sessions panel forward with this chat (e.g. from a notification click).
    private func revealSession(_ id: UUID) {
        guard let session = sessionStore.session(id: id) else { return }
        // Leave drawing mode before showing chat.
        if overlay.isActive {
            overlay.exit()
        }
        let path = session.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty, !SessionStore.sameWorkspace(path, Preferences.agentWorkspace) {
            Preferences.agentWorkspace = path
        }
        sessionsPanel.openChat(for: id)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let id = SessionNotifier.sessionID(from: response) {
            DispatchQueue.main.async { [weak self] in
                self?.revealSession(id)
            }
        } else if let path = ScreenshotNotifier.path(from: response) {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
        completionHandler()
    }

    @objc private func openSettings() {
        pendingStrokes = []
        annotatePanel.hide()
        overlay.exit()
        settings.show()
    }

    @objc private func showWelcome() {
        overlay.exit()
        welcome.show()
    }

    @objc private func checkForUpdates() {
        overlay.exit()
        updater.checkForUpdates()
    }

    @objc private func quit() {
        overlay.deactivate()
        NSApp.terminate(nil)
    }

    private func enableLaunchAtLoginOnFirstRun() {
        let key = "loginItemSetUp"
        let path = Bundle.main.bundlePath
        let installed = path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        guard installed, !UserDefaults.standard.bool(forKey: key) else {
            return
        }
        UserDefaults.standard.set(true, forKey: key)
        Preferences.launchAtLogin = true
        Log.write("first run: open at login = \(Preferences.launchAtLogin)")
    }

    private func updateIcon() {
        let on = overlay.isActive
        let image = Bundle.main.image(forResource: on ? "menubar_on" : "menubar_off")
            ?? NSImage(systemSymbolName: on ? "hand.point.up.left.fill" : "hand.point.up.left",
                       accessibilityDescription: "AiHand")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.attributedTitle = sessionBadgeTitle()
        statusItem.button?.appearsDisabled = false

        var tip = overlay.isActive
            ? "AiHand is on — click to turn off, right-click for the menu"
            : "AiHand — click to turn on, right-click for the menu"
        let active = sessionStore.activeCount
        let completed = sessionStore.completedCount
        if active > 0 || completed > 0 {
            var parts: [String] = []
            if active > 0 { parts.append("\(active) active") }
            if completed > 0 { parts.append("\(completed) completed") }
            tip += "\n" + parts.joined(separator: " · ")
        }
        statusItem.button?.toolTip = tip
    }

    private func sessionBadgeTitle() -> NSAttributedString {
        let active = sessionStore.activeCount
        let completed = sessionStore.completedCount
        guard active > 0 || completed > 0 else {
            return NSAttributedString()
        }

        let title = NSMutableAttributedString(string: " ")
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let baseline = (font.capHeight - 6) / 2

        func appendDot(_ color: NSColor, count: Int) {
            guard count > 0 else { return }
            if title.length > 1 {
                title.append(NSAttributedString(string: " ", attributes: [
                    .font: font,
                    .foregroundColor: NSColor.secondaryLabelColor
                ]))
            }
            let attachment = NSTextAttachment()
            attachment.image = Self.menuBarDot(color: color, diameter: 6)
            attachment.bounds = CGRect(x: 0, y: baseline, width: 6, height: 6)
            title.append(NSAttributedString(attachment: attachment))
            title.append(NSAttributedString(string: "\(count)", attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .baselineOffset: 0
            ]))
        }

        appendDot(NSColor.systemBlue, count: active)
        appendDot(NSColor.systemGreen, count: completed)
        return title
    }

    private static func menuBarDot(color: NSColor, diameter: CGFloat) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.25, dy: 0.25)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func editingMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        // ⌘W archives the selected AI session when that panel is key (see SessionsSidePanel).
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "")
        let archiveSession = appMenu.addItem(
            withTitle: "Archive Session",
            action: #selector(archiveSelectedSession),
            keyEquivalent: "w"
        )
        archiveSession.keyEquivalentModifierMask = [.command]
        appMenu.addItem(.separator())
        // ⌘, must live on the main menu — status-item key equivalents only fire while that menu is open.
        let settingsItem = appMenu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit AiHand", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        // Menu key equivalent is the reliable path for ⌘/ (local monitors miss it with ⌘ held).
        let cycle = edit.addItem(
            withTitle: "Cycle Agent Model",
            action: #selector(cycleAgentModel),
            keyEquivalent: "/"
        )
        cycle.keyEquivalentModifierMask = [.command]
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    @objc private func cycleAgentModel() {
        if annotatePanel.isVisible {
            annotatePanel.cycleFavorite()
            return
        }
        guard sessionsPanel.isVisible,
              let id = sessionsPanel.selectedSessionID,
              let session = sessionStore.session(id: id) else { return }
        session.cycleFavorite()
    }

    @objc private func archiveSelectedSession() {
        // ⌘W closes a focused chat image preview instead of archiving the session.
        if ChatImageActions.closeKeyPreviewIfNeeded() { return }
        sessionsPanel.archiveSelectedSession()
    }
}
