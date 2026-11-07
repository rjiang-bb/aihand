import AppKit
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

    private let listWidth: CGFloat = 360
    private let chatWidth: CGFloat = 440

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
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.isReleasedWhenClosed = false

        let root = SessionsSidePanelView(
            store: store,
            selection: selection,
            onSelect: { [weak self] id in
                self?.openChat(for: id)
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
    }

    func hide() {
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

    private func closeChat() {
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
}

private final class SessionsPanelSelection: ObservableObject {
    @Published var selectedID: UUID?
}

private struct SessionsSidePanelView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var selection: SessionsPanelSelection
    var onSelect: (UUID) -> Void
    var onCloseChat: () -> Void
    var onClose: () -> Void
    var onSend: (UUID, String) -> Void
    var onStop: (UUID) -> Void

    var body: some View {
        HStack(spacing: 0) {
            sessionsList
                .frame(width: 344)
            if let id = selection.selectedID, let session = store.session(id: id) {
                Divider().opacity(0.35)
                SessionChatView(
                    session: session,
                    onSend: { text in onSend(id, text) },
                    onStop: { onStop(id) },
                    onClose: onCloseChat,
                    compact: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffect(material: .hudWindow)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
        .padding(8)
    }

    private var sessionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sessions")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundColor(.secondary)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if store.sessions.isEmpty {
                Spacer()
                Text("Draw on screen to start an agent session.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.sessions) { session in
                            SessionCardView(
                                session: session,
                                isSelected: selection.selectedID == session.id
                            ) {
                                onSelect(session.id)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
            }
        }
    }
}

private struct SessionCardView: View {
    @ObservedObject var session: AgentSession
    var isSelected: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                statusIcon
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(session.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(relativeTime(session.createdAt))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Text(session.preview)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(isSelected ? 0.95 : 0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch session.status {
        case .working:
            ProgressView()
                .controlSize(.small)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 18))
        case .waiting, .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 18))
        case .stopped:
            Image(systemName: "stop.circle.fill")
                .foregroundColor(.secondary)
                .font(.system(size: 18))
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
