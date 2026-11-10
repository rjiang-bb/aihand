import AppKit
import SwiftUI

/// Cursor/Codex-style multiline prompt: owned `NSTextView` with live markdown highlighting.
struct ComposerPromptEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    @Binding var height: CGFloat
    var placeholder: String
    var onSubmit: () -> Void
    var onHeightChange: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> ComposerPromptScrollView {
        let scroll = ComposerPromptScrollView()
        let textView = ComposerPromptTextView()
        textView.delegate = context.coordinator
        textView.parent = context.coordinator
        textView.placeholderString = placeholder

        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.documentView = textView
        // Don't let AppKit stretch the document to the clip view's height.
        scroll.contentView.postsBoundsChangedNotifications = true

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: 200,
            height: CGFloat.greatestFiniteMagnitude
        )

        context.coordinator.textView = textView
        context.coordinator.scrollView = scroll
        context.coordinator.applyText(text, force: true)
        ComposerFieldEditor.register(textView)

        DispatchQueue.main.async {
            context.coordinator.syncFocus(focused)
            context.coordinator.recalculateHeight(force: true)
        }
        return scroll
    }

    func updateNSView(_ scroll: ComposerPromptScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.placeholderString = placeholder
        ComposerFieldEditor.register(textView)

        let width = max(scroll.contentSize.width, scroll.bounds.width)
        if width > 1 {
            textView.textContainer?.containerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
        }

        if textView.string != text {
            context.coordinator.applyText(text, force: false)
        }
        context.coordinator.syncFocus(focused)
        context.coordinator.recalculateHeight(force: false)
    }

    static func dismantleNSView(_ nsView: ComposerPromptScrollView, coordinator: Coordinator) {
        if let textView = coordinator.textView {
            ComposerFieldEditor.unregister(textView)
        }
        coordinator.textView = nil
        coordinator.scrollView = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerPromptEditor
        weak var textView: ComposerPromptTextView?
        weak var scrollView: ComposerPromptScrollView?
        private var applying = false

        init(_ parent: ComposerPromptEditor) {
            self.parent = parent
        }

        func applyText(_ string: String, force: Bool) {
            guard let textView else { return }
            if !force, textView.string == string { return }
            applying = true
            defer { applying = false }

            let selected = textView.selectedRange()
            textView.string = string
            restyleKeepingSelection(selected: selected)
            recalculateHeight(force: true)
        }

        func restyleKeepingSelection(selected: NSRange? = nil) {
            guard let textView, let storage = textView.textStorage else { return }
            let sel = selected ?? textView.selectedRange()
            applying = true
            ComposerMarkdownStyler.normalizeListMarkers(in: storage)
            ComposerMarkdownStyler.apply(to: storage)
            let next = storage.string
            if parent.text != next {
                parent.text = next
            }
            applying = false
            // Don't inherit clear/tiny marker attrs into the next keystroke.
            textView.typingAttributes = ComposerMarkdownStyler.typingAttributes()
            let end = storage.length
            let clamped = NSRange(
                location: min(sel.location, end),
                length: min(sel.length, max(0, end - min(sel.location, end)))
            )
            textView.setSelectedRange(clamped)
            textView.needsDisplay = true
        }

        func syncFocus(_ shouldFocus: Bool) {
            guard shouldFocus, let textView else { return }
            if textView.window?.firstResponder === textView { return }
            DispatchQueue.main.async {
                _ = ComposerFieldEditor.makePromptFirstResponder()
            }
        }

        func recalculateHeight(force: Bool) {
            guard let textView, let scrollView else { return }
            let width = max(scrollView.contentSize.width, scrollView.bounds.width, textView.bounds.width)
            if width > 1 {
                textView.textContainer?.containerSize = NSSize(
                    width: width,
                    height: CGFloat.greatestFiniteMagnitude
                )
            }

            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            var used = layoutManager.usedRect(for: container).height
            // Before first real layout (width ~0) usedRect can be nonsense — stay one line.
            if width < 8 {
                used = 0
            }

            let inset = textView.textContainerInset
            let line = ceil((textView.font ?? .systemFont(ofSize: 14.5)).ascender
                - (textView.font ?? .systemFont(ofSize: 14.5)).descender + 2)
            let minH = line + inset.height * 2
            let maxH = line * 12 + inset.height * 2
            let contentH = max(minH, ceil(used + inset.height * 2))
            let height = min(contentH, maxH)
            scrollView.hasVerticalScroller = contentH > maxH + 0.5
            scrollView.preferredHeight = height

            if force || abs(height - parent.height) > 0.5 {
                parent.height = height
                scrollView.invalidateIntrinsicContentSize()
                parent.onHeightChange?()
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !applying, let textView else { return }
            restyleKeepingSelection()
            if parent.text != textView.string {
                parent.text = textView.string
            }
            recalculateHeight(force: true)
        }

        func textDidBeginEditing(_ notification: Notification) {
            if !parent.focused {
                parent.focused = true
            }
            ComposerFieldEditor.register(textView)
        }

        func textDidEndEditing(_ notification: Notification) {
            if parent.focused {
                parent.focused = false
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
                if flags.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.insertLineBreak(_:)) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            return false
        }
    }
}

final class ComposerPromptScrollView: NSScrollView {
    var preferredHeight: CGFloat = 22

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight)
    }

    override func layout() {
        super.layout()
        if let textView = documentView as? ComposerPromptTextView {
            let width = max(contentSize.width, bounds.width)
            if width > 1 {
                textView.textContainer?.containerSize = NSSize(
                    width: width,
                    height: CGFloat.greatestFiniteMagnitude
                )
            }
        }
    }
}

final class ComposerPromptTextView: NSTextView {
    weak var parent: ComposerPromptEditor.Coordinator?
    var placeholderString: String = "" {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        commonInit()
    }

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(
            width: max(frameRect.width, 100),
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: frameRect, textContainer: container)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isRichText = true
        allowsUndo = true
        isEditable = true
        isSelectable = true
        drawsBackground = false
        backgroundColor = .clear
        textColor = .labelColor
        insertionPointColor = .labelColor
        font = .systemFont(ofSize: 14.5)
        textContainerInset = NSSize(width: 0, height: 1)
        textContainer?.lineFragmentPadding = 0
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        enabledTextCheckingTypes = 0
        if #available(macOS 15.0, *) {
            usesAdaptiveColorMappingForDarkAppearance = true
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            parent?.parent.focused = true
            ComposerFieldEditor.register(self)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            parent?.parent.focused = false
        }
        return ok
    }

    override func draw(_ dirtyRect: NSRect) {
        drawQuoteBars(in: dirtyRect)
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let inset = textContainerInset
        let rect = bounds.insetBy(dx: inset.width, dy: inset.height)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14.5),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.38),
        ]
        let size = (placeholderString as NSString).size(withAttributes: attrs)
        let drawRect = CGRect(
            x: rect.minX,
            y: rect.minY + max(0, (rect.height - size.height) / 2 - 1),
            width: rect.width,
            height: size.height
        )
        (placeholderString as NSString).draw(in: drawRect, withAttributes: attrs)
    }

    private func drawQuoteBars(in dirtyRect: NSRect) {
        guard let layoutManager, let textContainer else { return }
        let ns = string as NSString
        let quotes = ComposerMarkdownStyler.quoteLineRanges(in: ns)
        guard !quotes.isEmpty else { return }

        let origin = textContainerOrigin
        let barColor = NSColor.labelColor.withAlphaComponent(0.38)
        let width = ComposerMarkdownStyler.quoteBarWidth
        let inset = ComposerMarkdownStyler.quoteBarInset
        barColor.setFill()

        for range in quotes {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            guard rect.intersects(dirtyRect) else { continue }
            let bar = NSRect(
                x: rect.minX + inset,
                y: rect.minY + 1,
                width: width,
                height: max(rect.height - 2, 8)
            )
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        // Keep the text view height content-driven — don't fill a tall clip view.
        let width = newSize.width
        guard let layoutManager, let textContainer else {
            super.setFrameSize(newSize)
            return
        }
        textContainer.containerSize = NSSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        let line = ceil((font ?? .systemFont(ofSize: 14.5)).ascender
            - (font ?? .systemFont(ofSize: 14.5)).descender + 2)
        let h = max(used + textContainerInset.height * 2, line + textContainerInset.height * 2)
        super.setFrameSize(NSSize(width: width, height: h))
    }

    override func paste(_ sender: Any?) {
        if let plain = NSPasteboard.general.string(forType: .string) {
            insertText(plain, replacementRange: selectedRange())
            return
        }
        super.pasteAsPlainText(sender)
    }

    func restyleAfterExternalEdit() {
        parent?.restyleKeepingSelection()
        parent?.recalculateHeight(force: true)
        needsDisplay = true
    }
}
