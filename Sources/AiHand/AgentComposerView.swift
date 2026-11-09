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
    /// Content width of the prompt field (excludes padding); drives soft-wrap height.
    @State private var fieldWidth: CGFloat = 360

    private let promptLineLimit = 1...12
    private let promptFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Soft-wrapped height for the current prompt. Vertical TextField alone often keeps a
    /// single-line intrinsic size on macOS, so the floating annotate panel never grows.
    private var promptFieldMinHeight: CGFloat {
        Self.measuredTextHeight(
            text: text,
            width: max(40, fieldWidth),
            font: promptFont,
            maxLines: promptLineLimit.upperBound
        )
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
                    .lineLimit(promptLineLimit)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.primary)
                    .focused($focused)
                    .frame(minHeight: promptFieldMinHeight, alignment: .topLeading)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: PromptFieldWidthKey.self, value: geo.size.width)
                        }
                    )
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
                    .onPreferenceChange(PromptFieldWidthKey.self) { width in
                        guard abs(width - fieldWidth) > 0.5 else { return }
                        fieldWidth = width
                        requestLayout()
                    }
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

                if isWorking, let onStop {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundColor(.secondary)
                            .softHoverInnerBorder(Circle(), inset: 2.5)
                    }
                    .buttonStyle(.plain)
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
            requestLayout()
        }
        .onChange(of: skillAC.isActive) { _ in
            requestLayout()
        }
        .onDisappear {
            removeNewlineMonitor()
            skillAC.teardown()
        }
    }

    private func requestLayout() {
        // Defer so SwiftUI applies the new minHeight before the panel reads fittingSize.
        DispatchQueue.main.async {
            onLayoutNeeded?()
        }
    }

    private static func measuredTextHeight(
        text: String,
        width: CGFloat,
        font: NSFont,
        maxLines: Int
    ) -> CGFloat {
        let lineHeight = max(1, ceil(font.ascender - font.descender + font.leading))
        let sample = text.isEmpty ? " " : text
        let storage = NSTextStorage(attributedString: NSAttributedString(
            string: sample,
            attributes: [.font: font]
        ))
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        _ = layout.glyphRange(for: container)
        let used = ceil(layout.usedRect(for: container).height)
        let maxHeight = lineHeight * CGFloat(maxLines)
        return min(max(used, lineHeight), maxHeight)
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

    /// ⇧↩ inserts a newline. Updates the SwiftUI binding so vertical TextFields grow
    /// (needed in the floating annotate panel, which sizes from fittingSize).
    private func installNewlineMonitor() {
        guard newlineMonitor == nil else { return }
        newlineMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Don't rely on FocusState — it's flaky inside NSPanels.
            guard let textView = Self.editableTextView(), textView.isEditable else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let code = Int(event.keyCode)
            guard code == kVK_Return || code == 76 else { return event }
            guard flags.contains(.shift),
                  !flags.contains(.command),
                  !flags.contains(.option),
                  !flags.contains(.control) else {
                return event
            }

            let range = textView.selectedRange()
            let ns = textView.string as NSString
            let updated = ns.replacingCharacters(in: range, with: "\n")
            text = updated
            let insertedAt = range.location + 1

            DispatchQueue.main.async {
                if let textView = Self.editableTextView() {
                    let maxLoc = (textView.string as NSString).length
                    textView.setSelectedRange(NSRange(location: min(insertedAt, maxLoc), length: 0))
                }
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

private enum PromptFieldWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
