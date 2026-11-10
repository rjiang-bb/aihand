import AppKit

/// Inline file/folder chip in the composer (`NSTextAttachment` ↔ serialized token).
enum ComposerFileChipToken {
    static let objectReplacement = "\u{FFFC}"

    /// Stable plain-text form kept in the draft binding / undo.
    static func serialize(path: String, isDirectory: Bool) -> String {
        let kind = isDirectory ? "dir" : "file"
        let escaped = path.replacingOccurrences(of: "⟧", with: "")
        return "⟦\(kind):\(escaped)⟧"
    }

    static func parse(_ token: String) -> (path: String, isDirectory: Bool)? {
        guard token.hasPrefix("⟦"), token.hasSuffix("⟧"), token.count > 3 else { return nil }
        let inner = String(token.dropFirst().dropLast())
        if inner.hasPrefix("dir:") {
            return (String(inner.dropFirst(4)), true)
        }
        if inner.hasPrefix("file:") {
            return (String(inner.dropFirst(5)), false)
        }
        return nil
    }

    /// Expand chips in plain draft text for send: inline relative/name + collected paths.
    static func expandForSend(
        _ text: String,
        workspace: String
    ) -> (prompt: String, filePaths: [String]) {
        var paths: [String] = []
        var prompt = ""
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "⟦", let end = text[i...].firstIndex(of: "⟧") {
                let token = String(text[i...end])
                if let parsed = parse(token) {
                    paths.append(parsed.path)
                    prompt += displayName(for: parsed.path, isDirectory: parsed.isDirectory)
                    i = text.index(after: end)
                    continue
                }
            }
            prompt.append(text[i])
            i = text.index(after: i)
        }
        // Dedupe paths, keep order.
        var seen = Set<String>()
        let unique = paths.filter { seen.insert($0).inserted }
        return (prompt, unique)
    }

    static func displayName(for path: String, isDirectory: Bool) -> String {
        let name = (path as NSString).lastPathComponent
        if name.isEmpty { return path }
        return isDirectory && !name.hasSuffix("/") ? name + "/" : name
    }

    static func relativePath(_ path: String, workspace: String) -> String {
        let ws = (workspace as NSString).standardizingPath
        let full = (path as NSString).standardizingPath
        guard !ws.isEmpty, full.hasPrefix(ws + "/") else { return path }
        return String(full.dropFirst(ws.count + 1))
    }
}

final class ComposerFileChipAttachment: NSTextAttachment {
    let path: String
    let isDirectory: Bool
    let darkChrome: Bool

    init(path: String, isDirectory: Bool, darkChrome: Bool) {
        self.path = path
        self.isDirectory = isDirectory
        self.darkChrome = darkChrome
        super.init(data: nil, ofType: nil)
        let cell = ComposerFileChipAttachmentCell(
            path: path,
            isDirectory: isDirectory,
            darkChrome: darkChrome
        )
        attachmentCell = cell
    }

    required init?(coder: NSCoder) {
        self.path = ""
        self.isDirectory = false
        self.darkChrome = true
        super.init(coder: coder)
    }

    var serializedToken: String {
        ComposerFileChipToken.serialize(path: path, isDirectory: isDirectory)
    }

    var attributedString: NSAttributedString {
        NSAttributedString(attachment: self)
    }
}

final class ComposerFileChipAttachmentCell: NSTextAttachmentCell {
    private let path: String
    private let isDirectory: Bool
    private let darkChrome: Bool
    private let label: String

    private let chipFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    private let iconSize: CGFloat = 12
    private let paddingX: CGFloat = 7
    private let paddingY: CGFloat = 3
    private let gap: CGFloat = 5

    init(path: String, isDirectory: Bool, darkChrome: Bool) {
        self.path = path
        self.isDirectory = isDirectory
        self.darkChrome = darkChrome
        self.label = ComposerFileChipToken.displayName(for: path, isDirectory: isDirectory)
        super.init()
    }

    required init(coder: NSCoder) {
        self.path = ""
        self.isDirectory = false
        self.darkChrome = true
        self.label = ""
        super.init(coder: coder)
    }

    private var chipBlue: NSColor {
        NSColor(srgbRed: 0.45, green: 0.72, blue: 1.0, alpha: 1)
    }

    private var chipFill: NSColor {
        darkChrome
            ? NSColor(white: 1, alpha: 0.08)
            : NSColor(white: 0, alpha: 0.06)
    }

    override func cellSize() -> NSSize {
        let textSize = (label as NSString).size(withAttributes: [.font: chipFont])
        let w = paddingX + iconSize + gap + ceil(textSize.width) + paddingX
        let h = max(20, ceil(textSize.height) + paddingY * 2)
        return NSSize(width: w, height: h)
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -4)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let radius: CGFloat = 6
        let path = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        chipFill.setFill()
        path.fill()
        chipBlue.withAlphaComponent(0.28).setStroke()
        path.lineWidth = 1
        path.stroke()

        let symbol = isDirectory ? "folder" : "doc"
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let iconRect = NSRect(
                x: cellFrame.minX + paddingX,
                y: cellFrame.midY - iconSize / 2,
                width: iconSize,
                height: iconSize
            )
            let tinted = NSImage(size: iconRect.size)
            tinted.lockFocus()
            let local = NSRect(origin: .zero, size: iconRect.size)
            base.draw(in: local, from: .zero, operation: .sourceOver, fraction: 1)
            chipBlue.set()
            local.fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
        }

        let textOrigin = NSPoint(
            x: cellFrame.minX + paddingX + iconSize + gap,
            y: cellFrame.minY + (cellFrame.height - chipFont.ascender + chipFont.descender) / 2 - 1
        )
        (label as NSString).draw(
            at: textOrigin,
            withAttributes: [
                .font: chipFont,
                .foregroundColor: chipBlue,
            ]
        )
    }
}

enum ComposerFileChipCodec {
    private static let tokenRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"⟦(?:file|dir):([^⟧]*)⟧"#)
    }()

    /// Plain draft (with `⟦…⟧` tokens) → attributed string with chips.
    static func attributedString(
        from serialized: String,
        darkChrome: Bool,
        base: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let ns = serialized as NSString
        var cursor = 0
        let matches = tokenRegex.matches(in: serialized, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            let tokenRange = match.range(at: 0)
            if tokenRange.location > cursor {
                let before = NSRange(location: cursor, length: tokenRange.location - cursor)
                out.append(NSAttributedString(string: ns.substring(with: before), attributes: base))
            }
            let token = ns.substring(with: tokenRange)
            if let parsed = ComposerFileChipToken.parse(token) {
                let chip = ComposerFileChipAttachment(
                    path: parsed.path,
                    isDirectory: parsed.isDirectory,
                    darkChrome: darkChrome
                )
                out.append(chip.attributedString)
            } else {
                out.append(NSAttributedString(string: token, attributes: base))
            }
            cursor = NSMaxRange(tokenRange)
        }
        if cursor < ns.length {
            let rest = NSRange(location: cursor, length: ns.length - cursor)
            out.append(NSAttributedString(string: ns.substring(with: rest), attributes: base))
        }
        return out
    }

    /// Attributed storage → plain draft with `⟦…⟧` tokens (attachments expanded).
    static func serialize(_ storage: NSAttributedString) -> String {
        var result = ""
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            if let chip = attrs[.attachment] as? ComposerFileChipAttachment {
                result += chip.serializedToken
                return
            }
            if attrs[.attachment] != nil {
                // Unknown attachment — skip object-replacement glyph.
                return
            }
            result += (storage.string as NSString).substring(with: range)
        }
        return result
    }

    static func insertChip(
        path: String,
        isDirectory: Bool,
        darkChrome: Bool,
        into textView: NSTextView
    ) {
        let chip = ComposerFileChipAttachment(
            path: path,
            isDirectory: isDirectory,
            darkChrome: darkChrome
        )
        let attr = NSMutableAttributedString(attributedString: chip.attributedString)
        // Trailing space so the caret lands after the chip cleanly.
        let spaceAttrs = textView.typingAttributes
        attr.append(NSAttributedString(string: " ", attributes: spaceAttrs))
        let range = textView.selectedRange()
        if textView.shouldChangeText(in: range, replacementString: ComposerFileChipToken.objectReplacement + " ") {
            textView.textStorage?.replaceCharacters(in: range, with: attr)
            textView.didChangeText()
            let caret = range.location + attr.length
            textView.setSelectedRange(NSRange(location: caret, length: 0))
        }
    }
}
