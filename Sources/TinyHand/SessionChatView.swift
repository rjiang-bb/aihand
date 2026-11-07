import AppKit
import SwiftUI

struct SessionChatView: View {
    @ObservedObject var session: AgentSession
    var onSend: (String) -> Void
    var onStop: () -> Void
    var onClose: (() -> Void)? = nil
    var compact: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private var solidBG: Color { colorScheme == .dark ? .black : .white }
    private var solidFG: Color { colorScheme == .dark ? .white : .black }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ChatTranscriptView(messages: session.messages)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            composer
        }
        .background(compact ? solidBG : Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: compact ? 22 : 0, style: .continuous))
        .onAppear { focusComposer() }
        .onChange(of: session.id) { _ in
            focusComposer()
        }
    }

    private func focusComposer() {
        DispatchQueue.main.async {
            composerFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            statusBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(solidFG)
                    .lineLimit(1)
                Text(statusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(solidFG.opacity(0.6))
            }
            Spacer()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(solidFG)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(solidFG.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding(.horizontal, compact ? 14 : 16)
        .padding(.vertical, 12)
        .background(compact ? solidBG : Color.clear)
    }

    private var statusLabel: String {
        if session.messages.isEmpty, session.status == .waiting {
            return "Type a message to start"
        }
        switch session.status {
        case .working: return "Working…"
        case .finished: return "Finished"
        case .waiting: return "Waiting"
        case .failed: return session.errorMessage ?? "Failed"
        case .stopped: return "Stopped"
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if session.messages.isEmpty, session.status == .waiting {
            Image(systemName: "plus.circle.fill").foregroundColor(.accentColor)
        } else {
            switch session.status {
            case .working:
                ProgressView().controlSize(.small)
            case .finished:
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case .waiting, .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange)
            case .stopped:
                Image(systemName: "stop.circle.fill").foregroundColor(.secondary)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Follow up…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .foregroundStyle(.primary)
                .focused($composerFocused)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(compact ? 0.10 : 0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
                        )
                )
                .onSubmit(send)
            if session.status == .working {
                Button(action: onStop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop")
            }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(12)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        onSend(text)
    }
}
