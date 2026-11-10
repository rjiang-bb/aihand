import AppKit

/// Non-destructive markdown highlighting for the composer `NSTextView`.
/// Keeps the plain string intact (send / @ / / / paste still see source text).
enum ComposerMarkdownStyler {
    private static let bodySize: CGFloat = 14.5
    private static let monoSize: CGFloat = 13.0
    static let bodyFont = NSFont.systemFont(ofSize: bodySize)
    /// Composer text line height.
    ///
    /// Never derive this from `textView.font`: AppKit answers with the attributes of
    /// character 0, and a list line starts with the collapsed 0.01pt marker run. That
    /// reported a 3pt line, which shrank the 8-line height cap to ~32pt and forced the
    /// composer into its own scroller instead of growing.
    static let bodyLineHeight: CGFloat = ceil(bodyFont.ascender - bodyFont.descender + 2)
    /// Height AppKit lays out for one plain body line (no extra spacing).
    static let bodyNaturalLineHeight: CGFloat = ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading)
    /// Fallback line height for fenced-code chrome (mono runs are slightly smaller).
    static let codeLineHeight: CGFloat = ceil(NSFont.monospacedSystemFont(ofSize: monoSize, weight: .regular).ascender
        - NSFont.monospacedSystemFont(ofSize: monoSize, weight: .regular).descender + 4)
    /// Hanging indent for wrapped list lines (text aligns under the body, not the bullet).
    private static let listHangIndent: CGFloat = 0
    /// Width reserved for the painted bullet after collapsing `-`/`*` + gap.
    static let listBulletGutter: CGFloat = 14
    /// Spaces per nest level (markdown-compatible; 4 reads clearly in the composer).
    static let listIndentUnit = 4
    /// Visual step per nest level. Leading source spaces are collapsed, so nesting is
    /// drawn only through this paragraph indent.
    static let listLevelIndent: CGFloat = 18
    /// Absolute nest ceiling (MarkdownEngine-style; Tab no-ops past this).
    static let listMaximumNestingLevel = 3
    /// Display-only nest glyphs (source stays `-` / `*`). Level 0 •, 1 ○, 2+ ▪.
    private static let bulletByLevel = ["•", "○", "▪"]
    /// Fancy bullets we may still see in old drafts / paste — normalize back to `-`.
    private static let fancyBulletChars = CharacterSet(charactersIn: "•○◦▪■‣·")
    /// Gutter for the painted quote bar (marker width is collapsed separately).
    private static let quoteIndent: CGFloat = 8
    static let quoteBarWidth: CGFloat = 2.5
    static let quoteBarInset: CGFloat = 1.5
    /// Painted bullet diameter (Bezier path — never rely on Unicode glyphs on SoftChrome).
    static let listBulletDiameter: CGFloat = 4.5
    /// Inset for the painted fenced-code chrome (Codex-style rounded chip).
    static let codeBlockCornerRadius: CGFloat = 12
    static let codeBlockInsetX: CGFloat = 4
    static let codeBlockInsetY: CGFloat = 4
    /// Text inset inside the chip (paragraph indent). Caret stays on text; fence
    /// marker lines are snapped away so they don't park in this gutter.
    static let codeBlockTextInset: CGFloat = 12
    static let codeBlockParagraphPad: CGFloat = 10
    /// Gap kept between the chip and prose above/below it. The block's paragraph
    /// spacing (`codeBlockParagraphPad + codeBlockInsetY`) is split into this margin
    /// plus the chip's inner padding.
    static let codeBlockOuterMargin: CGFloat = 6

    /// True when the caret sits inside a fenced code body (or on a fence marker line).
    static func caretIsInFence(in textView: NSTextView) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let ns = storage.string as NSString
        let caret = min(textView.selectedRange().location, ns.length)
        return fenceRegion(containing: caret, in: ns) != nil
    }

    /// ⇧↩ inside a fence → soft newline (Enter alone always submits). Empty line after body can close.
    @discardableResult
    static func handleFenceEnter(in textView: NSTextView) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let ns = storage.string as NSString
        let sel = textView.selectedRange()
        guard sel.length == 0 else { return false }
        let caret = min(sel.location, ns.length)
        guard let region = fenceRegion(containing: caret, in: ns) else { return false }

        // Empty content line at end of an *unclosed* fence → close with ```.
        // Scaffolded fences are already closed, so Enter just adds lines in the chip.
        if region.isOpen,
           caret >= region.contentStart,
           lineIsEmpty(at: caret, in: ns),
           region.contentStart < caret {
            let insertion = "```\n"
            let insertRange = NSRange(location: caret, length: 0)
            if textView.shouldChangeText(in: insertRange, replacementString: insertion) {
                storage.replaceCharacters(in: insertRange, with: insertion)
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: caret + insertion.count, length: 0))
            }
            return true
        }

        // Don't split the collapsed ``` line — jump into the body first.
        if caret < region.contentStart {
            textView.setSelectedRange(NSRange(location: region.contentStart, length: 0))
        }
        textView.insertNewlineIgnoringFieldEditor(nil)
        return true
    }

    /// ↓ skips collapsed fence markers. From the opener → body; from the last body
    /// line / closer → a normal-height line below the chip (never park on ```).
    @discardableResult
    static func handleFenceMoveDown(in textView: NSTextView) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let ns = storage.string as NSString
        let sel = textView.selectedRange()
        guard sel.length == 0 else { return false }
        let caret = min(sel.location, ns.length)
        guard let region = fenceRegion(containing: caret, in: ns) else { return false }

        // Opener / pre-body → jump into the first body character.
        if caret < region.contentStart {
            let dest = min(region.contentStart, storage.length)
            textView.setSelectedRange(NSRange(location: dest, length: 0))
            textView.scrollRangeToVisible(NSRange(location: dest, length: 0))
            return true
        }

        let onCloser = region.closeLine.map { caret >= $0.location && caret <= NSMaxRange($0) } ?? false
        let inBody = caret >= region.contentStart && caret <= region.contentEnd

        // Last body line = this line ends at the closer (or EOF if still open).
        var onLastBodyLine = false
        if inBody {
            if region.contentEnd <= region.contentStart {
                onLastBodyLine = true
            } else {
                let probe = min(caret, max(region.contentStart, region.contentEnd - 1))
                let lineRange = ns.lineRange(for: NSRange(location: probe, length: 0))
                let afterLine = NSMaxRange(lineRange)
                if let close = region.closeLine {
                    onLastBodyLine = afterLine >= close.location
                } else {
                    onLastBodyLine = afterLine >= ns.length || afterLine >= region.contentEnd
                }
            }
        }

        guard onLastBodyLine || onCloser else { return false }

        let bodyAttrs = typingAttributes(darkChrome: nil)
        // Destination: first character after the closing fence line.
        var exit = region.closeLine.map { NSMaxRange($0) } ?? region.contentEnd

        // Ensure a dedicated blank line AFTER the fence (never park on collapsed ```).
        // Avoid didChangeText here — it re-enters scaffold/restyle and can yank the caret
        // back into the chip; the caller restyles once we're done.
        // Skip past a collapsed closer if `exit` somehow landed on it.
        if exit < storage.length {
            let probe = min(exit, max(0, storage.length - 1))
            let next = (storage.string as NSString).lineRange(for: NSRange(location: probe, length: 0))
            let nextText = (storage.string as NSString).substring(with: next)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if nextText.hasPrefix("```") {
                exit = NSMaxRange(next)
            }
        }

        let needsTrailingLine: Bool = {
            if exit >= storage.length { return true }
            let probe = min(exit, max(0, storage.length - 1))
            let next = (storage.string as NSString).lineRange(for: NSRange(location: probe, length: 0))
            let nextText = (storage.string as NSString).substring(with: next)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Already a blank line after the fence — use it.
            if nextText.isEmpty { return false }
            // Still on a fence marker somehow — push past with a new line.
            return nextText.hasPrefix("```")
        }()

        if needsTrailingLine {
            let insertAt = min(exit, storage.length)
            let insertion = NSAttributedString(string: "\n", attributes: bodyAttrs)
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: insertAt, length: 0), with: insertion)
            storage.endEditing()
            exit = insertAt + 1
        } else if exit < storage.length {
            // Prefer the start of the existing blank line after the fence.
            let probe = min(exit, max(0, storage.length - 1))
            let next = (storage.string as NSString).lineRange(for: NSRange(location: probe, length: 0))
            if next.location >= exit {
                exit = next.location
            }
        }

        // Normalize paragraph metrics on the exit line so it isn't zero-height.
        if storage.length > 0 {
            let lineProbe = min(exit, max(0, storage.length - 1))
            let exitLine = (storage.string as NSString).lineRange(
                for: NSRange(location: lineProbe, length: 0)
            )
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 1
            para.paragraphSpacing = 1
            para.minimumLineHeight = ceil(bodySize + 2)
            para.maximumLineHeight = ceil(bodySize + 6)
            storage.addAttributes(bodyAttrs.merging([.paragraphStyle: para]) { _, new in new }, range: exitLine)
        }

        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
        }
        textView.typingAttributes = bodyAttrs
        let caretOut = min(exit, storage.length)
        textView.setSelectedRange(NSRange(location: caretOut, length: 0))
        textView.scrollRangeToVisible(NSRange(location: caretOut, length: 0))
        return true
    }

    /// Chat-composer ⇧↩: fence → quote → list → soft break.
    /// (MarkdownEngine routes all of these on Enter; we keep Enter = submit.)
    @discardableResult
    static func handleShiftReturn(in textView: NSTextView) -> Bool {
        if handleFenceEnter(in: textView) { return true }
        // Inside a fence body, never run quote/list helpers.
        if caretIsInFence(in: textView) {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        if handleQuoteEnter(in: textView) { return true }
        if handleListEnter(in: textView) { return true }
        textView.insertNewlineIgnoringFieldEditor(nil)
        return true
    }

    /// Normalize pasted `•‣◦·` line-start bullets to markdown `- ` (MarkdownEngine paste path).
    static func normalizePastedListMarkers(_ pasted: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: #"^([ \t]*)[•○◦▪■‣·][ \t]+"#,
            options: [.anchorsMatchLines]
        ) else { return pasted }
        let ns = pasted as NSString
        let full = NSRange(location: 0, length: ns.length)
        return re.stringByReplacingMatches(
            in: pasted,
            options: [],
            range: full,
            withTemplate: "$1- "
        )
    }

    /// Fence lines are revealed (full height, visible ticks) while the caret sits on
    /// them, so the caret may park there to edit/delete the block. No snapping.
    @discardableResult
    static func snapCaretOffFenceMarkers(in textView: NSTextView) -> Bool {
        false
    }

    /// Known fence language tags — anything else after ``` is body text, not a lang.
    private static let fenceLanguages: Set<String> = [
        "swift", "python", "py", "javascript", "js", "typescript", "ts", "tsx", "jsx",
        "json", "html", "css", "scss", "rust", "go", "c", "cpp", "c++", "objc", "java",
        "kotlin", "ruby", "rb", "php", "sh", "bash", "zsh", "shell", "sql", "yaml", "yml",
        "toml", "xml", "md", "markdown", "text", "txt", "diff", "dockerfile", "make",
        "cmake", "lua", "r", "perl", "scala", "haskell", "elixir", "erlang", "zig",
    ]

    private static func fenceLanguage(inRest rest: String) -> String? {
        let token = rest.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty,
              token.range(of: #"^[A-Za-z][A-Za-z0-9_+#.-]{0,24}$"#, options: .regularExpression) != nil,
              fenceLanguages.contains(token.lowercased()) else { return nil }
        return token
    }

    /// Can `rest` (text after the ` ``` ` ticks) still become a language tag?
    ///
    /// Scaffolding on the 3rd backtick used to be instant, so ` ```swift ` became a code
    /// body containing `swift`. A token that is a prefix of a known language (`s`, `sw`,
    /// `swift`) holds the raw opener so the tag can be typed. Whitespace after the ticks
    /// means the author wanted body text, not a tag.
    private static func isPossibleFenceTag(_ rest: String) -> Bool {
        guard rest == rest.trimmingCharacters(in: .whitespaces),
              !rest.isEmpty,
              rest.range(of: #"^[A-Za-z][A-Za-z0-9_+#.-]{0,24}$"#, options: .regularExpression) != nil
        else { return false }
        let lower = rest.lowercased()
        return fenceLanguages.contains { $0.hasPrefix(lower) }
    }

    /// True while a ` ``` ` opener must stay raw instead of becoming a chip:
    /// bare ticks (wait for a tag), or a tag prefix still being typed.
    static func fenceTagIsPendingForChip(in textView: NSTextView) -> Bool {
        guard let rest = pendingFenceRest(in: textView) else { return false }
        if rest.isEmpty { return true }
        return isPossibleFenceTag(rest)
    }

    /// Text after a pending opener's ticks, or nil when the caret isn't on one.
    private static func pendingFenceRest(in textView: NSTextView) -> String? {
        guard let storage = textView.textStorage else { return nil }
        let ns = storage.string as NSString
        guard ns.length > 0 else { return nil }
        let caret = min(textView.selectedRange().location, ns.length)
        let probe = min(max(0, caret - 1), max(0, ns.length - 1))
        let lineRange = ns.lineRange(for: NSRange(location: probe, length: 0))
        let trimmed = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return nil }
        // Caret must sit on the opener line (otherwise it's already body text).
        guard caret >= lineRange.location + 3, caret <= NSMaxRange(lineRange) else { return nil }
        return String(trimmed.dropFirst(3))
    }

    /// After typing ```, normalize to Codex shape: hidden opener, body line, closer.
    /// Never leaves body text on the fence line (` ```dsdsfds ` → body `dsdsfds`).
    ///
    /// A bare opener (or a would-be language tag — ` ```sw`, ` ```python`) is *held*
    /// while `force` is false so the tag can be typed. The coordinator schedules a
    /// forced pass shortly after typing stops, so ` ``` ` on its own still becomes a
    /// chip. Without the hold, the 3rd backtick scaffolded instantly and the tag text
    /// was swallowed into the code body.
    @discardableResult
    static func scaffoldFenceIfNeeded(in textView: NSTextView, force: Bool = false) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let ns = storage.string as NSString
        let caret = min(textView.selectedRange().location, ns.length)
        guard ns.length > 0 else { return false }

        let probe = min(max(0, caret - 1), max(0, ns.length - 1))
        let lineRange = ns.lineRange(for: NSRange(location: probe, length: 0))
        let contentLen = ns.substring(with: lineRange).hasSuffix("\n")
            ? lineRange.length - 1 : lineRange.length
        guard contentLen > 0 else { return false }
        let contentRange = NSRange(location: lineRange.location, length: contentLen)
        let content = ns.substring(with: contentRange)
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") else { return false }

        // Only scaffold when this fence is an opener.
        var fencesBefore = 0
        var loc = 0
        while loc < lineRange.location {
            let lr = ns.lineRange(for: NSRange(location: loc, length: 0))
            let t = ns.substring(with: lr).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("```") { fencesBefore += 1 }
            loc = NSMaxRange(lr)
        }
        guard fencesBefore % 2 == 0 else { return false }

        let afterTicks = String(trimmed.dropFirst(3))
        // Hold the raw opener while a language tag is still being typed (` ```sw` →
        // ` ```swift`). The coordinator schedules a forced pass shortly after typing
        // stops, so a bare ` ``` ` still becomes a chip on its own.
        if !force, fenceTagIsPendingForChip(in: textView) { return false }

        let lang = fenceLanguage(inRest: afterTicks)

        let sameLineBody: String = {
            if lang != nil { return "" }
            return afterTicks.trimmingCharacters(in: .whitespaces)
    }()

        let afterLine = NSMaxRange(lineRange)
        let hasTrailingNewline = ns.substring(with: lineRange).hasSuffix("\n")

        // Already have body + closing scaffold?
        if hasTrailingNewline, afterLine < ns.length, sameLineBody.isEmpty {
            let rest = ns.substring(from: afterLine)
            if rest.hasPrefix("\n```") || rest.hasPrefix("```") {
                // Caret still on fence line → move into body.
                if caret <= afterLine {
                    textView.setSelectedRange(NSRange(location: afterLine, length: 0))
                    return true
                }
                return false
            }
        }

        // Rebuild opener as ```lang?\n + body + \n``` (Codex chip).
        let openLine = lang.map { "```\($0)" } ?? "```"
        var rebuilt = openLine + "\n"
        if !sameLineBody.isEmpty {
            rebuilt += sameLineBody
        }
        rebuilt += "\n```"
        let replaceEnd = hasTrailingNewline ? afterLine : (lineRange.location + contentLen)
        let replaceRange = NSRange(
            location: lineRange.location,
            length: replaceEnd - lineRange.location
        )
        if textView.shouldChangeText(in: replaceRange, replacementString: rebuilt) {
            storage.replaceCharacters(in: replaceRange, with: rebuilt)
            textView.didChangeText()
            // Caret at end of body (after same-line content, or on the blank body line).
            let bodyStart = lineRange.location + openLine.count + 1
            let bodyCaret = bodyStart + sameLineBody.count
            textView.setSelectedRange(NSRange(location: bodyCaret, length: 0))
            return true
        }
        return false
    }

    /// Fence marker character ranges (opener/closer ticks + language tags) for glyph hiding.
    static func fenceMarkerRanges(in string: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var loc = 0
        var inFence = false
        while loc < string.length {
            let lineRange = string.lineRange(for: NSRange(location: loc, length: 0))
            defer { loc = NSMaxRange(lineRange) }
            let line = string.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("```") else { continue }
            let tokenLen = line.hasSuffix("\n") ? lineRange.length - 1 : lineRange.length
            guard tokenLen > 0 else {
                inFence.toggle()
                continue
            }
            let contentRange = NSRange(location: lineRange.location, length: tokenLen)
            let nsLine = string.substring(with: contentRange) as NSString
            var lead = 0
            while lead < nsLine.length {
                let u = nsLine.character(at: lead)
                if u == 32 || u == 9 { lead += 1 } else { break }
            }
            let tickLen = min(3, max(0, nsLine.length - lead))
            if tickLen > 0 {
                ranges.append(NSRange(location: contentRange.location + lead, length: tickLen))
            }
            let afterTicks = lead + tickLen
            if afterTicks < nsLine.length {
                let rest = NSRange(
                    location: contentRange.location + afterTicks,
                    length: nsLine.length - afterTicks
                )
                let restText = string.substring(with: rest).trimmingCharacters(in: .whitespaces)
                if inFence || fenceLanguage(inRest: restText) != nil {
                    ranges.append(rest)
                }
            }
            inFence.toggle()
        }
        return ranges
    }

    /// Hide fence glyphs at the layout level (survives SoftChrome / chip compositing).
    /// The line under the caret is revealed so the ticks can be edited/deleted.
    static func suppressFenceGlyphs(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let storage = textView.textStorage else { return }
        layoutManager.ensureLayout(for: container)
        let ns = storage.string as NSString
        let sel = textView.selectedRange()
        var revealedLine: NSRange?
        if sel.length == 0, ns.length > 0 {
            revealedLine = caretLine(at: sel.location, in: ns)
        }
        for range in fenceMarkerRanges(in: ns) where range.length > 0 {
            if let revealedLine,
               range.location >= revealedLine.location,
               range.location < NSMaxRange(revealedLine) {
                continue
            }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            for i in glyphs.location..<NSMaxRange(glyphs) {
                layoutManager.setNotShownAttribute(true, forGlyphAt: i)
            }
        }
    }

    /// Hide unordered list `-`/`*` + following gap glyphs (clear fg bleeds on SoftChrome).
    /// Skips caret/selection-revealed markers so the raw source stays editable.
    static func suppressListMarkerGlyphs(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let storage = textView.textStorage else { return }
        layoutManager.ensureLayout(for: container)
        let ns = storage.string as NSString
        let sel = textView.selectedRange()
        let caret = sel.length == 0 ? sel.location : nil
        let selection = sel.length > 0 ? sel : nil
        for site in unorderedListBulletSites(in: ns, caret: caret, selection: selection) {
            guard !site.revealed else { continue }
            // Suppress marker and the markdown gap spaces that follow it.
            let end = min(site.bodyStart, ns.length)
            let len = max(0, end - site.markerLocation)
            guard len > 0 else { continue }
            let range = NSRange(location: site.markerLocation, length: len)
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            for i in glyphs.location..<NSMaxRange(glyphs) {
                layoutManager.setNotShownAttribute(true, forGlyphAt: i)
            }
        }
    }

    private struct FenceRegion {
        var contentStart: Int
        var contentEnd: Int
        var isOpen: Bool
        var openLine: NSRange
        var closeLine: NSRange?

        /// Whole-block range: opener through closer (or EOF when still open).
        var blockRange: NSRange {
            let start = openLine.location
            let end = closeLine.map(NSMaxRange) ?? contentEnd
            return NSRange(location: start, length: max(0, end - start))
        }
    }

    /// Delete the whole fenced block when Backspace is pressed with the caret at
    /// the code body start (or on a revealed fence marker). Returns true if handled.
    @discardableResult
    static func handleFenceDeleteBackward(in textView: NSTextView) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let sel = textView.selectedRange()
        guard sel.length == 0 else { return false }
        let ns = storage.string as NSString
        guard ns.length > 0 else { return false }
        let caret = min(sel.location, ns.length)
        guard let region = fenceRegion(containing: caret, in: ns) else { return false }

        // Only at the opener's own characters, the closing ticks, or the first body
        // character. (Backspacing on an unbalanced closer used to strand a lone ``` .)
        let atOpen = caret >= region.openLine.location && caret <= NSMaxRange(region.openLine)
        let atClose = region.closeLine.map {
            caret >= $0.location && caret <= NSMaxRange($0)
        } ?? false
        let atBodyStart = caret == region.contentStart
        guard atOpen || atClose || atBodyStart else { return false }

        let block = region.blockRange
        var delete = block
        // Swallow one trailing newline so the block doesn't leave a stranded blank line.
        if NSMaxRange(delete) < ns.length,
           ns.substring(with: NSRange(location: NSMaxRange(delete), length: 1)) == "\n" {
            delete.length += 1
        } else if delete.location > 0,
                  ns.substring(with: NSRange(location: delete.location - 1, length: 1)) == "\n" {
            delete.location -= 1
            delete.length += 1
        }
        if textView.shouldChangeText(in: delete, replacementString: "") {
            storage.replaceCharacters(in: delete, with: "")
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: min(delete.location, storage.length), length: 0))
        }
        return true
    }

    private static func fenceRegion(containing caret: Int, in ns: NSString) -> FenceRegion? {
        var loc = 0
        var openLine: NSRange?
        var contentStart = 0
        while loc < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            let trimmed = ns.substring(with: lineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isFence = trimmed.hasPrefix("```")
            if isFence {
                if let open = openLine {
                    let contentEnd = lineRange.location
                    let region = FenceRegion(
                        contentStart: contentStart,
                        contentEnd: contentEnd,
                        isOpen: false,
                        openLine: open,
                        closeLine: lineRange
                    )
                    if caretInFence(caret, region: region, closeLine: lineRange, in: ns) {
                        return region
                    }
                    openLine = nil
                } else {
                    openLine = lineRange
                    contentStart = NSMaxRange(lineRange)
                    // Same-line body after ``` counts as content.
                    let tokenLen = ns.substring(with: lineRange).hasSuffix("\n")
                        ? lineRange.length - 1 : lineRange.length
                    if tokenLen > 0 {
                        let lineContent = ns.substring(
                            with: NSRange(location: lineRange.location, length: tokenLen)
                        ) as NSString
                        var lead = 0
                        while lead < lineContent.length {
                            let u = lineContent.character(at: lead)
                            if u == 32 || u == 9 { lead += 1 } else { break }
                        }
                        let afterTicks = lead + min(3, max(0, lineContent.length - lead))
                        if afterTicks < lineContent.length {
                            let rest = lineContent.substring(from: afterTicks)
                                .trimmingCharacters(in: .whitespaces)
                            if !rest.isEmpty, fenceLanguage(inRest: rest) == nil {
                                contentStart = lineRange.location + afterTicks
                            }
                        }
                    }
                    if caret >= lineRange.location, caret < contentStart || caret <= NSMaxRange(lineRange) {
                        // Caret on opener — still "in fence" for Enter handling.
                        if caret <= NSMaxRange(lineRange), openLine != nil {
                            // Keep scanning for closer; if none, open region below.
                        }
                    }
                }
            }
            loc = NSMaxRange(lineRange)
        }
        if let open = openLine {
            let region = FenceRegion(
                contentStart: contentStart,
                contentEnd: ns.length,
                isOpen: true,
                openLine: open,
                closeLine: nil
            )
            if caretInFence(caret, region: region, closeLine: nil, in: ns) {
                return region
            }
        }
        return nil
    }

    private static func caretInFence(_ caret: Int, region: FenceRegion, closeLine: NSRange?, in ns: NSString) -> Bool {
        if caret >= region.openLine.location,
           caret < region.contentStart { return true }
        if caret >= region.contentStart, caret <= region.contentEnd { return true }
        // The closer's own newline belongs to the next line: a caret after it is prose.
        if let close = closeLine,
           caret >= close.location,
           caret <= close.location
            + (ns.substring(with: close).hasSuffix("\n") ? close.length - 1 : close.length) { return true }
        return false
    }

    /// Line containing `caret`. At the very end of text that ends in a newline the
    /// caret is on the empty last line — clamping to `length - 1` instead reported the
    /// line above (e.g. the closing ``` , revealing it after ↓ out of a block).
    static func caretLine(at caret: Int, in ns: NSString) -> NSRange {
        let caret = max(0, min(caret, ns.length))
        if caret == ns.length, ns.length == 0 || ns.character(at: ns.length - 1) == 10 {
            return NSRange(location: ns.length, length: 0)
        }
        return ns.lineRange(for: NSRange(location: min(caret, ns.length - 1), length: 0))
    }

    private static func lineIsEmpty(at caret: Int, in ns: NSString) -> Bool {
        guard ns.length > 0 else { return true }
        let lineRange = caretLine(at: caret, in: ns)
        let contentLen = ns.substring(with: lineRange).hasSuffix("\n")
            ? lineRange.length - 1 : lineRange.length
        if contentLen == 0 { return true }
        let content = ns.substring(with: NSRange(location: lineRange.location, length: contentLen))
        return content.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Character ranges of fenced code bodies (for painting the rounded chip).
    static func fenceContentRanges(in string: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var loc = 0
        var inFence = false
        var contentStart = 0
        while loc < string.length {
            let lineRange = string.lineRange(for: NSRange(location: loc, length: 0))
            let trimmed = string.substring(with: lineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                if inFence {
                    let contentEnd = lineRange.location
                    if contentEnd > contentStart {
                        ranges.append(NSRange(location: contentStart, length: contentEnd - contentStart))
                    }
                    inFence = false
                } else {
                    inFence = true
                    contentStart = NSMaxRange(lineRange)
                    let tokenLen = string.substring(with: lineRange).hasSuffix("\n")
                        ? lineRange.length - 1 : lineRange.length
                    if tokenLen > 0 {
                        let lineContent = string.substring(
                            with: NSRange(location: lineRange.location, length: tokenLen)
                        ) as NSString
                        var lead = 0
                        while lead < lineContent.length {
                            let u = lineContent.character(at: lead)
                            if u == 32 || u == 9 { lead += 1 } else { break }
                        }
                        let afterTicks = lead + min(3, max(0, lineContent.length - lead))
                        if afterTicks < lineContent.length {
                            let rest = lineContent.substring(from: afterTicks)
                                .trimmingCharacters(in: .whitespaces)
                            if !rest.isEmpty, fenceLanguage(inRest: rest) == nil {
                                contentStart = lineRange.location + afterTicks
                            }
                        }
                    }
                }
            }
            loc = NSMaxRange(lineRange)
        }
        if inFence, string.length > contentStart {
            ranges.append(NSRange(location: contentStart, length: string.length - contentStart))
        }
        return ranges
    }

    private struct ListLine {
        var indent: String
        var marker: String
        var isOrdered: Bool
        var number: Int
        var gap: String
        var body: String
        var contentRange: NSRange
        var activeLine: NSRange

        var level: Int {
            // Count leading spaces; tabs count as one indent unit.
            var spaces = 0
            for ch in indent {
                if ch == "\t" { spaces += listIndentUnit }
                else if ch == " " { spaces += 1 }
                else { break }
            }
            return max(0, spaces / listIndentUnit)
        }

        /// Source prefix for continue/indent — always markdown atoms (`- `, `1. `).
        var sourcePrefix: String {
            let gapOut = gap.isEmpty ? " " : gap
            if isOrdered {
                return indent + "\(number)." + gapOut
            }
            let atom = markdownUnorderedMarker(marker)
            return indent + atom + gapOut
        }

        var bodyStart: Int {
            contentRange.location + (indent as NSString).length
                + (isOrdered ? "\(number).".count : (marker as NSString).length)
                + (gap as NSString).length
        }
    }

    static func bulletMarker(forLevel level: Int) -> String {
        let idx = min(max(0, level), bulletByLevel.count - 1)
        return bulletByLevel[idx]
    }

    private static func markdownUnorderedMarker(_ existing: String) -> String {
        if existing == "*" { return "*" }
        return "-"
    }

    /// True when the caret sits on a markdown list line.
    static func caretIsInList(in textView: NSTextView) -> Bool {
        listLine(atCaretIn: textView) != nil
    }

    private static func listLine(atCaretIn textView: NSTextView) -> ListLine? {
        guard let storage = textView.textStorage else { return nil }
        let ns = storage.string as NSString
        let sel = textView.selectedRange()
        guard ns.length > 0 else { return nil }
        let caret = min(sel.location, ns.length)
        let activeLine = caretLine(at: caret, in: ns)
        let hasTrailingNewline = ns.substring(with: activeLine).hasSuffix("\n")
        let contentLen = hasTrailingNewline ? activeLine.length - 1 : activeLine.length
        guard contentLen > 0 else { return nil }
        let contentRange = NSRange(location: activeLine.location, length: contentLen)
        let content = ns.substring(with: contentRange)
        return parseListLine(content, contentRange: contentRange, activeLine: activeLine)
    }

    private static func parseListLine(
        _ content: String,
        contentRange: NSRange,
        activeLine: NSRange
    ) -> ListLine? {
        let nsContent = content as NSString
        let full = NSRange(location: 0, length: nsContent.length)
        if let re = try? NSRegularExpression(pattern: #"^(\s*)([-*•○◦▪■])(\s+)(.*)$"#),
           let m = re.firstMatch(in: content, range: full),
           m.numberOfRanges >= 5 {
            return ListLine(
                indent: nsContent.substring(with: m.range(at: 1)),
                marker: nsContent.substring(with: m.range(at: 2)),
                isOrdered: false,
                number: 1,
                gap: nsContent.substring(with: m.range(at: 3)),
                body: nsContent.substring(with: m.range(at: 4)),
                contentRange: contentRange,
                activeLine: activeLine
            )
        }
        if let re = try? NSRegularExpression(pattern: #"^(\s*)(\d+)\.(\s+)(.*)$"#),
           let m = re.firstMatch(in: content, range: full),
           m.numberOfRanges >= 5 {
            return ListLine(
                indent: nsContent.substring(with: m.range(at: 1)),
                marker: "",
                isOrdered: true,
                number: Int(nsContent.substring(with: m.range(at: 2))) ?? 1,
                gap: nsContent.substring(with: m.range(at: 3)),
                body: nsContent.substring(with: m.range(at: 4)),
                contentRange: contentRange,
                activeLine: activeLine
            )
        }
        return nil
    }

    /// Previous list item above `line` (skips blanks). Used to cap Tab sink at parent+1.
    private static func previousListLine(
        before line: ListLine,
        in ns: NSString
    ) -> ListLine? {
        var loc = line.activeLine.location
        while loc > 0 {
            let probe = loc - 1
            let prevRange = ns.lineRange(for: NSRange(location: probe, length: 0))
            if prevRange.location >= loc { break }
            loc = prevRange.location
            let contentLen = ns.substring(with: prevRange).hasSuffix("\n")
                ? prevRange.length - 1 : prevRange.length
            if contentLen == 0 { continue }
            let contentRange = NSRange(location: prevRange.location, length: contentLen)
            let content = ns.substring(with: contentRange)
            if let parsed = parseListLine(
                content,
                contentRange: contentRange,
                activeLine: prevRange
            ) {
                return parsed
            }
            // Non-list prose breaks the list chain.
            if !content.trimmingCharacters(in: .whitespaces).isEmpty {
                return nil
            }
        }
        return nil
    }

    private static func replaceListLine(
        _ line: ListLine,
        with rebuilt: String,
        in textView: NSTextView,
        caretBias: Int
    ) {
        guard let storage = textView.textStorage else { return }
        let caret = textView.selectedRange().location
        let caretInLine = max(0, caret - line.activeLine.location)
        if textView.shouldChangeText(in: line.contentRange, replacementString: rebuilt) {
            storage.replaceCharacters(in: line.contentRange, with: rebuilt)
            textView.didChangeText()
            let delta = (rebuilt as NSString).length - line.contentRange.length
            let next = max(
                line.activeLine.location,
                min(line.activeLine.location + caretInLine + delta + caretBias, storage.length)
            )
            textView.setSelectedRange(NSRange(location: next, length: 0))
        }
    }

    /// ⇧↩: continue the list (or outdent / exit on an empty item). Enter always submits.
    @discardableResult
    static func handleListEnter(in textView: NSTextView) -> Bool {
        guard !caretIsInFence(in: textView) else { return false }
        guard let storage = textView.textStorage,
              var line = listLine(atCaretIn: textView) else { return false }
        let caret = min(textView.selectedRange().location, storage.length)
        let contentLen = line.contentRange.length

        if line.body.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty item → outdent one level; at root, strip marker (MarkdownEngine exit).
            if line.level > 0 {
                return handleListOutdent(in: textView)
            }
            removeLinePrefix(
                in: textView,
                line: line.activeLine,
                prefixLength: (line.indent as NSString).length
                    + (line.isOrdered ? "\(line.number).".count : (line.marker as NSString).length)
                    + (line.gap as NSString).length
            )
            return true
        }

        // Next item keeps indent; ordered numbers increment; unordered stays `-`/`*`
        // (legacy `•` → `-`, matching MarkdownEngine continuation).
        if line.isOrdered {
            line.number += 1
        }
        let caretInLine = max(0, min(caret - line.activeLine.location, contentLen))
        let insertion = "\n" + line.sourcePrefix
        let insertAt = line.activeLine.location + caretInLine
        let insertRange = NSRange(location: insertAt, length: 0)
        if textView.shouldChangeText(in: insertRange, replacementString: insertion) {
            storage.replaceCharacters(in: insertRange, with: insertion)
            textView.didChangeText()
            let nextCaret = insertAt + (insertion as NSString).length
            textView.setSelectedRange(NSRange(location: nextCaret, length: 0))
        }
        return true
    }

    /// Tab fallback when the caret isn't on a list line.
    ///
    /// Code fences get real indentation (4 spaces — a raw `\t` renders as a weird
    /// stretchy tab in the chip). Plain prose consumes the key instead of inserting an
    /// invisible tab character that would be sent verbatim to the model.
    @discardableResult
    static func handleTabIndentFallback(in textView: NSTextView) -> Bool {
        guard caretIsInFence(in: textView),
              let storage = textView.textStorage else { return true }
        let ns = storage.string as NSString
        let sel = textView.selectedRange()
        guard sel.length == 0, ns.length > 0 else { return true }
        let caret = min(sel.location, ns.length)
        let probe = min(max(0, caret - 1), max(0, ns.length - 1))
        let lineRange = ns.lineRange(for: NSRange(location: probe, length: 0))
        let contentLen = ns.substring(with: lineRange).hasSuffix("\n")
            ? lineRange.length - 1 : lineRange.length
        // Never indent a fence tick line — that would break the fence.
        let content = ns.substring(with: NSRange(location: lineRange.location, length: contentLen))
        guard !content.trimmingCharacters(in: .whitespaces).hasPrefix("```") else { return true }
        let spaces = String(repeating: " ", count: listIndentUnit)
        let insertAt = lineRange.location
        if textView.shouldChangeText(in: NSRange(location: insertAt, length: 0), replacementString: spaces) {
            storage.replaceCharacters(in: NSRange(location: insertAt, length: 0), with: spaces)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: caret + spaces.count, length: 0))
        }
        return true
    }

    /// ⇧Tab fallback: outdent code by one indent unit; prose is a no-op.
    @discardableResult
    static func handleTabOutdentFallback(in textView: NSTextView) -> Bool {
        guard caretIsInFence(in: textView),
              let storage = textView.textStorage else { return true }
        let ns = storage.string as NSString
        let sel = textView.selectedRange()
        guard sel.length == 0, ns.length > 0 else { return true }
        let caret = min(sel.location, ns.length)
        let probe = min(max(0, caret - 1), max(0, ns.length - 1))
        let lineRange = ns.lineRange(for: NSRange(location: probe, length: 0))
        let contentLen = ns.substring(with: lineRange).hasSuffix("\n")
            ? lineRange.length - 1 : lineRange.length
        guard contentLen > 0 else { return true }
        let content = ns.substring(with: NSRange(location: lineRange.location, length: contentLen))

        var remove = 0
        if content.hasPrefix("\t") {
            remove = 1
        } else {
            while remove < min(listIndentUnit, content.count),
                  (content as NSString).character(at: remove) == 32 {
                remove += 1
            }
        }
        guard remove > 0 else { return true }
        let range = NSRange(location: lineRange.location, length: remove)
        if textView.shouldChangeText(in: range, replacementString: "") {
            storage.replaceCharacters(in: range, with: "")
            textView.didChangeText()
            textView.setSelectedRange(
                NSRange(location: max(lineRange.location, caret - remove), length: 0)
            )
        }
        return true
    }

    /// ⇧↩ on a blockquote: continue `>` / exit empty quote (MarkdownEngine Enter path).
    @discardableResult
    static func handleQuoteEnter(in textView: NSTextView) -> Bool {
        guard !caretIsInFence(in: textView) else { return false }
        guard let storage = textView.textStorage else { return false }
        let ns = storage.string as NSString
        guard ns.length > 0 else { return false }
        let sel = textView.selectedRange()
        guard sel.length == 0 else { return false }
        let caret = min(sel.location, ns.length)
        let activeLine = caretLine(at: caret, in: ns)
        let hasTrailingNewline = ns.substring(with: activeLine).hasSuffix("\n")
        let contentLen = hasTrailingNewline ? activeLine.length - 1 : activeLine.length
        guard contentLen > 0 else { return false }
        let contentRange = NSRange(location: activeLine.location, length: contentLen)
        let content = ns.substring(with: contentRange)
        guard let re = try? NSRegularExpression(pattern: #"^(\s*)(>+)(\s?)(.*)$"#),
              let m = re.firstMatch(
                in: content,
                range: NSRange(location: 0, length: (content as NSString).length)
              ),
              m.numberOfRanges >= 5 else { return false }

        let nsContent = content as NSString
        let indent = nsContent.substring(with: m.range(at: 1))
        let markers = nsContent.substring(with: m.range(at: 2))
        let gap = nsContent.substring(with: m.range(at: 3))
        let body = nsContent.substring(with: m.range(at: 4))
        let prefixLen = m.range(at: 1).length + m.range(at: 2).length + m.range(at: 3).length

        if body.trimmingCharacters(in: .whitespaces).isEmpty {
            removeLinePrefix(in: textView, line: activeLine, prefixLength: prefixLen)
            return true
        }

        let gapOut = gap.isEmpty ? " " : gap
        let insertion = "\n" + indent + markers + gapOut
        let caretInLine = max(0, min(caret - activeLine.location, contentLen))
        let insertAt = activeLine.location + caretInLine
        let insertRange = NSRange(location: insertAt, length: 0)
        if textView.shouldChangeText(in: insertRange, replacementString: insertion) {
            storage.replaceCharacters(in: insertRange, with: insertion)
            textView.didChangeText()
            textView.setSelectedRange(
                NSRange(location: insertAt + (insertion as NSString).length, length: 0)
            )
        }
        return true
    }

    /// Backspace at (or inside) a quote prefix strips the whole `> ` so the line becomes
    /// plain text; deleting the hidden space alone left a still-quoted `>body`.
    @discardableResult
    static func handleQuoteBackspace(in textView: NSTextView) -> Bool {
        guard !caretIsInFence(in: textView) else { return false }
        guard let storage = textView.textStorage else { return false }
        let ns = storage.string as NSString
        let sel = textView.selectedRange()
        guard sel.length == 0, ns.length > 0 else { return false }
        let caret = min(sel.location, ns.length)
        let activeLine = caretLine(at: caret, in: ns)
        let hasTrailingNewline = ns.substring(with: activeLine).hasSuffix("\n")
        let contentLen = hasTrailingNewline ? activeLine.length - 1 : activeLine.length
        guard contentLen > 0 else { return false }
        let content = ns.substring(with: NSRange(location: activeLine.location, length: contentLen))
        guard let re = try? NSRegularExpression(pattern: #"^\s*>+\s?"#),
              let m = re.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length))
        else { return false }
        let prefixEnd = activeLine.location + m.range.length
        guard caret > activeLine.location, caret <= prefixEnd else { return false }
        removeLinePrefix(in: textView, line: activeLine, prefixLength: m.range.length)
        return true
    }

    /// Strip a leading marker run and park the caret at line start (empty-item exit).
    private static func removeLinePrefix(
        in textView: NSTextView,
        line: NSRange,
        prefixLength: Int
    ) {
        guard let storage = textView.textStorage else { return }
        let ns = storage.string as NSString
        let hasNewline = line.length > 0
            && ns.substring(with: NSRange(location: NSMaxRange(line) - 1, length: 1)) == "\n"
        let maxBodyLen = hasNewline ? line.length - 1 : line.length
        let removalLength = min(max(0, prefixLength), maxBodyLen)
        guard removalLength > 0 else { return }
        let removalRange = NSRange(location: line.location, length: removalLength)
        if textView.shouldChangeText(in: removalRange, replacementString: "") {
            storage.replaceCharacters(in: removalRange, with: "")
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: line.location, length: 0))
        }
    }

    /// Tab: nest one level deeper (prev+1 and absolute max; first item / fence = no-op).
    @discardableResult
    static func handleListIndent(in textView: NSTextView) -> Bool {
        guard !caretIsInFence(in: textView) else { return false }
        if textView.selectedRange().length > 0 {
            return shiftSelectedListLines(in: textView, deeper: true)
        }
        guard let storage = textView.textStorage,
              let line = listLine(atCaretIn: textView) else { return false }
        if let rebuilt = indentedListLine(line, in: storage.string as NSString) {
            replaceListLine(line, with: rebuilt, in: textView, caretBias: 0)
            renumberOrderedLists(around: line.activeLine.location, in: textView)
        }
        // First item / at the cap: consume Tab but don't nest.
        return true
    }

    /// ⇧Tab: un-nest one level; at root, unlist to a plain paragraph.
    @discardableResult
    static func handleListOutdent(in textView: NSTextView) -> Bool {
        guard !caretIsInFence(in: textView) else { return false }
        if textView.selectedRange().length > 0 {
            return shiftSelectedListLines(in: textView, deeper: false)
        }
        guard let line = listLine(atCaretIn: textView) else { return false }
        replaceListLine(line, with: outdentedListLine(line), in: textView, caretBias: 0)
        renumberOrderedLists(around: line.activeLine.location, in: textView)
        return true
    }

    /// Source for `line` one level deeper, or nil when nesting isn't allowed (first
    /// item, already parent+1, or the absolute ceiling).
    private static func indentedListLine(_ line: ListLine, in ns: NSString) -> String? {
        guard line.level + 1 <= listMaximumNestingLevel,
              let prev = previousListLine(before: line, in: ns),
              line.level < min(prev.level + 1, listMaximumNestingLevel)
        else { return nil }
        let unit = String(repeating: " ", count: listIndentUnit)
        let marker = line.isOrdered ? "\(line.number)." : markdownUnorderedMarker(line.marker)
        return line.indent + unit + marker + (line.gap.isEmpty ? " " : line.gap) + line.body
    }

    /// Source for `line` one level shallower; a root item becomes plain text.
    private static func outdentedListLine(_ line: ListLine) -> String {
        if line.level == 0, line.indent.count < listIndentUnit {
            return line.body
        }
        var stripped = line.indent
        var removed = 0
        while removed < listIndentUnit, !stripped.isEmpty {
            if stripped.hasPrefix("\t") {
                stripped = String(stripped.dropFirst())
                removed = listIndentUnit
            } else if stripped.hasPrefix(" ") {
                stripped = String(stripped.dropFirst())
                removed += 1
            } else {
                break
            }
        }
        let marker = line.isOrdered ? "\(line.number)." : markdownUnorderedMarker(line.marker)
        return stripped + marker + (line.gap.isEmpty ? " " : line.gap) + line.body
    }

    /// Tab / ⇧Tab with a selection: shift every list line it touches, top to bottom
    /// (so each line's parent+1 cap sees the already-shifted line above), then keep
    /// the same lines selected.
    private static func shiftSelectedListLines(in textView: NSTextView, deeper: Bool) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let sel = textView.selectedRange()
        var ns = storage.string as NSString
        let firstLine = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        // A selection ending at a line start doesn't include that line.
        let lastProbe = max(sel.location, NSMaxRange(sel) - 1)
        var end = NSMaxRange(ns.lineRange(for: NSRange(location: min(lastProbe, max(0, ns.length - 1)), length: 0)))
        var loc = firstLine.location
        var touchedList = false
        while loc < end, loc < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            let contentLen = ns.substring(with: lineRange).hasSuffix("\n") ? lineRange.length - 1 : lineRange.length
            let contentRange = NSRange(location: lineRange.location, length: contentLen)
            var nextLoc = NSMaxRange(lineRange)
            if contentLen > 0,
               let line = parseListLine(ns.substring(with: contentRange), contentRange: contentRange, activeLine: lineRange) {
                touchedList = true
                let rebuilt = deeper ? indentedListLine(line, in: ns) : outdentedListLine(line)
                if let rebuilt, textView.shouldChangeText(in: contentRange, replacementString: rebuilt) {
                    storage.replaceCharacters(in: contentRange, with: rebuilt)
                    textView.didChangeText()
                    let delta = (rebuilt as NSString).length - contentLen
                    end += delta
                    nextLoc += delta
                    ns = storage.string as NSString
                }
            }
            loc = nextLoc
        }
        guard touchedList else { return false }
        renumberOrderedLists(around: firstLine.location, in: textView)
        ns = storage.string as NSString
        let newEnd = min(end, ns.length)
        let trimmedEnd = newEnd > firstLine.location && ns.character(at: newEnd - 1) == 10 ? newEnd - 1 : newEnd
        textView.setSelectedRange(NSRange(location: firstLine.location, length: max(0, trimmedEnd - firstLine.location)))
        return true
    }

    /// Renumber ordered items in the list block containing `location`: each nest level
    /// counts on from its previous sibling; a new nested level starts at 1; the first
    /// root item keeps its own start (`5.` stays `5.`).
    static func renumberOrderedLists(around location: Int, in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        let probe = min(max(0, location), ns.length - 1)
        func parsedLine(_ lineRange: NSRange) -> ListLine? {
            let contentLen = ns.substring(with: lineRange).hasSuffix("\n") ? lineRange.length - 1 : lineRange.length
            guard contentLen > 0 else { return nil }
            let contentRange = NSRange(location: lineRange.location, length: contentLen)
            return parseListLine(ns.substring(with: contentRange), contentRange: contentRange, activeLine: lineRange)
        }
        // Walk up to the first line of this contiguous list block.
        var start = ns.lineRange(for: NSRange(location: probe, length: 0))
        guard parsedLine(start) != nil else { return }
        while start.location > 0 {
            let prev = ns.lineRange(for: NSRange(location: start.location - 1, length: 0))
            guard parsedLine(prev) != nil else { break }
            start = prev
        }

        var counters: [Int: Int] = [:]
        var edits: [(range: NSRange, text: String)] = []
        var loc = start.location
        while loc < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            guard let line = parsedLine(lineRange) else { break }
            let level = line.level
            for key in counters.keys where key > level { counters[key] = nil }
            if line.isOrdered {
                let want = counters[level].map { $0 + 1 } ?? (level == 0 ? line.number : 1)
                counters[level] = want
                if want != line.number {
                    let numLoc = line.contentRange.location + (line.indent as NSString).length
                    edits.append((NSRange(location: numLoc, length: "\(line.number)".count), "\(want)"))
                }
            } else {
                counters[level] = nil
            }
            loc = NSMaxRange(lineRange)
        }
        guard !edits.isEmpty else { return }
        var sel = textView.selectedRange()
        for edit in edits.reversed() {
            guard textView.shouldChangeText(in: edit.range, replacementString: edit.text) else { continue }
            storage.replaceCharacters(in: edit.range, with: edit.text)
            textView.didChangeText()
            let delta = (edit.text as NSString).length - edit.range.length
            if edit.range.location < sel.location {
                sel.location += delta
            } else if edit.range.location < NSMaxRange(sel) {
                sel.length += delta
            }
        }
        textView.setSelectedRange(NSRange(location: min(sel.location, storage.length),
                                          length: min(sel.length, storage.length - min(sel.location, storage.length))))
    }

    /// Backspace at the start of a list body → unlist (keep body) or join previous item.
    @discardableResult
    static func handleListBackspace(in textView: NSTextView) -> Bool {
        guard !caretIsInFence(in: textView) else { return false }
        guard let storage = textView.textStorage else { return false }
        let sel = textView.selectedRange()
        guard sel.length == 0 else { return false }
        guard let line = listLine(atCaretIn: textView) else { return false }
        let caret = min(sel.location, storage.length)
        // Only when caret is at/before the body start (in marker/gap or very start of body).
        guard caret <= line.bodyStart else { return false }

        let ns = storage.string as NSString
        if let prev = previousListLine(before: line, in: ns),
           !line.body.isEmpty {
            // Join: delete from end of previous body through our prefix; keep our body.
            let prevBodyEnd = prev.contentRange.location + prev.contentRange.length
            let joinStart = prevBodyEnd
            // Include the newline between items.
            let deleteEnd = line.bodyStart
            guard deleteEnd > joinStart else {
                replaceListLine(line, with: line.body, in: textView, caretBias: 0)
                return true
            }
            let deleteRange = NSRange(location: joinStart, length: deleteEnd - joinStart)
            if textView.shouldChangeText(in: deleteRange, replacementString: " ") {
                storage.replaceCharacters(in: deleteRange, with: " ")
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: joinStart + 1, length: 0))
            }
            return true
        }

        // No previous item (or empty body) → unlist to plain paragraph / blank.
        replaceListLine(line, with: line.body, in: textView, caretBias: 0)
        return true
    }

    /// Convert fancy bullets (`•○▪…`) back to markdown `-` so send stays literal.
    static func normalizeListMarkers(in textStorage: NSTextStorage) {
        let string = textStorage.string as NSString
        var loc = 0
        var replacements: [(NSRange, String)] = []
        while loc < string.length {
            let lineRange = string.lineRange(for: NSRange(location: loc, length: 0))
            defer { loc = NSMaxRange(lineRange) }
            let contentLen = string.substring(with: lineRange).hasSuffix("\n")
                ? lineRange.length - 1 : lineRange.length
            guard contentLen > 0 else { continue }
            let contentRange = NSRange(location: lineRange.location, length: contentLen)
            if string.character(at: contentRange.location) == 0xFFFC { continue }
            let content = string.substring(with: contentRange)
            guard let parsed = parseListLine(
                content,
                contentRange: contentRange,
                activeLine: lineRange
            ), !parsed.isOrdered else { continue }
            guard parsed.marker.unicodeScalars.contains(where: { fancyBulletChars.contains($0) })
            else { continue }
            let markerAbs = NSRange(
                location: contentRange.location + (parsed.indent as NSString).length,
                length: (parsed.marker as NSString).length
            )
            guard markerAbs.length == 1,
                  NSMaxRange(markerAbs) <= textStorage.length else { continue }
            if textStorage.attribute(.attachment, at: markerAbs.location, effectiveRange: nil) != nil {
                continue
            }
            replacements.append((markerAbs, "-"))
        }
        for (range, replacement) in replacements.reversed() {
            textStorage.replaceCharacters(in: range, with: replacement)
        }
    }

    /// Unordered list lines that need a painted bullet (source marker is hidden).
    /// Sites with `revealed == true` keep the raw `-`/`*` visible (caret/selection in syntax).
    static func unorderedListBulletSites(
        in string: NSString,
        caret: Int? = nil,
        selection: NSRange? = nil
    ) -> [(line: NSRange, level: Int, markerLocation: Int, bodyStart: Int, revealed: Bool)] {
        var sites: [(line: NSRange, level: Int, markerLocation: Int, bodyStart: Int, revealed: Bool)] = []
        var loc = 0
        var inFence = false
        while loc < string.length {
            let lineRange = string.lineRange(for: NSRange(location: loc, length: 0))
            defer { loc = NSMaxRange(lineRange) }
            let trimmed = string.substring(with: lineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            let contentLen = string.substring(with: lineRange).hasSuffix("\n")
                ? lineRange.length - 1 : lineRange.length
            guard contentLen > 0 else { continue }
            let contentRange = NSRange(location: lineRange.location, length: contentLen)
            let content = string.substring(with: contentRange)
            guard let parsed = parseListLine(
                content,
                contentRange: contentRange,
                activeLine: lineRange
            ), !parsed.isOrdered else { continue }
            let markerLoc = contentRange.location + (parsed.indent as NSString).length
            let syntax = NSRange(location: markerLoc, length: max(0, parsed.bodyStart - markerLoc))
            let revealed = listSyntaxRevealed(
                syntax: syntax, caret: caret, selection: selection, edgesReveal: false
            )
            sites.append((lineRange, parsed.level, markerLoc, parsed.bodyStart, revealed))
        }
        return sites
    }

    /// MarkdownEngine caret/selection reveal: show raw `-` while editing the marker.
    ///
    /// `edgesReveal` treats a caret touching either edge of the syntax as editing it
    /// (right for inline-code ticks). List markers pass false: the marker's end is the
    /// body start where you type, so revealing there flashed a raw `-` after `- ` until
    /// the first body character moved the caret on.
    private static func listSyntaxRevealed(
        syntax: NSRange,
        caret: Int?,
        selection: NSRange?,
        edgesReveal: Bool = true
    ) -> Bool {
        guard syntax.length > 0 else { return false }
        if let selection, selection.length > 0,
           NSIntersectionRange(selection, syntax).length > 0 {
            return true
        }
        if let caret {
            if edgesReveal {
                if caret == NSMaxRange(syntax) { return true }
                if NSLocationInRange(caret, syntax) { return true }
            } else if caret > syntax.location, caret < NSMaxRange(syntax) {
                return true
            }
        }
        return false
    }

    /// - Parameter darkChrome: SoftChrome card is dark (from SwiftUI `colorScheme`).
    ///   Prefer this over `NSApp` appearance — catalog colors were baking light-mode
    ///   (near-black) text onto charcoal SoftChrome.
    /// - Parameter caret: when inside a list marker / gap, keep the raw `-` visible
    ///   (MarkdownEngine caret-reveal) instead of painting a bullet over it.
    /// - Parameter selection: non-zero selection intersecting a marker also reveals.
    static func apply(
        to textStorage: NSTextStorage,
        darkChrome: Bool? = nil,
        caret: Int? = nil,
        selection: NSRange? = nil
    ) {
        let length = textStorage.length
        guard length > 0 else { return }

        let full = NSRange(location: 0, length: length)
        let bodyFont = NSFont.systemFont(ofSize: bodySize)
        let monoFont = NSFont.monospacedSystemFont(ofSize: monoSize, weight: .regular)
        let dark = darkChrome ?? isDarkAppearance()
        let label = dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.12, alpha: 1)
        let secondary = dark ? NSColor(white: 0.72, alpha: 1) : NSColor(white: 0.38, alpha: 1)
        // Bullets need extra contrast on SoftChrome — secondary alone read as “missing”.
        let bullet = dark ? NSColor(white: 0.86, alpha: 1) : NSColor(white: 0.32, alpha: 1)
        // High-contrast code — never rely on catalog colors here.
        let codeFg = dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.1, alpha: 1)
        let codeBg = dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.08)
        let fenceBg = dark ? NSColor(white: 1, alpha: 0.11) : NSColor(white: 0, alpha: 0.06)
        let quoteFg = dark ? NSColor(white: 0.88, alpha: 1) : NSColor(white: 0.28, alpha: 1)
        // Truly invisible — SoftChrome is a gradient and the code chip is lighter,
        // so matching a flat charcoal still left white/gray ``` ticks visible.
        let markerHide = NSColor.clear

        let basePara = NSMutableParagraphStyle()
        basePara.lineSpacing = 1
        basePara.paragraphSpacing = 1

        textStorage.beginEditing()
        defer { textStorage.endEditing() }

        // Preserve inline file chips (NSTextAttachment); only reset text runs.
        var attachmentRanges = IndexSet()
        textStorage.enumerateAttribute(.attachment, in: full) { value, range, _ in
            if value != nil {
                attachmentRanges.insert(integersIn: range.location..<(range.location + range.length))
            }
        }
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: label,
            .backgroundColor: NSColor.clear,
            .kern: 0,
            .paragraphStyle: basePara,
            .baselineOffset: 0,
            .underlineStyle: 0,
        ]
        var loc = 0
        while loc < length {
            if attachmentRanges.contains(loc) {
                loc += 1
                continue
            }
            var end = loc + 1
            while end < length, !attachmentRanges.contains(end) { end += 1 }
            textStorage.addAttributes(baseAttrs, range: NSRange(location: loc, length: end - loc))
            loc = end
        }

        let string = textStorage.string as NSString
        var protected = attachmentRanges

        styleFencedBlocks(
            in: textStorage,
            string: string,
            protected: &protected,
            monoFont: monoFont,
            codeFg: codeFg,
            fenceBg: fenceBg,
            secondary: secondary,
            markerHide: markerHide,
            caret: caret
        )

        styleInlineCode(
            in: textStorage,
            string: string,
            protected: protected,
            monoFont: monoFont,
            codeFg: codeFg,
            codeBg: codeBg,
            markerHide: markerHide,
            caret: caret,
            selection: selection
        )

        styleEmphasis(
            in: textStorage,
            string: string,
            protected: protected,
            secondary: secondary
        )

        styleURLs(
            in: textStorage,
            string: string,
            protected: protected,
            dark: dark
        )

        styleLinePrefixes(
            in: textStorage,
            string: string,
            protected: protected,
            bodyFont: bodyFont,
            label: label,
            bullet: bullet,
            quoteFg: quoteFg,
            caret: caret,
            selection: selection
        )
    }

    // MARK: - Fenced blocks

    private static func styleFencedBlocks(
        in textStorage: NSTextStorage,
        string: NSString,
        protected: inout IndexSet,
        monoFont: NSFont,
        codeFg: NSColor,
        fenceBg: NSColor,
        secondary: NSColor,
        markerHide: NSColor,
        caret: Int?
    ) {
        let revealedLine: NSRange? = {
            guard let caret, string.length > 0 else { return nil }
            return caretLine(at: caret, in: string)
        }()
        var loc = 0
        var inFence = false
        var contentStart = 0
        var codeRuns: [NSRange] = []
        var revealedFence: (line: NSRange, isOpener: Bool)?

        while loc < string.length {
            let lineRange = string.lineRange(for: NSRange(location: loc, length: 0))
            let line = string.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            // Opening/closing fence: line whose first non-space chars are ```.
            let isFence = trimmed.hasPrefix("```")

            if isFence {
                // Codex-style: collapse fence-only lines (ticks + optional lang) to ~0 height.
                // Never collapse a line that still has body text after ``` — scaffold should
                // have moved that onto its own line; if it hasn't, keep the body readable.
                let tokenLen = line.hasSuffix("\n") ? lineRange.length - 1 : lineRange.length
                var sameLineCode: NSRange?
                var isFenceOnlyLine = true
                // Caret on this fence line → keep the raw ticks visible and rows normal
                // height, so Backspace/selection can actually edit or delete the block.
                let revealed = revealedLine.map {
                    lineRange.location >= $0.location && lineRange.location < NSMaxRange($0)
                } ?? false
                if tokenLen > 0 {
                    let contentRange = NSRange(location: lineRange.location, length: tokenLen)
                    let nsLine = string.substring(with: contentRange) as NSString
                    var lead = 0
                    while lead < nsLine.length {
                        let u = nsLine.character(at: lead)
                        if u == 32 || u == 9 { lead += 1 } else { break }
                    }
                    let tickLen = min(3, max(0, nsLine.length - lead))
                    if tickLen > 0 {
                        let ticks = NSRange(location: contentRange.location + lead, length: tickLen)
                        if revealed {
                            textStorage.addAttributes([
                                .font: monoFont,
                                .foregroundColor: secondary,
                                .kern: 0,
                            ], range: ticks)
                        } else {
                            hideMarkdownMarkers(
                                in: textStorage,
                                range: ticks,
                                font: monoFont,
                                hideColor: markerHide,
                                collapseToWidth: 0
                            )
                        }
                    }
                    let afterTicks = lead + tickLen
                    if afterTicks < nsLine.length {
                        let rest = NSRange(
                            location: contentRange.location + afterTicks,
                            length: nsLine.length - afterTicks
                        )
                        let restText = string.substring(with: rest)
                            .trimmingCharacters(in: .whitespaces)
                        let languageTag = !inFence && fenceLanguage(inRest: restText) != nil
                        if languageTag || inFence {
                            // Language tag / closing junk — hide with the fence line.
                            if revealed {
                                textStorage.addAttributes([
                                    .font: monoFont,
                                    .foregroundColor: codeFg,
                                    .kern: 0,
                                ], range: rest)
                            } else {
                                hideMarkdownMarkers(
                                    in: textStorage,
                                    range: rest,
                                    font: monoFont,
                                    hideColor: markerHide,
                                    collapseToWidth: 0
                                )
                            }
                        } else if !inFence {
                            sameLineCode = rest
                            isFenceOnlyLine = false
                        }
                    }
                    if isFenceOnlyLine, !revealed {
                        let collapse = NSMutableParagraphStyle()
                        collapse.minimumLineHeight = 0.01
                        collapse.maximumLineHeight = 0.01
                        collapse.lineSpacing = 0
                        collapse.paragraphSpacing = 0
                        collapse.paragraphSpacingBefore = 0
                        // Collapse only the ``` tokens — leave the trailing newline with
                        // normal metrics so a caret after the fence isn't zero-height.
                        textStorage.addAttributes([.paragraphStyle: collapse], range: contentRange)
                        if line.hasSuffix("\n") {
                            let nl = NSRange(location: NSMaxRange(contentRange), length: 1)
                            let after = NSMutableParagraphStyle()
                            after.lineSpacing = 1
                            after.paragraphSpacing = 1
                            after.minimumLineHeight = ceil(bodySize + 2)
                            textStorage.addAttributes([.paragraphStyle: after], range: nl)
                        }
                    } else if isFenceOnlyLine, revealed {
                        revealedFence = (lineRange, !inFence)
                    }
                    protected.insert(
                        integersIn: contentRange.location..<(contentRange.location + contentRange.length)
                    )
                }

                if inFence {
                    let contentEnd = lineRange.location
                    if contentEnd > contentStart {
                        codeRuns.append(
                            NSRange(location: contentStart, length: contentEnd - contentStart)
                        )
                    }
                    inFence = false
                } else {
                    inFence = true
                    // Same-line body after ``` starts the code run immediately.
                    if let sameLineCode {
                        contentStart = sameLineCode.location
                    } else {
                        contentStart = NSMaxRange(lineRange)
                    }
                }
            }

            loc = NSMaxRange(lineRange)
        }

        if inFence, string.length > contentStart {
            codeRuns.append(
                NSRange(location: contentStart, length: string.length - contentStart)
            )
        }

        for content in codeRuns {
            // Clear character bg — the text view paints a rounded chip behind the run.
            // Never setAttributes across file-chip attachments (that orphaned U+FFFC bars).
            paintCodeRun(
                in: textStorage,
                range: content,
                font: monoFont,
                foreground: codeFg,
                background: NSColor.clear,
                fenced: true
            )
            protected.insert(integersIn: content.location..<(content.location + content.length))
        }
        if let revealedFence {
            styleRevealedFenceLine(revealedFence.line, isOpener: revealedFence.isOpener, in: textStorage)
        }
        _ = fenceBg
    }

    /// A fence line under the caret is drawn inside the chip: aligned with the code
    /// body and carrying the block's outer pad, so the raw ticks don't float above the
    /// chip at the prose margin.
    private static func styleRevealedFenceLine(
        _ lineRange: NSRange,
        isOpener: Bool,
        in textStorage: NSTextStorage
    ) {
        let string = textStorage.string as NSString
        let outerPad = codeBlockParagraphPad + codeBlockInsetY
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        para.firstLineHeadIndent = codeBlockTextInset
        para.headIndent = codeBlockTextInset
        para.tailIndent = -codeBlockTextInset
        para.paragraphSpacingBefore = isOpener ? outerPad : 0
        para.paragraphSpacing = isOpener ? 0 : outerPad
        textStorage.addAttributes([.paragraphStyle: para], range: lineRange)

        // The neighbouring body line no longer owns the outer pad.
        let neighbour: NSRange? = {
            if isOpener {
                let next = NSMaxRange(lineRange)
                guard next < string.length else { return nil }
                return string.lineRange(for: NSRange(location: next, length: 0))
            }
            guard lineRange.location > 0 else { return nil }
            return string.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
        }()
        guard let neighbour, neighbour.length > 0,
              let existing = textStorage.attribute(
                .paragraphStyle, at: neighbour.location, effectiveRange: nil
              ) as? NSParagraphStyle,
              existing.firstLineHeadIndent == codeBlockTextInset
        else { return }
        let adjusted = NSMutableParagraphStyle()
        adjusted.setParagraphStyle(existing)
        if isOpener {
            adjusted.paragraphSpacingBefore = 0
        } else {
            adjusted.paragraphSpacing = 0
        }
        textStorage.addAttributes([.paragraphStyle: adjusted], range: neighbour)
    }

    private static func paintCodeRun(
        in textStorage: NSTextStorage,
        range: NSRange,
        font: NSFont,
        foreground: NSColor,
        background: NSColor,
        fenced: Bool = false
    ) {
        guard range.length > 0 else { return }
        let string = textStorage.string as NSString
        let end = NSMaxRange(range)

        // Walk line-by-line so fenced blocks get outer pad without puffing every row.
        var loc = range.location
        while loc < end {
            let lineRange = string.lineRange(for: NSRange(location: loc, length: 0))
            let sliceStart = max(lineRange.location, range.location)
            let sliceEnd = min(NSMaxRange(lineRange), end)
            let slice = NSRange(location: sliceStart, length: max(0, sliceEnd - sliceStart))
            defer { loc = NSMaxRange(lineRange) }
            guard slice.length > 0 else { continue }

            let para = NSMutableParagraphStyle()
            if let existing = textStorage.attribute(
                .paragraphStyle, at: slice.location, effectiveRange: nil
            ) as? NSParagraphStyle {
                para.setParagraphStyle(existing)
            }
            if fenced {
                para.lineSpacing = 3
                para.firstLineHeadIndent = codeBlockTextInset
                para.headIndent = codeBlockTextInset
                para.tailIndent = -codeBlockTextInset
                // Space above the first body line so chrome doesn't sit on prior prose/URLs
                // (``` itself is collapsed to ~0 height).
                para.paragraphSpacingBefore = sliceStart == range.location
                    ? codeBlockParagraphPad + codeBlockInsetY
                    : 0
                // Pad after the last line of the run (including its newline if present).
                let isLast = sliceEnd >= end
                para.paragraphSpacing = isLast ? codeBlockParagraphPad + codeBlockInsetY : 0
            }

            var i = slice.location
            while i < sliceEnd {
                if textStorage.attribute(.attachment, at: i, effectiveRange: nil) != nil {
                    i += 1
                    continue
                }
                var runEnd = i + 1
                while runEnd < sliceEnd,
                      textStorage.attribute(.attachment, at: runEnd, effectiveRange: nil) == nil {
                    runEnd += 1
                }
                textStorage.addAttributes([
                    .font: font,
                    .foregroundColor: foreground,
                    .backgroundColor: background,
                    .kern: 0,
                    .baselineOffset: 0,
                    .paragraphStyle: para,
                ], range: NSRange(location: i, length: runEnd - i))
                i = runEnd
            }
        }
    }

    // MARK: - Inline code

    private static func styleInlineCode(
        in textStorage: NSTextStorage,
        string: NSString,
        protected: IndexSet,
        monoFont: NSFont,
        codeFg: NSColor,
        codeBg: NSColor,
        markerHide: NSColor,
        caret: Int?,
        selection: NSRange?
    ) {
        guard let regex = try? NSRegularExpression(pattern: "`([^`\\n]+)`") else { return }
        let full = NSRange(location: 0, length: string.length)
        regex.enumerateMatches(in: string as String, options: [], range: full) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            let all = match.range(at: 0)
            let inner = match.range(at: 1)
            guard all.location != NSNotFound, inner.location != NSNotFound else { return }
            if rangeOverlapsProtected(all, protected) { return }

            let open = NSRange(location: all.location, length: 1)
            let close = NSRange(location: NSMaxRange(all) - 1, length: 1)
            // Caret/selection touching either tick → keep the raw backtick visible so it
            // can be edited or deleted (same reveal contract as list markers and fences).
            let revealed = listSyntaxRevealed(syntax: open, caret: caret, selection: selection)
                || listSyntaxRevealed(syntax: close, caret: caret, selection: selection)
            if revealed {
                textStorage.addAttributes([
                    .font: monoFont,
                    .foregroundColor: codeFg.withAlphaComponent(0.55),
                    .backgroundColor: codeBg,
                    .kern: 0,
                ], range: open)
                textStorage.addAttributes([
                    .font: monoFont,
                    .foregroundColor: codeFg.withAlphaComponent(0.55),
                    .backgroundColor: codeBg,
                    .kern: 0,
                ], range: close)
            } else {
                hideMarkdownMarkers(
                    in: textStorage,
                    range: open,
                    font: monoFont,
                    hideColor: markerHide,
                    collapseToWidth: 0
                )
                hideMarkdownMarkers(
                    in: textStorage,
                    range: close,
                    font: monoFont,
                    hideColor: markerHide,
                    collapseToWidth: 0
                )
            }
            paintCodeRun(
                in: textStorage,
                range: inner,
                font: monoFont,
                foreground: codeFg,
                background: codeBg
            )
        }
    }

    /// Keep markdown markers in the string (for send) but don’t paint them.
    /// - Parameter keepLineMetrics: when true (quotes), keep the caller's font size so an
    ///   empty `>` line still has normal height for the painted quote bar. Fence ticks use
    ///   a near-zero font so they don't show over the code chip.
    private static func hideMarkdownMarkers(
        in textStorage: NSTextStorage,
        range: NSRange,
        font: NSFont,
        hideColor: NSColor? = nil,
        collapseToWidth: CGFloat? = nil,
        keepLineMetrics: Bool = false
    ) {
        guard range.length > 0 else { return }
        let color = hideColor ?? NSColor.clear
        let hideFont = keepLineMetrics
            ? font
            : NSFont.monospacedSystemFont(ofSize: 0.01, weight: .regular)
        textStorage.addAttributes([
            .foregroundColor: color,
            .backgroundColor: NSColor.clear,
            .font: hideFont,
            .kern: 0,
        ], range: range)

        guard let target = collapseToWidth else { return }
        // Collapse glyph advance so a hidden marker doesn’t push the body far right.
        let ns = textStorage.string as NSString
        let fragment = ns.substring(with: range)
        // Measure against the caller's font (pre-hide) so we know how much to shrink.
        let natural = (fragment as NSString).size(withAttributes: [.font: font]).width
        let shrink = natural - max(0, target)
        guard shrink > 0.5 else { return }
        let last = NSRange(location: NSMaxRange(range) - 1, length: 1)
        let existing = (textStorage.attribute(.kern, at: last.location, effectiveRange: nil) as? CGFloat) ?? 0
        textStorage.addAttributes([.kern: existing - shrink], range: last)
    }

    private static func isDarkAppearance() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Safe luminance 0…1 for SoftChrome marker detection (never calls `whiteComponent` on RGB).
    private static func grayLevel(_ color: NSColor) -> CGFloat {
        if let gray = color.usingColorSpace(.deviceGray) {
            return gray.whiteComponent
        }
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return -1 }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r + g + b) / 3
    }

    static func typingAttributes(darkChrome: Bool? = nil) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 1
        para.paragraphSpacing = 1
        let dark = darkChrome ?? isDarkAppearance()
        return [
            .font: NSFont.systemFont(ofSize: bodySize),
            .foregroundColor: dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.12, alpha: 1),
            .backgroundColor: NSColor.clear,
            .kern: 0,
            .paragraphStyle: para,
            .baselineOffset: 0,
        ]
    }

    /// Prefer mono + chip background when the caret sits in a code run.
    static func typingAttributes(for textView: NSTextView, darkChrome: Bool? = nil) -> [NSAttributedString.Key: Any] {
        let dark = darkChrome ?? isDarkAppearance()
        var attrs = typingAttributes(darkChrome: dark)
        guard let storage = textView.textStorage, storage.length > 0 else { return attrs }
        let loc = textView.selectedRange().location
        let idx = min(max(0, loc > 0 ? loc - 1 : 0), storage.length - 1)
        let at = storage.attributes(at: idx, effectiveRange: nil)
        if let fg = at[.foregroundColor] as? NSColor {
            // Hidden markdown markers (clear / SoftChrome-matched) — don’t inherit.
            // Must use gray space (or RGB average): `whiteComponent` on sRGB throws
            // NSException and AppKit aborts via _crashOnException.
            if fg.alphaComponent < 0.08 { return attrs }
            let w = Self.grayLevel(fg)
            if dark, abs(w - 0.14) < 0.03 { return attrs }
            if !dark, w > 0.95 { return attrs }
        }
        if let bg = at[.backgroundColor] as? NSColor, bg.alphaComponent > 0.03 {
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: monoSize, weight: .regular)
            attrs[.foregroundColor] = dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.1, alpha: 1)
            attrs[.backgroundColor] = bg
        }
        return attrs
    }

    // MARK: - URLs

    /// Paint bare `https://…` / `http://…` / `www.…` links blue (skip code / chips).
    private static func styleURLs(
        in textStorage: NSTextStorage,
        string: NSString,
        protected: IndexSet,
        dark: Bool
    ) {
        // Trailing punctuation common in prose is trimmed from the match.
        let pattern = #"((?:https?://|www\.)[^\s<>\[\]{}\"'`]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return
        }
        let linkBlue = dark
            ? NSColor(srgbRed: 0.45, green: 0.72, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.10, green: 0.42, blue: 0.95, alpha: 1)
        let full = NSRange(location: 0, length: string.length)
        regex.enumerateMatches(in: string as String, options: [], range: full) { match, _, _ in
            guard let match, match.numberOfRanges >= 1 else { return }
            var range = match.range(at: 1)
            guard range.location != NSNotFound, range.length > 0 else { return }
            if rangeOverlapsProtected(range, protected) { return }

            // Drop trailing sentence punctuation that isn't part of the URL.
            while range.length > 0 {
                let last = string.character(at: NSMaxRange(range) - 1)
                let trim: Bool
                switch last {
                case 0x2E, 0x2C, 0x3B, 0x3A, 0x21, 0x3F, 0x29, 0x5D, 0x7D, 0x27, 0x22:
                    // . , ; : ! ? ) ] } ' "
                    trim = true
                default:
                    trim = false
                }
                if trim {
                    range.length -= 1
                } else {
                    break
                }
            }
            guard range.length > 0 else { return }
            textStorage.addAttributes([
                .foregroundColor: linkBlue,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: linkBlue.withAlphaComponent(0.55),
            ], range: range)
        }
    }

    // MARK: - Emphasis

    private static func styleEmphasis(
        in textStorage: NSTextStorage,
        string: NSString,
        protected: IndexSet,
        secondary: NSColor
    ) {
        let boldFont = NSFont.systemFont(ofSize: bodySize, weight: .semibold)
        let italicFont: NSFont = {
            let base = NSFont.systemFont(ofSize: bodySize)
            return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        }()

        func apply(pattern: String, innerFont: NSFont) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let full = NSRange(location: 0, length: string.length)
            regex.enumerateMatches(in: string as String, options: [], range: full) { match, _, _ in
                guard let match, match.numberOfRanges >= 2 else { return }
                let all = match.range(at: 0)
                let inner = match.range(at: 1)
                guard all.location != NSNotFound, inner.location != NSNotFound else { return }
                if rangeOverlapsProtected(all, protected) { return }
                if let bg = textStorage.attribute(.backgroundColor, at: inner.location, effectiveRange: nil) as? NSColor,
                   bg.alphaComponent > 0.01 {
                    return
                }

                let markerLen = (all.length - inner.length) / 2
                if markerLen > 0 {
                    let open = NSRange(location: all.location, length: markerLen)
                    let close = NSRange(location: NSMaxRange(inner), length: markerLen)
                    textStorage.addAttributes([
                        .foregroundColor: secondary.withAlphaComponent(0.4),
                    ], range: open)
                    textStorage.addAttributes([
                        .foregroundColor: secondary.withAlphaComponent(0.4),
                    ], range: close)
                }
                textStorage.addAttributes([.font: innerFont], range: inner)
            }
        }

        apply(pattern: #"\*\*([^*\n]+)\*\*"#, innerFont: boldFont)
        apply(pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#, innerFont: italicFont)
    }

    // MARK: - Lists / quotes (Codex-style indent + markers)

    private static func styleLinePrefixes(
        in textStorage: NSTextStorage,
        string: NSString,
        protected: IndexSet,
        bodyFont: NSFont,
        label: NSColor,
        bullet: NSColor,
        quoteFg: NSColor,
        caret: Int?,
        selection: NSRange?
    ) {
        var loc = 0
        while loc < string.length {
            let lineRange = string.lineRange(for: NSRange(location: loc, length: 0))
            defer { loc = NSMaxRange(lineRange) }
            if rangeOverlapsProtected(lineRange, protected) { continue }

            let line = string.substring(with: lineRange)
            // Style the full line including the newline so paragraph indent doesn't
            // leak onto the following paragraph via the terminator's attributes.
            let contentLen = line.hasSuffix("\n") ? lineRange.length - 1 : lineRange.length
            guard contentLen > 0 else { continue }
            let contentRange = NSRange(location: lineRange.location, length: contentLen)
            let content = string.substring(with: contentRange)

            // Prefix only — do not include the body in the match (that painted the
            // whole line as “gap” / marker and made bullets easy to lose).
            if let match = content.range(of: #"^(\s*)([-*•○◦▪■])(\s+)"#, options: .regularExpression) {
                applyListStyle(
                    in: textStorage,
                    paragraphRange: lineRange,
                    contentRange: contentRange,
                    line: content,
                    match: match,
                    bodyFont: bodyFont,
                    bulletColor: bullet,
                    bodyColor: label,
                    caret: caret,
                    selection: selection
                )
                continue
            }
            if let match = content.range(of: #"^(\s*)(\d+)\.(\s+)"#, options: .regularExpression) {
                applyOrderedListStyle(
                    in: textStorage,
                    paragraphRange: lineRange,
                    contentRange: contentRange,
                    line: content,
                    match: match,
                    bodyFont: bodyFont,
                    markerColor: bullet,
                    bodyColor: label
                )
                continue
            }
            if let match = content.range(of: #"^(\s*)>+(\s?)"#, options: .regularExpression) {
                applyQuoteStyle(
                    in: textStorage,
                    paragraphRange: lineRange,
                    contentRange: contentRange,
                    line: content,
                    match: match,
                    bodyFont: bodyFont,
                    quoteFg: quoteFg,
                    markerColor: bullet,
                    caret: caret,
                    selection: selection
                )
            }
        }
    }

    /// Character ranges that should show a left quote bar (for text-view drawing).
    static func quoteLineRanges(in string: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var loc = 0
        var inFence = false
        while loc < string.length {
            let lineRange = string.lineRange(for: NSRange(location: loc, length: 0))
            defer { loc = NSMaxRange(lineRange) }
            let line = string.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            let contentLen = line.hasSuffix("\n") ? lineRange.length - 1 : lineRange.length
            guard contentLen > 0 else { continue }
            let content = string.substring(with: NSRange(location: lineRange.location, length: contentLen))
            if content.range(of: #"^(\s*)>"#, options: .regularExpression) != nil {
                ranges.append(NSRange(location: lineRange.location, length: contentLen))
            }
        }
        return ranges
    }

    /// Split a list prefix into its leading indent and the marker + gap. The indent is
    /// always collapsed to zero width; callers draw nesting with `listLevelIndent`.
    private static func splitListIndent(
        prefix: NSRange,
        line: String,
        contentRange: NSRange,
        textStorage: NSTextStorage,
        bodyFont: NSFont
    ) -> (indent: NSRange, marker: NSRange, level: Int) {
        let nsLine = line as NSString
        var spaces = 0
        var lead = 0
        while lead < prefix.length {
            let u = nsLine.character(at: prefix.location + lead)
            if u == 32 { spaces += 1 } else if u == 9 { spaces += listIndentUnit } else { break }
            lead += 1
        }
        let level = min(spaces / listIndentUnit, listMaximumNestingLevel)
        let indent = NSRange(location: contentRange.location + prefix.location, length: lead)
        if indent.length > 0 {
            hideMarkdownMarkers(
                in: textStorage,
                range: indent,
                font: bodyFont,
                hideColor: NSColor.clear,
                collapseToWidth: 0,
                keepLineMetrics: false
            )
        }
        let marker = NSRange(location: NSMaxRange(indent), length: prefix.length - lead)
        return (indent, marker, level)
    }

    private static func applyListStyle(
        in textStorage: NSTextStorage,
        paragraphRange: NSRange,
        contentRange: NSRange,
        line: String,
        match: Range<String.Index>,
        bodyFont: NSFont,
        bulletColor: NSColor,
        bodyColor: NSColor,
        caret: Int?,
        selection: NSRange?
    ) {
        let prefix = NSRange(match, in: line)
        let (indentRange, absMarker, level) = splitListIndent(
            prefix: prefix,
            line: line,
            contentRange: contentRange,
            textStorage: textStorage,
            bodyFont: bodyFont
        )
        _ = indentRange
        // Nesting = leading spaces in source, drawn as paragraph indent (never kern —
        // SoftChrome turns clear+kern runs into dash/arrow stubs).
        let para = NSMutableParagraphStyle()
        let levelX = CGFloat(level) * listLevelIndent
        para.firstLineHeadIndent = levelX + listBulletGutter
        para.headIndent = levelX + listBulletGutter + listHangIndent
        para.lineSpacing = 1
        para.paragraphSpacingBefore = 0
        // An empty item (`- ` just typed) is only collapsed marker glyphs; without a
        // floor the row shrinks to ~0, giving a speck-sized caret and a raised bullet.
        para.minimumLineHeight = bodyNaturalLineHeight
        textStorage.addAttributes([.paragraphStyle: para], range: paragraphRange)

        let revealed = listSyntaxRevealed(
            syntax: absMarker, caret: caret, selection: selection, edgesReveal: false
        )
        if revealed {
            // Caret/selection in syntax → show raw `-`/`*` (MarkdownEngine reveal).
            textStorage.addAttributes([
                .font: NSFont.systemFont(ofSize: bodySize, weight: .semibold),
                .foregroundColor: bulletColor,
                .kern: 0,
            ], range: absMarker)
        } else {
            // Collapse the entire `- `/`* ` prefix; glyphs suppressed in draw.
            hideMarkdownMarkers(
                in: textStorage,
                range: absMarker,
                font: bodyFont,
                hideColor: NSColor.clear,
                collapseToWidth: 0,
                keepLineMetrics: false
            )
        }
        let bodyStart = NSMaxRange(absMarker)
        let bodyLen = NSMaxRange(contentRange) - bodyStart
        if bodyLen > 0 {
            textStorage.addAttributes([
                .font: bodyFont,
                .foregroundColor: bodyColor,
                .kern: 0,
            ], range: NSRange(location: bodyStart, length: bodyLen))
        }
    }

    private static func applyOrderedListStyle(
        in textStorage: NSTextStorage,
        paragraphRange: NSRange,
        contentRange: NSRange,
        line: String,
        match: Range<String.Index>,
        bodyFont: NSFont,
        markerColor: NSColor,
        bodyColor: NSColor
    ) {
        let prefix = NSRange(match, in: line)
        let (_, absMarker, level) = splitListIndent(
            prefix: prefix,
            line: line,
            contentRange: contentRange,
            textStorage: textStorage,
            bodyFont: bodyFont
        )
        let levelX = CGFloat(level) * listLevelIndent
        let markerWidth = ((textStorage.string as NSString).substring(with: absMarker) as NSString)
            .size(withAttributes: [.font: bodyFont]).width
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = levelX
        para.headIndent = levelX + ceil(markerWidth)
        para.lineSpacing = 1
        textStorage.addAttributes([.paragraphStyle: para], range: paragraphRange)
        textStorage.addAttributes([
            .font: bodyFont,
            .foregroundColor: markerColor,
        ], range: absMarker)
        let bodyStart = NSMaxRange(absMarker)
        let bodyLen = NSMaxRange(contentRange) - bodyStart
        if bodyLen > 0 {
            textStorage.addAttributes([
                .font: bodyFont,
                .foregroundColor: bodyColor,
                .kern: 0,
            ], range: NSRange(location: bodyStart, length: bodyLen))
        }
    }

    private static func applyQuoteStyle(
        in textStorage: NSTextStorage,
        paragraphRange: NSRange,
        contentRange: NSRange,
        line: String,
        match: Range<String.Index>,
        bodyFont: NSFont,
        quoteFg: NSColor,
        markerColor: NSColor,
        caret: Int?,
        selection: NSRange?
    ) {
        let markerRange = NSRange(match, in: line)
        let absMarker = NSRange(location: contentRange.location + markerRange.location, length: markerRange.length)
        let revealed = listSyntaxRevealed(
            syntax: absMarker, caret: caret, selection: selection, edgesReveal: false
        )
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = quoteIndent
        para.headIndent = quoteIndent
        para.lineSpacing = 1
        // Empty `>` must keep a full line so the painted bar and caret aren't specks.
        para.minimumLineHeight = bodyNaturalLineHeight
        textStorage.addAttributes([.paragraphStyle: para], range: paragraphRange)
        if revealed {
            textStorage.addAttributes([
                .font: bodyFont,
                .foregroundColor: markerColor,
            ], range: absMarker)
        } else {
            // Keep `>` in the string for markdown send but give it no width, so the
            // first line and wrapped lines both start at `quoteIndent`.
            hideMarkdownMarkers(in: textStorage, range: absMarker, font: bodyFont)
        }
        let bodyStart = NSMaxRange(absMarker)
        let bodyLen = NSMaxRange(contentRange) - bodyStart
        if bodyLen > 0 {
            textStorage.addAttributes([
                .font: bodyFont,
                .foregroundColor: quoteFg,
            ], range: NSRange(location: bodyStart, length: bodyLen))
        }
    }

    private static func rangeOverlapsProtected(_ range: NSRange, _ protected: IndexSet) -> Bool {
        guard range.length > 0 else { return protected.contains(range.location) }
        let end = range.location + range.length
        return protected.intersects(integersIn: range.location..<end)
    }
}
