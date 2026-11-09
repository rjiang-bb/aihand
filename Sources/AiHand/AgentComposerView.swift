import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Shared prompt composer used by session chat and the annotate comment panel.
struct AgentComposerView: View {
    enum Kind {
        /// Follow-ups in an existing session (queue / steer while working).
        case followUp
        /// First prompt for a new annotate / blank session (no steering).
        case initial
    }

    var kind: Kind
    var isWorking: Bool = false
    /// When false, empty text may still submit (annotate optional prompt).
    var requireNonEmpty: Bool = true
    var placeholder: String = "Follow up…"
    @Binding var text: String
    var workspace: String
    var favorites: [AgentFavorite]
    var selectedFavoriteID: UUID?
    var favoriteMenuTitle: String? = nil
    var onSelectFavorite: (AgentFavorite) -> Void
    var onSend: () -> Void
    var onQueue: (() -> Void)? = nil
    var onStop: (() -> Void)? = nil
    /// Called when the composer height may have changed (newline, skills list).
    var onLayoutNeeded: (() -> Void)? = nil
    @FocusState.Binding var focused: Bool

    @StateObject private var skillAC = SkillAutocompleteController()
    @State private var newlineMonitor: Any?

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        requireNonEmpty ? !trimmed.isEmpty : true
    }

    private var selectedFavorite: AgentFavorite? {
        if let id = selectedFavoriteID {
            return favorites.first(where: { $0.id == id })
        }
        return favorites.first
    }

    private var pickerTitle: String {
        if let favoriteMenuTitle, !favoriteMenuTitle.isEmpty {
            return favoriteMenuTitle
        }
        return selectedFavorite?.title ?? "Default"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if skillAC.isActive {
                SkillSuggestionList(
                    controller: skillAC,
                    query: SkillCatalog.slashQuery(in: text)?.query ?? ""
                ) { skill in
                    applySkill(skill)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...12)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.primary)
                    .focused($focused)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(
                                        focused
                                            ? Color(red: 0.2, green: 0.55, blue: 0.98)
                                            : Color.primary.opacity(0.45),
                                        lineWidth: focused ? 1.5 : 1
                                    )
                            )
                    )
                    .onSubmit {
                        if skillAC.isActive {
                            applySelectedSkill()
                        } else if isWorking, let onQueue {
                            onQueue()
                        } else {
                            guard canSend else { return }
                            onSend()
                        }
                    }
                    .help("Type / for skills · ⇧↩ for a new line")

                if isWorking, let onStop {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundColor(.secondary)
                            .softHoverInnerBorder(Circle(), inset: 2.5)
                    }
                    .buttonStyle(.plain)
                    .help("Stop (⌃C)")
                }

                Button(action: {
                    guard canSend else { return }
                    onSend()
                }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            canSend ? Color.white : Color.secondary.opacity(0.55),
                            canSend ? Color.accentColor : Color.secondary.opacity(0.25)
                        )
                        .softHoverInnerBorder(Circle(), inset: 2.5, enabled: canSend)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help(kind == .followUp ? "Send / Steer (⌘↩)" : "Send (⌘↩)")
            }

            HStack(alignment: .center, spacing: 14) {
                if kind == .followUp {
                    if isWorking {
                        hintPair(key: "Enter", label: "queue")
                        hintPair(key: "⇧↩", label: "newline")
                        hintPair(key: "⌘↩", label: "steer")
                        hintPair(key: "⌃C", label: "stop")
                    } else {
                        hintPair(key: "/", label: "skills")
                        hintPair(key: "⇧↩", label: "newline")
                        hintPair(key: "Enter", label: "send")
                    }
                    Spacer(minLength: 8)
                    hintPair(key: "⌘/", label: "model")
                } else {
                    hintPair(key: "⇧↩", label: "newline")
                    hintPair(key: "Enter", label: "send to agent")
                    hintPair(key: "Esc", label: "cancel")
                    Spacer(minLength: 8)
                }
                favoritePicker
            }
            .padding(.horizontal, 4)
        }
        .onAppear {
            skillAC.configure(workspace: workspace)
            skillAC.readText = { text }
            skillAC.writeText = { text = $0 }
            installNewlineMonitor()
        }
        .onChange(of: workspace) { newValue in
            skillAC.configure(workspace: newValue)
        }
        .onChange(of: text) { _ in
            skillAC.update(text: text)
            onLayoutNeeded?()
        }
        .onChange(of: skillAC.isActive) { _ in
            onLayoutNeeded?()
        }
        .onDisappear {
            removeNewlineMonitor()
            skillAC.teardown()
        }
    }

    private var favoritePicker: some View {
        Menu {
            ForEach(favorites) { fav in
                Button {
                    onSelectFavorite(fav)
                } label: {
                    if fav.id == selectedFavorite?.id {
                        Label(fav.title, systemImage: "checkmark")
                    } else {
                        Text(fav.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(pickerTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Color.primary.opacity(0.78))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            )
            .softHoverInnerBorder(Capsule(style: .continuous), inset: 2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func hintPair(key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.72))
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.primary.opacity(0.55))
        }
    }

    private func applySkill(_ skill: AgentSkill) {
        var next = text
        skillAC.apply(skill, to: &next)
        text = next
    }

    private func applySelectedSkill() {
        var next = text
        skillAC.applySelected(to: &next)
        text = next
    }

    /// ⇧↩ inserts a newline into the focused field editor and SwiftUI binding.
    private func installNewlineMonitor() {
        guard newlineMonitor == nil else { return }
        newlineMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Require FocusState so a hidden sessions chat composer doesn't steal
            // ⇧↩ from the annotate panel (sessions is ordered out, not destroyed).
            guard focused else { return event }
            guard let textView = Self.editableTextView(), textView.isEditable else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let code = Int(event.keyCode)
            guard code == kVK_Return || code == kVK_ANSI_KeypadEnter else { return event }
            guard flags.contains(.shift),
                  !flags.contains(.command),
                  !flags.contains(.option),
                  !flags.contains(.control) else {
                return event
            }

            let range = textView.selectedRange()
            let ns = textView.string as NSString
            let updated = ns.replacingCharacters(in: range, with: "\n")
            // Mutate the live editor — binding-only updates often don't reach it.
            textView.string = updated
            text = updated
            let insertedAt = min(range.location + 1, (updated as NSString).length)
            textView.setSelectedRange(NSRange(location: insertedAt, length: 0))

            DispatchQueue.main.async {
                onLayoutNeeded?()
            }
            return nil
        }
    }

    private func removeNewlineMonitor() {
        if let newlineMonitor {
            NSEvent.removeMonitor(newlineMonitor)
        }
        newlineMonitor = nil
    }

    private static func editableTextView() -> NSTextView? {
        let responder = NSApp.keyWindow?.firstResponder
        if let textView = responder as? NSTextView, textView.isEditable {
            return textView
        }
        if let field = responder as? NSTextField,
           let editor = field.currentEditor() as? NSTextView,
           editor.isEditable {
            return editor
        }
        return nil
    }
}
