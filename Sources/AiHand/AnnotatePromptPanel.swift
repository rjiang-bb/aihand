import AppKit
import Carbon.HIToolbox
import SwiftUI

final class AnnotatePromptPanel: NSObject, NSWindowDelegate {
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onOpenChanged: ((Bool) -> Void)?

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private let panel: Panel
    private let model = AnnotatePromptModel()
    private var hosting: NSHostingView<AnnotatePromptView>?
    private var keyMonitor: Any?
    private var lastScreen: NSScreen?
    private var lastPlacement: Placement = .bottom

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
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
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.delegate = self
        panel.isReleasedWhenClosed = false

        model.onSubmit = { [weak self] text in
            self?.submit(text)
        }
        model.onCancel = { [weak self] in
            self?.cancel()
        }
        model.onLayoutNeeded = { [weak self] in
            self?.refitContent()
        }

        let host = NSHostingView(rootView: AnnotatePromptView(model: model))
        hosting = host
        panel.contentView = host
    }

    enum Placement {
        /// Pin to the bottom-center of the screen (Sessions → New).
        case bottom
        /// Near a stroke / ink bounds when available.
        case near(CGRect)
    }

    func show(
        on screen: NSScreen,
        placement: Placement = .bottom,
        workspaceMissing: Bool,
        requirePrompt: Bool = false
    ) {
        model.text = ""
        model.workspaceMissing = workspaceMissing
        model.requirePrompt = requirePrompt
        model.reloadFavorites()
        model.focusTick += 1
        lastScreen = screen
        lastPlacement = placement

        position(on: screen, placement: placement)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        onOpenChanged?(true)
        focusPromptField()

        // SwiftUI needs a turn to apply requirePrompt / focus before fitting size is accurate.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.position(on: screen, placement: placement)
            self.panel.makeKeyAndOrderFront(nil)
            self.model.focusTick += 1
            self.focusPromptField()
        }
        // One more pass after layout settles (hosting view / field editor).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.model.focusTick += 1
            self.focusPromptField()
        }
    }

    /// Grow/shrink the floating panel when the composer adds newlines or skill suggestions.
    private func refitContent() {
        guard panel.isVisible, let screen = lastScreen ?? panel.screen ?? NSScreen.main else { return }
        position(on: screen, placement: lastPlacement)
    }

    /// Force the prompt NSTextField to become first responder (SwiftUI FocusState alone is flaky in panels).
    private func focusPromptField() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        guard let root = panel.contentView else { return }
        if let field = findPromptTextField(in: root) {
            panel.makeFirstResponder(field)
            if let editor = panel.fieldEditor(true, for: field) as? NSTextView {
                let end = (field.stringValue as NSString).length
                editor.setSelectedRange(NSRange(location: end, length: 0))
            }
            return
        }
        // Fallback: whatever SwiftUI focused via FocusState.
        if let textView = editableFieldEditor() {
            let end = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
        }
    }

    private func findPromptTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for sub in view.subviews {
            if let found = findPromptTextField(in: sub) {
                return found
            }
        }
        return nil
    }

    private func position(on screen: NSScreen, placement: Placement) {
        if let host = hosting {
            host.layoutSubtreeIfNeeded()
            let fitting = host.fittingSize
            if fitting.width > 10, fitting.height > 10 {
                panel.setContentSize(NSSize(width: max(480, fitting.width), height: fitting.height))
            }
        }

        let margin: CGFloat = 12
        let bottomPad: CGFloat = 28
        let size = panel.frame.size
        let visible = screen.visibleFrame
        var origin: CGPoint
        switch placement {
        case .bottom:
            origin = CGPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + bottomPad
            )
        case .near(let screenBounds):
            origin = CGPoint(
                x: screenBounds.midX - size.width / 2,
                y: screenBounds.minY - size.height - margin
            )
            if origin.y < visible.minY + margin {
                origin.y = min(screenBounds.maxY + margin, visible.maxY - size.height - margin)
            }
        }
        origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
        origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)
        panel.setFrameOrigin(origin)
    }

    /// Compatibility wrapper for older call sites.
    func show(
        on screen: NSScreen,
        near screenBounds: CGRect?,
        workspaceMissing: Bool,
        requirePrompt: Bool = false
    ) {
        let placement: Placement = screenBounds.map { .near($0) } ?? .bottom
        show(on: screen, placement: placement, workspaceMissing: workspaceMissing, requirePrompt: requirePrompt)
    }

    func hide() {
        guard panel.isVisible else { return }
        removeKeyMonitor()
        panel.orderOut(nil)
        onOpenChanged?(false)
    }

    func cycleFavorite() {
        model.cycleFavorite()
    }

    private func submit(_ text: String) {
        // Ensure the chosen favorite is Current before the session is created.
        if let id = model.selectedFavoriteID {
            Preferences.selectAgentFavorite(id)
        }
        hide()
        onSubmit?(text)
    }

    private func cancel() {
        hide()
        onCancel?()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Keep open; Esc / Cmd+Enter handle dismiss.
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // ⇧↩ newlines are handled by AgentComposerView (updates binding + asks us to refit).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // ⌘/ → cycle favorite models (keyCode: ⌘ makes charactersIgnoringModifiers flaky).
            if flags.contains(.command),
               !flags.contains(.shift),
               !flags.contains(.option),
               !flags.contains(.control),
               (Int(event.keyCode) == kVK_ANSI_Slash || event.charactersIgnoringModifiers == "/") {
                DispatchQueue.main.async {
                    self.model.cycleFavorite()
                }
                return nil
            }
            return event
        }
    }

    private func editableFieldEditor() -> NSTextView? {
        let responder = panel.firstResponder ?? NSApp.keyWindow?.firstResponder
        if let textView = responder as? NSTextView, textView.isEditable {
            return textView
        }
        if let field = responder as? NSTextField,
           let editor = panel.fieldEditor(false, for: field) as? NSTextView,
           editor.isEditable {
            return editor
        }
        return nil
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }
}

final class AnnotatePromptModel: ObservableObject {
    @Published var text = ""
    @Published var workspaceMissing = false
    @Published var requirePrompt = false
    @Published var cliTitle = ""
    @Published var favorites: [AgentFavorite] = []
    @Published var selectedFavoriteID: UUID?
    @Published var focusTick = 0
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onLayoutNeeded: (() -> Void)?

    var canSubmit: Bool {
        guard !workspaceMissing else { return false }
        if requirePrompt {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    var favoriteMenuTitle: String {
        let name = favorites.first(where: { $0.id == selectedFavoriteID })?.title
            ?? favorites.first?.title
            ?? "Default"
        if cliTitle.isEmpty { return name }
        return "\(cliTitle) · \(name)"
    }

    func reloadFavorites() {
        Preferences.ensureAgentFavorites()
        let kind = Preferences.agentCLI
        cliTitle = kind.title
        favorites = Preferences.favorites(for: kind)
        selectedFavoriteID = Preferences.currentAgentFavorite.id
    }

    func selectFavorite(_ fav: AgentFavorite) {
        selectedFavoriteID = fav.id
        Preferences.setCurrentAgentFavoriteID(fav.id, for: fav.cliKind)
    }

    func cycleFavorite() {
        guard !favorites.isEmpty else { return }
        let idx = favorites.firstIndex(where: { $0.id == selectedFavoriteID }) ?? -1
        selectFavorite(favorites[(idx + 1) % favorites.count])
    }
}

private struct AnnotatePromptView: View {
    @ObservedObject var model: AnnotatePromptModel
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var solidBG: Color { SoftChrome.cardFill(dark: colorScheme == .dark) }

    private var workspace: String {
        Preferences.agentWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask the agent")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            if model.workspaceMissing {
                Text("Set an agent workspace in Settings")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }

            AgentComposerView(
                kind: .initial,
                isWorking: false,
                requireNonEmpty: model.requirePrompt,
                placeholder: model.requirePrompt ? "Prompt…" : "Optional prompt…",
                text: $model.text,
                workspace: workspace,
                favorites: model.favorites,
                selectedFavoriteID: model.selectedFavoriteID,
                favoriteMenuTitle: model.favoriteMenuTitle,
                onSelectFavorite: { model.selectFavorite($0) },
                onSend: {
                    guard model.canSubmit else { return }
                    model.onSubmit?(model.text)
                },
                onLayoutNeeded: { model.onLayoutNeeded?() },
                focused: $focused
            )
            .disabled(model.workspaceMissing)
            .opacity(model.workspaceMissing ? 0.55 : 1)
            .onChange(of: model.focusTick) { _ in
                focused = true
            }
        }
        .padding(14)
        .frame(width: 480)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(solidBG)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08),
                            lineWidth: 0.5
                        )
                )
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.16), radius: 12, y: 6)
        )
        .onExitCommand {
            model.onCancel?()
        }
        .onAppear { focused = true }
    }
}
