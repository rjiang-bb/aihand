import AppKit
import SwiftUI

struct SessionChatView: View {
    @ObservedObject var session: AgentSession
    var onSend: (String) -> Void
    var onStop: () -> Void
    var onClose: (() -> Void)? = nil
    var compact: Bool = false

    @State private var draft = ""
    @State private var quotedSelection: String?
    @State private var selectionOffer: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(session.messages) { message in
                            MessageBubble(message: message) { selected in
                                selectionOffer = selected
                            }
                            .id(message.id)
                        }
                    }
                    .padding(compact ? 12 : 16)
                }
                .onChange(of: session.messages.count) { _ in
                    if let last = session.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            if let offer = selectionOffer {
                selectionBar(offer)
            }
            Divider()
            composer
        }
        .background(compact ? Color.clear : Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            statusBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(statusLabel)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if session.status == .working {
                Button("Stop", action: onStop)
                    .controlSize(.small)
            }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundColor(.secondary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding(.horizontal, compact ? 14 : 16)
        .padding(.vertical, 12)
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
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                    .onSubmit(send)
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

private struct MessageBubble: View {
    let message: AgentMessage
    var onSelect: (String) -> Void

    var body: some View {
        HStack {
            if message.kind == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 8) {
                if let path = message.imagePath, let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 280, maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(message.kind == .tool
                              ? .system(size: 11, design: .monospaced)
                              : .system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if message.kind == .assistant || message.kind == .user {
                    Button("Ask about this") {
                        onSelect(message.text)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
            }
            .padding(10)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contextMenu {
                Button("Ask about selection") {
                    if let selected = NSPasteboard.general.string(forType: .string), !selected.isEmpty,
                       message.text.contains(selected) {
                        onSelect(selected)
                    } else {
                        onSelect(message.text)
                    }
                }
                Button("Ask about this message") {
                    onSelect(message.text)
                }
            }
            if message.kind != .user { Spacer(minLength: 40) }
        }
    }

    private var background: Color {
        switch message.kind {
        case .user: return Color.accentColor.opacity(0.18)
        case .assistant: return Color(nsColor: .controlBackgroundColor)
        case .tool: return Color.primary.opacity(0.05)
        case .system: return Color.orange.opacity(0.12)
        }
    }
}
