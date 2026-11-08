import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

final class SessionsSidePanel: NSObject, NSWindowDelegate {
    var onFollowUp: ((UUID, String, FollowUpSubmit) -> Void)?
    var onStop: ((UUID) -> Void)?
    var onNew: (() -> Void)?
    var onManageWorkspaces: (() -> Void)?
    var onDismiss: (() -> Void)?

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private let panel: Panel
    private let store: SessionStore
    private let selection = SessionsPanelSelection()
    private var hosting: NSHostingView<SessionsSidePanelView>?
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var applyingLayout = false
    private var chatResizeStartFrame: NSRect?
    private var panelMoveStartOrigin: CGPoint?
    private var hasCustomPlacement = Preferences.sessionsPanelOrigin != nil
    private var cancellables = Set<AnyCancellable>()
    private var lastLaidOutListHeight: CGFloat = 0
    private var hintHideWork: DispatchWorkItem?

    private let listWidth: CGFloat = 360
    /// Grows with session count up to 10 rows + pagination (+ ⌘ hints when shown).
    private var listHeight: CGFloat {
        SessionsListMetrics.panelHeight(
            sessionCount: store.sessions.count,
            showShortcutHints: selection.showShortcutBadges
        )
    }
    /// Floor at the default expanded size — users can only grow the chat from here.
    /// Never shorter than the current list (top-aligned) so rows aren’t clipped.
    private var minExpandedWidth: CGFloat { Preferences.sessionsPanelDefaultWidth }
    private var minExpandedHeight: CGFloat {
        max(Preferences.sessionsPanelDefaultHeight, listHeight)
    }
    private let maxShortcutSlots = 9

    fileprivate struct ChatResizeEdges: OptionSet {
        let rawValue: Int
        static let leading = ChatResizeEdges(rawValue: 1 << 0)
        static let trailing = ChatResizeEdges(rawValue: 1 << 1)
        static let top = ChatResizeEdges(rawValue: 1 << 2)
        static let bottom = ChatResizeEdges(rawValue: 1 << 3)
    }

    var isVisible: Bool { panel.isVisible }
    var selectedSessionID: UUID? { selection.selectedID }

    /// Archive the open session and select the next one (⌘W).
    func archiveSelectedSession() {
        guard isVisible, let id = selection.selectedID else { return }
        archive(id)
    }

    /// Return key focus to the sessions panel (e.g. after closing a chat image preview).
    func focus() {
        guard isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    var screen: NSScreen? { panel.screen ?? NSScreen.main }

    /// Collapse the open chat so a New prompt can take focus cleanly.
    func collapseChat() {
        closeChat()
    }

    private func archive(_ id: UUID) {
        let sessions = store.sessions
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        // Prefer the next (older) row; otherwise the previous (newer) one.
        let nextID: UUID? = {
            if idx + 1 < sessions.count { return sessions[idx + 1].id }
            if idx > 0 { return sessions[idx - 1].id }
            return nil
        }()
        let wasSelected = selection.selectedID == id
        if wasSelected {
            // Clear before remove so blank-draft cleanup doesn't race.
            selection.selectedID = nil
        }
        store.remove(id)
        if wasSelected {
            if let nextID, store.session(id: nextID) != nil {
                openChat(for: nextID)
            } else {
                layout()
            }
        }
    }

    /// Archive every session listed below `id` (older rows when newest-first).
    private func archiveAllBelow(_ id: UUID) {
        let sessions = store.sessions
        guard let idx = sessions.firstIndex(where: { $0.id == id }),
              idx + 1 < sessions.count else { return }
        archiveMany(sessions[(idx + 1)...].map(\.id))
    }

    private func archiveAll() {
        archiveMany(store.sessions.map(\.id))
    }

    private func archiveMany(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let selected = selection.selectedID
        let removingSelected = selected.map(ids.contains) ?? false
        let selectingNext: UUID? = {
            guard let selected, removingSelected else { return nil }
            let sessions = store.sessions
            guard let idx = sessions.firstIndex(where: { $0.id == selected }) else { return nil }
            for j in (idx + 1)..<sessions.count where !ids.contains(sessions[j].id) {
                return sessions[j].id
            }
            for j in stride(from: idx - 1, through: 0, by: -1) where !ids.contains(sessions[j].id) {
                return sessions[j].id
            }
            return nil
        }()
        if removingSelected {
            selection.selectedID = nil
        }
        for id in ids {
            store.remove(id)
        }
        if let selectingNext, store.session(id: selectingNext) != nil {
            openChat(for: selectingNext)
        } else if removingSelected {
            layout()
        }
    }

    init(store: SessionStore) {
        self.store = store
        panel = Panel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Preferences.sessionsPanelDefaultWidth,
                height: Preferences.sessionsPanelDefaultHeight
            ),
            // Resize via chat-card grips only — not the outer window chrome.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovable = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        // Let the desktop show through; cards provide their own glass.
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let root = SessionsSidePanelView(
            store: store,
            selection: selection,
            onSelect: { [weak self] id in
                self?.toggleChat(for: id)
            },
            onCloseChat: { [weak self] in
                self?.closeChat()
            },
            onClose: { [weak self] in
                self?.hide()
            },
            onNew: { [weak self] in
                self?.onNew?()
            },
            onManageWorkspaces: { [weak self] in
                self?.onManageWorkspaces?()
            },
            onArchive: { [weak self] id in
                self?.archive(id)
            },
            onArchiveAllBelow: { [weak self] id in
                self?.archiveAllBelow(id)
            },
            onArchiveAll: { [weak self] in
                self?.archiveAll()
            },
            onSend: { [weak self] id, text, submit in
                self?.onFollowUp?(id, text, submit)
            },
            onStop: { [weak self] id in
                self?.onStop?(id)
            },
            onChatResizeBegan: { [weak self] in
                self?.chatResizeBegan()
            },
            onChatResizeChanged: { [weak self] translation, edges in
                self?.chatResizeChanged(translation: translation, edges: edges)
            },
            onChatResizeEnded: { [weak self] in
                self?.chatResizeEnded()
            },
            onPanelDragEnded: { [weak self] in
                self?.panelMoveEnded()
            }
        )
        let host = NSHostingView(rootView: root)
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        host.layer?.backgroundColor = NSColor.clear.cgColor
        hosting = host
        panel.contentView = host

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.relayoutForSessionCountIfNeeded() }
            }
            .store(in: &cancellables)
        lastLaidOutListHeight = listHeight
    }

    /// Grow / shrink the list-only panel as sessions are added or archived.
    private func relayoutForSessionCountIfNeeded(animateFrame: Bool = true) {
        let height = listHeight
        guard abs(height - lastLaidOutListHeight) > 0.5 else { return }
        lastLaidOutListHeight = height
        guard isVisible, selection.selectedID == nil else { return }
        layout(animateFrame: animateFrame)
    }

    func show(on screen: NSScreen? = nil) {
        lastLaidOutListHeight = listHeight
        layout(on: screen)
        // Become key so ⌘N / ⌘1–9 work immediately after the global sessions shortcut.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installShortcutMonitors()
        // Nonactivating panels sometimes need a second pass after ordering front.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.panel.makeKeyAndOrderFront(nil)
        }
    }

    func hide() {
        discardBlankDraftIfLeaving()
        // Only refresh the remembered origin while list-only. If a chat is open,
        // keep the existing list-home — expanded geometry must not shift it.
        if selection.selectedID == nil {
            persistListPlacement()
        }
        removeShortcutMonitors()
        selection.showShortcutBadges = false
        selection.selectedID = nil
        panel.orderOut(nil)
        onDismiss?()
    }

    func toggle(on screen: NSScreen? = nil) {
        if isVisible {
            hide()
        } else {
            show(on: screen)
        }
    }

    func openChat(for id: UUID) {
        if selection.selectedID != id {
            discardBlankDraftIfLeaving(except: id)
        }
        // Only relayout when expanding from the list; switching sessions must not
        // move the panel (that was the animated "jump" on each select).
        let needsExpand = selection.selectedID == nil
        if needsExpand, isVisible {
            // Lock in the list-only home before the panel grows for chat.
            persistListPlacement()
        }
        selection.selectedID = id
        selection.revealSessionInList(id, sessions: store.sessions)
        if isVisible {
            if needsExpand {
                layout()
            }
        } else {
            show()
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Select a session, or collapse the chat if that session is already selected.
    private func toggleChat(for id: UUID) {
        if selection.selectedID == id {
            closeChat()
        } else {
            openChat(for: id)
        }
    }

    private func closeChat() {
        guard selection.selectedID != nil else { return }
        // Keep the expanded panel’s trailing edge; the list slides right into
        // where the chat card was (instead of staying pinned to the left).
        let expanded = panel.frame
        discardBlankDraftIfLeaving()
        selection.selectedID = nil
        layout(
            listOriginOverride: CGPoint(
                x: expanded.maxX - listWidth,
                y: expanded.maxY - listHeight
            )
        )
        persistListPlacement()
    }

    /// Drop an untouched "New session" when leaving it (switch, Esc, click away, hide).
    private func discardBlankDraftIfLeaving(except keepID: UUID? = nil) {
        guard let id = selection.selectedID,
              id != keepID,
              let session = store.session(id: id),
              session.isBlankDraft else { return }
        selection.selectedID = nil
        store.remove(id)
    }

    private func layout(on screen: NSScreen? = nil, listOriginOverride: CGPoint? = nil, animateFrame: Bool = true) {
        let screen = screen ?? panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let expanded = selection.selectedID != nil
        updateSizeLimits(visible: visible, expanded: expanded)

        let size = preferredSize(visible: visible, expanded: expanded)
        // Expanded: pin the list’s leading edge so chat grows to the right.
        // Collapsing passes `listOriginOverride` so the list’s trailing edge
        // matches the chat’s former trailing edge. Otherwise prefer the live
        // frame, then the saved list-home, then the default trailing dock.
        let listOrigin: CGPoint = {
            if let listOriginOverride {
                return listOriginOverride
            }
            if isVisible, panel.frame.width > 1 {
                return listOnlyOrigin(from: panel.frame)
            }
            if hasCustomPlacement, let saved = Preferences.sessionsPanelOrigin {
                return saved
            }
            return CGPoint(
                x: visible.maxX - listWidth - 12,
                y: visible.minY + (visible.height - listHeight) / 2
            )
        }()
        let frame = clampFramePreservingList(
            frameAlignedToListOrigin(listOrigin, size: size),
            listOrigin: listOrigin,
            to: visible
        )
        let sizeChanged = abs(panel.frame.width - frame.width) > 0.5
            || abs(panel.frame.height - frame.height) > 0.5
        applyingLayout = true
        // ⌘ hint toggles pass animateFrame: false so only SwiftUI’s slide runs —
        // AppKit window animation + SwiftUI together was the list-only jank.
        panel.setFrame(frame, display: true, animate: animateFrame && isVisible && sizeChanged)
        applyingLayout = false
    }

    /// Origin of the sessions list assuming chat is closed (list is leading in the HStack).
    private func listOnlyOrigin(from frame: NSRect) -> CGPoint {
        CGPoint(
            x: frame.minX,
            y: frame.maxY - listHeight
        )
    }

    /// Panel frame for `size` with the list fixed at `listOrigin` and chat to its right.
    private func frameAlignedToListOrigin(_ listOrigin: CGPoint, size: NSSize) -> NSRect {
        NSRect(
            x: listOrigin.x,
            y: listOrigin.y + listHeight - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Fit on-screen while keeping the list's leading edge stable when possible.
    private func clampFramePreservingList(_ frame: NSRect, listOrigin: CGPoint, to visible: NSRect) -> NSRect {
        var frame = frame
        frame.size.width = min(frame.width, floor(visible.width * 0.5))
        frame.size.height = min(frame.height, floor(visible.height * 0.9))
        // Keep list leading edge; only nudge left if chat would overflow the display.
        frame.origin.x = listOrigin.x
        if frame.maxX > visible.maxX - 8 {
            frame.origin.x = max(visible.minX + 8, (visible.maxX - 8) - frame.width)
        } else if frame.origin.x < visible.minX + 8 {
            frame.origin.x = visible.minX + 8
        }
        let maxY = listOrigin.y + listHeight
        frame.origin.y = maxY - frame.height
        if frame.origin.y < visible.minY + 8 {
            frame.origin.y = visible.minY + 8
        } else if frame.maxY > visible.maxY - 8 {
            frame.origin.y = (visible.maxY - 8) - frame.height
        }
        return frame
    }

    private func persistListPlacement(from frame: NSRect? = nil) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let source = frame ?? panel.frame
        guard source.width > 1, source.height > 1 else { return }
        let listSize = NSSize(width: listWidth, height: listHeight)
        let listFrame = clampFrame(
            NSRect(origin: listOnlyOrigin(from: source), size: listSize),
            to: screen.visibleFrame
        )
        Preferences.sessionsPanelOrigin = listFrame.origin
        hasCustomPlacement = true
    }

    private func preferredSize(visible: NSRect, expanded: Bool) -> NSSize {
        let maxW = floor(visible.width * 0.5)
        let maxH = floor(visible.height * 0.9)
        if expanded {
            let minW = min(minExpandedWidth, maxW)
            let minH = min(minExpandedHeight, maxH)
            let width = min(max(Preferences.sessionsPanelWidth, minW), maxW)
            let height = min(max(Preferences.sessionsPanelHeight, minH), maxH)
            return NSSize(width: width, height: height)
        }
        // Sessions list alone stays a fixed size — only the chat pane resizes.
        return NSSize(
            width: min(listWidth, maxW),
            height: min(listHeight, maxH)
        )
    }

    private func updateSizeLimits(visible: NSRect, expanded: Bool) {
        let maxW = max(1, floor(visible.width * 0.5))
        let maxH = max(1, floor(visible.height * 0.9))
        if expanded {
            let minW = min(minExpandedWidth, maxW)
            let minH = min(minExpandedHeight, maxH)
            panel.minSize = NSSize(width: minW, height: minH)
            panel.maxSize = NSSize(width: maxW, height: maxH)
        } else {
            let width = min(listWidth, maxW)
            let height = min(listHeight, maxH)
            panel.minSize = NSSize(width: width, height: height)
            panel.maxSize = NSSize(width: width, height: height)
        }
    }

    private func persistSizeIfNeeded() {
        guard !applyingLayout else { return }
        guard selection.selectedID != nil else { return }
        let size = panel.frame.size
        guard size.width > 0, size.height > 0 else { return }
        Preferences.sessionsPanelWidth = size.width
        Preferences.sessionsPanelHeight = size.height
    }

    private func clampFrame(_ frame: NSRect, to visible: NSRect) -> NSRect {
        var frame = frame
        frame.size.width = min(frame.width, floor(visible.width * 0.5))
        frame.size.height = min(frame.height, floor(visible.height * 0.9))
        frame.origin.x = min(max(frame.origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        frame.origin.y = min(max(frame.origin.y, visible.minY + 8), visible.maxY - frame.height - 8)
        return frame
    }

    private func clampToVisibleFrame() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let clamped = clampFrame(panel.frame, to: screen.visibleFrame)
        applyingLayout = true
        panel.setFrame(clamped, display: true)
        applyingLayout = false
        if hasCustomPlacement {
            persistListPlacement(from: clamped)
        }
    }

    private func panelMoveEnded() {
        hasCustomPlacement = true
        clampToVisibleFrame()
        persistListPlacement()
    }

    func windowDidMove(_ notification: Notification) {
        guard !applyingLayout else { return }
        hasCustomPlacement = true
    }

    private func chatResizeBegan() {
        guard selection.selectedID != nil else { return }
        chatResizeStartFrame = panel.frame
    }

    private func chatResizeChanged(translation: CGSize, edges: ChatResizeEdges) {
        guard selection.selectedID != nil,
              let start = chatResizeStartFrame,
              let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let maxW = floor(visible.width * 0.5)
        let maxH = floor(visible.height * 0.9)
        let minW = min(minExpandedWidth, maxW)
        let minH = min(minExpandedHeight, maxH)

        var width = start.width
        var height = start.height
        if edges.contains(.leading) {
            width = start.width - translation.width
        }
        if edges.contains(.trailing) {
            width = start.width + translation.width
        }
        // SwiftUI +y is down; AppKit +y is up.
        if edges.contains(.bottom) {
            height = start.height + translation.height
        }
        if edges.contains(.top) {
            height = start.height - translation.height
        }

        width = min(max(width, minW), maxW)
        height = min(max(height, minH), maxH)

        var frame = start
        frame.size = NSSize(width: width, height: height)
        // Keep the opposite edge fixed while the dragged edge moves.
        if edges.contains(.leading), !edges.contains(.trailing) {
            frame.origin.x = start.maxX - width
        } else if edges.contains(.trailing), !edges.contains(.leading) {
            frame.origin.x = start.origin.x
        } else {
            frame.origin.x = start.midX - width / 2
        }
        if edges.contains(.bottom), !edges.contains(.top) {
            frame.origin.y = start.maxY - height
        } else if edges.contains(.top), !edges.contains(.bottom) {
            frame.origin.y = start.origin.y
        } else {
            frame.origin.y = start.midY - height / 2
        }
        frame = clampFrame(frame, to: visible)

        applyingLayout = true
        panel.setFrame(frame, display: true)
        applyingLayout = false
        hasCustomPlacement = true
    }

    private func chatResizeEnded() {
        persistSizeIfNeeded()
        clampToVisibleFrame()
        chatResizeStartFrame = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        installShortcutMonitors()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Do not close chat here — menu key equivalents (⌘/) and the favorite
        // picker briefly resign key; collapsing would clear the selection and
        // make model cycling a no-op. Esc / the chat close button dismiss chat.
        selection.showShortcutBadges = false
    }

    private func installShortcutMonitors() {
        guard keyMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event)
        }
    }

    private func removeShortcutMonitors() {
        hintHideWork?.cancel()
        hintHideWork = nil
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        flagsMonitor = nil
        keyMonitor = nil
        selection.showShortcutBadges = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard isVisible else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmdAlone = flags.contains(.command)
            && !flags.contains(.shift)
            && !flags.contains(.option)
            && !flags.contains(.control)
        let show = cmdAlone && !store.sessions.isEmpty
        guard selection.showShortcutBadges != show else { return }
        setShortcutHintsVisible(show)
    }

    /// Slide ⌘ hints in/out inside the list card. List-only grows the panel without
    /// AppKit frame animation so SwiftUI’s slide isn’t fighting a window resize.
    private func setShortcutHintsVisible(_ show: Bool) {
        hintHideWork?.cancel()
        hintHideWork = nil

        if selection.selectedID != nil {
            selection.showShortcutBadges = show
            return
        }

        if show {
            selection.showShortcutBadges = true
            lastLaidOutListHeight = -1
            relayoutForSessionCountIfNeeded(animateFrame: false)
            return
        }

        selection.showShortcutBadges = false
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.selection.showShortcutBadges else { return }
            self.lastLaidOutListHeight = -1
            self.relayoutForSessionCountIfNeeded(animateFrame: false)
        }
        hintHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard isVisible else { return event }

        if Int(event.keyCode) == kVK_Escape, panel.isKeyWindow {
            if selection.selectedID != nil {
                closeChat()
            } else {
                hide()
            }
            return nil
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // ⌃C stops the open chat (same as the Stop button).
        if panel.isKeyWindow,
           Int(event.keyCode) == kVK_ANSI_C,
           flags.contains(.control),
           !flags.contains(.command),
           !flags.contains(.option),
           !flags.contains(.shift),
           let id = selection.selectedID,
           store.session(id: id)?.status == .working {
            onStop?(id)
            return nil
        }

        guard flags.contains(.command),
              !flags.contains(.shift),
              !flags.contains(.option),
              !flags.contains(.control) else {
            return event
        }

        // ⌘/ → cycle favorite models for the open chat (panel owns this while key).
        if panel.isKeyWindow,
           Self.isModelCycleKey(event),
           let id = selection.selectedID,
           let session = store.session(id: id) {
            session.cycleFavorite()
            return nil
        }

        if Int(event.keyCode) == kVK_ANSI_N, panel.isKeyWindow {
            onNew?()
            return nil
        }

        // ⌘W → close a focused image preview, else archive the selected session.
        if Int(event.keyCode) == kVK_ANSI_W, panel.isKeyWindow || ChatImageActions.isPreviewKey {
            if ChatImageActions.closeKeyPreviewIfNeeded() {
                focus()
                return nil
            }
            if panel.isKeyWindow, let id = selection.selectedID {
                archive(id)
                return nil
            }
        }

        // ⌘↑ / ⌘↓ → previous / next session while a chat is open.
        if panel.isKeyWindow,
           selection.selectedID != nil,
           Int(event.keyCode) == kVK_UpArrow || Int(event.keyCode) == kVK_DownArrow {
            selectAdjacentSession(delta: Int(event.keyCode) == kVK_UpArrow ? -1 : 1)
            return nil
        }

        guard let index = shortcutIndex(for: event) else { return event }
        let pageSessions = selection.pagedSessions(store.sessions)
        guard index >= 0, index < pageSessions.count, index < maxShortcutSlots else { return event }
        openChat(for: pageSessions[index].id)
        selection.showShortcutBadges = true
        return nil
    }

    /// Move selection by `delta` in the newest-first sessions list (−1 = above, +1 = below).
    private func selectAdjacentSession(delta: Int) {
        let sessions = store.sessions
        guard let id = selection.selectedID,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let next = idx + delta
        guard sessions.indices.contains(next) else { return }
        openChat(for: sessions[next].id)
    }

    private func shortcutIndex(for event: NSEvent) -> Int? {
        switch Int(event.keyCode) {
        case kVK_ANSI_1: return 0
        case kVK_ANSI_2: return 1
        case kVK_ANSI_3: return 2
        case kVK_ANSI_4: return 3
        case kVK_ANSI_5: return 4
        case kVK_ANSI_6: return 5
        case kVK_ANSI_7: return 6
        case kVK_ANSI_8: return 7
        case kVK_ANSI_9: return 8
        default:
            if let ch = event.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n) {
                return n - 1
            }
            return nil
        }
    }

    private static func isModelCycleKey(_ event: NSEvent) -> Bool {
        if Int(event.keyCode) == kVK_ANSI_Slash { return true }
        if event.charactersIgnoringModifiers == "/" { return true }
        return false
    }
}

private enum SessionsListPaging {
    static let pageSize = 10
    /// Show the pager once the list grows past the old hard cap of 9.
    static let threshold = 9

    static func needsPagination(_ count: Int) -> Bool { count > threshold }

    static func pageCount(total: Int) -> Int {
        guard needsPagination(total) else { return 1 }
        return max(1, (total + pageSize - 1) / pageSize)
    }

    static func clampedPage(_ page: Int, total: Int) -> Int {
        min(max(0, page), max(0, pageCount(total: total) - 1))
    }

    static func slice(page: Int, total: Int) -> Range<Int> {
        guard total > 0 else { return 0..<0 }
        if !needsPagination(total) { return 0..<total }
        let p = clampedPage(page, total: total)
        let start = p * pageSize
        let end = min(start + pageSize, total)
        return start..<end
    }
}

/// List panel height grows with session count up to one full page + pagination.
private enum SessionsListMetrics {
    static let chromeVertical: CGFloat = 68 + 14
    /// Workspace picker: 13+13 pad + ~34pt title/path stack.
    private static let picker: CGFloat = 60
    private static let columnGap: CGFloat = 16
    /// Embedded session row: 8+8 pad + 14pt title + 4 gap + 13pt single-line preview.
    private static let row: CGFloat = 54
    private static let rowGap: CGFloat = 4
    private static let listPadTop: CGFloat = 8
    private static let listPadBottom: CGFloat = 8
    private static let listPadBottomPaginated: CGFloat = 4
    private static let footer: CGFloat = 40
    private static let emptyHint: CGFloat = 92

    static var maxPanelHeight: CGFloat {
        panelHeight(sessionCount: SessionsListPaging.pageSize + 1)
    }

    static func panelHeight(sessionCount: Int, showShortcutHints: Bool = false) -> CGFloat {
        chromeVertical + columnHeight(sessionCount: sessionCount, showShortcutHints: showShortcutHints)
    }

    static func columnHeight(sessionCount: Int, showShortcutHints: Bool = false) -> CGFloat {
        if sessionCount <= 0 {
            return picker + columnGap + emptyHint
        }
        let paginate = SessionsListPaging.needsPagination(sessionCount)
        // Paginated lists already have a footer; ⌘ hints reuse that slot.
        let showFooter = paginate || showShortcutHints
        let rows = CGFloat(paginate ? SessionsListPaging.pageSize : sessionCount)
        let stack = rows * row + max(0, rows - 1) * rowGap
        let bottomPad = showFooter ? listPadBottomPaginated : listPadBottom
        return picker + columnGap + listPadTop + bottomPad + stack + (showFooter ? footer : 0)
    }
}

private final class SessionsPanelSelection: ObservableObject {
    @Published var selectedID: UUID?
    @Published var showShortcutBadges = false
    @Published var listPage = 0

    func pagedSessions(_ sessions: [AgentSession]) -> [AgentSession] {
        let range = SessionsListPaging.slice(page: listPage, total: sessions.count)
        guard !range.isEmpty else { return [] }
        return Array(sessions[range])
    }

    func revealSessionInList(_ id: UUID, sessions: [AgentSession]) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        if SessionsListPaging.needsPagination(sessions.count) {
            listPage = idx / SessionsListPaging.pageSize
        } else {
            listPage = 0
        }
    }

    func clampListPage(total: Int) {
        listPage = SessionsListPaging.clampedPage(listPage, total: total)
    }
}

private struct SessionsSidePanelView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var selection: SessionsPanelSelection
    var onSelect: (UUID) -> Void
    var onCloseChat: () -> Void
    var onClose: () -> Void
    var onNew: () -> Void
    var onManageWorkspaces: () -> Void
    var onArchive: (UUID) -> Void
    var onArchiveAllBelow: (UUID) -> Void
    var onArchiveAll: () -> Void
    var onSend: (UUID, String, FollowUpSubmit) -> Void
    var onStop: (UUID) -> Void
    var onChatResizeBegan: () -> Void
    var onChatResizeChanged: (CGSize, SessionsSidePanel.ChatResizeEdges) -> Void
    var onChatResizeEnded: () -> Void
    var onPanelDragEnded: () -> Void

    private let listColumnWidth: CGFloat = 344

    @Environment(\.colorScheme) private var colorScheme

    private var headerFG: Color { colorScheme == .dark ? .white : .black }
    private var headerBG: Color { SoftChrome.cardFill(dark: colorScheme == .dark) }

    private var allSessions: [AgentSession] { store.sessions }
    private var pageSessions: [AgentSession] { selection.pagedSessions(allSessions) }
    private var needsPagination: Bool { SessionsListPaging.needsPagination(allSessions.count) }
    private var pageRange: Range<Int> {
        SessionsListPaging.slice(page: selection.listPage, total: allSessions.count)
    }
    private var listContentHeight: CGFloat {
        SessionsListMetrics.columnHeight(
            sessionCount: allSessions.count,
            showShortcutHints: selection.showShortcutBadges
        )
    }

    private var showListFooter: Bool {
        needsPagination || selection.showShortcutBadges
    }

    var body: some View {
        // Clear panel chrome; cards use solid white/black for readable contrast.
        HStack(alignment: .top, spacing: 12) {
            sessionsColumn
                // Always hug session content — never stretch the list to the chat height.
                .frame(width: listColumnWidth, height: listContentHeight, alignment: .top)
            if let id = selection.selectedID, let session = store.session(id: id) {
                SessionChatView(
                    session: session,
                    onSend: { text, submit in onSend(id, text, submit) },
                    onStop: { onStop(id) },
                    onClose: onCloseChat,
                    compact: true,
                    onPanelDragEnded: onPanelDragEnded
                )
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .background(SolidCardBackground(cornerRadius: 22, selected: false))
                .overlay {
                    ChatCardResizeHandles(
                        onBegan: onChatResizeBegan,
                        onChanged: onChatResizeChanged,
                        onEnded: onChatResizeEnded
                    )
                }
                .layoutPriority(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 68)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .overlay(alignment: .top) {
            floatingHeader
        }
        .onChange(of: store.sessions.map(\.id)) { ids in
            selection.clampListPage(total: ids.count)
            if let id = selection.selectedID, !ids.contains(id) {
                onCloseChat()
            }
        }
        .onChange(of: store.currentWorkspace) { _ in
            selection.listPage = 0
            if let id = selection.selectedID,
               !store.sessions.contains(where: { $0.id == id }) {
                onCloseChat()
            }
        }
    }

    private var floatingHeader: some View {
        HStack(alignment: .center) {
            Text("AI sessions")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black)
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white, lineWidth: 1.25)
                        )
                )
                .panelDragHandle(onEnded: onPanelDragEnded)
                .help("Drag to move")
            Spacer(minLength: 8)
            Button(action: onNew) {
                Text("New")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(headerFG)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        Capsule(style: .continuous)
                            .fill(headerBG)
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                    )
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Start a new session")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(headerFG)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(headerBG)
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                    )
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Close")
        }
        // Match the list column’s leading inset (content HStack uses 14).
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private var sessionsColumn: some View {
        VStack(spacing: 16) {
            WorkspacePicker(
                folders: store.workspaceFolders,
                current: store.currentWorkspace,
                onSelect: { Preferences.selectAgentWorkspace($0) },
                onManage: onManageWorkspaces
            )
            if store.sessions.isEmpty {
                Text(store.currentWorkspace.isEmpty
                     ? "Add a working folder to start sessions here."
                     : "Tap New to start a prompt, or draw on screen to annotate.")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .background(SolidCardBackground(cornerRadius: 22, selected: false))
                Spacer(minLength: 0)
            } else {
                sessionsListContainer
            }
        }
    }

    private var sessionsListRows: some View {
        LazyVStack(spacing: 4) {
            ForEach(Array(pageSessions.enumerated()), id: \.element.id) { index, session in
                let globalIndex = pageRange.lowerBound + index
                SessionCardView(
                    session: session,
                    isSelected: selection.selectedID == session.id,
                    shortcutNumber: index < 9 ? index + 1 : nil,
                    showShortcutBadge: selection.showShortcutBadges && index < 9,
                    embedded: true,
                    canArchiveBelow: globalIndex + 1 < allSessions.count,
                    onTap: { onSelect(session.id) },
                    onArchive: { onArchive(session.id) },
                    onArchiveAllBelow: { onArchiveAllBelow(session.id) },
                    onArchiveAll: onArchiveAll
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, showListFooter ? 4 : 8)
    }

    private var sessionsListContainer: some View {
        VStack(spacing: 0) {
            if needsPagination {
                ScrollView {
                    sessionsListRows
                }
                .scrollContentBackground(.hidden)
            } else {
                sessionsListRows
            }
            if selection.showShortcutBadges {
                sessionsShortcutHintsFooter
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if needsPagination {
                sessionsPaginationFooter
                    .transition(.opacity)
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: needsPagination ? .infinity : nil,
            alignment: .top
        )
        .background(SolidCardBackground(cornerRadius: 22, selected: false))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.easeOut(duration: 0.14), value: selection.showShortcutBadges)
    }

    /// Shown while ⌘ is held — pairs with the ⌘1…9 badges.
    private var sessionsShortcutHintsFooter: some View {
        HStack(spacing: 14) {
            shortcutHint(key: "⌘1–9", label: "select")
            shortcutHint(key: "⌘↑↓", label: "navigate")
            shortcutHint(key: "⌘W", label: "archive")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    private func shortcutHint(key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.72))
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.secondary)
        }
    }

    private var sessionsPaginationFooter: some View {
        let total = allSessions.count
        let start = pageRange.lowerBound + 1
        let end = pageRange.upperBound
        let page = selection.listPage
        let pages = SessionsListPaging.pageCount(total: total)
        return HStack(spacing: 10) {
            Button {
                selection.listPage = max(0, page - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(page <= 0)
            .opacity(page <= 0 ? 0.35 : 1)
            .help("Previous page")

            Text("\(start)–\(end) of \(total)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                selection.listPage = min(pages - 1, page + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(page >= pages - 1)
            .opacity(page >= pages - 1 ? 0.35 : 1)
            .help("Next page")
        }
        .foregroundStyle(.primary.opacity(0.75))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }
}

private struct WorkspacePicker: View {
    let folders: [String]
    let current: String
    var onSelect: (String) -> Void
    var onManage: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var fg: Color { colorScheme == .dark ? .white : .black }

    private var title: String {
        if current.isEmpty { return "No folder" }
        return URL(fileURLWithPath: current).lastPathComponent
    }

    var body: some View {
        // Draw the card ourselves — Menu’s borderless label swallows custom backgrounds.
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(current.isEmpty ? "Choose a working folder" : current)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(fg.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(fg.opacity(0.45))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspacePickerBackground(cornerRadius: 22))
        .overlay {
            Menu {
                if folders.isEmpty {
                    Button("Add folders…", action: onManage)
                } else {
                    ForEach(folders, id: \.self) { path in
                        Button {
                            onSelect(path)
                        } label: {
                            // One primary string — Menu drops a second Text “subtitle” on macOS.
                            if SessionStore.sameWorkspace(path, current) {
                                Label(menuLabel(for: path), systemImage: "checkmark")
                            } else {
                                Text(menuLabel(for: path))
                            }
                        }
                    }
                    Divider()
                    Button("Manage folders…", action: onManage)
                }
            } label: {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .help(current.isEmpty ? "Choose a working folder" : current)
    }

    private func menuTitle(for path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private func menuLabel(for path: String) -> String {
        "\(menuTitle(for: path)) - \(path)"
    }
}

extension View {
    /// Native AppKit window drag — avoids SwiftUI translation fighting a moving window.
    func panelDragHandle(
        enabled: Bool = true,
        onEnded: @escaping () -> Void
    ) -> some View {
        overlay {
            if enabled {
                WindowDragHandle(onDragEnded: onEnded)
            }
        }
    }
}

/// Transparent AppKit region that calls `NSWindow.performDrag` for smooth moving.
private struct WindowDragHandle: NSViewRepresentable {
    var onDragEnded: () -> Void

    func makeNSView(context: Context) -> WindowDragNSView {
        let view = WindowDragNSView()
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: WindowDragNSView, context: Context) {
        nsView.onDragEnded = onDragEnded
    }
}

private final class WindowDragNSView: NSView {
    var onDragEnded: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        window.performDrag(with: event)
        onDragEnded?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Invisible hit targets on the chat card edges — drives panel resize without
/// AppKit's outer-window resize chrome (which sat in empty transparent space).
private struct ChatCardResizeHandles: View {
    var onBegan: () -> Void
    var onChanged: (CGSize, SessionsSidePanel.ChatResizeEdges) -> Void
    var onEnded: () -> Void

    private let edge: CGFloat = 8
    private let corner: CGFloat = 18

    var body: some View {
        // Overlay + alignment keeps hit targets to the strip/corner size only
        // (expanding `.frame(max…)` around a child steals the whole card).
        // Edges are inset by `corner` so diagonal corners own those pixels.
        Color.clear
            .overlay(alignment: .leading) {
                edgeHandle(.leading, cursor: .resizeLeftRight)
                    .frame(width: edge)
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, corner)
            }
            .overlay(alignment: .trailing) {
                edgeHandle(.trailing, cursor: .resizeLeftRight)
                    .frame(width: edge)
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, corner)
            }
            .overlay(alignment: .top) {
                edgeHandle(.top, cursor: .resizeUpDown)
                    .frame(height: edge)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, corner)
            }
            .overlay(alignment: .bottom) {
                edgeHandle(.bottom, cursor: .resizeUpDown)
                    .frame(height: edge)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, corner)
            }
            .overlay(alignment: .bottomLeading) {
                cornerHandle([.leading, .bottom])
            }
            .overlay(alignment: .bottomTrailing) {
                cornerHandle([.trailing, .bottom])
            }
            .overlay(alignment: .topLeading) {
                cornerHandle([.leading, .top])
            }
            .overlay(alignment: .topTrailing) {
                cornerHandle([.trailing, .top])
            }
            .padding(1)
            .allowsHitTesting(true)
    }

    private func edgeHandle(
        _ edges: SessionsSidePanel.ChatResizeEdges,
        cursor: NSCursor
    ) -> some View {
        ChatResizeEdgeDrag(
            edges: edges,
            cursor: cursor,
            onBegan: onBegan,
            onChanged: onChanged,
            onEnded: onEnded
        )
    }

    private func cornerHandle(_ edges: SessionsSidePanel.ChatResizeEdges) -> some View {
        ChatResizeEdgeDrag(
            edges: edges,
            cursor: Self.cornerCursor(for: edges),
            onBegan: onBegan,
            onChanged: onChanged,
            onEnded: onEnded
        )
        .frame(width: corner, height: corner)
        .contentShape(Rectangle())
    }

    private static func cornerCursor(for edges: SessionsSidePanel.ChatResizeEdges) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            if edges.contains([.leading, .top]) {
                position = .topLeft
            } else if edges.contains([.trailing, .top]) {
                position = .topRight
            } else if edges.contains([.leading, .bottom]) {
                position = .bottomLeft
            } else {
                position = .bottomRight
            }
            return .frameResize(position: position, directions: [.all])
        }
        // No public diagonal resize cursor before Sequoia.
        return .crosshair
    }
}

private struct ChatResizeEdgeDrag: View {
    var edges: SessionsSidePanel.ChatResizeEdges
    var cursor: NSCursor
    var onBegan: () -> Void
    var onChanged: (CGSize, SessionsSidePanel.ChatResizeEdges) -> Void
    var onEnded: () -> Void

    @State private var dragging = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { inside in
                if inside || dragging {
                    cursor.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            onBegan()
                            cursor.set()
                        }
                        onChanged(value.translation, edges)
                    }
                    .onEnded { _ in
                        dragging = false
                        onEnded()
                        NSCursor.arrow.set()
                    }
            )
    }
}

private struct SolidCardBackground: View {
    var cornerRadius: CGFloat
    var selected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        let base = SoftChrome.cardFill(dark: dark)
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(base)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(selected ? (dark ? 0.22 : 0.12) : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        selected
                            ? Color.accentColor
                            : (dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08)),
                        lineWidth: selected ? 2 : 0.5
                    )
            )
            .shadow(
                color: selected
                    ? Color.accentColor.opacity(dark ? 0.4 : 0.22)
                    : .black.opacity(dark ? 0.5 : 0.16),
                radius: selected ? 16 : 12,
                y: 6
            )
    }
}

/// Same chrome as session cards, but a muted fill so the folder picker reads as chrome.
private struct WorkspacePickerBackground: View {
    var cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        let base = dark
            ? Color(white: 0.16)
            : Color(white: 0.94)
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(base)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06),
                        lineWidth: 0.5
                    )
            )
            .shadow(color: .black.opacity(dark ? 0.4 : 0.12), radius: 10, y: 4)
    }
}

private struct SessionCardView: View {
    @ObservedObject var session: AgentSession
    var isSelected: Bool
    var shortcutNumber: Int?
    var showShortcutBadge: Bool
    /// Flat row chrome when nested inside the opaque list container.
    var embedded: Bool = false
    var canArchiveBelow: Bool = false
    var onTap: () -> Void
    var onArchive: () -> Void
    var onArchiveAllBelow: (() -> Void)? = nil
    var onArchiveAll: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    private var fg: Color { colorScheme == .dark ? .white : .black }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onTap) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        statusIcon
                            .frame(width: 30, height: 30)
                        if showShortcutBadge, let shortcutNumber {
                            ShortcutBadge(number: shortcutNumber)
                                .transition(.opacity)
                        }
                    }
                    .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(session.title)
                                .font(.system(size: 14, weight: isSelected ? .bold : .semibold))
                                .foregroundStyle(fg)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(relativeTime(session.createdAt))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(fg.opacity(hovering ? 0 : 0.55))
                        }
                        Text(session.preview.isEmpty ? "Type a message to start" : session.preview)
                            .font(.system(size: 13))
                            .foregroundStyle(fg.opacity(session.preview.isEmpty ? 0.45 : 0.82))
                            // Single line keeps list row height stable so the panel can hug content.
                            .lineLimit(embedded ? 1 : 2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(.horizontal, embedded ? 10 : 14)
                .padding(.vertical, embedded ? 8 : 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground)
            }
            .buttonStyle(.plain)

            // Float over the card — do not pad/reflow text when it appears.
            if hovering {
                Button(action: onArchive) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(fg)
                        .frame(width: 28, height: 28)
                        .background {
                            let dark = colorScheme == .dark
                            Circle()
                                .fill(SoftChrome.cardFill(dark: dark))
                                .overlay(
                                    Circle().fill(Color.accentColor.opacity(isSelected ? (dark ? 0.22 : 0.12) : 0))
                                )
                                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                        }
                }
                .buttonStyle(.plain)
                .help("Archive session")
                .padding(.trailing, 10)
                .transition(.opacity)
            }
        }
        .contextMenu {
            Button("Archive", role: .destructive, action: onArchive)
            Button("Archive All Below") {
                onArchiveAllBelow?()
            }
            .disabled(!canArchiveBelow)
            Divider()
            Button("Archive All", role: .destructive) {
                onArchiveAll?()
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: showShortcutBadge)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder
    private var cardBackground: some View {
        if embedded {
            let dark = colorScheme == .dark
            let idle = dark ? Color(white: 0.18) : Color(white: 0.94)
            let hover = dark ? Color(white: 0.22) : Color(white: 0.90)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(dark ? 0.22 : 0.14)
                        : (hovering ? hover : idle)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            isSelected
                                ? Color.accentColor
                                : (dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)),
                            lineWidth: isSelected ? 1.5 : 0.5
                        )
                )
        } else {
            SolidCardBackground(cornerRadius: 22, selected: isSelected)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        let icon = Group {
            if session.messages.isEmpty, session.status == .waiting {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 20))
            } else {
                switch session.status {
                case .working:
                    ProgressView()
                        .controlSize(.small)
                case .finished:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 20))
                case .waiting, .failed:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 20))
                case .stopped:
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 20))
                }
            }
        }
        icon.opacity(showShortcutBadge ? 0 : 1)
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct ShortcutBadge: View {
    let number: Int

    var body: some View {
        HStack(spacing: 2) {
            Text("⌘")
                .font(.system(size: 10, weight: .semibold))
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor)
        )
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}
