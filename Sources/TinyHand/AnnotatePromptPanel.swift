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

    func show(near screenBounds: CGRect, on screen: NSScreen, workspaceMissing: Bool) {
        model.text = ""
        model.workspaceMissing = workspaceMissing
        model.focusTick += 1

        let margin: CGFloat = 12
        let size = panel.frame.size
        let visible = screen.visibleFrame
        var origin = CGPoint(
            x: screenBounds.midX - size.width / 2,
            y: screenBounds.minY - size.height - margin
        )
        if origin.y < visible.minY + margin {
            origin.y = min(screenBounds.maxY + margin, visible.maxY - size.height - margin)
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
    @Published var focusTick = 0
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
}

private struct AnnotatePromptView: View {
    @ObservedObject var model: AnnotatePromptModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask the agent")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            ZStack(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text("Optional prompt…")
                        .foregroundColor(Color.secondary.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                }
                TextEditor(text: $model.text)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 52, maxHeight: 72)
                    .onChange(of: model.focusTick) { _ in
                        focused = true
                    }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.55)))
            HStack {
                if model.workspaceMissing {
                    Text("Set an agent workspace in Settings")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                } else {
                    Text("⌘↩ to send · Esc to cancel")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Send") {
                    guard !model.workspaceMissing else { return }
                    model.onSubmit?(model.text)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.workspaceMissing)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(
            VisualEffect(material: .hudWindow)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .onExitCommand {
            model.onCancel?()
        }
        .onAppear { focused = true }
    }
}
