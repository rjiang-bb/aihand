import AppKit

/// Non-destructive markdown highlighting for the composer `NSTextView`.
/// Keeps the plain string intact (send / @ / / / paste still see source text).
enum ComposerMarkdownStyler {
    private static let bodySize: CGFloat = 14.5
    private static let monoSize: CGFloat = 13.0
    private static let listIndent: CGFloat = 4
    /// Gutter for the painted quote bar (marker width is collapsed separately).
    private static let quoteIndent: CGFloat = 8
    static let quoteBarWidth: CGFloat = 2.5
    static let quoteBarInset: CGFloat = 1.5

    /// Cursor-style list Enter: continue the list, or exit on an empty item.
    /// Returns `true` when Enter was handled (caller should not submit).
    @discardableResult
    static func handleListEnter(in textView: NSTextView) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let ns = storage.string as NSString
        let sel = textView.selectedRange()
        guard sel.length == 0, ns.length > 0 else { return false }

        let caret = min(sel.location, ns.length)
        let probe = min(caret, max(0, ns.length - 1))
        let activeLine = ns.lineRange(for: NSRange(location: probe, length: 0))
        let hasTrailingNewline = ns.substring(with: activeLine).hasSuffix("\n")
        let contentLen = hasTrailingNewline ? activeLine.length - 1 : activeLine.length
        guard contentLen > 0 else { return false }
        let contentRange = NSRange(location: activeLine.location, length: contentLen)
        let content = ns.substring(with: contentRange)
        let nsContent = content as NSString
        let fullContent = NSRange(location: 0, length: nsContent.length)

        let prefix: String
        let body: String
        if let re = try? NSRegularExpression(pattern: #"^(\s*)([-*•])(\s+)(.*)$"#),
           let m = re.firstMatch(in: content, range: fullContent),
           m.numberOfRanges >= 5 {
            let indent = nsContent.substring(with: m.range(at: 1))
            let marker = nsContent.substring(with: m.range(at: 2))
            let gap = nsContent.substring(with: m.range(at: 3))
            body = nsContent.substring(with: m.range(at: 4))
            prefix = indent + marker + (gap.isEmpty ? " " : gap)
        } else if let re = try? NSRegularExpression(pattern: #"^(\s*)(\d+)\.(\s+)(.*)$"#),
                  let m = re.firstMatch(in: content, range: fullContent),
                  m.numberOfRanges >= 5 {
            let indent = nsContent.substring(with: m.range(at: 1))
            let number = Int(nsContent.substring(with: m.range(at: 2))) ?? 1
            let gap = nsContent.substring(with: m.range(at: 3))
            body = nsContent.substring(with: m.range(at: 4))
            prefix = indent + "\(number + 1)." + (gap.isEmpty ? " " : gap)
        } else {
            return false
        }

        if body.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty item → exit list (strip the marker, leave a blank line).
            if textView.shouldChangeText(in: contentRange, replacementString: "") {
                storage.replaceCharacters(in: contentRange, with: "")
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: contentRange.location, length: 0))
            }
            return true
        }

        // Split at caret when mid-item; otherwise continue after the line.
        let caretInLine = max(0, min(caret - activeLine.location, contentLen))
        let insertion = "\n" + prefix
        let insertAt = activeLine.location + caretInLine
        let insertRange = NSRange(location: insertAt, length: 0)
        if textView.shouldChangeText(in: insertRange, replacementString: insertion) {
            storage.replaceCharacters(in: insertRange, with: insertion)
            textView.didChangeText()
            let nextCaret = insertAt + (insertion as NSString).length
            textView.setSelectedRange(NSRange(location: nextCaret, length: 0))
        }
        return true
    }

    /// Codex-style: turn leading `-` / `*` list markers into `•` (same UTF-16 width).
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
            // Skip lines that start with an inline file chip (U+FFFC).
            if contentLen > 0, string.character(at: contentRange.location) == 0xFFFC {
                continue
            }
            let content = string.substring(with: contentRange)
            guard let match = content.range(of: #"^(\s*)([-*])(\s+)"#, options: .regularExpression) else {
                continue
            }
            let full = NSRange(match, in: content)
            let nsContent = content as NSString
            let fullMarker = nsContent.substring(with: full)
            guard let lead = fullMarker.range(of: #"^\s*"#, options: .regularExpression) else { continue }
            let leadLen = NSRange(lead, in: fullMarker).length
            let markerAbs = NSRange(location: contentRange.location + full.location + leadLen, length: 1)
            if textStorage.attribute(.attachment, at: markerAbs.location, effectiveRange: nil) != nil {
                continue
            }
            let ch = nsContent.character(at: full.location + leadLen)
            if ch == 0x2D /* - */ || ch == 0x2A /* * */ {
                replacements.append((markerAbs, "•"))
            }
        }
        // Apply back-to-front so ranges stay valid.
        for (range, replacement) in replacements.reversed() {
            textStorage.replaceCharacters(in: range, with: replacement)
        }
    }

    /// - Parameter darkChrome: SoftChrome card is dark (from SwiftUI `colorScheme`).
    ///   Prefer this over `NSApp` appearance — catalog colors were baking light-mode
    ///   (near-black) text onto charcoal SoftChrome.
    static func apply(to textStorage: NSTextStorage, darkChrome: Bool? = nil) {
        let length = textStorage.length
        guard length > 0 else { return }

        let full = NSRange(location: 0, length: length)
        let bodyFont = NSFont.systemFont(ofSize: bodySize)
        let monoFont = NSFont.monospacedSystemFont(ofSize: monoSize, weight: .regular)
        let dark = darkChrome ?? isDarkAppearance()
        let label = dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.12, alpha: 1)
        let secondary = dark ? NSColor(white: 0.72, alpha: 1) : NSColor(white: 0.38, alpha: 1)
        // High-contrast code — never rely on catalog colors here.
        let codeFg = dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.1, alpha: 1)
        let codeBg = dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.08)
        let fenceBg = dark ? NSColor(white: 1, alpha: 0.11) : NSColor(white: 0, alpha: 0.06)
        let quoteFg = dark ? NSColor(white: 0.88, alpha: 1) : NSColor(white: 0.28, alpha: 1)
        let quoteBg = dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.05)
        // Match SoftChrome charcoal so ``` ticks disappear without alpha=0 inheritance.
        let markerHide = dark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 1, alpha: 1)

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
            markerHide: markerHide
        )

        styleInlineCode(
            in: textStorage,
            string: string,
            protected: protected,
            monoFont: monoFont,
            codeFg: codeFg,
            codeBg: codeBg,
            markerHide: markerHide
        )

        styleEmphasis(
            in: textStorage,
            string: string,
            protected: protected,
            secondary: secondary
        )

        styleLinePrefixes(
            in: textStorage,
            string: string,
            protected: protected,
            bodyFont: bodyFont,
            secondary: secondary,
            quoteFg: quoteFg,
            quoteBg: quoteBg
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
        markerHide: NSColor
    ) {
        var loc = 0
        var inFence = false
        var contentStart = 0
        var codeRuns: [NSRange] = []

        while loc < string.length {
            let lineRange = string.lineRange(for: NSRange(location: loc, length: 0))
            let line = string.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            // Opening/closing fence: line whose first non-space chars are ```.
            let isFence = trimmed.hasPrefix("```")

            if isFence {
                // Hide/collapse only the ``` ticks; mute any info string without
                // collapsing the whole line (that was eating following body layout).
                let tokenLen = line.hasSuffix("\n") ? lineRange.length - 1 : lineRange.length
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
                        hideMarkdownMarkers(
                            in: textStorage,
                            range: ticks,
                            font: monoFont,
                            hideColor: markerHide,
                            collapseToWidth: 0
                        )
                    }
                    let afterTicks = lead + tickLen
                    if afterTicks < nsLine.length {
                        let info = NSRange(
                            location: contentRange.location + afterTicks,
                            length: nsLine.length - afterTicks
                        )
                        hideMarkdownMarkers(
                            in: textStorage,
                            range: info,
                            font: monoFont,
                            hideColor: markerHide,
                            collapseToWidth: nil
                        )
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
                    contentStart = NSMaxRange(lineRange)
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
            paintCodeRun(
                in: textStorage,
                range: content,
                font: monoFont,
                foreground: codeFg,
                background: fenceBg
            )
            protected.insert(integersIn: content.location..<(content.location + content.length))
        }
    }

    private static func paintCodeRun(
        in textStorage: NSTextStorage,
        range: NSRange,
        font: NSFont,
        foreground: NSColor,
        background: NSColor
    ) {
        guard range.length > 0 else { return }
        // Replace (don’t merge) so a prior marker/ghost fg can’t stick on code body.
        var attrs = textStorage.attributes(at: range.location, effectiveRange: nil)
        attrs[.font] = font
        attrs[.foregroundColor] = foreground
        attrs[.backgroundColor] = background
        attrs[.kern] = 0
        attrs[.baselineOffset] = 0
        textStorage.setAttributes(attrs, range: range)
    }

    // MARK: - Inline code

    private static func styleInlineCode(
        in textStorage: NSTextStorage,
        string: NSString,
        protected: IndexSet,
        monoFont: NSFont,
        codeFg: NSColor,
        codeBg: NSColor,
        markerHide: NSColor
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
    /// Uses a normal font size so the caret and typingAttributes stay usable.
    private static func hideMarkdownMarkers(
        in textStorage: NSTextStorage,
        range: NSRange,
        font: NSFont,
        hideColor: NSColor? = nil,
        collapseToWidth: CGFloat? = nil
    ) {
        guard range.length > 0 else { return }
        let color = hideColor ?? (
            isDarkAppearance()
                ? NSColor(white: 0.14, alpha: 1)
                : NSColor(white: 1, alpha: 1)
        )
        textStorage.addAttributes([
            .foregroundColor: color,
            .backgroundColor: NSColor.clear,
            .font: font,
            .kern: -0.8,
        ], range: range)

        guard let target = collapseToWidth else { return }
        // Collapse glyph advance so a hidden marker doesn’t push the body far right.
        let ns = textStorage.string as NSString
        let fragment = ns.substring(with: range)
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
            // SoftChrome-matched marker color — don’t inherit into typing.
            let w = fg.usingColorSpace(.deviceRGB)?.whiteComponent ?? -1
            if dark, abs(w - 0.14) < 0.03 { return attrs }
            if !dark, w > 0.95 { return attrs }
            if fg.alphaComponent < 0.08 { return attrs }
        }
        if let bg = at[.backgroundColor] as? NSColor, bg.alphaComponent > 0.03 {
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: monoSize, weight: .regular)
            attrs[.foregroundColor] = dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.1, alpha: 1)
            attrs[.backgroundColor] = bg
        }
        return attrs
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
        secondary: NSColor,
        quoteFg: NSColor,
        quoteBg: NSColor
    ) {
        var loc = 0
        while loc < string.length {
            let lineRange = string.lineRange(for: NSRange(location: loc, length: 0))
            defer { loc = NSMaxRange(lineRange) }
            if rangeOverlapsProtected(lineRange, protected) { continue }

            let line = string.substring(with: lineRange)
            // Exclude trailing newline from content styling.
            let contentLen = line.hasSuffix("\n") ? lineRange.length - 1 : lineRange.length
            guard contentLen > 0 else { continue }
            let contentRange = NSRange(location: lineRange.location, length: contentLen)
            let content = string.substring(with: contentRange)

            if let match = content.range(of: #"^(\s*)([-*•])(\s+)"#, options: .regularExpression) {
                applyListStyle(
                    in: textStorage,
                    lineRange: contentRange,
                    line: content,
                    match: match,
                    bodyFont: bodyFont,
                    secondary: secondary
                )
                continue
            }
            if let match = content.range(of: #"^(\s*)(\d+)\.(\s+)"#, options: .regularExpression) {
                applyOrderedListStyle(
                    in: textStorage,
                    lineRange: contentRange,
                    line: content,
                    match: match,
                    bodyFont: bodyFont,
                    secondary: secondary
                )
                continue
            }
            if let match = content.range(of: #"^(\s*)>(\s?)"#, options: .regularExpression) {
                applyQuoteStyle(
                    in: textStorage,
                    lineRange: contentRange,
                    line: content,
                    match: match,
                    bodyFont: bodyFont,
                    quoteFg: quoteFg,
                    quoteBg: quoteBg
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

    private static func applyListStyle(
        in textStorage: NSTextStorage,
        lineRange: NSRange,
        line: String,
        match: Range<String.Index>,
        bodyFont: NSFont,
        secondary: NSColor
    ) {
        let markerRange = NSRange(match, in: line)
        let absMarker = NSRange(location: lineRange.location + markerRange.location, length: markerRange.length)
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = listIndent
        para.headIndent = listIndent + 14
        para.lineSpacing = 2
        para.paragraphSpacingBefore = 1
        textStorage.addAttributes([.paragraphStyle: para], range: lineRange)

        let nsLine = line as NSString
        let fullMarker = nsLine.substring(with: markerRange)
        var markerCharLoc = absMarker.location
        if let m = fullMarker.range(of: #"^\s*"#, options: .regularExpression) {
            markerCharLoc += NSRange(m, in: fullMarker).length
        }
        let charRange = NSRange(location: markerCharLoc, length: 1)
        let gapStart = markerCharLoc + 1
        let gapLen = max(0, NSMaxRange(absMarker) - gapStart)
        let bullet = isDarkAppearance()
            ? NSColor(white: 0.78, alpha: 1)
            : NSColor(white: 0.25, alpha: 1)
        let body = isDarkAppearance()
            ? NSColor(white: 0.93, alpha: 1)
            : NSColor(white: 0.12, alpha: 1)
        textStorage.addAttributes([
            .font: NSFont.systemFont(ofSize: bodySize * 0.95, weight: .regular),
            .foregroundColor: bullet,
            .baselineOffset: 1,
        ], range: charRange)
        if gapLen > 0 {
            textStorage.addAttributes([
                .font: bodyFont,
                .foregroundColor: body,
                .kern: 1.5,
            ], range: NSRange(location: gapStart, length: gapLen))
        }
    }

    private static func applyOrderedListStyle(
        in textStorage: NSTextStorage,
        lineRange: NSRange,
        line: String,
        match: Range<String.Index>,
        bodyFont: NSFont,
        secondary: NSColor
    ) {
        let markerRange = NSRange(match, in: line)
        let absMarker = NSRange(location: lineRange.location + markerRange.location, length: markerRange.length)
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = listIndent
        para.headIndent = listIndent + 18
        para.lineSpacing = 1
        textStorage.addAttributes([.paragraphStyle: para], range: lineRange)
        textStorage.addAttributes([
            .font: bodyFont,
            .foregroundColor: secondary.withAlphaComponent(0.8),
        ], range: absMarker)
    }

    private static func applyQuoteStyle(
        in textStorage: NSTextStorage,
        lineRange: NSRange,
        line: String,
        match: Range<String.Index>,
        bodyFont: NSFont,
        quoteFg: NSColor,
        quoteBg: NSColor
    ) {
        let markerRange = NSRange(match, in: line)
        let absMarker = NSRange(location: lineRange.location + markerRange.location, length: markerRange.length)
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = quoteIndent
        para.headIndent = quoteIndent
        para.lineSpacing = 1
        textStorage.addAttributes([.paragraphStyle: para], range: lineRange)
        // Keep `>` in the string for markdown send; collapse its width so the body
        // sits just after the painted bar (not a full character + indent away).
        let markerHide = isDarkAppearance()
            ? NSColor(white: 0.14, alpha: 1)
            : NSColor(white: 1, alpha: 1)
        hideMarkdownMarkers(
            in: textStorage,
            range: absMarker,
            font: bodyFont,
            hideColor: markerHide,
            collapseToWidth: 0
        )
        let bodyStart = NSMaxRange(absMarker)
        let bodyLen = NSMaxRange(lineRange) - bodyStart
        if bodyLen > 0 {
            textStorage.addAttributes([
                .font: bodyFont,
                .foregroundColor: quoteFg,
                .backgroundColor: quoteBg,
            ], range: NSRange(location: bodyStart, length: bodyLen))
        }
    }

    private static func rangeOverlapsProtected(_ range: NSRange, _ protected: IndexSet) -> Bool {
        guard range.length > 0 else { return protected.contains(range.location) }
        let end = range.location + range.length
        return protected.intersects(integersIn: range.location..<end)
    }
}
