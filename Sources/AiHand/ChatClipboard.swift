import AppKit

/// Pasteboard writes for chat transcript selection / code-copy.
enum ChatClipboard {
    /// Write plain text plus optional HTML (and RTF derived from it) to `pasteboard`.
    static func write(plain: String, html: String?, to pasteboard: NSPasteboard = .general) {
        let trimmedPlain = plain
        let fragment = html?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        pasteboard.clearContents()

        guard !fragment.isEmpty else {
            pasteboard.setString(trimmedPlain, forType: .string)
            return
        }

        // Selection cloneContents often yields bare <li>s (no <ul>) — AppKit then
        // drops markers. Re-wrap before rich/plain conversion.
        let normalized = normalizeListFragment(fragment)
        let document = htmlDocument(fragment: normalized)
        var plainOut = trimmedPlain
        var rtfData: Data?
        if let attr = attributedString(fromHTML: document) {
            let fromHTML = plainTextPreservingLists(from: attr)
            plainOut = preferredListedPlain(fromHTML: fromHTML, supplied: trimmedPlain)
            let full = NSRange(location: 0, length: attr.length)
            if full.length > 0 {
                rtfData = attr.rtf(from: full, documentAttributes: [:])
            }
        }

        // Declare rich types first so Notes / Word / Slack prefer HTML/RTF over plain.
        var types: [NSPasteboard.PasteboardType] = [.html, .string]
        if rtfData != nil { types.insert(.rtf, at: 0) }
        pasteboard.declareTypes(types, owner: nil)
        if let rtfData {
            pasteboard.setData(rtfData, forType: .rtf)
        }
        if let htmlData = document.data(using: .utf8) {
            pasteboard.setData(htmlData, forType: .html)
        } else {
            pasteboard.setString(document, forType: .html)
        }
        pasteboard.setString(plainOut, forType: .string)
    }

    /// Convert an HTML fragment to markdown-ish plain text (`- ` / `1. ` + indent).
    static func plainTextPreservingLists(fromHTML fragment: String, fallback: String) -> String {
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let normalized = normalizeListFragment(trimmed)
        let document = htmlDocument(fragment: normalized)
        guard let attr = attributedString(fromHTML: document) else { return fallback }
        let plain = plainTextPreservingLists(from: attr)
        return preferredListedPlain(fromHTML: plain, supplied: fallback)
    }

    /// Selection HTML often contains bare `<li>` nodes; wrap them in `<ul>` so AppKit keeps markers.
    static func normalizeListFragment(_ fragment: String) -> String {
        let lower = fragment.lowercased()
        guard lower.contains("<li") else { return fragment }
        // Already structured (including nested lists) — leave alone. Do not scan for
        // inner `<li>` or we rewrite `<ol>` children into a `<ul>` and drop numbering.
        if lower.contains("<ul") || lower.contains("<ol") {
            return fragment
        }
        return "<ul>\(fragment)</ul>"
    }

    /// Prefer whichever plain string keeps more markdown list markers (plain paste targets).
    static func preferredListedPlain(fromHTML: String, supplied: String) -> String {
        let htmlScore = listMarkerScore(fromHTML)
        let suppliedScore = listMarkerScore(supplied)
        if htmlScore == 0 && suppliedScore == 0 {
            return fromHTML.isEmpty ? supplied : fromHTML
        }
        if suppliedScore > htmlScore { return supplied }
        if htmlScore > suppliedScore { return fromHTML }
        // Tie: prefer supplied when it already has markers (JS nodeToPlain), else HTML.
        return suppliedScore > 0 ? supplied : (fromHTML.isEmpty ? supplied : fromHTML)
    }

    static func listMarkerScore(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { score, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                return score + 1
            }
            if line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                return score + 1
            }
            return score
        }
    }

    // MARK: - Internals

    private static func htmlDocument(fragment: String) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8"></head><body>\(fragment)</body></html>
        """
    }

    private static func attributedString(fromHTML document: String) -> NSAttributedString? {
        guard let data = document.data(using: .utf8) else { return nil }
        return try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        )
    }

    /// AppKit embeds `\t•\t` / `\t1\t` list markers; rewrite to `- ` / `1. ` with indent by nest depth.
    static func plainTextPreservingLists(from attr: NSAttributedString) -> String {
        let ns = attr.string as NSString
        guard ns.length > 0 else { return "" }
        var lines: [String] = []
        var index = 0
        while index < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: index, length: 0))
            var effective = NSRange()
            let style = attr.attribute(.paragraphStyle, at: index, effectiveRange: &effective) as? NSParagraphStyle
            var line = ns.substring(with: paragraph)
            if line.hasSuffix("\n") {
                line.removeLast()
            }
            let depth = style?.textLists.count ?? 0
            let stripped = stripAppKitListPrefix(line)
            if depth > 0, !stripped.isEmpty {
                let indent = String(repeating: "  ", count: max(depth - 1, 0))
                let marker = listMarker(for: style?.textLists.last, line: line)
                lines.append(indent + marker + stripped)
            } else {
                lines.append(stripped)
            }
            index = NSMaxRange(paragraph)
        }
        return lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func listMarker(for list: NSTextList?, line: String) -> String {
        guard let list else { return "- " }
        let format = String(describing: list.markerFormat)
        // Ordered formats look like `{decimal}` / `{lower-alpha}` / …
        let orderedHints = ["decimal", "alpha", "roman", "ordinal"]
        if orderedHints.contains(where: { format.localizedCaseInsensitiveContains($0) }) {
            if let number = orderedMarkerNumber(in: line) {
                return "\(number). "
            }
            return "1. "
        }
        return "- "
    }

    /// AppKit ordered markers look like `\t12\trest`.
    private static func orderedMarkerNumber(in line: String) -> Int? {
        guard line.first == "\t" else { return nil }
        let rest = line.dropFirst()
        var digits = ""
        for ch in rest {
            if ch.isNumber {
                digits.append(ch)
            } else {
                break
            }
        }
        guard !digits.isEmpty, rest.dropFirst(digits.count).first == "\t" else { return nil }
        return Int(digits)
    }

    /// Drop `\t•\t`, `\t◦\t`, `\t12\t`, or leftover leading tabs from an AppKit list line.
    private static func stripAppKitListPrefix(_ line: String) -> String {
        guard line.first == "\t" else { return line }
        let chars = Array(line)
        var i = 0
        while i < chars.count, chars[i] == "\t" { i += 1 }
        guard i < chars.count else { return "" }

        // `\t+` + bullet + `\t` + body
        let bullets: Set<Character> = ["•", "◦", "▪", "◆", "■", "○", "●", "▫", "‣"]
        if bullets.contains(chars[i]) {
            let after = i + 1
            if after < chars.count, chars[after] == "\t" {
                return String(chars[(after + 1)...])
            }
            return String(chars[after...]).trimmingCharacters(in: .whitespaces)
        }

        // `\t+` + digits + `\t` + body
        var j = i
        while j < chars.count, chars[j].isNumber { j += 1 }
        if j > i, j < chars.count, chars[j] == "\t" {
            return String(chars[(j + 1)...])
        }

        return String(chars[i...])
    }
}
