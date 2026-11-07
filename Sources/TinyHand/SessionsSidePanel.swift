import AppKit
import Carbon.HIToolbox
import SwiftUI

final class SessionsSidePanel: NSObject, NSWindowDelegate {
    var onFollowUp: ((UUID, String) -> Void)?
    var onStop: ((UUID) -> Void)?
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

    private let listWidth: CGFloat = 360
    private let chatWidth: CGFloat = 440
    private let maxShortcutSlots = 9

    var isVisible: Bool { panel.isVisible }

    init(store: SessionStore) {
        self.store = store
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 640),
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
            onSend: { [weak self] id, text in
                self?.onFollowUp?(id, text)
            },
            onStop: { [weak self] id in
                self?.onStop?(id)
            }
        )
        let host = NSHostingView(rootView: root)
        hosting = host
        panel.contentView = host
    }

    func show(on screen: NSScreen? = nil) {
        layout(on: screen)
        panel.orderFrontRegardless()
        installShortcutMonitors()
    }

    func hide() {
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
        selection.selectedID = nil
        layout()
    }

    private func layout(on screen: NSScreen? = nil) {
        let screen = screen ?? panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let expanded = selection.selectedID != nil
        let width = expanded ? listWidth + chatWidth : listWidth
        let height = min(640, visible.height - 40)
        let frame = NSRect(
            x: visible.maxX - width - 12,
            y: visible.minY + (visible.height - height) / 2,
            width: width,
            height: height
        )
        panel.setFrame(frame, display: true, animate: isVisible)
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

        if Int(event.keyCode) == kVK_Escape,
           selection.selectedID != nil,
           panel.isKeyWindow {
            closeChat()
            return nil
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.shift),
              !flags.contains(.option),
              !flags.contains(.control) else {
            return event
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
    var onSend: (UUID, String) -> Void
    var onStop: (UUID) -> Void

    private let listColumnWidth: CGFloat = 344

    var body: some View {
        ZStack {
            // Notification Center–style frosted strip; no solid chrome.
            VisualEffect(material: .fullScreenUI, blending: .behindWindow, emphasized: true)
                .opacity(0.92)
                .ignoresSafeArea()

            HStack(alignment: .top, spacing: 12) {
                sessionsColumn
                    .frame(width: listColumnWidth)
                if let id = selection.selectedID, let session = store.session(id: id) {
                    SessionChatView(
                        session: session,
                        onSend: { text in onSend(id, text) },
                        onStop: { onStop(id) },
                        onClose: onCloseChat,
                        compact: true
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NotificationCardBackground(cornerRadius: 22, selected: false))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 52)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            floatingHeader
        }
    }

    private var floatingHeader: some View {
        HStack(alignment: .center) {
            Text("Sessions")
                .font(.system(size: 20, weight: .semibold, design: .default))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.white.opacity(0.18)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Close")
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var sessionsColumn: some View {
        Group {
            if store.sessions.isEmpty {
                VStack {
                    Spacer()
                    Text("Draw on screen to start an agent session.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(20)
                        .frame(maxWidth: .infinity)
                        .background(NotificationCardBackground(cornerRadius: 22, selected: false))
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
                                showShortcutBadge: selection.showShortcutBadges && index < 9
                            ) {
                                onSelect(session.id)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

private struct NotificationCardBackground: View {
    var cornerRadius: CGFloat
    var selected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.16 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(selected ? 0.28 : 0.14), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.28), radius: selected ? 14 : 10, y: 6)
    }
}

private struct SessionCardView: View {
    @ObservedObject var session: AgentSession
    var isSelected: Bool
    var shortcutNumber: Int?
    var showShortcutBadge: Bool
    var onTap: () -> Void

    var body: some View {
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
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(relativeTime(session.createdAt))
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                    Text(session.preview)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.78))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NotificationCardBackground(cornerRadius: 22, selected: isSelected))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: showShortcutBadge)
    }

    @ViewBuilder
    private var statusIcon: some View {
        let icon = Group {
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
