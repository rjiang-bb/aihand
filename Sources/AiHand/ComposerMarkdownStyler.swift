import AppKit

/// Non-destructive markdown highlighting for the composer `NSTextView`.
/// Keeps the plain string intact (send / @ / / / paste still see source text).
enum ComposerMarkdownStyler {
    private static let bodySize: CGFloat = 14.5
    private static let monoSize: CGFloat = 13.0
    private static let listIndent: CGFloat = 4
    /// Space for the painted quote bar + gap before body text.
    private static let quoteIndent: CGFloat = 14
    static let quoteBarWidth: CGFloat = 2.5
    static let quoteBarInset: CGFloat = 2

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

    static func apply(to textStorage: NSTextStorage) {
        let length = textStorage.length
        guard length > 0 else { return }

        let full = NSRange(location: 0, length: length)
        let bodyFont = NSFont.systemFont(ofSize: bodySize)
        let monoFont = NSFont.monospacedSystemFont(ofSize: monoSize, weight: .regular)
        let label = NSColor.labelColor
        let secondary = NSColor.secondaryLabelColor
        let codeFg = NSColor.labelColor.withAlphaComponent(0.92)
        let codeBg = NSColor.labelColor.withAlphaComponent(0.10)
        let fenceBg = NSColor.labelColor.withAlphaComponent(0.07)

        let basePara = NSMutableParagraphStyle()
        basePara.lineSpacing = 1
        basePara.paragraphSpacing = 1

        textStorage.beginEditing()
        defer { textStorage.endEditing() }

        textStorage.setAttributes([
            .font: bodyFont,
            .foregroundColor: label,
            .backgroundColor: NSColor.clear,
            .kern: 0,
            .paragraphStyle: basePara,
            .baselineOffset: 0,
        ], range: full)

        let string = textStorage.string as NSString
        var protected = IndexSet()

        styleFencedBlocks(
            in: textStorage,
            string: string,
            protected: &protected,
            monoFont: monoFont,
            codeFg: codeFg,
            fenceBg: fenceBg
        )

        styleInlineCode(
            in: textStorage,
            string: string,
            protected: protected,
            monoFont: monoFont,
            codeFg: codeFg,
            codeBg: codeBg
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
            secondary: secondary
        )
    }

    // MARK: - Fenced blocks

    private static func styleFencedBlocks(
        in textStorage: NSTextStorage,
        string: NSString,
        protected: inout IndexSet,
        monoFont: NSFont,
        codeFg: NSColor,
        fenceBg: NSColor
    ) {
        var loc = 0
        var inFence = false
        var contentStart = 0

        while loc < string.length {
            let lineRange = string.lineRange(for: NSRange(location: loc, length: 0))
            let line = string.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let isFence = trimmed.hasPrefix("```")

            if isFence {
                // Hide the ``` token only — never the newline or a 0.01pt font
                // (that collapses the caret and poisons typingAttributes).
                let tokenLen = line.hasSuffix("\n") ? lineRange.length - 1 : lineRange.length
                if tokenLen > 0 {
                    let token = NSRange(location: lineRange.location, length: tokenLen)
                    hideMarkdownMarkers(in: textStorage, range: token, font: monoFont)
                    protected.insert(integersIn: token.location..<(token.location + token.length))
                }

                if inFence {
                    let contentEnd = lineRange.location
                    if contentEnd > contentStart {
                        let content = NSRange(location: contentStart, length: contentEnd - contentStart)
                        textStorage.addAttributes([
                            .font: monoFont,
                            .foregroundColor: codeFg,
                            .backgroundColor: fenceBg,
                        ], range: content)
                        protected.insert(integersIn: contentStart..<contentEnd)
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
            let content = NSRange(location: contentStart, length: string.length - contentStart)
            textStorage.addAttributes([
                .font: monoFont,
                .foregroundColor: codeFg,
                .backgroundColor: fenceBg,
            ], range: content)
            protected.insert(integersIn: contentStart..<string.length)
        }
    }

    // MARK: - Inline code

    private static func styleInlineCode(
        in textStorage: NSTextStorage,
        string: NSString,
        protected: IndexSet,
        monoFont: NSFont,
        codeFg: NSColor,
        codeBg: NSColor
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
            hideMarkdownMarkers(in: textStorage, range: open, font: monoFont)
            hideMarkdownMarkers(in: textStorage, range: close, font: monoFont)
            textStorage.addAttributes([
                .font: monoFont,
                .foregroundColor: codeFg,
                .backgroundColor: codeBg,
            ], range: inner)
        }
    }

    /// Keep markdown markers in the string (for send) but don’t paint them.
    /// Uses a normal font size so the caret and typingAttributes stay usable.
    private static func hideMarkdownMarkers(
        in textStorage: NSTextStorage,
        range: NSRange,
        font: NSFont
    ) {
        guard range.length > 0 else { return }
        textStorage.addAttributes([
            .foregroundColor: NSColor.clear,
            .backgroundColor: NSColor.clear,
            .font: font,
            .kern: -0.6,
        ], range: range)
    }

    static func typingAttributes() -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 1
        para.paragraphSpacing = 1
        return [
            .font: NSFont.systemFont(ofSize: bodySize),
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.clear,
            .kern: 0,
            .paragraphStyle: para,
            .baselineOffset: 0,
        ]
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
        secondary: NSColor
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
                    secondary: secondary
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
        textStorage.addAttributes([
            .font: NSFont.systemFont(ofSize: bodySize * 0.95, weight: .regular),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.7),
            .baselineOffset: 1,
        ], range: charRange)
        if gapLen > 0 {
            textStorage.addAttributes([
                .font: bodyFont,
                .foregroundColor: NSColor.labelColor,
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
        secondary: NSColor
    ) {
        let markerRange = NSRange(match, in: line)
        let absMarker = NSRange(location: lineRange.location + markerRange.location, length: markerRange.length)
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = quoteIndent
        para.headIndent = quoteIndent
        para.lineSpacing = 1
        textStorage.addAttributes([.paragraphStyle: para], range: lineRange)
        // Keep `>` in the string for markdown send; bar is painted by the text view.
        hideMarkdownMarkers(in: textStorage, range: absMarker, font: bodyFont)
        let bodyStart = NSMaxRange(absMarker)
        let bodyLen = NSMaxRange(lineRange) - bodyStart
        if bodyLen > 0 {
            textStorage.addAttributes([
                .font: bodyFont,
                .foregroundColor: secondary.withAlphaComponent(0.95),
                .backgroundColor: NSColor.labelColor.withAlphaComponent(0.05),
            ], range: NSRange(location: bodyStart, length: bodyLen))
        }
    }

    private static func rangeOverlapsProtected(_ range: NSRange, _ protected: IndexSet) -> Bool {
        guard range.length > 0 else { return protected.contains(range.location) }
        let end = range.location + range.length
        return protected.intersects(integersIn: range.location..<end)
    }
}
