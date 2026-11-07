import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
    private var pendingStrokes: [StrokeResult] = []
    private var sessionIconBag: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = editingMenu()
        Preferences.ensureScreenshotsFolder()
        HandAsset.preloadThumbnails(PointerStyle.allCases.compactMap(\.assetName))
        Log.write("launch \(Bundle.main.bundlePath) trusted=\(AXIsProcessTrusted())")
        CursorHider.enableBackgroundHiding()
        overlay.onActiveChanged = { [weak self] in
            self?.updateIcon()
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
        enableLaunchAtLoginOnFirstRun()
        updater.start()
        setupStatusItem()
        setupSettings()
        registerHotKeys()
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

        annotatePanel.onOpenChanged = { [weak self] open in
            self?.overlay.suspendInput(open)
            self?.overlay.setAnnotationHintsVisible(!open)
        }
        annotatePanel.onCancel = { [weak self] in
            // Keep drawings — Esc only closes the comment box.
            self?.overlay.setAnnotationHintsVisible(true)
        }
        annotatePanel.onSubmit = { [weak self] prompt in
            self?.submitAnnotation(prompt: prompt)
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
        overlay.onInkCleared = { [weak self] in
            self?.pendingStrokes = []
            self?.annotatePanel.hide()
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

        let pad: CGFloat = 8
        let union = strokes.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        let strokeScreen = CGRect(
            x: overlayFrame.origin.x + union.minX - pad,
            y: overlayFrame.origin.y + union.minY - pad,
            width: union.width + pad * 2,
            height: union.height + pad * 2
        )

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
                    self.overlay.releaseStrokeHold(stroke, fadeNow: true)
                }
                self.overlay.exit()
                if let session = self.sessionManager.startFromAnnotation(prompt: prompt, screenshotPath: outcome.path) {
                    self.sessionsPanel.openChat(for: session.id)
                }
            } catch {
                for stroke in strokes {
                    self.overlay.releaseStrokeHold(stroke, fadeNow: true)
                }
                self.overlay.exit()
                Log.write("capture failed: \(error.localizedDescription)")
                let needsScreenRecording = (error as? WindowCapture.CaptureError) == .permissionDenied
                    || error.localizedDescription.localizedCaseInsensitiveContains("Screen Recording")
                if needsScreenRecording {
                    _ = WindowCapture.ensureScreenRecordingAccess()
                }
                let alert = NSAlert()
                alert.messageText = "Couldn’t capture screenshot"
                alert.informativeText = needsScreenRecording
                    ? "Turn on TinyHand under Privacy & Security → Screen Recording, then draw again."
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
        menu.addItem(NSMenuItem(title: "Quit TinyHand", action: #selector(quit), keyEquivalent: "q"))
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
        sessionsItem?.title = "Tinyhand sessions    \(Preferences.sessionsShortcut.display)"
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

    /// Menu bar click / toggle shortcut: turn the pointer on/off and show Sessions when starting.
    private func togglePointerWithSessions() {
        if overlay.isActive {
            overlay.toggle()
            return
        }
        startPointerWithSessions()
    }

    private func startPointerWithSessions() {
        guard overlay.activate() else { return }
        sessionsPanel.show()
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
        sessionsPanel.toggle()
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
                       accessibilityDescription: "TinyHand")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.attributedTitle = sessionBadgeTitle()
        statusItem.button?.appearsDisabled = false

        var tip = overlay.isActive
            ? "TinyHand is on — click to turn off, right-click for the menu"
            : "TinyHand — click to turn on, right-click for the menu"
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
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit TinyHand", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
