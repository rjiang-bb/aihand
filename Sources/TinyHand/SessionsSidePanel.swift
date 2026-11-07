import AppKit
import Carbon.HIToolbox
import SwiftUI

final class SessionsSidePanel: NSObject, NSWindowDelegate {
    var onFollowUp: ((UUID, String, FollowUpSubmit) -> Void)?
    var onStop: ((UUID) -> Void)?
    var onNew: (() -> Void)?
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

    private let listWidth: CGFloat = 360
    /// Fixed outer height for the sessions list alone — only the chat pane is user-resizable.
    private let listHeight: CGFloat = 640
    /// Top + bottom padding around the HStack in `SessionsSidePanelView`.
    private let listChromeVertical: CGFloat = 68 + 14
    /// Floor at the default expanded size — users can only grow the chat from here.
    private var minExpandedWidth: CGFloat { Preferences.sessionsPanelDefaultWidth }
    private var minExpandedHeight: CGFloat { Preferences.sessionsPanelDefaultHeight }
    private let maxShortcutSlots = SessionStore.maxSessions

    fileprivate struct ChatResizeEdges: OptionSet {
        let rawValue: Int
        static let leading = ChatResizeEdges(rawValue: 1 << 0)
        static let trailing = ChatResizeEdges(rawValue: 1 << 1)
        static let top = ChatResizeEdges(rawValue: 1 << 2)
        static let bottom = ChatResizeEdges(rawValue: 1 << 3)
    }

    var isVisible: Bool { panel.isVisible }
    var screen: NSScreen? { panel.screen ?? NSScreen.main }

    /// Collapse the open chat so a New prompt can take focus cleanly.
    func collapseChat() {
        closeChat()
    }

    private func archive(_ id: UUID) {
        if selection.selectedID == id {
            closeChat()
        }
        store.remove(id)
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
            onArchive: { [weak self] id in
                self?.archive(id)
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
            },
            listContentHeight: max(1, listHeight - listChromeVertical)
        )
        let host = NSHostingView(rootView: root)
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        host.layer?.backgroundColor = NSColor.clear.cgColor
        hosting = host
        panel.contentView = host
    }

    func show(on screen: NSScreen? = nil) {
        layout(on: screen)
        panel.orderFrontRegardless()
        installShortcutMonitors()
    }

    func hide() {
        discardBlankDraftIfLeaving()
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
        selection.selectedID = id
        if isVisible {
            layout()
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
        discardBlankDraftIfLeaving()
        selection.selectedID = nil
        layout()
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

    private func layout(on screen: NSScreen? = nil) {
        let screen = screen ?? panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let expanded = selection.selectedID != nil
        updateSizeLimits(visible: visible, expanded: expanded)

        let previous = panel.frame
        let size = preferredSize(visible: visible, expanded: expanded)
        let frame: NSRect
        if hasCustomPlacement {
            var origin = Preferences.sessionsPanelOrigin ?? previous.origin
            // Keep the trailing edge fixed when expanding/collapsing the chat so the
            // sessions list slides into where the chat's right edge was.
            if isVisible, previous.width > 1, abs(previous.width - size.width) > 0.5 {
                origin.x = previous.maxX - size.width
            }
            if isVisible, previous.height > 1, abs(previous.height - size.height) > 0.5 {
                origin.y = previous.maxY - size.height
            }
            frame = clampFrame(NSRect(origin: origin, size: size), to: visible)
            Preferences.sessionsPanelOrigin = frame.origin
        } else {
            // Default: pin to the screen's trailing edge (list lands where chat ended).
            frame = NSRect(
                x: visible.maxX - size.width - 12,
                y: visible.minY + (visible.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
        }
        applyingLayout = true
        panel.setFrame(frame, display: true, animate: isVisible)
        applyingLayout = false
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
            Preferences.sessionsPanelOrigin = clamped.origin
        }
    }

    private func panelMoveEnded() {
        hasCustomPlacement = true
        clampToVisibleFrame()
        Preferences.sessionsPanelOrigin = panel.frame.origin
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
        selection.showShortcutBadges = false
        closeChat()
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
        selection.showShortcutBadges = cmdAlone && !store.sessions.isEmpty
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

        if Int(event.keyCode) == kVK_ANSI_N, panel.isKeyWindow {
            onNew?()
            return nil
        }

        guard let index = shortcutIndex(for: event) else { return event }
        let sessions = store.sessions
        guard index >= 0, index < sessions.count, index < maxShortcutSlots else { return event }
        openChat(for: sessions[index].id)
        selection.showShortcutBadges = true
        return nil
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
}

private final class SessionsPanelSelection: ObservableObject {
    @Published var selectedID: UUID?
    @Published var showShortcutBadges = false
}

private struct SessionsSidePanelView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var selection: SessionsPanelSelection
    var onSelect: (UUID) -> Void
    var onCloseChat: () -> Void
    var onClose: () -> Void
    var onNew: () -> Void
    var onArchive: (UUID) -> Void
    var onSend: (UUID, String, FollowUpSubmit) -> Void
    var onStop: (UUID) -> Void
    var onChatResizeBegan: () -> Void
    var onChatResizeChanged: (CGSize, SessionsSidePanel.ChatResizeEdges) -> Void
    var onChatResizeEnded: () -> Void
    var onPanelDragEnded: () -> Void
    /// Height of the sessions list column (panel height minus vertical chrome).
    var listContentHeight: CGFloat

    private let listColumnWidth: CGFloat = 344

    @Environment(\.colorScheme) private var colorScheme

    private var headerFG: Color { colorScheme == .dark ? .white : .black }
    private var headerBG: Color { colorScheme == .dark ? .black : .white }

    var body: some View {
        // Clear panel chrome; cards use solid white/black for readable contrast.
        HStack(alignment: .top, spacing: 12) {
            // List stays fixed size; only the chat card grows with panel resize.
            sessionsColumn
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
            if let id = selection.selectedID, !ids.contains(id) {
                onCloseChat()
            }
        }
    }

    private var floatingHeader: some View {
        HStack(alignment: .center) {
            Text("Tinyhand sessions")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.clear)
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.black, lineWidth: 1.25)
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
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private var sessionsColumn: some View {
        Group {
            if store.sessions.isEmpty {
                VStack {
                    Spacer()
                    Text("Tap New to start a prompt, or draw on screen to annotate.")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .padding(20)
                        .frame(maxWidth: .infinity)
                        .background(SolidCardBackground(cornerRadius: 22, selected: false))
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                            SessionCardView(
                                session: session,
                                isSelected: selection.selectedID == session.id,
                                shortcutNumber: index < 9 ? index + 1 : nil,
                                showShortcutBadge: selection.showShortcutBadges && index < 9,
                                onTap: { onSelect(session.id) },
                                onArchive: { onArchive(session.id) }
                            )
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
        }
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
    private let corner: CGFloat = 16

    var body: some View {
        ZStack {
            handle(edges: .leading, cursor: .resizeLeftRight)
                .frame(width: edge)
                .frame(maxHeight: .infinity)
                .frame(maxWidth: .infinity, alignment: .leading)
            handle(edges: .trailing, cursor: .resizeLeftRight)
                .frame(width: edge)
                .frame(maxHeight: .infinity)
                .frame(maxWidth: .infinity, alignment: .trailing)
            handle(edges: .top, cursor: .resizeUpDown)
                .frame(height: edge)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity, alignment: .top)
            handle(edges: .bottom, cursor: .resizeUpDown)
                .frame(height: edge)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity, alignment: .bottom)
            handle(edges: [.leading, .bottom], cursor: .resizeLeftRight)
                .frame(width: corner, height: corner)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            handle(edges: [.trailing, .bottom], cursor: .resizeLeftRight)
                .frame(width: corner, height: corner)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            handle(edges: [.leading, .top], cursor: .resizeLeftRight)
                .frame(width: corner, height: corner)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            handle(edges: [.trailing, .top], cursor: .resizeLeftRight)
                .frame(width: corner, height: corner)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .padding(1)
        .allowsHitTesting(true)
    }

    private func handle(edges: SessionsSidePanel.ChatResizeEdges, cursor: NSCursor) -> some View {
        ChatResizeEdgeDrag(
            edges: edges,
            cursor: cursor,
            onBegan: onBegan,
            onChanged: onChanged,
            onEnded: onEnded
        )
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
        let base = dark ? Color.black : Color.white
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

private struct SessionCardView: View {
    @ObservedObject var session: AgentSession
    var isSelected: Bool
    var shortcutNumber: Int?
    var showShortcutBadge: Bool
    var onTap: () -> Void
    var onArchive: () -> Void
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
                                .transition(.opacity.combined(with: .scale(scale: 0.85)))
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
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.trailing, hovering ? 36 : 0)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SolidCardBackground(cornerRadius: 22, selected: isSelected))
            }
            .buttonStyle(.plain)

            if hovering {
                Button(action: onArchive) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(fg)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(fg.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .help("Archive session")
                .padding(.trailing, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: showShortcutBadge)
        .animation(.easeOut(duration: 0.12), value: hovering)
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
