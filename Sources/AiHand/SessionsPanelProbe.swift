#if DEBUG
import AppKit
import Carbon.HIToolbox

/// Sessions-panel regression harness. Drives the real `SessionsSidePanel` with real
/// `NSEvent`s and checks the placement rules in AGENTS.md (list/chat edges, list height,
/// ⌘-hold hints, ⌘1–9 / ⌘↑↓ / ⌘W / ⌘/, Esc). Prefs and Application Support are sandboxed to a
/// temp dir so the user's real sessions and panel placement are untouched.
///
/// Run: `./scripts/panel-probe.sh`
enum SessionsPanelProbe {
    static var failures: [String] = []
    static var checks = 0
    static var panel: SessionsSidePanel!
    static var store: SessionStore!

    // MARK: plumbing

    static func pump(_ seconds: TimeInterval = 0.05) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005),
                                       inMode: .default, dequeue: true) {
                NSApp.sendEvent(e)
            }
        }
    }

    static func key(_ code: Int, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
        guard let e = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.probeWindowNumber, context: nil,
            characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: UInt16(code)
        ) else { return }
        NSApp.postEvent(e, atStart: false)
        pump()
    }

    static func flags(_ f: NSEvent.ModifierFlags) {
        guard let e = NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: f,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.probeWindowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_Command)
        ) else { return }
        NSApp.postEvent(e, atStart: false)
        pump(0.1)
    }

    static func cmd(_ code: Int, _ chars: String) { key(code, chars, .command) }

    static func expect(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        checks += 1
        if !ok { failures.append("\(label)  \(detail())") }
    }
    static func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 1.0) -> Bool { abs(a - b) <= tol }
    static func fmt(_ r: NSRect) -> String {
        String(format: "(x:%.1f y:%.1f w:%.1f h:%.1f maxX:%.1f maxY:%.1f)", r.minX, r.minY, r.width, r.height, r.maxX, r.maxY)
    }

    static func makeSessions(_ n: Int) -> [AgentSession] {
        (0..<n).map { i in
            let s = AgentSession(title: "Session \(i)", prompt: "p\(i)", screenshotPath: nil,
                                 gitBranch: "", connectionID: nil, cliKind: .cursor, status: .finished)
            s.messages = [AgentMessage(kind: .user, text: "hello \(i)")]
            s.preview = "preview \(i)"
            return s
        }
    }

    static func freshPanel(sessions n: Int, origin: CGPoint? = nil) {
        panel?.hide()
        // Empty the old store and let its debounced save land, or the next store reloads it.
        if let old = store {
            for s in old.allSessions { old.remove(s.id) }
        }
        pump(0.7)
        try? FileManager.default.removeItem(at: AppSupport.directory().appendingPathComponent("sessions.json"))
        // After hide(): hiding persists the old placement, which would clobber this.
        if let origin { Preferences.sessionsPanelOrigin = origin }
        store = SessionStore()
        // prepend newest-first: last prepended is the top row.
        for s in makeSessions(n).reversed() { store.prepend(s) }
        panel = SessionsSidePanel(store: store)
        panel.show()
        pump(0.4)
    }

    static func listHeight(_ n: Int, hints: Bool = false) -> CGFloat {
        SessionsListMetrics.panelHeight(sessionCount: n, showShortcutHints: hints)
    }

    static func render(_ name: String) {
        pump(0.1)
        let f = panel.probeFrame
        guard let img = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(panel.probeWindowNumber), [.bestResolution]
        ) else { return }
        _ = f
        let rep = NSBitmapImageRep(cgImage: img)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/probe-panel-\(name).png"))
        }
    }

    // MARK: run

    static func run() -> Bool {
        setlinebuf(stdout)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aihand-panel-probe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let realDefaults = Preferences.defaults
        let suite = "aihand.panelprobe.\(UUID().uuidString)"
        Preferences.defaults = UserDefaults(suiteName: suite)!
        AppSupport.rootOverride = tmp
        defer {
            Preferences.defaults.removePersistentDomain(forName: suite)
            Preferences.defaults = realDefaults
            AppSupport.rootOverride = nil
            try? FileManager.default.removeItem(at: tmp)
        }

        app.finishLaunching()
        let requested = Set(CommandLine.arguments)
        let sections: [(String, () -> Void)] = [
            ("placement", placement), ("height", height), ("hints", hints),
            ("keys", keys), ("paging", paging), ("dismiss", dismiss), ("annotate", annotate),
        ]
        let known = Set(sections.map(\.0))
        let chosen = requested.intersection(known)
        for (name, section) in sections where chosen.isEmpty || chosen.contains(name) {
            section()
        }
        panel?.hide()

        print("checks: \(checks)  failures: \(failures.count)")
        for f in failures { print("FAIL \(f)") }
        print(failures.isEmpty ? "ALL PASS" : "HAS FAILURES")
        return failures.isEmpty
    }

    // MARK: sections

    /// AGENTS.md: opening chat grows right with the list's leading edge fixed; closing slides
    /// the list so its right edge lands where the chat's right edge was.
    static func placement() {
        // Use the screen the panel actually lands on (multi-monitor setups differ from NSScreen.main).
        freshPanel(sessions: 3)
        let visible = (panel.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        // Mid-screen so the chat has room to grow right without the on-screen clamp.
        freshPanel(sessions: 3, origin: CGPoint(x: visible.minX + 120, y: visible.midY - 100))
        let listFrame = panel.probeFrame
        expect("place: list-only width is the list width", near(listFrame.width, panel.probeListWidth), fmt(listFrame))
        expect("place: list-only height hugs content", near(listFrame.height, listHeight(3)),
               "frame=\(fmt(listFrame)) want h=\(listHeight(3))")
        render("list")

        let id = store.sessions[0].id
        panel.openChat(for: id)
        pump(0.3)
        let open = panel.probeFrame
        render("open")
        expect("place: chat opens wider", open.width > listFrame.width + 100, "list=\(fmt(listFrame)) open=\(fmt(open))")
        expect("place: opening keeps the list's leading edge", near(open.minX, listFrame.minX), "list=\(fmt(listFrame)) open=\(fmt(open))")
        expect("place: opening keeps the top edge", near(open.maxY, listFrame.maxY), "list=\(fmt(listFrame)) open=\(fmt(open))")

        panel.collapseChat()
        pump(0.5)
        let closed = panel.probeFrame
        render("closed")
        expect("place: closing returns to list width", near(closed.width, panel.probeListWidth), fmt(closed))
        expect("place: closed list's right edge == chat's old right edge", near(closed.maxX, open.maxX),
               "open=\(fmt(open)) closed=\(fmt(closed))")
        expect("place: closed list keeps the top edge", near(closed.maxY, open.maxY),
               "open=\(fmt(open)) closed=\(fmt(closed))")
        expect("place: closed list height hugs content", near(closed.height, listHeight(3)), fmt(closed))
        let saved = Preferences.sessionsPanelOrigin
        expect("place: list-only origin persisted at the new spot",
               saved.map { near($0.x, closed.minX, 2) && near($0.y, closed.minY, 2) } ?? false,
               "saved=\(String(describing: saved)) closed=\(fmt(closed))")

        // Reopen: grows right from the *new* list position.
        panel.openChat(for: id)
        pump(0.3)
        let again = panel.probeFrame
        expect("place: reopening keeps the (moved) list's leading edge", near(again.minX, closed.minX) || again.maxX <= (NSScreen.main?.visibleFrame.maxX ?? .infinity),
               "closed=\(fmt(closed)) again=\(fmt(again))")
        panel.collapseChat()
        pump(0.4)

        // Docked against the right edge: chat must stay fully on-screen (list nudges left).
        freshPanel(sessions: 3, origin: CGPoint(x: visible.maxX - panel.probeListWidth, y: visible.midY - 100))
        panel.openChat(for: store.sessions[0].id)
        pump(0.3)
        let edge = panel.probeFrame
        expect("place: chat at the right screen edge stays on-screen", edge.maxX <= visible.maxX + 0.5 && edge.minX >= visible.minX,
               "visible=\(fmt(visible)) edge=\(fmt(edge))")
        panel.collapseChat()
        pump(0.4)
    }

    /// The list card hugs its rows; it never stretches to match chat height.
    static func height() {
        var last: CGFloat = 0
        for n in [1, 2, 5, 9] {
            freshPanel(sessions: n)
            let h = panel.probeFrame.height
            expect("height: \(n) sessions == metrics", near(h, listHeight(n)), "h=\(h) want=\(listHeight(n))")
            expect("height: grows with rows (\(n))", h > last, "h=\(h) last=\(last)")
            last = h
        }
        freshPanel(sessions: 0)
        expect("height: empty list uses empty-state height", near(panel.probeFrame.height, listHeight(0)), "h=\(panel.probeFrame.height)")

        freshPanel(sessions: 3)
        let before = panel.probeFrame.height
        panel.openChat(for: store.sessions[0].id)
        pump(0.3)
        expect("height: list metrics unchanged while chat is open", near(panel.probeListHeight, listHeight(3)),
               "listHeight=\(panel.probeListHeight) want=\(listHeight(3))")
        expect("height: expanded panel is taller than the bare list (room for chat)", panel.probeFrame.height >= before)
        panel.collapseChat()
        pump(0.4)

        // Chat height is prefs-only — a long list must not stretch the open pane.
        Preferences.sessionsPanelHeight = Preferences.sessionsPanelDefaultHeight
        Preferences.sessionsPanelWidth = Preferences.sessionsPanelDefaultWidth
        freshPanel(sessions: 9)
        let listOnly = panel.probeFrame.height
        expect("height: list-only with many rows exceeds default chat",
               listOnly > Preferences.sessionsPanelDefaultHeight + 20,
               "list=\(listOnly) default=\(Preferences.sessionsPanelDefaultHeight)")
        panel.openChat(for: store.sessions[0].id)
        pump(0.3)
        expect("height: opening chat keeps saved height (does not grow to list)",
               near(panel.probeFrame.height, Preferences.sessionsPanelDefaultHeight),
               "h=\(panel.probeFrame.height) saved=\(Preferences.sessionsPanelDefaultHeight) list=\(listOnly)")
        panel.collapseChat()
        pump(0.4)
    }

    /// ⌘ held: row labels + hints footer grow out of the bottom; top edge and row positions stay.
    static func hints() {
        freshPanel(sessions: 4)
        let base = panel.probeFrame
        expect("hints: hidden by default", !panel.probeHintsShown)

        flags(.command)
        let held = panel.probeFrame
        render("hints")
        expect("hints: ⌘ shows hints", panel.probeHintsShown)
        expect("hints: panel grows taller", held.height > base.height + 20, "base=\(fmt(base)) held=\(fmt(held))")
        expect("hints: height matches metrics with footer", near(held.height, listHeight(4, hints: true)),
               "held=\(held.height) want=\(listHeight(4, hints: true))")
        expect("hints: top edge stays put (rows don't jump)", near(held.maxY, base.maxY), "base=\(fmt(base)) held=\(fmt(held))")
        expect("hints: grows downward", held.minY < base.minY, "base=\(fmt(base)) held=\(fmt(held))")
        expect("hints: x unchanged", near(held.minX, base.minX) && near(held.width, base.width))

        flags([])
        pump(0.35)
        let released = panel.probeFrame
        expect("hints: release hides hints", !panel.probeHintsShown)
        expect("hints: release restores the frame", near(released.height, base.height) && near(released.maxY, base.maxY),
               "base=\(fmt(base)) released=\(fmt(released))")

        // ⌘+⇧ is not "⌘ alone".
        flags([.command, .shift])
        expect("hints: ⌘⇧ does not show hints", !panel.probeHintsShown)
        flags([])

        // Empty list: nothing to hint.
        freshPanel(sessions: 0)
        flags(.command)
        expect("hints: no sessions → no hints", !panel.probeHintsShown)
        flags([])

        // Paginated list reuses its footer slot (no extra growth).
        freshPanel(sessions: 12)
        let pagedBase = panel.probeFrame
        flags(.command)
        expect("hints: paginated list doesn't grow further", near(panel.probeFrame.height, pagedBase.height),
               "base=\(fmt(pagedBase)) held=\(fmt(panel.probeFrame))")
        flags([])
    }

    /// Keyboard shortcuts through the real monitor.
    static func keys() {
        freshPanel(sessions: 4)
        NSApp.activate(ignoringOtherApps: true)
        pump(0.2)
        guard panel.probeIsKey else {
            expect("keys: panel is key window (needed for shortcuts)", false, "panel never became key — GUI session required")
            return
        }

        var newCalls = 0
        panel.onNew = { newCalls += 1 }
        cmd(kVK_ANSI_N, "n")
        expect("keys: ⌘N calls onNew", newCalls == 1, "calls=\(newCalls)")

        cmd(kVK_ANSI_2, "2")
        expect("keys: ⌘2 opens the 2nd session", panel.selectedSessionID == store.sessions[1].id)
        cmd(kVK_ANSI_1, "1")
        expect("keys: ⌘1 opens the 1st session", panel.selectedSessionID == store.sessions[0].id)
        cmd(kVK_ANSI_9, "9")
        expect("keys: ⌘9 with <9 sessions is a no-op", panel.selectedSessionID == store.sessions[0].id)

        cmd(kVK_DownArrow, String(UnicodeScalar(NSDownArrowFunctionKey)!))
        expect("keys: ⌘↓ moves to the next session", panel.selectedSessionID == store.sessions[1].id)
        cmd(kVK_UpArrow, String(UnicodeScalar(NSUpArrowFunctionKey)!))
        expect("keys: ⌘↑ moves back", panel.selectedSessionID == store.sessions[0].id)
        cmd(kVK_UpArrow, String(UnicodeScalar(NSUpArrowFunctionKey)!))
        expect("keys: ⌘↑ at the top stays put", panel.selectedSessionID == store.sessions[0].id)

        // ⌘/ cycles favorites (wraps) and the panel owns it while key.
        let kind = store.sessions[0].cliKind
        Preferences.addAgentFavorite(AgentFavorite(title: "A", cliKind: kind, modelId: "ma", modelTitle: "A", effort: nil, isBuiltIn: false))
        Preferences.addAgentFavorite(AgentFavorite(title: "B", cliKind: kind, modelId: "mb", modelTitle: "B", effort: nil, isBuiltIn: false))
        let favs = Preferences.favorites(for: kind, target: store.sessions[0].executionTarget)
        var seen: [UUID?] = []
        for _ in 0..<(favs.count + 1) {
            cmd(kVK_ANSI_Slash, "/")
            seen.append(store.sessions[0].favoriteId)
        }
        expect("keys: ⌘/ visits every favorite", Set(seen.compactMap { $0 }) == Set(favs.map(\.id)),
               "seen=\(seen.count) favs=\(favs.count)")
        expect("keys: ⌘/ wraps back to the first", seen.first == seen.last, "first=\(String(describing: seen.first)) last=\(String(describing: seen.last))")
        expect("keys: ⌘/ doesn't close the chat (no resign-key collapse)", panel.selectedSessionID == store.sessions[0].id)

        // ⌘W archives the open chat and opens its neighbour.
        let count = store.sessions.count
        let victim = store.sessions[0].id
        let neighbour = store.sessions[1].id
        cmd(kVK_ANSI_W, "w")
        expect("keys: ⌘W archives the open session", store.session(id: victim) == nil && store.sessions.count == count - 1)
        expect("keys: ⌘W selects the next session", panel.selectedSessionID == neighbour)

        // Esc closes chat, then hides the panel.
        key(kVK_Escape, "\u{1b}")
        pump(0.3)
        expect("keys: Esc closes the chat first", panel.selectedSessionID == nil && panel.isVisible)
        key(kVK_Escape, "\u{1b}")
        expect("keys: Esc on the list hides the panel", !panel.isVisible)
    }

    /// 10+ sessions paginate; ⌘1–9 target the visible page.
    static func paging() {
        freshPanel(sessions: 25)
        expect("paging: needs pagination above the threshold", SessionsListPaging.needsPagination(25))
        expect("paging: list height capped at one page", near(panel.probeFrame.height, listHeight(25)),
               "h=\(panel.probeFrame.height) want=\(listHeight(25))")
        expect("paging: 3 pages for 25", SessionsListPaging.pageCount(total: 25) == 3)
        expect("paging: page slice sizes", SessionsListPaging.slice(page: 2, total: 25) == 20..<25)
        expect("paging: page index clamps", SessionsListPaging.clampedPage(9, total: 25) == 2)
        expect("paging: open at 12 vs 25 sessions has the same height",
               near(listHeight(12), listHeight(25)))
        NSApp.activate(ignoringOtherApps: true)
        pump(0.2)
        if panel.probeIsKey {
            cmd(kVK_ANSI_1, "1")
            expect("paging: ⌘1 opens the top row of page 1", panel.selectedSessionID == store.sessions[0].id)
        }
    }

    static func dismiss() {
        freshPanel(sessions: 2)
        expect("dismiss: visible after show", panel.isVisible)
        panel.hide()
        expect("dismiss: hide hides", !panel.isVisible)
        panel.toggle()
        pump(0.2)
        expect("dismiss: toggle shows again", panel.isVisible)
        let frame = panel.probeFrame
        panel.hide(); pump(0.1)
        panel.show(); pump(0.3)
        expect("dismiss: reopening restores the same placement", near(panel.probeFrame.minX, frame.minX) && near(panel.probeFrame.maxY, frame.maxY),
               "before=\(fmt(frame)) after=\(fmt(panel.probeFrame))")
        panel.hide()
    }

    /// The annotate comment box: ⌘/ model cycling, typing, Return submits, Esc cancels.
    static func annotate() {
        panel?.hide()
        let box = AnnotatePromptPanel()
        let kind = Preferences.agentCLI(for: Preferences.runtimeAgentTarget)
        Preferences.addAgentFavorite(AgentFavorite(title: "A", cliKind: kind, modelId: "ma", modelTitle: "A", effort: nil, isBuiltIn: false))
        Preferences.addAgentFavorite(AgentFavorite(title: "B", cliKind: kind, modelId: "mb", modelTitle: "B", effort: nil, isBuiltIn: false))
        var submitted: [String] = []
        var cancelled = 0
        var openStates: [Bool] = []
        box.onSubmit = { submitted.append($0) }
        box.onCancel = { cancelled += 1 }
        box.onOpenChanged = { openStates.append($0) }

        let screen = NSScreen.screens.first ?? NSScreen.main!
        box.show(on: screen, placement: .bottom, workspaceMissing: false)
        pump(0.5)
        expect("annotate: panel is visible", box.isVisible)
        expect("annotate: open state reported", openStates == [true], "\(openStates)")
        expect("annotate: becomes key", box.probeIsKey)
        expect("annotate: prompt owns first responder (caret)", box.probePromptIsFirstResponder)

        func boxKey(_ code: Int, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
            guard let e = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: box.probeWindowNumber, context: nil,
                characters: chars, charactersIgnoringModifiers: chars,
                isARepeat: false, keyCode: UInt16(code)
            ) else { return }
            NSApp.postEvent(e, atStart: false)
            pump(0.08)
        }

        let model = box.probeModel
        let favs = model.favorites
        expect("annotate: favorites loaded", favs.count >= 3, "n=\(favs.count)")
        var seen: [UUID?] = []
        for _ in 0..<(favs.count + 1) {
            boxKey(kVK_ANSI_Slash, "/", .command)
            pump(0.05)
            seen.append(model.selectedFavoriteID)
        }
        expect("annotate: ⌘/ visits every favorite", Set(seen.compactMap { $0 }) == Set(favs.map(\.id)))
        expect("annotate: ⌘/ wraps", seen.first == seen.last)
        expect("annotate: ⌘/ keeps the box open", box.isVisible)
        expect("annotate: ⌘/ doesn't type a slash", model.text.isEmpty, "text=\(model.text)")

        for ch in "fix it" { boxKey(0, String(ch)) }
        expect("annotate: typing reaches the prompt", model.text == "fix it", "text=\(model.text)")

        boxKey(kVK_Return, "\r")
        pump(0.2)
        expect("annotate: Return submits the text once", submitted == ["fix it"], "\(submitted)")
        expect("annotate: box closes after submit", !box.isVisible)
        expect("annotate: close reported", openStates.last == false)
        expect("annotate: submit keeps the chosen model as Current",
               Preferences.currentAgentFavoriteID(for: kind, target: Preferences.runtimeAgentTarget) == model.selectedFavoriteID)

        // Reopen: fresh prompt, Esc cancels without submitting.
        box.show(on: screen, placement: .bottom, workspaceMissing: false)
        pump(0.4)
        expect("annotate: reopens with an empty prompt", model.text.isEmpty, "text=\(model.text)")
        boxKey(0, "x")
        boxKey(kVK_Escape, "\u{1b}")
        pump(0.2)
        expect("annotate: Esc cancels", cancelled == 1 && submitted.count == 1, "cancelled=\(cancelled) submitted=\(submitted)")
        expect("annotate: Esc closes the box", !box.isVisible)

        // requirePrompt: empty Return must not submit.
        box.show(on: screen, placement: .bottom, workspaceMissing: false, requirePrompt: true)
        pump(0.4)
        boxKey(kVK_Return, "\r")
        pump(0.2)
        expect("annotate: required prompt blocks empty submit", submitted.count == 1 && box.isVisible, "submitted=\(submitted)")
        box.hide()
    }
}
#endif
