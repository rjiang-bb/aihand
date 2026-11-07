import AppKit
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

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 132),
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

        let host = NSHostingView(rootView: AnnotatePromptView(model: model))
        hosting = host
        panel.contentView = host
    }

    func show(
        on screen: NSScreen,
        near screenBounds: CGRect? = nil,
        workspaceMissing: Bool,
        requirePrompt: Bool = false
    ) {
        model.text = ""
        model.workspaceMissing = workspaceMissing
        model.requirePrompt = requirePrompt
        let kind = Preferences.agentCLI
        model.agentSummary = "\(kind.title) · \(kind.defaultModelTitle)"
        model.focusTick += 1

        let margin: CGFloat = 12
        let size = panel.frame.size
        let visible = screen.visibleFrame
        var origin: CGPoint
        if let screenBounds {
            origin = CGPoint(
                x: screenBounds.midX - size.width / 2,
                y: screenBounds.minY - size.height - margin
            )
            if origin.y < visible.minY + margin {
                origin.y = min(screenBounds.maxY + margin, visible.maxY - size.height - margin)
            }
        } else {
            origin = CGPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + 72
            )
        }
        origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
        origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)

        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        onOpenChanged?(true)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        onOpenChanged?(false)
    }

    private func submit(_ text: String) {
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
}

final class AnnotatePromptModel: ObservableObject {
    @Published var text = ""
    @Published var workspaceMissing = false
    @Published var requirePrompt = false
    @Published var agentSummary = ""
    @Published var focusTick = 0
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    var canSubmit: Bool {
        guard !workspaceMissing else { return false }
        if requirePrompt {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }
}

private struct AnnotatePromptView: View {
    @ObservedObject var model: AnnotatePromptModel
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var solidBG: Color { colorScheme == .dark ? .black : .white }
    private var fieldFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.05)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Ask the agent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer(minLength: 8)
                if !model.agentSummary.isEmpty {
                    Text(model.agentSummary)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            TextField(model.requirePrompt ? "Prompt…" : "Optional prompt…", text: $model.text, axis: .vertical)
                .font(.system(size: 14))
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(minHeight: 52, maxHeight: 72, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fieldFill))
                .onChange(of: model.focusTick) { _ in
                    focused = true
                }
            HStack {
                if model.workspaceMissing {
                    Text("Set an agent workspace in Settings")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                } else {
                    Text("⌘↩ to send · Esc to close")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Send") {
                    guard model.canSubmit else { return }
                    model.onSubmit?(model.text)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!model.canSubmit)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(14)
        .frame(width: 360)
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
