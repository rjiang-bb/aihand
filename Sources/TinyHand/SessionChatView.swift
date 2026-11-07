import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SessionChatView: View {
    @ObservedObject var session: AgentSession
    var onSend: (String, FollowUpSubmit) -> Void
    var onStop: () -> Void
    var onClose: (() -> Void)? = nil
    var compact: Bool = false
    var onPanelDragEnded: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var draft = ""
    @State private var draggingQueueID: UUID?
    @FocusState private var composerFocused: Bool
    @StateObject private var skillAC = SkillAutocompleteController()
    @State private var newlineMonitor: Any?

    private var solidBG: Color { colorScheme == .dark ? .black : .white }
    private var solidFG: Color { colorScheme == .dark ? .white : .black }
    private var isWorking: Bool { session.status == .working }
    private var workspace: String { Preferences.agentWorkspace }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ChatTranscriptView(messages: session.messages)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            if !session.queuedFollowUps.isEmpty {
                queueSection
                Divider()
            }
            composer
                .overlay(alignment: .top) {
                    if skillAC.isActive {
                        SkillSuggestionList(
                            controller: skillAC,
                            query: SkillCatalog.slashQuery(in: draft)?.query ?? ""
                        ) { skill in
                            applySkill(skill)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                        // Anchor the list's bottom to the composer's top so it floats upward.
                        .alignmentGuide(.top) { $0[.bottom] }
                    }
                }
                .zIndex(1)
        }
        .background(compact ? solidBG : Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: compact ? 22 : 0, style: .continuous))
        .onAppear {
            skillAC.configure(workspace: workspace)
            skillAC.readText = { draft }
            skillAC.writeText = { draft = $0 }
            focusComposer()
        }
        .onDisappear {
            removeNewlineMonitor()
            skillAC.teardown()
        }
        .onChange(of: session.id) { _ in
            focusComposer()
        }
        .onChange(of: draft) { _ in
            skillAC.update(text: draft)
        }
        .onChange(of: composerFocused) { focused in
            if focused {
                installNewlineMonitor()
            } else {
                removeNewlineMonitor()
            }
        }
    }

    private func focusComposer() {
        DispatchQueue.main.async {
            composerFocused = true
        }
    }

    private func installNewlineMonitor() {
        guard newlineMonitor == nil else { return }
        newlineMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Shift+Return → newline; plain Return still submits via onSubmit.
            let code = Int(event.keyCode)
            guard code == 36 || code == 76 else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.shift),
                  !flags.contains(.command),
                  !flags.contains(.option),
                  !flags.contains(.control) else {
                return event
            }
            guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
                  textView.isEditable else {
                return event
            }
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return nil
        }
    }

    private func removeNewlineMonitor() {
        if let newlineMonitor {
            NSEvent.removeMonitor(newlineMonitor)
        }
        newlineMonitor = nil
    }

    private var header: some View {
        HStack(spacing: 10) {
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
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .panelDragHandle(
                enabled: compact && onPanelDragEnded != nil,
                onEnded: { onPanelDragEnded?() }
            )
            .modifier(OptionalHelp(text: compact ? "Drag to move" : nil))
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

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                    .font(.system(size: 10, weight: .semibold))
                Text("Queued · \(session.queuedFollowUps.count)")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("Drag to reorder")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)

            VStack(spacing: 4) {
                ForEach(session.queuedFollowUps) { item in
                    queueRow(item)
                        .opacity(draggingQueueID == item.id ? 0.45 : 1)
                        .onDrag {
                            draggingQueueID = item.id
                            return NSItemProvider(object: item.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: QueueReorderDropDelegate(
                                target: item,
                                items: Binding(
                                    get: { session.queuedFollowUps },
                                    set: { session.queuedFollowUps = $0 }
                                ),
                                draggingID: $draggingQueueID
                            )
                        )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(compact ? 0.06 : 0.04))
    }

    private func queueRow(_ item: QueuedFollowUp) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(item.text)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                steerQueued(item)
            } label: {
                Text("Steer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Interrupt and send this now")
            Button {
                session.queuedFollowUps.removeAll { $0.id == item.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Remove from queue")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(compact ? 0.10 : 0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Follow up…", text: $draft, axis: .vertical)
                    .lineLimit(1...12)
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
                    .onSubmit {
                        if skillAC.isActive {
                            applySelectedSkill()
                        } else {
                            submit(.queue)
                        }
                    }
                    .help("Type / for skills · ⇧↩ for a new line")
                if isWorking {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop (⌃C)")
                }
                Button(action: { submit(.sendNow) }) {
                    let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            canSend ? Color.white : Color.secondary.opacity(0.55),
                            canSend ? Color.accentColor : Color.secondary.opacity(0.25)
                        )
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .help(isWorking ? "Send now" : "Send")
            }

            if isWorking {
                HStack(spacing: 14) {
                    hintPair(key: "Enter", label: "queue")
                    hintPair(key: "⇧↩", label: "newline")
                    hintPair(key: "⌘↩", label: "steer")
                    hintPair(key: "⌃C", label: "stop")
                }
                .padding(.horizontal, 4)
            } else if !skillAC.isActive {
                HStack(spacing: 14) {
                    hintPair(key: "/", label: "skills")
                    hintPair(key: "⇧↩", label: "newline")
                    hintPair(key: "Enter", label: "send")
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func hintPair(key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func submit(_ mode: FollowUpSubmit) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        skillAC.clear()
        // Idle turns treat both as send-now; queue only applies while working.
        let resolved: FollowUpSubmit = (isWorking && mode == .queue) ? .queue : .sendNow
        onSend(text, resolved)
    }

    private func steerQueued(_ item: QueuedFollowUp) {
        session.queuedFollowUps.removeAll { $0.id == item.id }
        onSend(item.text, .sendNow)
    }

    private func applySkill(_ skill: AgentSkill) {
        var text = draft
        skillAC.apply(skill, to: &text)
        draft = text
    }

    private func applySelectedSkill() {
        var text = draft
        skillAC.applySelected(to: &text)
        draft = text
    }
}

private struct QueueReorderDropDelegate: DropDelegate {
    let target: QueuedFollowUp
    @Binding var items: [QueuedFollowUp]
    @Binding var draggingID: UUID?

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggingID,
              draggingID != target.id,
              let from = items.firstIndex(where: { $0.id == draggingID }),
              let to = items.firstIndex(where: { $0.id == target.id }),
              from != to else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private struct OptionalHelp: ViewModifier {
    var text: String?
    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}
