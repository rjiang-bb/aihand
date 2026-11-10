import AppKit
import SwiftUI

/// Cursor/Codex-style multiline prompt: owned `NSTextView` with live markdown highlighting.
struct ComposerPromptEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    @Binding var height: CGFloat
    var placeholder: String
    /// SoftChrome card is dark — drives attributed text colors (not `NSApp` appearance).
    var darkChrome: Bool = true
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
        scroll.clipsToBounds = true
        scroll.contentView.clipsToBounds = true
        scroll.documentView = textView
        // Don't let AppKit stretch the document to the clip view's height.
        scroll.contentView.postsBoundsChangedNotifications = true

        textView.clipsToBounds = true
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

        // Compare serialized chips — `textView.string` uses U+FFFC and never matches `⟦…⟧`.
        let current = textView.textStorage.map { ComposerFileChipCodec.serialize($0) } ?? textView.string
        if current != text {
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
            guard let textView, let storage = textView.textStorage else { return }
            let current = ComposerFileChipCodec.serialize(storage)
            if !force, current == string { return }
            applying = true
            defer { applying = false }

            let selected = textView.selectedRange()
            let typing = ComposerMarkdownStyler.typingAttributes(darkChrome: parent.darkChrome)
            let attributed = ComposerFileChipCodec.attributedString(
                from: string,
                darkChrome: parent.darkChrome,
                base: typing
            )
            storage.setAttributedString(attributed)
            // Re-sync the growth baseline: `textDidChange` decides whether to scaffold a
            // fence by comparing against it, so a stale value silently disables scaffolding.
            lastKnownLength = storage.length
            restyleKeepingSelection(selected: selected)
            // Collapse / grow on the next turn. Writing `parent.height` during
            // `updateNSView` (e.g. submit clearing a multiline draft) is often
            // dropped by SwiftUI, so the frame stayed tall until the next keystroke.
            recalculateHeightAfterLayout()
        }

        func restyleKeepingSelection(selected: NSRange? = nil) {
            guard let textView, let storage = textView.textStorage else { return }
            let sel = selected ?? textView.selectedRange()
            applying = true
            _ = ComposerFileChipCodec.sanitizeOrphans(in: storage)
            ComposerMarkdownStyler.normalizeListMarkers(in: storage)
            let caret = sel.length == 0 ? sel.location : nil
            let selection = sel.length > 0 ? sel : nil
            ComposerMarkdownStyler.apply(
                to: storage,
                darkChrome: parent.darkChrome,
                caret: caret,
                selection: selection
            )
            let next = ComposerFileChipCodec.serialize(storage)
            if parent.text != next {
                parent.text = next
            }
            applying = false
            let end = storage.length
            let clamped = NSRange(
                location: min(sel.location, end),
                length: min(sel.length, max(0, end - min(sel.location, end)))
            )
            textView.setSelectedRange(clamped)
            let typing = ComposerMarkdownStyler.typingAttributes(
                for: textView,
                darkChrome: parent.darkChrome
            )
            textView.typingAttributes = typing
            // Never assign `textView.textColor`: it rewrites the foreground color of
            // *every* run, wiping emphasis-marker dimming, quote tint, bullet color,
            // and link blue. Only the caret/typing colors need syncing here.
            textView.insertionPointColor = typing[.foregroundColor] as? NSColor
                ?? textView.insertionPointColor
            // Layout-level hide — clear/kern alone still showed ``` over the chip.
            ComposerMarkdownStyler.suppressFenceGlyphs(in: textView)
            textView.needsDisplay = true
            recalculateHeight(force: true)
        }

        /// Insert an inline file/folder chip at the caret (serialized as `⟦file:…⟧`).
        func insertFileChip(path: String, isDirectory: Bool) {
            guard let textView else { return }
            applying = true
            ComposerFileChipCodec.insertChip(
                path: path,
                isDirectory: isDirectory,
                darkChrome: parent.darkChrome,
                into: textView
            )
            applying = false
            restyleKeepingSelection()
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
                  let container = textView.textContainer,
                  let storage = textView.textStorage else { return }
            layoutManager.ensureLayout(for: container)
            ComposerMarkdownStyler.suppressFenceGlyphs(in: textView)

            let inset = textView.textContainerInset
            let line = ComposerMarkdownStyler.bodyLineHeight
            let ns = storage.string as NSString
            let fenceRanges = ComposerMarkdownStyler.fenceContentRanges(in: ns)
            // Air under a fenced chip for the painted rounded chrome (paragraph spacing
            // is already part of the fragment union — never add it a second time).
            let codeAir: CGFloat = fenceRanges.isEmpty ? 0 : ComposerMarkdownStyler.codeBlockInsetY * 2

            // Layout is the source of truth: the union of visible line fragments already
            // carries line height, paragraph spacing, and fenced chip padding.
            // A trailing empty line (⇧↩ with no text yet) has no glyphs — TextKit only
            // exposes it as `extraLineFragmentRect`, so glyph unions alone stay 1 line
            // short until the first character is typed.
            let visibleLines = max(1, countVisibleLines(in: ns))
            var used = CGFloat(visibleLines) * line
            if width >= 8, storage.length > 0 {
                let fragH = visibleContentHeight(
                    in: layoutManager,
                    characterRange: NSRange(location: 0, length: storage.length)
                )
                used = max(used, fragH)
                let extra = layoutManager.extraLineFragmentUsedRect
                if extra.height > 0.5 {
                    let bottom = max(fragH, extra.maxY)
                    used = max(used, bottom)
                }
            }

            let minH = line + inset.height * 2 + 6
            let maxH = line * 8 + inset.height * 2 + 6
            let contentH = max(minH, ceil(used + inset.height * 2 + 6 + codeAir))
            let height = min(contentH, maxH)
            let needsScroll = contentH > maxH + 0.5

            // Under the cap: no scroller at all (avoids the stub thumb when the
            // document briefly outgrows a stale short clip).
            scrollView.hasVerticalScroller = needsScroll
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            scrollView.verticalScrollElasticity = needsScroll ? .automatic : .none
            if !needsScroll {
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            scrollView.preferredHeight = height
            scrollView.invalidateIntrinsicContentSize()

            var scrollFrame = scrollView.frame
            if abs(scrollFrame.height - height) > 0.5 {
                scrollFrame.size.height = height
                scrollView.frame = scrollFrame
            }

            // Pin the document to the clip while under the cap so AppKit can't
            // keep a taller textView (which forces the weird stub scrollbar).
            var docFrame = textView.frame
            docFrame.size.width = max(width, 1)
            docFrame.size.height = needsScroll ? max(contentH, height) : height
            textView.frame = docFrame
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: needsScroll ? CGFloat.greatestFiniteMagnitude : height
            )

            if force || abs(height - parent.height) > 0.5 {
                parent.height = height
                parent.onHeightChange?()
            }
        }

        /// Visible composer lines — fence marker lines (` ``` `) are collapsed, skip them.
        private func countVisibleLines(in ns: NSString) -> Int {
            guard ns.length > 0 else { return 1 }
            var count = 0
            var loc = 0
            while loc < ns.length {
                let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
                let line = ns.substring(with: lineRange)
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.hasPrefix("```") {
                    count += 1
                }
                loc = NSMaxRange(lineRange)
            }
            // `lineRange` stops at the final `\n` — the empty caret row after it is a
            // separate line that only appears once you type (or via extraLineFragment).
            if ns.character(at: ns.length - 1) == 10 /* \n */ {
                count += 1
            }
            return max(1, count)
        }

        /// Union of non-collapsed line-fragment heights for `characterRange`.
        private func visibleContentHeight(
            in layoutManager: NSLayoutManager,
            characterRange: NSRange
        ) -> CGFloat {
            guard characterRange.length > 0 else { return 0 }
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            guard glyphs.length > 0 else { return 0 }
            var fragIndex = glyphs.location
            let fragEnd = NSMaxRange(glyphs)
            var top = CGFloat.greatestFiniteMagnitude
            var bottom: CGFloat = 0
            while fragIndex < fragEnd {
                var fragRange = NSRange(location: 0, length: 0)
                let lineFrag = layoutManager.lineFragmentRect(
                    forGlyphAt: fragIndex,
                    effectiveRange: &fragRange
                )
                if lineFrag.height > 0.5 {
                    top = min(top, lineFrag.minY)
                    bottom = max(bottom, lineFrag.maxY)
                }
                var next = NSMaxRange(fragRange)
                if next <= fragIndex {
                    next = fragIndex + 1
                }
                fragIndex = next
            }
            return bottom > top ? bottom - top : 0
        }

        /// List / fence Enter can land before TextKit finishes line-fragment layout.
        func recalculateHeightAfterLayout() {
            recalculateHeight(force: true)
            DispatchQueue.main.async { [weak self] in
                self?.recalculateHeight(force: true)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !applying, let textView else { return }
            // Codex: typing ``` scaffolds the chip. Never on a deletion — that used to
            // immediately re-create the block you were backspacing out of.
            let grew = textView.textStorage.map { $0.length > lastKnownLength } ?? false
            lastKnownLength = textView.textStorage?.length ?? 0
            var heldFence = false
            if grew {
                applying = true
                heldFence = ComposerMarkdownStyler.fenceTagIsPendingForChip(in: textView)
                _ = ComposerMarkdownStyler.scaffoldFenceIfNeeded(in: textView)
                applying = false
            }
            restyleKeepingSelection()
            // Always defer — list/fence paragraph styles need a layout pass.
            recalculateHeightAfterLayout()
            if heldFence { scheduleFenceFinalize() }
        }

        /// A ` ``` ` opener is waiting for a language tag. If typing stops, finalize the
        /// chip anyway (120ms) — plain ``` must still become a code block on its own.
        private func scheduleFenceFinalize() {
            fenceFinalizeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let textView = self.textView, !self.applying else { return }
                // Stale guard: the caret must still be sitting on the pending opener.
                // Without this, a timer armed in one draft fires after the user moved on
                // (or after send / session switch) and yanks the caret into a code body.
                guard ComposerMarkdownStyler.fenceTagIsPendingForChip(in: textView) else { return }
                self.applying = true
                let built = ComposerMarkdownStyler.scaffoldFenceIfNeeded(in: textView, force: true)
                self.applying = false
                if built { self.restyleKeepingSelection() }
            }
            fenceFinalizeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        private var fenceFinalizeWork: DispatchWorkItem?
        /// Incremented on each user-driven selection change so deferred caret re-asserts
        /// can detect that they are stale and skip mutating the selection.
        var selectionGeneration = 0

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying, let textView else { return }
            // Bumped on every user-driven caret move/selection (see `selectionGeneration`).
            selectionGeneration &+= 1
            applying = true
            let snapped = ComposerMarkdownStyler.snapCaretOffFenceMarkers(in: textView)
            // Refresh marker reveal without setSelectedRange / parent.text writes —
            // those re-enter this callback and stack-overflow (seen in crash logs).
            if let storage = textView.textStorage {
                let sel = textView.selectedRange()
                ComposerMarkdownStyler.apply(
                    to: storage,
                    darkChrome: parent.darkChrome,
                    caret: sel.length == 0 ? sel.location : nil,
                    selection: sel.length > 0 ? sel : nil
                )
                ComposerMarkdownStyler.suppressFenceGlyphs(in: textView)
                ComposerMarkdownStyler.suppressListMarkerGlyphs(in: textView)
                textView.needsDisplay = true
            }
            applying = false
            if snapped {
                recalculateHeightAfterLayout()
            }
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

        private var ignoringChipDeleteGuard = false
        /// Last observed storage length — lets a deletion be told apart from typing.
        private var lastKnownLength = 0

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedRange: NSRange,
            replacementString: String?
        ) -> Bool {
            if ignoringChipDeleteGuard { return true }
            guard let storage = textView.textStorage else { return true }
            let replacement = replacementString ?? ""
            // Selection delete that intersects a chip → drop the whole chip.
            guard replacement.isEmpty, affectedRange.length > 0 else { return true }
            let expanded = ComposerFileChipCodec.expansionForChipMutation(
                in: storage,
                range: affectedRange
            )
            guard expanded != affectedRange, expanded.length > 0 else { return true }
            ignoringChipDeleteGuard = true
            storage.replaceCharacters(in: expanded, with: "")
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: expanded.location, length: 0))
            ignoringChipDeleteGuard = false
            return false
        }

        @discardableResult
        func deleteAdjacentChip(in textView: NSTextView, forward: Bool) -> Bool {
            guard let storage = textView.textStorage else { return false }
            let sel = textView.selectedRange()
            guard sel.length == 0, storage.length > 0 else { return false }
            let idx: Int
            if forward {
                guard sel.location < storage.length else { return false }
                idx = sel.location
            } else {
                guard sel.location > 0 else { return false }
                idx = sel.location - 1
            }
            var eff = NSRange()
            let attachment = storage.attribute(.attachment, at: idx, effectiveRange: &eff)
            guard ComposerFileChipCodec.isComposerChip(attachment) else { return false }
            ignoringChipDeleteGuard = true
            if textView.shouldChangeText(in: eff, replacementString: "") {
                storage.replaceCharacters(in: eff, with: "")
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: eff.location, length: 0))
            }
            ignoringChipDeleteGuard = false
            return true
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.deleteBackward(_:))
                || commandSelector == #selector(NSResponder.deleteForward(_:)) {
                if deleteAdjacentChip(
                    in: textView,
                    forward: commandSelector == #selector(NSResponder.deleteForward(_:))
                ) {
                    return true
                }
                if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                    if ComposerMarkdownStyler.handleFenceDeleteBackward(in: textView)
                        || ComposerMarkdownStyler.handleListBackspace(in: textView) {
                        restyleKeepingSelection()
                        recalculateHeightAfterLayout()
                        return true
                    }
                }
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                if ComposerMarkdownStyler.handleFenceMoveDown(in: textView) {
                    // Sync draft without clobbering the exit caret (applyText preserves selection).
                    applying = true
                    if let storage = textView.textStorage {
                        ComposerMarkdownStyler.normalizeListMarkers(in: storage)
                        let caret = textView.selectedRange()
                        ComposerMarkdownStyler.apply(
                            to: storage,
                            darkChrome: parent.darkChrome,
                            caret: caret.length == 0 ? caret.location : nil,
                            selection: caret.length > 0 ? caret : nil
                        )
                        let next = ComposerFileChipCodec.serialize(storage)
                        if parent.text != next { parent.text = next }
                        ComposerMarkdownStyler.suppressFenceGlyphs(in: textView)
                    }
                    applying = false
                    let caret = textView.selectedRange()
                    textView.setSelectedRange(caret)
                    textView.scrollRangeToVisible(caret)
                    textView.typingAttributes = ComposerMarkdownStyler.typingAttributes(
                        darkChrome: parent.darkChrome
                    )
                    recalculateHeightAfterLayout()
                    // Height growth can leave the exit line clipped, so re-assert the caret
                    // on the next runloop turn — but only if the user hasn't moved it since
                    // (a later ↓/click/⇧↩ must win; a stale re-assert used to yank the
                    // caret back into the code body mid-edit).
                    let generation = selectionGeneration
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let tv = self.textView else { return }
                        guard self.selectionGeneration == generation else { return }
                        tv.setSelectedRange(caret)
                        tv.scrollRangeToVisible(caret)
                        self.recalculateHeight(force: true)
                    }
                    return true
                }
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                if ComposerMarkdownStyler.handleListIndent(in: textView)
                    || ComposerMarkdownStyler.handleTabIndentFallback(in: textView) {
                    restyleKeepingSelection()
                    recalculateHeightAfterLayout()
                    return true
                }
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                if ComposerMarkdownStyler.handleListOutdent(in: textView)
                    || ComposerMarkdownStyler.handleTabOutdentFallback(in: textView) {
                    restyleKeepingSelection()
                    recalculateHeightAfterLayout()
                    return true
                }
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
                // ⌘↩ → Send / Steer only (never list / fence).
                if flags.contains(.command) {
                    return false
                }
                // ⇧↩ → fence newline / list continue / soft break.
                if flags.contains(.shift) {
                    _ = ComposerMarkdownStyler.handleShiftReturn(in: textView)
                    restyleKeepingSelection()
                    recalculateHeightAfterLayout()
                    return true
                }
                // Plain Enter always submits — even inside fences / lists.
                parent.onSubmit()
                // Submit clears the binding synchronously; apply it now so the
                // field collapses immediately instead of waiting for updateNSView
                // (which used to leave a multiline-tall empty "Follow up…" box).
                if parent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !(textView.string.isEmpty) {
                    applyText("", force: true)
                } else if parent.text.isEmpty {
                    recalculateHeightAfterLayout()
                }
                return true
            }
            if commandSelector == #selector(NSResponder.insertLineBreak(_:)) {
                // Soft break path (⌥↩ / some IMEs) — same as ⇧↩.
                _ = ComposerMarkdownStyler.handleShiftReturn(in: textView)
                restyleKeepingSelection()
                recalculateHeightAfterLayout()
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
        // System text-check / completion overlays tint typed words (pink/red runs in code blocks).
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        if #available(macOS 14.0, *) {
            inlinePredictionType = .no
        }
        if #available(macOS 15.0, *) {
            writingToolsBehavior = .none
            mathExpressionCompletionType = .no
        }
        // SoftChrome isn’t system textBackgroundColor — adaptive remapping made
        // attributed code runs (fg + chip bg) unreadable.
        if #available(macOS 15.0, *) {
            usesAdaptiveColorMappingForDarkAppearance = false
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
        drawCodeBlocks(in: dirtyRect)
        drawQuoteBars(in: dirtyRect)
        drawListBullets(in: dirtyRect)
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

    private func drawCodeBlocks(in dirtyRect: NSRect) {
        // Re-assert after any layout pass that regenerated glyphs.
        ComposerMarkdownStyler.suppressFenceGlyphs(in: self)
        let rects = codeBlockChipRects()
        guard !rects.isEmpty else { return }
        let dark = parent?.parent.darkChrome ?? true
        let fill = dark
            ? NSColor(white: 1, alpha: 0.12)
            : NSColor(white: 0, alpha: 0.07)
        let stroke = dark
            ? NSColor(white: 1, alpha: 0.16)
            : NSColor(white: 0, alpha: 0.10)
        let radius = ComposerMarkdownStyler.codeBlockCornerRadius
        for rect in rects {
            // Keep the full rounded corners inside the view (clipsToBounds).
            let maxRadius = min(radius, floor(min(rect.width, rect.height) / 2) - 0.5)
            guard rect.intersects(dirtyRect), maxRadius > 1 else { continue }
            fill.setFill()
            let path = NSBezierPath(roundedRect: rect, xRadius: maxRadius, yRadius: maxRadius)
            path.fill()
            stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// View-space rect of each fenced block's rounded chip.
    func codeBlockChipRects() -> [NSRect] {
        guard let layoutManager, let textContainer else { return [] }
        let ns = string as NSString
        let ranges = ComposerMarkdownStyler.fenceContentRanges(in: ns)
        guard !ranges.isEmpty else { return [] }
        layoutManager.ensureLayout(for: textContainer)

        let origin = textContainerOrigin
        let padX = ComposerMarkdownStyler.codeBlockInsetX
        let padY = ComposerMarkdownStyler.codeBlockInsetY
        let margin = ComposerMarkdownStyler.codeBlockOuterMargin
        let containerWidth = max(textContainer.containerSize.width, bounds.width - textContainerInset.width * 2)
        let lineH = ComposerMarkdownStyler.codeLineHeight
        var rects: [NSRect] = []

        func fragUnion(_ chars: NSRange, top: inout CGFloat, bottom: inout CGFloat) {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }
            var fragIndex = glyphRange.location
            let fragEnd = NSMaxRange(glyphRange)
            while fragIndex < fragEnd {
                var fragRange = NSRange()
                let frag = layoutManager.lineFragmentRect(forGlyphAt: fragIndex, effectiveRange: &fragRange)
                // Collapsed (hidden) fence lines are ~0 tall; revealed ones are real rows.
                if frag.height > 4 {
                    top = min(top, frag.minY)
                    bottom = max(bottom, frag.maxY)
                }
                var next = NSMaxRange(fragRange)
                if next <= fragIndex { next = fragIndex + 1 }
                fragIndex = next
            }
        }

        for range in ranges {
            // Union visible body line fragments — never abort on not-shown fence glyphs.
            var top = CGFloat.greatestFiniteMagnitude
            var bottom: CGFloat = 0
            fragUnion(range, top: &top, bottom: &bottom)
            let hasBody = bottom > top
            // A caret-revealed opener/closer is a full-height row drawn inside the chip.
            if range.location > 0 {
                let opener = ns.lineRange(for: NSRange(location: range.location - 1, length: 0))
                fragUnion(opener, top: &top, bottom: &bottom)
            }
            if NSMaxRange(range) < ns.length {
                let closer = ns.lineRange(for: NSRange(location: NSMaxRange(range), length: 0))
                fragUnion(closer, top: &top, bottom: &bottom)
            }
            var rect: NSRect
            if bottom > top {
                // Line fragments include the block's outer paragraph spacing; give part
                // of it back as a gap so prose above/below doesn't touch the chip.
                rect = NSRect(
                    x: origin.x + textContainerInset.width + padX,
                    y: origin.y + textContainerInset.height + top + margin,
                    width: max(containerWidth - padX * 2, 1),
                    height: max(bottom - top - margin * 2, lineH)
                )
                _ = hasBody
            } else {
                let union: NSRect
                // Empty body — one-line chip just after the opener.
                let y: CGFloat
                if range.location > 0 {
                    let prev = layoutManager.glyphRange(
                        forCharacterRange: NSRange(location: max(0, range.location - 1), length: 1),
                        actualCharacterRange: nil
                    )
                    if prev.length > 0 {
                        let frag = layoutManager.lineFragmentRect(
                            forGlyphAt: prev.location,
                            effectiveRange: nil
                        )
                        y = frag.maxY
                    } else {
                        y = 0
                    }
                } else {
                    y = 0
                }
                union = NSRect(x: 0, y: y, width: max(containerWidth, 1), height: lineH)
                rect = union
                rect.origin.x = origin.x + textContainerInset.width + padX
                rect.origin.y += origin.y + textContainerInset.height - padY
                rect.size.width = max(containerWidth - padX * 2, 1)
                rect.size.height = lineH + padY * 2
            }

            // Clamp so the chip never paints over the previous *visible prose* line.
            // Skip fence marker lines — the opener's trailing newline keeps normal
            // line height and would otherwise sit on top of the body, eating padY
            // and clipping the first code line.
            if range.location > 0 {
                var prevBottom: CGFloat = 0
                var charLoc = 0
                while charLoc < range.location {
                    let lineRange = ns.lineRange(for: NSRange(location: charLoc, length: 0))
                    defer { charLoc = NSMaxRange(lineRange) }
                    let trimmed = ns.substring(with: lineRange)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("```") { continue }
                    let probeLen = min(lineRange.length, range.location - lineRange.location)
                    guard probeLen > 0 else { continue }
                    let glyphs = layoutManager.glyphRange(
                        forCharacterRange: NSRange(location: lineRange.location, length: probeLen),
                        actualCharacterRange: nil
                    )
                    guard glyphs.length > 0 else { continue }
                    var gi = glyphs.location
                    let gEnd = NSMaxRange(glyphs)
                    while gi < gEnd {
                        var fr = NSRange()
                        let frag = layoutManager.lineFragmentRect(forGlyphAt: gi, effectiveRange: &fr)
                        if frag.height > 0.5 {
                            prevBottom = max(prevBottom, frag.maxY)
                        }
                        var next = NSMaxRange(fr)
                        if next <= gi { next = gi + 1 }
                        gi = next
                    }
                }
                if prevBottom > 0 {
                    let minY = origin.y + textContainerInset.height + prevBottom + 2
                    if rect.minY < minY {
                        let bottom = rect.maxY
                        rect.origin.y = minY
                        rect.size.height = max(lineH + padY * 2, bottom - minY)
                    }
                }
            }
            rects.append(rect)
        }
        return rects
    }

    private func drawQuoteBars(in dirtyRect: NSRect) {
        guard let layoutManager, textContainer != nil else { return }
        let ns = string as NSString
        let quotes = ComposerMarkdownStyler.quoteLineRanges(in: ns)
        guard !quotes.isEmpty else { return }

        let origin = textContainerOrigin
        let dark = parent?.parent.darkChrome ?? true
        let barColor = dark
            ? NSColor(white: 1, alpha: 0.42)
            : NSColor(white: 0, alpha: 0.35)
        let width = ComposerMarkdownStyler.quoteBarWidth
        let inset = ComposerMarkdownStyler.quoteBarInset
        // Sit in the quote gutter, not at the (collapsed) marker glyph.
        let barX = origin.x + textContainerInset.width + inset
        let fallbackLine = ComposerMarkdownStyler.bodyLineHeight
        barColor.setFill()

        for range in quotes {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }
            let frag = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
            var rect = frag
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            // Bare `>` used to collapse to a speck — always paint at least one line.
            let barHeight = max(rect.height - 2, fallbackLine - 2, 14)
            guard rect.intersects(dirtyRect) || NSRect(
                x: barX, y: rect.minY, width: width, height: barHeight
            ).intersects(dirtyRect) else { continue }
            let bar = NSRect(
                x: barX,
                y: rect.minY + 1,
                width: width,
                height: barHeight
            )
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
        }
    }

    private func drawListBullets(in dirtyRect: NSRect) {
        guard let layoutManager, textContainer != nil else { return }
        ComposerMarkdownStyler.suppressListMarkerGlyphs(in: self)
        let ns = string as NSString
        let sel = selectedRange()
        let sites = ComposerMarkdownStyler.unorderedListBulletSites(
            in: ns,
            caret: sel.length == 0 ? sel.location : nil,
            selection: sel.length > 0 ? sel : nil
        )
        guard !sites.isEmpty else { return }

        let origin = textContainerOrigin
        let dark = parent?.parent.darkChrome ?? true
        let color = dark ? NSColor(white: 0.88, alpha: 1) : NSColor(white: 0.28, alpha: 1)
        let diameter = ComposerMarkdownStyler.listBulletDiameter
        let gutter = ComposerMarkdownStyler.listBulletGutter

        for site in sites {
            // Caret/selection in the marker → raw `-` is visible; skip painted bullet.
            guard !site.revealed else { continue }
            // Anchor on the body (or line start) — marker glyphs are not-shown / zero-width.
            let anchorChar = min(max(site.bodyStart, site.line.location), max(0, ns.length - 1))
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: anchorChar, length: 1),
                actualCharacterRange: nil
            )
            let frag: NSRect
            let bodyX: CGFloat
            if glyphRange.length > 0 {
                var fragRange = NSRange()
                frag = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphRange.location,
                    effectiveRange: &fragRange
                )
                bodyX = layoutManager.location(forGlyphAt: glyphRange.location).x
            } else {
                let lineGlyphs = layoutManager.glyphRange(
                    forCharacterRange: site.line,
                    actualCharacterRange: nil
                )
                guard lineGlyphs.length > 0 else { continue }
                frag = layoutManager.lineFragmentRect(
                    forGlyphAt: lineGlyphs.location,
                    effectiveRange: nil
                )
                bodyX = gutter
            }
            let x = origin.x + textContainerInset.width + frag.minX + bodyX
                - gutter + (gutter - diameter) / 2
            let y = origin.y + textContainerInset.height + frag.minY
                + max(0, (frag.height - diameter) / 2)
            let rect = NSRect(x: x, y: y, width: diameter, height: diameter)
            guard rect.intersects(dirtyRect) else { continue }

            color.set()
            switch site.level {
            case 0:
                NSBezierPath(ovalIn: rect).fill()
            case 1:
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1.25
                ring.stroke()
            default:
                let square = NSBezierPath(
                    roundedRect: rect.insetBy(dx: 0.25, dy: 0.25),
                    xRadius: 0.6,
                    yRadius: 0.6
                )
                square.fill()
            }
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
        let line = ComposerMarkdownStyler.bodyLineHeight
        let h = max(used + textContainerInset.height * 2, line + textContainerInset.height * 2)
        super.setFrameSize(NSSize(width: width, height: h))
    }

    override func paste(_ sender: Any?) {
        if let plain = NSPasteboard.general.string(forType: .string) {
            let normalized = ComposerMarkdownStyler.normalizePastedListMarkers(plain)
            insertText(normalized, replacementRange: selectedRange())
            return
        }
        super.pasteAsPlainText(sender)
    }

    func restyleAfterExternalEdit() {
        parent?.restyleKeepingSelection()
        parent?.recalculateHeightAfterLayout()
        needsDisplay = true
    }
}
