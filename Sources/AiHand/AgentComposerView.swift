import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

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
    /// Optional Cursor-style media strip (chat follow-ups). Nil hides paste/drop UI.
    var attachments: Binding<[ComposerAttachment]>? = nil
    var workspace: String
    /// SSH connection for the open session (skills + `@` file index). Falls back to prefs.
    var connectionID: UUID? = nil
    /// Which agent CLI this composer is bound to — gates `/` skill roots.
    var cliKind: AgentCLIKind = Preferences.agentCLI(for: Preferences.runtimeAgentTarget)
    var favorites: [AgentFavorite]
    var selectedFavoriteID: UUID?
    var favoriteMenuTitle: String? = nil
    var onSelectFavorite: (AgentFavorite) -> Void
    var onSend: () -> Void
    var onQueue: (() -> Void)? = nil
    var onStop: (() -> Void)? = nil
    /// Composer is editing a queued follow-up (Cursor-style).
    var isEditingQueued: Bool = false
    var onConfirmEdit: (() -> Void)? = nil
    var onCancelEdit: (() -> Void)? = nil
    /// Follow-up only: enter drawing mode and send the capture back to this session.
    var onDraw: (() -> Void)? = nil
    /// Called when the composer height may have changed (newline, skills list).
    var onLayoutNeeded: (() -> Void)? = nil
    /// Insets so SoftChrome / drop chrome can sit flush with the chat card edges.
    var contentInsets: EdgeInsets = EdgeInsets()
    /// Bottom corners of the drop/SoftChrome chrome (0 top; matches the sessions chat card).
    var bottomCornerRadius: CGFloat = 0
    @FocusState.Binding var focused: Bool

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var skillAC = SkillAutocompleteController()
    @StateObject private var fileAC = FileAutocompleteController()
    @State private var keyMonitor: Any?
    @State private var plusMenuMouseMonitor: Any?
    @State private var dropTargeted = false
    @State private var plusMenuOpen = false
    @State private var ignoreNextPlusMenuDismiss = false
    @State private var promptEditorHeight: CGFloat = 22
    @State private var shortcutButtonHovered = false
    @State private var shortcutPopoverHovered = false
    @State private var shortcutDismissWork: DispatchWorkItem?
    /// ⌘ held while the prompt is focused → send button shows the steer glyph.
    @State private var commandHeld = false
    /// Local key monitor closes over a class so Esc sees live edit / + menu state.
    @State private var keyBridge = ComposerKeyBridge()
    @State private var flagsMonitor: Any?

    private var resolvedConnectionID: UUID? {
        connectionID ?? Preferences.agentWorkspaceConnectionID
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasAttachments: Bool {
        !(attachments?.wrappedValue.isEmpty ?? true)
    }

    private var canSend: Bool {
        if hasAttachments { return true }
        return requireNonEmpty ? !trimmed.isEmpty : true
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
        VStack(alignment: .leading, spacing: 2) {
            if fileAC.isActive {
                FileSuggestionList(
                    controller: fileAC,
                    query: WorkspaceFileCatalog.atQuery(in: text)?.query ?? ""
                ) { entry in
                    applyFile(entry)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            } else if skillAC.isActive {
                SkillSuggestionList(
                    controller: skillAC,
                    query: SkillCatalog.slashQuery(in: text)?.query ?? ""
                ) { skill in
                    applySkill(skill)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            } else if plusMenuOpen {
                // Custom + menu sits above the field (same slot as @ / skill lists).
                composerPlusMenu
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            promptField

            HStack(alignment: .center, spacing: 6) {
                composerPlusButton
                if isEditingQueued {
                    editingQueuedBadge
                }
                shortcutsButton
                Spacer(minLength: 8)
                favoritePicker
                composerActionButtons
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 2)
        }
        .padding(contentInsets)
        // Empty SoftChrome (not buttons / menus / the NSTextView) focuses the prompt.
        .contentShape(ComposerDropChromeShape(bottomRadius: bottomCornerRadius))
        .onTapGesture { focusPrompt() }
        .background(SoftChrome.cardFill(dark: colorScheme == .dark))
        .clipShape(ComposerDropChromeShape(bottomRadius: bottomCornerRadius))
        // Window-wide drag monitor: highlight as soon as a file drag enters the window;
        // only the SoftChrome band accepts the drop.
        .background {
            if attachments != nil {
                ComposerMediaDragCatcher(
                    isTargeted: $dropTargeted,
                    onDrop: { handleFileDrop() }
                )
            }
        }
        .overlay {
            if dropTargeted {
                dropFilesHighlight
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            syncKeyBridge()
            configureAutocomplete()
            installKeyMonitor()
            installFlagsMonitor()
        }
        .onChange(of: isEditingQueued) { _ in syncKeyBridge() }
        .onChange(of: plusMenuOpen) { _ in syncKeyBridge() }
        .onChange(of: focused) { _ in
            syncKeyBridge()
            refreshCommandHeld()
        }
        .onChange(of: workspace) { _ in
            configureAutocomplete()
        }
        .onChange(of: connectionID) { _ in
            configureAutocomplete()
        }
        .onChange(of: cliKind) { _ in
            configureAutocomplete()
        }
        .onReceive(NotificationCenter.default.publisher(for: Preferences.changed)) { _ in
            // No invalidate here: every prefs change (including a workspace click) used to wipe the
            // cache and force a fresh SSH skill scan. The 30s TTL + per-workspace/CLI key cover staleness.
            configureAutocomplete()
        }
        .onChange(of: text) { _ in
            updateAutocomplete(for: text)
            // Submit clears the draft while the editor height binding may still
            // hold the multiline value — snap back so SoftChrome doesn't stay tall.
            if text.isEmpty, promptEditorHeight > 28 {
                promptEditorHeight = 22
            }
            onLayoutNeeded?()
        }
        .onChange(of: skillAC.isActive) { active in
            if active { plusMenuOpen = false }
            onLayoutNeeded?()
        }
        .onChange(of: fileAC.isActive) { active in
            if active { plusMenuOpen = false }
            onLayoutNeeded?()
        }
        .onChange(of: attachments?.wrappedValue.count ?? -1) { _ in
            onLayoutNeeded?()
        }
        .onChange(of: plusMenuOpen) { open in
            if open {
                fileAC.clear()
                skillAC.clear()
                ignoreNextPlusMenuDismiss = true
                installPlusMenuMouseMonitor()
            } else {
                removePlusMenuMouseMonitor()
            }
            onLayoutNeeded?()
        }
        .onDisappear {
            removeKeyMonitor()
            removeFlagsMonitor()
            removePlusMenuMouseMonitor()
            skillAC.teardown()
            fileAC.teardown()
        }
    }

    private var promptIsFocused: Bool {
        focused || (ComposerFieldEditor.editableTextView() as? ComposerPromptTextView) != nil
    }

    /// Follow-up send glyph: steer while ⌘ is held in the prompt.
    private var sendButtonSymbol: String {
        ComposerSendButtonIcon.systemName(
            isFollowUp: kind == .followUp,
            commandHeld: commandHeld,
            promptFocused: promptIsFocused
        )
    }

    private func configureAutocomplete() {
        let conn = resolvedConnectionID
        skillAC.configure(workspace: workspace, connectionID: conn, cli: cliKind)
        skillAC.readText = { text }
        skillAC.writeText = { text = $0 }
        skillAC.onPick = { [self] skill in
            applySkill(skill)
        }
        fileAC.configure(workspace: workspace, connectionID: conn)
        fileAC.readText = { text }
        fileAC.writeText = { text = $0 }
        let attachBinding = attachments
        let ws = workspace
        fileAC.onPick = { [self] entry in
            // Keyboard pick — same deferred path as click (avoid list teardown crashes).
            applyFile(entry)
            _ = attachBinding
            _ = ws
        }
    }

    private func updateAutocomplete(for text: String) {
        if WorkspaceFileCatalog.atQuery(in: text) != nil {
            skillAC.clear()
            fileAC.update(text: text)
        } else if SkillCatalog.slashQuery(in: text) != nil {
            fileAC.clear()
            skillAC.update(text: text)
        } else {
            fileAC.clear()
            skillAC.clear()
        }
    }

    /// Cursor-style field: attachments above the text (chrome + drop zone live on the outer composer).
    private var promptField: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let attachments, !attachments.wrappedValue.isEmpty {
                attachmentArea(attachments)
            }
            ComposerPromptEditor(
                text: $text,
                focused: Binding(
                    get: { focused },
                    set: { focused = $0 }
                ),
                height: $promptEditorHeight,
                placeholder: placeholder,
                darkChrome: colorScheme == .dark,
                onSubmit: handleSubmit,
                onHeightChange: { onLayoutNeeded?() },
                onPasteMedia: attachments == nil ? nil : { pasteMediaFromClipboard() }
            )
            .frame(maxWidth: .infinity, minHeight: promptEditorHeight, maxHeight: promptEditorHeight, alignment: .topLeading)
            // NSTextView can paint past its frame; without this, lines sit on + / Shortcuts.
            .clipped()
        }
        // Match toolbar inset (SessionChatView 12 + row 2 → 14pt).
        // Keep a little air above + / Shortcuts so list lines never sit under them.
        .padding(.horizontal, 2)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composerPlusButton: some View {
        Button {
            plusMenuOpen.toggle()
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 22, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.primary.opacity(0.72))
                .frame(width: 24, height: 24)
                .softHoverInnerBorder(Circle(), inset: 1.25)
        }
        .buttonStyle(.pointerPlain)
        .hoverTooltip(HoverTooltipLabel.icon("Plan or attach"))
    }

    private var editingQueuedBadge: some View {
        EditingQueuedBadge(onCancel: { onCancelEdit?() })
    }

    @ViewBuilder
    private var composerActionButtons: some View {
        if kind == .followUp, let onDraw, !isEditingQueued {
            Button(action: onDraw) {
                Image(systemName: "pencil.tip.crop.circle.fill")
                    .font(.system(size: 26))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .softHoverInnerBorder(Circle(), inset: 2.5)
            }
            .buttonStyle(.pointerPlain)
            .keyboardShortcut("d", modifiers: .command)
            .hoverTooltip(HoverTooltipLabel.icon("Draw", shortcut: "⌘D"))
        }

        if isEditingQueued {
            Button(action: {
                guard canSend else { return }
                onConfirmEdit?()
            }) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        canSend ? Color.white : Color.secondary.opacity(0.55),
                        canSend ? Color.accentColor : Color.secondary.opacity(0.25)
                    )
                    .softHoverInnerBorder(Circle(), inset: 2.5, enabled: canSend)
            }
            .buttonStyle(.pointerPlain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .hoverTooltip(HoverTooltipLabel.icon("Confirm edit", shortcut: "↩"))
        } else if isWorking, let onStop {
            // Gray stop replaces Send while a turn runs; Enter still queues, ⌘↩ steers.
            Button(action: onStop) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 26))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.secondary.opacity(0.9))
                    .softHoverInnerBorder(Circle(), inset: 2.5)
            }
            .buttonStyle(.pointerPlain)
            .hoverTooltip(HoverTooltipLabel.icon("Stop", shortcut: "⌃C"))
            .background(steerKeyboardShortcut)
        } else {
            Button(action: {
                guard canSend else { return }
                onSend()
            }) {
                Image(systemName: sendButtonSymbol)
                    .font(.system(size: 26))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        canSend ? Color.white : Color.secondary.opacity(0.55),
                        canSend ? Color.accentColor : Color.secondary.opacity(0.25)
                    )
                    .softHoverInnerBorder(Circle(), inset: 2.5, enabled: canSend)
            }
            .buttonStyle(.pointerPlain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .hoverTooltip(
                kind == .followUp
                    ? "Send (↩) / Steer (⌘↩)"
                    : HoverTooltipLabel.icon("Send", shortcut: "⌘↩")
            )
            .accessibilityLabel(
                kind == .followUp && commandHeld && promptIsFocused ? "Steer" : "Send"
            )
        }
    }

    /// Hidden ⌘↩ while Stop is showing so steer still works from the keyboard.
    private var steerKeyboardShortcut: some View {
        Button {
            guard canSend else { return }
            onSend()
        } label: {
            EmptyView()
        }
        .keyboardShortcut(.return, modifiers: .command)
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var composerPlusMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            composerPlusMenuRow(
                symbol: "list.bullet.clipboard",
                title: "Plan",
                subtitle: "Generate an implementation plan"
            ) {
                plusMenuOpen = false
                insertPlanCommand()
            }

            if attachments != nil {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)

                composerPlusMenuRow(
                    symbol: "paperclip",
                    title: "Attach",
                    subtitle: nil
                ) {
                    plusMenuOpen = false
                    presentAttachPanel()
                }
            }
        }
        .padding(4)
        .frame(width: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SoftChrome.cardFill(dark: colorScheme == .dark))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
        )
    }

    private func composerPlusMenuRow(
        symbol: String,
        title: String,
        subtitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, subtitle == nil ? 8 : 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(shape)
            .softHoverInnerBorder(shape, inset: 1.5)
        }
        .buttonStyle(.pointerPlain)
    }

    /// Put the caret in the prompt (AppKit first responder — FocusState alone is flaky).
    private func focusPrompt() {
        focused = true
        ComposerFieldEditor.focus()
    }

    /// Square top, rounded bottom — matches the sessions chat card’s lower corners.
    private var dropFilesHighlight: some View {
        let tint = Color(red: 0.2, green: 0.55, blue: 0.98)
        let shape = ComposerDropChromeShape(bottomRadius: bottomCornerRadius)
        return shape
            .fill(tint.opacity(0.16))
            .overlay(shape.strokeBorder(tint, lineWidth: 1.5))
            .overlay(
                Text("Drop files")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(tint)
            )
    }

    private func insertPlanCommand() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            text = "/plan "
        } else if trimmed.lowercased().hasPrefix("/plan") {
            // Already planning — just focus.
        } else {
            text = "/plan " + trimmed
        }
        focusPrompt()
        DispatchQueue.main.async {
            ComposerFieldEditor.setStringPlacingCaretAtEnd(text)
        }
        updateAutocomplete(for: text)
        onLayoutNeeded?()
    }

    private func presentAttachPanel() {
        guard attachments != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.message = "Attach files or folders to this message"
        let ws = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ws.isEmpty, resolvedConnectionID == nil {
            panel.directoryURL = URL(fileURLWithPath: ws)
        }
        guard panel.runModal() == .OK else { return }
        let existing = Set(attachments?.wrappedValue.map(\.path) ?? [])
        let imported = ComposerMediaImport.attachments(fromFileURLs: panel.urls)
            .filter { !existing.contains($0.path) }
        // Directories aren't imported by ComposerMediaImport — add as chips.
        var extras: [ComposerAttachment] = []
        for url in panel.urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            if existing.contains(url.path) { continue }
            if imported.contains(where: { $0.path == url.path }) { continue }
            extras.append(ComposerAttachment(path: url.path, ownsFile: false, isDirectory: true))
        }
        appendAttachments(imported + extras)
    }

    private func attachmentArea(_ binding: Binding<[ComposerAttachment]>) -> some View {
        // Media only — non-media files / @ refs are inline chips in the prompt.
        let media = binding.wrappedValue.filter(\.isMedia)
        return Group {
            if !media.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(media) { item in
                            ComposerAttachmentThumb(attachment: item) {
                                removeAttachment(id: item.id, from: binding)
                            }
                        }
                    }
                }
            }
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
        // Menu chrome doesn't always inherit the label's cursor tracking — assert on the Menu itself.
        .pointerCursor()
        .hoverTooltip(HoverTooltipLabel.icon("Cycle model", shortcut: "⌘/"))
        .fixedSize()
    }

    private var showShortcutPopover: Bool {
        shortcutButtonHovered || shortcutPopoverHovered
    }

    private var shortcutHints: [(key: String, label: String)] {
        if kind == .followUp {
            if isEditingQueued {
                return [
                    ("Enter", "confirm edit"),
                    ("Esc", "cancel edit"),
                    ("⇧↩", "add newline"),
                    ("⌘/", "switch model"),
                ]
            }
            if isWorking {
                return [
                    ("Enter", "queue"),
                    ("⌘↩", "steer"),
                    ("⇧↩", "add newline"),
                    ("⌃C", "stop"),
                    ("⌘/", "switch model"),
                ]
            }
            return [
                ("@", "files"),
                ("/", "skills"),
                ("Enter", "send"),
                ("⌘↩", "send (steer)"),
                ("⇧↩", "add newline"),
                ("⌘V", "paste file"),
                ("⌘L", "add selection"),
                ("⇧⌘L", "selection → new"),
                ("⌘/", "switch model"),
            ]
        }
        return [
            ("Enter", "send to agent"),
            ("⌘↩", "send"),
            ("⇧↩", "add newline"),
            ("Tab / ⇧Tab", "indent / outdent"),
            ("Esc", "cancel"),
        ]
    }

    private var shortcutsButton: some View {
        HStack(spacing: 3) {
            Image(systemName: "keyboard")
                .font(.system(size: 12, weight: .medium))
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(Color.primary.opacity(0.78))
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityLabel("Shortcuts")
        .pointerCursor()
        .onHover { hovering in
            shortcutDismissWork?.cancel()
            if hovering {
                shortcutButtonHovered = true
            } else {
                scheduleShortcutDismissFromButton()
            }
        }
        .popover(isPresented: shortcutPopoverBinding, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(shortcutHints.enumerated()), id: \.offset) { _, hint in
                    HStack(spacing: 10) {
                        Text(hint.key)
                            .font(.system(size: 11, weight: .semibold).monospaced())
                            .foregroundStyle(Color.primary.opacity(0.85))
                            .frame(minWidth: 52, alignment: .leading)
                        Text(hint.label)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.primary.opacity(0.6))
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minWidth: 180)
            .onHover { hovering in
                shortcutDismissWork?.cancel()
                shortcutPopoverHovered = hovering
                if !hovering {
                    scheduleShortcutDismissFromPopover()
                }
            }
        }
    }

    private var shortcutPopoverBinding: Binding<Bool> {
        Binding(
            get: { showShortcutPopover },
            set: { presented in
                if !presented {
                    shortcutButtonHovered = false
                    shortcutPopoverHovered = false
                }
            }
        )
    }

    private func scheduleShortcutDismissFromButton() {
        let work = DispatchWorkItem {
            shortcutButtonHovered = false
        }
        shortcutDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func scheduleShortcutDismissFromPopover() {
        let work = DispatchWorkItem {
            shortcutPopoverHovered = false
        }
        shortcutDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func handleSubmit() {
        // Keep Enter inside the @ / skill pickers (don't send the draft).
        if fileAC.isActive {
            if !fileAC.matches.isEmpty {
                applySelectedFile()
            }
            return
        }
        if skillAC.isActive {
            applySelectedSkill()
            return
        }
        if isEditingQueued {
            guard canSend else { return }
            onConfirmEdit?()
            return
        }
        if isWorking, let onQueue, !hasAttachments {
            onQueue()
        } else {
            guard canSend else { return }
            onSend()
        }
    }

    private func applySkill(_ skill: AgentSkill) {
        // Defer — mutating @Published / tearing down SkillSuggestionList's ScrollView
        // inside the Button action crashes SwiftUI Observation (EXC_BAD_ACCESS).
        DispatchQueue.main.async {
            var next = self.text
            self.skillAC.apply(skill, to: &next)
            self.text = next
            self.focused = true
            ComposerFieldEditor.setStringPlacingCaretAtEnd(next)
            self.onLayoutNeeded?()
        }
    }

    private func applySelectedSkill() {
        guard skillAC.matches.indices.contains(skillAC.selectedIndex) else { return }
        applySkill(skillAC.matches[skillAC.selectedIndex])
    }

    private func applyFile(_ entry: WorkspaceFileEntry) {
        // Same deferral as skills — avoid tearing down FileSuggestionList mid-click.
        DispatchQueue.main.async {
            self.replaceAtQuery(withChipFor: entry)
            self.onLayoutNeeded?()
        }
    }

    private func applySelectedFile() {
        guard fileAC.matches.indices.contains(fileAC.selectedIndex) else { return }
        applyFile(fileAC.matches[fileAC.selectedIndex])
    }

    private func absolutePath(for entry: WorkspaceFileEntry) -> String {
        if entry.path.hasPrefix("/") { return entry.path }
        let ws = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ws.isEmpty else { return entry.path }
        return (ws as NSString).appendingPathComponent(entry.path)
    }

    /// Swap the active `@…` token for an inline chip in one draft update (avoids wipe races).
    private func replaceAtQuery(withChipFor entry: WorkspaceFileEntry) {
        // Dismiss before mutating text so onChange / index refresh can't reopen the list.
        fileAC.clear()
        var next = text
        let token = ComposerFileChipToken.serialize(
            path: absolutePath(for: entry),
            isDirectory: entry.isDirectory
        )
        if let range = WorkspaceFileCatalog.atQuery(in: next)?.range {
            next.replaceSubrange(range, with: token + " ")
        } else {
            appendChipToken(token, to: &next)
        }
        text = next
        fileAC.clear()
        focused = true
        ComposerFieldEditor.setStringPlacingCaretAtEnd(next)
    }

    private func appendInlineFileChipToken(path: String, isDirectory: Bool) {
        var next = text
        let token = ComposerFileChipToken.serialize(path: path, isDirectory: isDirectory)
        appendChipToken(token, to: &next)
        text = next
        focused = true
    }

    private func appendChipToken(_ token: String, to text: inout String) {
        if text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") {
            text += token + " "
        } else {
            text += " " + token + " "
        }
    }

    private func insertInlineFileChip(path: String, isDirectory: Bool) {
        // Live caret insert (Attach / drop). Falls back to draft token append.
        if ComposerFieldEditor.insertFileChip(path: path, isDirectory: isDirectory) {
            focused = true
            return
        }
        appendInlineFileChipToken(path: path, isDirectory: isDirectory)
    }

    private func removeAttachment(id: UUID, from binding: Binding<[ComposerAttachment]>) {
        guard let item = binding.wrappedValue.first(where: { $0.id == id }) else { return }
        binding.wrappedValue.removeAll { $0.id == id }
        ComposerMediaImport.discard([item])
        onLayoutNeeded?()
    }

    private func appendAttachments(_ items: [ComposerAttachment]) {
        guard let attachments, !items.isEmpty else { return }
        let media = items.filter(\.isMedia)
        let files = items.filter { !$0.isMedia }
        if !media.isEmpty {
            attachments.wrappedValue.append(contentsOf: media)
        }
        for file in files {
            insertInlineFileChip(path: file.path, isDirectory: file.isDirectory)
        }
        focused = true
        onLayoutNeeded?()
    }

    @discardableResult
    private func handleFileDrop() -> Bool {
        guard attachments != nil else { return false }
        let imported = ComposerMediaImport.attachmentsFromDragPasteboard()
        guard !imported.isEmpty else { return false }
        appendAttachments(imported)
        return true
    }

    /// True when the pasteboard had attachable media and it was appended.
    @discardableResult
    private func pasteMediaFromClipboard() -> Bool {
        guard attachments != nil,
              let imported = ComposerMediaImport.attachmentsFromPasteboard(),
              !imported.isEmpty else { return false }
        appendAttachments(imported)
        return true
    }

    private func syncKeyBridge() {
        keyBridge.isEditingQueued = isEditingQueued
        keyBridge.plusMenuOpen = plusMenuOpen
        keyBridge.focused = focused
        keyBridge.onCancelEdit = onCancelEdit
        keyBridge.onDismissPlusMenu = { plusMenuOpen = false }
        keyBridge.pasteMedia = { [self] in pasteMediaFromClipboard() }
        keyBridge.onCommandHeld = { held in
            if commandHeld != held {
                commandHeld = held
            }
        }
    }

    /// ⌘V media paste (backup when the prompt isn't first responder) + Esc dismiss
    /// for the + menu / queue edit (Return owned by the prompt editor).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let bridge = keyBridge
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let code = Int(event.keyCode)

            if code == kVK_Escape,
               flags.isEmpty || flags == .function {
                if bridge.plusMenuOpen {
                    bridge.onDismissPlusMenu?()
                    return nil
                }
                if bridge.isEditingQueued {
                    bridge.onCancelEdit?()
                    return nil
                }
            }

            // Prompt first-responder paste: is handled in ComposerPromptTextView.paste.
            // This path covers ⌘V while the SoftChrome chrome / strip has focus.
            let promptActive = bridge.focused
                || (ComposerFieldEditor.editableTextView() as? ComposerPromptTextView) != nil
            if promptActive,
               code == kVK_ANSI_V,
               flags.contains(.command),
               !flags.contains(.shift),
               !flags.contains(.option),
               !flags.contains(.control),
               bridge.pasteMedia?() == true {
                return nil
            }

            // Return / ⇧↩ / ⌘↩ are owned by ComposerPromptEditor.doCommandBy
            // (chat map: Enter submit, ⇧↩ structure, ⌘↩ send/steer).
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func installFlagsMonitor() {
        guard flagsMonitor == nil else { return }
        let bridge = keyBridge
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let cmd = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
            bridge.onCommandHeld?(cmd)
            return event
        }
        refreshCommandHeld()
    }

    private func removeFlagsMonitor() {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
        }
        flagsMonitor = nil
        commandHeld = false
    }

    private func refreshCommandHeld() {
        let cmd = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        commandHeld = cmd
    }

    private func installPlusMenuMouseMonitor() {
        guard plusMenuMouseMonitor == nil else { return }
        plusMenuMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            // Skip the click that opened the menu; any later click dismisses
            // (menu rows close it themselves before this runs meaningfully).
            DispatchQueue.main.async {
                if ignoreNextPlusMenuDismiss {
                    ignoreNextPlusMenuDismiss = false
                    return
                }
                if plusMenuOpen {
                    plusMenuOpen = false
                }
            }
            return event
        }
    }

    private func removePlusMenuMouseMonitor() {
        if let plusMenuMouseMonitor {
            NSEvent.removeMonitor(plusMenuMouseMonitor)
        }
        plusMenuMouseMonitor = nil
        ignoreNextPlusMenuDismiss = false
    }

    static func editableTextView() -> NSTextView? {
        ComposerFieldEditor.editableTextView()
    }
}

enum ComposerFieldEditor {
    private static weak var registeredPrompt: ComposerPromptTextView?

    static func register(_ textView: ComposerPromptTextView?) {
        registeredPrompt = textView
    }

    static func unregister(_ textView: ComposerPromptTextView) {
        if registeredPrompt === textView {
            registeredPrompt = nil
        }
    }

    /// Insert a Cursor-style inline file/folder chip at the caret.
    @discardableResult
    static func insertFileChip(path: String, isDirectory: Bool) -> Bool {
        guard let textView = registeredPrompt,
              let parent = textView.parent else { return false }
        parent.insertFileChip(path: path, isDirectory: isDirectory)
        return true
    }

    static func editableTextView() -> NSTextView? {
        if let registeredPrompt, registeredPrompt.window != nil {
            return registeredPrompt
        }
        let window = NSApp.keyWindow
        let responder = window?.firstResponder
        if let textView = responder as? ComposerPromptTextView {
            return textView
        }
        if let textView = responder as? NSTextView, textView.isEditable, textView.isFieldEditor {
            return textView
        }
        if let field = responder as? NSTextField,
           let editor = field.currentEditor() as? NSTextView,
           editor.isEditable {
            return editor
        }
        if let editor = window?.fieldEditor(false, for: nil) as? NSTextView, editor.isEditable {
            return editor
        }
        if let root = window?.contentView, let found = findEditableTextView(in: root) {
            return found
        }
        return nil
    }

    /// Put the caret in the registered prompt (retries past list-click first-responder races).
    static func focus(attemptsRemaining: Int = 8) {
        DispatchQueue.main.async {
            let ok = makePromptFirstResponder()
            guard attemptsRemaining > 0 else { return }
            if !ok {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    focus(attemptsRemaining: attemptsRemaining - 1)
                }
            } else if attemptsRemaining > 4 {
                // Re-assert after mouse-up / SwiftUI button focus settles.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    _ = makePromptFirstResponder()
                }
            }
        }
    }

    @discardableResult
    static func makePromptFirstResponder() -> Bool {
        guard let textView = editableTextView() as? ComposerPromptTextView
                ?? registeredPrompt,
              let window = textView.window ?? NSApp.keyWindow else {
            return false
        }
        if window.firstResponder === textView { return true }
        return window.makeFirstResponder(textView)
    }

    /// Sync the live prompt editor to `string` and leave an empty caret at the end.
    /// Uses chip-aware apply so `⟦file:…⟧` / `⟦skill:…⟧` stay as attachments.
    static func setStringPlacingCaretAtEnd(_ string: String) {
        placeCaretAtEnd(of: string, attemptsRemaining: 10)
    }

    private static func placeCaretAtEnd(of string: String, attemptsRemaining: Int) {
        let apply: () -> Bool = {
            guard let textView = editableTextView() else { return false }
            if let prompt = textView as? ComposerPromptTextView,
               let coordinator = prompt.parent {
                let current = textView.textStorage.map { ComposerFileChipCodec.serialize($0) }
                    ?? textView.string
                if current != string {
                    coordinator.applyText(string, force: true)
                }
            } else if textView.string != string {
                textView.string = string
                if let storage = textView.textStorage {
                    ComposerMarkdownStyler.apply(to: storage, darkChrome: nil)
                }
            }
            let end = textView.textStorage?.length ?? (textView.string as NSString).length
            let caret = NSRange(location: end, length: 0)
            textView.setSelectedRange(caret)
            textView.scrollRangeToVisible(caret)
            return textView.selectedRange().length == 0
                && textView.selectedRange().location == end
        }

        DispatchQueue.main.async {
            let ok = apply()
            guard attemptsRemaining > 0 else { return }
            if ok {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                    _ = apply()
                    if attemptsRemaining > 1 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                            _ = apply()
                        }
                    }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    placeCaretAtEnd(of: string, attemptsRemaining: attemptsRemaining - 1)
                }
            }
        }
    }

    private static func findEditableTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? ComposerPromptTextView { return textView }
        if let textView = view as? NSTextView, textView.isEditable, textView.isFieldEditor {
            return textView
        }
        for sub in view.subviews {
            if let found = findEditableTextView(in: sub) { return found }
        }
        return nil
    }
}

/// Send vs steer glyph for the follow-up composer action button.
enum ComposerSendButtonIcon {
    static func systemName(isFollowUp: Bool, commandHeld: Bool, promptFocused: Bool) -> String {
        if isFollowUp, commandHeld, promptFocused {
            return "steeringwheel.circle.fill"
        }
        return "arrow.up.circle.fill"
    }
}

/// Mutable bag for the composer’s local key monitor (View structs capture stale values).
private final class ComposerKeyBridge {
    var isEditingQueued = false
    var plusMenuOpen = false
    var focused = false
    var onCancelEdit: (() -> Void)?
    var onDismissPlusMenu: (() -> Void)?
    var pasteMedia: (() -> Bool)?
    var onCommandHeld: ((Bool) -> Void)?
}

/// Cursor-style secondary “Editing” chip: slate fill, blue label, grey ✕ that lightens on hover.
private struct EditingQueuedBadge: View {
    var onCancel: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var xHovered = false

    private var labelBlue: Color {
        colorScheme == .dark
            ? Color(red: 0.35, green: 0.62, blue: 0.95)
            : Color(red: 0.15, green: 0.45, blue: 0.85)
    }

    private var slateFill: Color {
        colorScheme == .dark
            ? Color(red: 0.16, green: 0.20, blue: 0.27)
            : Color(red: 0.88, green: 0.91, blue: 0.96)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil")
                .font(.system(size: 10, weight: .semibold))
            Text("Editing")
                .font(.system(size: 12, weight: .semibold))
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(
                        xHovered
                            ? Color.primary.opacity(0.92)
                            : Color.primary.opacity(0.42)
                    )
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pointerPlain)
            .hoverTooltip(HoverTooltipLabel.icon("Cancel edit", shortcut: "Esc"))
            .onHover { xHovered = $0 }
        }
        .foregroundStyle(labelBlue)
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(slateFill)
        )
        .fixedSize()
    }
}

/// Square top + rounded bottom — matches the sessions chat card’s lower corners.
struct ComposerDropChromeShape: Shape, InsettableShape {
    var bottomRadius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let radius = max(0, min(bottomRadius - insetAmount, r.width / 2, r.height / 2))
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        if radius > 0 {
            path.addArc(
                center: CGPoint(x: r.maxX - radius, y: r.maxY - radius),
                radius: radius,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
        } else {
            path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        }
        path.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        if radius > 0 {
            path.addArc(
                center: CGPoint(x: r.minX + radius, y: r.maxY - radius),
                radius: radius,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
        } else {
            path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        }
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// Lifecycle hook that installs a window-wide file-drag monitor so “Drop files” lights up
/// as soon as a drag enters the window — not only when the pointer is over the composer.
/// Drops still only attach when released over the SoftChrome band (the anchor’s frame).
private struct ComposerMediaDragCatcher: NSViewRepresentable {
    @Binding var isTargeted: Bool
    var onDrop: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isTargeted: $isTargeted, onDrop: onDrop)
    }

    func makeNSView(context: Context) -> ComposerMediaDragCatcherAnchor {
        let view = ComposerMediaDragCatcherAnchor()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ComposerMediaDragCatcherAnchor, context: Context) {
        context.coordinator.isTargeted = $isTargeted
        context.coordinator.onDrop = onDrop
        nsView.coordinator = context.coordinator
        nsView.ensureWindowMonitor()
    }

    final class Coordinator {
        var isTargeted: Binding<Bool>
        var onDrop: () -> Bool
        /// SoftChrome band — drops outside this view are ignored.
        weak var dropZone: NSView?

        init(isTargeted: Binding<Bool>, onDrop: @escaping () -> Bool) {
            self.isTargeted = isTargeted
            self.onDrop = onDrop
        }

        var supportsDrag: Bool {
            ComposerMediaImport.dragHasFiles()
        }

        func setTargeted(_ value: Bool) {
            DispatchQueue.main.async {
                if self.isTargeted.wrappedValue != value {
                    self.isTargeted.wrappedValue = value
                }
            }
        }

        /// `draggingLocation` is in the base window’s coordinate space.
        func isDropInsideComposer(_ sender: NSDraggingInfo) -> Bool {
            guard let zone = dropZone else { return false }
            // Use the SoftChrome host only when the representable collapsed to ~zero;
            // otherwise hit-test the anchor so transcript drops above the band miss.
            let target: NSView = (zone.bounds.width > 1 && zone.bounds.height > 1)
                ? zone
                : (zone.superview ?? zone)
            let point = target.convert(sender.draggingLocation, from: nil)
            return target.bounds.insetBy(dx: -2, dy: -2).contains(point)
        }
    }
}

private enum ComposerDragTypes {
    static let all: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .png,
        .tiff,
        NSPasteboard.PasteboardType(UTType.image.identifier),
        NSPasteboard.PasteboardType(UTType.movie.identifier),
        NSPasteboard.PasteboardType(UTType.video.identifier),
    ]
}

/// Zero-hit anchor hosted in the composer; owns the window-covering monitor.
private final class ComposerMediaDragCatcherAnchor: NSView {
    weak var coordinator: ComposerMediaDragCatcher.Coordinator?
    private weak var monitor: ComposerWindowFileDragMonitor?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ensureWindowMonitor()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            tearDownMonitor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func removeFromSuperview() {
        tearDownMonitor()
        super.removeFromSuperview()
    }

    func ensureWindowMonitor() {
        coordinator?.dropZone = self
        guard let content = window?.contentView else {
            tearDownMonitor()
            return
        }
        if let monitor, monitor.superview === content {
            monitor.coordinator = coordinator
            content.addSubview(monitor, positioned: .above, relativeTo: nil)
            monitor.frame = content.bounds
            return
        }
        tearDownMonitor()
        let monitor = ComposerWindowFileDragMonitor(frame: content.bounds)
        monitor.autoresizingMask = [.width, .height]
        monitor.coordinator = coordinator
        content.addSubview(monitor, positioned: .above, relativeTo: nil)
        self.monitor = monitor
    }

    private func tearDownMonitor() {
        monitor?.coordinator = nil
        monitor?.removeFromSuperview()
        monitor = nil
        coordinator?.setTargeted(false)
    }
}

/// Covers the window content view; claims hits only during a live file drag so
/// normal clicks still reach SwiftUI. Highlights the composer for any in-window file drag.
private final class ComposerWindowFileDragMonitor: NSView {
    weak var coordinator: ComposerMediaDragCatcher.Coordinator?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(ComposerDragTypes.all)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `NSPasteboard(name: .drag)` keeps the last drop’s URLs after the drag ends,
    /// so pasteboard-alone checks would leave this view eating every click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), isLiveFileDrag else { return nil }
        return self
    }

    private var isLiveFileDrag: Bool {
        guard NSEvent.pressedMouseButtons != 0 else { return false }
        guard let type = NSApp.currentEvent?.type else { return false }
        switch type {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            break
        default:
            return false
        }
        return coordinator?.supportsDrag == true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard coordinator?.supportsDrag == true else {
            coordinator?.setTargeted(false)
            return []
        }
        coordinator?.setTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard coordinator?.supportsDrag == true else {
            coordinator?.setTargeted(false)
            return []
        }
        coordinator?.setTargeted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        coordinator?.setTargeted(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard coordinator?.supportsDrag == true else { return false }
        // Highlight is window-wide; accept only over the SoftChrome band.
        return coordinator?.isDropInsideComposer(sender) == true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        coordinator?.setTargeted(false)
        guard coordinator?.isDropInsideComposer(sender) == true else { return false }
        return coordinator?.onDrop() ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        coordinator?.setTargeted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        coordinator?.setTargeted(false)
    }
}

// MARK: - Inline file chips

private struct FlowFileChips: View {
    let items: [ComposerAttachment]
    var onRemove: (UUID) -> Void

    var body: some View {
        // Simple wrapping row — enough for a handful of chips without a layout engine.
        FlexibleChipWrap(spacing: 6) {
            ForEach(items) { item in
                ComposerFileChip(attachment: item) {
                    onRemove(item.id)
                }
            }
        }
    }
}

/// Left-to-right wrap layout for file chips.
private struct FlexibleChipWrap: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var height: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            height = max(height, y + rowHeight)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct ComposerFileChip: View {
    let attachment: ComposerAttachment
    var onRemove: () -> Void

    @State private var hovering = false

    private let chipBlue = Color(red: 0.45, green: 0.72, blue: 1.0)

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: attachment.isDirectory ? "folder" : "doc")
                .font(.system(size: 11, weight: .medium))
            Text(attachment.fileName)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(chipBlue.opacity(0.9))
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Color.primary.opacity(0.10)))
                }
                .buttonStyle(.pointerPlain)
                .hoverTooltip(HoverTooltipLabel.icon("Remove"))
            }
        }
        .foregroundStyle(chipBlue)
        .padding(.leading, 8)
        .padding(.trailing, hovering ? 5 : 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(chipBlue.opacity(0.22), lineWidth: 1)
        )
        .hoverTooltip(attachment.path)
        .onHover { hovering = $0 }
    }
}

// MARK: - Attachment thumb

private struct ComposerAttachmentThumb: View {
    let attachment: ComposerAttachment
    var onRemove: () -> Void

    @State private var hovering = false
    @State private var image: NSImage?

    private let size: CGFloat = 64

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: openPreview) {
                ZStack {
                    Group {
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Color.primary.opacity(0.08)
                            Image(systemName: attachment.isVideo ? "video.fill" : "photo")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.45))
                        }
                    }
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                    )

                    if attachment.isVideo {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 18))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.black.opacity(0.45))
                    }
                }
            }
            // Not `.pointerPlain` — that installs a hand cursor that fights the magnifier.
            .buttonStyle(.plain)
            .previewCursor()
            .hoverTooltip(HoverTooltipLabel.icon(attachment.isVideo ? "Play" : "Preview"))

            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.black.opacity(0.72)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.pointerPlain)
                .offset(x: 5, y: -5)
                .hoverTooltip(HoverTooltipLabel.icon("Remove"))
            }
        }
        .frame(width: size, height: size)
        .padding(.trailing, 4)
        .padding(.top, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onAppear { loadPreview() }
    }

    private func openPreview() {
        ChatImageActions.open(path: attachment.path)
    }

    private func loadPreview() {
        let path = attachment.path
        DispatchQueue.global(qos: .userInitiated).async {
            let preview: NSImage?
            if attachment.isVideo {
                preview = RegionRecorder.posterImage(for: URL(fileURLWithPath: path))
            } else {
                preview = NSImage(contentsOfFile: path)
            }
            DispatchQueue.main.async {
                image = preview
            }
        }
    }
}
