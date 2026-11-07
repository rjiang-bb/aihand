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
    @State private var quotedSelection: String?
    @State private var selectionOffer: String?

    private var solidBG: Color { colorScheme == .dark ? .black : .white }
    private var solidFG: Color { colorScheme == .dark ? .white : .black }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ChatTranscriptView(messages: session.messages) { selected in
                selectionOffer = selected
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let offer = selectionOffer {
                selectionBar(offer)
            }
            Divider()
            composer
        }
        .background(compact ? solidBG : Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: compact ? 22 : 0, style: .continuous))
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

    private func selectionBar(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text("Selected")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            Button("Ask about selection") {
                quotedSelection = text
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    draft = "About this: "
                }
                selectionOffer = nil
            }
            .controlSize(.small)
            Button("Dismiss") {
                selectionOffer = nil
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let quoted = quotedSelection {
                HStack {
                    Text("“\(quoted)”")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        quotedSelection = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Follow up…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.primary)
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
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && quotedSelection == nil)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
    }

    private func send() {
        var parts: [String] = []
        if let quoted = quotedSelection?.trimmingCharacters(in: .whitespacesAndNewlines), !quoted.isEmpty {
            parts.append("Regarding this selection:\n> \(quoted)")
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            parts.append(text)
        }
        guard !parts.isEmpty else { return }
        let prompt = parts.joined(separator: "\n\n")
        draft = ""
        quotedSelection = nil
        selectionOffer = nil
        onSend(prompt)
    }
}

