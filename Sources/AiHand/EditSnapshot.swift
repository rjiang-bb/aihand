import Foundation

/// Before/after text for one agent file edit, rendered as a Monaco diff in the transcript.
struct EditSnapshot: Codable, Equatable {
    var path: String
    var original: String
    var modified: String
    /// Lines hidden above a hunk-only snapshot (gutter shows `n + lineOffset`). 0 = full file.
    var lineOffset: Int = 0
    /// One side exceeded `EditSnapshotBuilder.maxBytes`; texts are dropped.
    var tooLarge: Bool = false
}

/// Turns agent edit tool payloads into `EditSnapshot`s.
enum EditSnapshotBuilder {
    static let maxBytes = 1_000_000

    struct Replacement: Equatable {
        var oldText: String
        var newText: String
        var replaceAll: Bool = false
    }

    /// Cursor `editToolCall` / `writeToolCall` completed payload (the value under that key).
    /// `preWriteContents` is the file as it was on disk when the tool started (writes only).
    static func fromCursor(
        payload: [String: Any],
        isWrite: Bool,
        preWriteContents: String?
    ) -> EditSnapshot? {
        let args = payload["args"] as? [String: Any] ?? [:]
        let success = (payload["result"] as? [String: Any])?["success"] as? [String: Any] ?? [:]
        guard let path = (success["path"] as? String) ?? (args["path"] as? String), !path.isEmpty else {
            return nil
        }
        let after = (success["afterFullFileContent"] as? String)
            ?? (isWrite ? ((args["contents"] as? String) ?? (args["fileText"] as? String)) : nil)
        let diffString = success["diffString"] as? String

        if isWrite, let after {
            return capped(EditSnapshot(path: path, original: preWriteContents ?? "", modified: after))
        }

        let replacements = Self.replacements(from: args)
        if let after {
            if !replacements.isEmpty, let original = reverseReplace(modified: after, replacements: replacements) {
                return capped(EditSnapshot(path: path, original: original, modified: after))
            }
            if let diffString, let original = reverseApply(diffString: diffString, to: after) {
                return capped(EditSnapshot(path: path, original: original, modified: after))
            }
        }

        // Hunk fallback: show only the changed region, with real line numbers when locatable.
        if let first = replacements.first {
            let offset = after.flatMap { lineOffset(of: first.newText, in: $0) } ?? 0
            return capped(EditSnapshot(path: path, original: first.oldText, modified: first.newText, lineOffset: offset))
        }
        if let diffString {
            let sides = hunkSides(diffString)
            guard !(sides.old.isEmpty && sides.new.isEmpty) else { return nil }
            let oldText = sides.old.joined(separator: "\n")
            let newText = sides.new.joined(separator: "\n")
            let offset = after.flatMap { lineOffset(of: newText, in: $0) } ?? 0
            return capped(EditSnapshot(path: path, original: oldText, modified: newText, lineOffset: offset))
        }
        if let after {
            // Nothing to diff against — show the resulting file as all-new.
            return capped(EditSnapshot(path: path, original: "", modified: after))
        }
        return nil
    }

    static func replacements(from args: [String: Any]) -> [Replacement] {
        if let one = args["strReplace"] as? [String: Any],
           let old = one["oldText"] as? String,
           let new = one["newText"] as? String {
            return [Replacement(oldText: old, newText: new, replaceAll: one["replaceAll"] as? Bool ?? false)]
        }
        if let multi = args["multiStrReplace"] as? [String: Any],
           let edits = multi["edits"] as? [[String: Any]] {
            return edits.compactMap { e in
                guard let old = e["oldText"] as? String, let new = e["newText"] as? String else { return nil }
                return Replacement(oldText: old, newText: new, replaceAll: e["replaceAll"] as? Bool ?? false)
            }
        }
        return []
    }

    /// Undo find/replace edits (last edit first). Nil when a `newText` can't be located.
    static func reverseReplace(modified: String, replacements: [Replacement]) -> String? {
        var text = modified
        for r in replacements.reversed() {
            guard !r.newText.isEmpty, text.contains(r.newText) else { return nil }
            if r.replaceAll {
                text = text.replacingOccurrences(of: r.newText, with: r.oldText)
            } else if let range = text.range(of: r.newText) {
                text.replaceSubrange(range, with: r.oldText)
            }
        }
        return text
    }

    /// Old/new sides of a diff body. Accepts unified (`+x`) and Cursor's (`+ x`) line styles.
    static func hunks(_ diffString: String) -> [(old: [String], new: [String])] {
        let lines = diffString.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let body = lines.filter {
            !$0.hasPrefix("@@") && !$0.hasPrefix("--- ") && !$0.hasPrefix("+++ ")
                && !$0.hasPrefix("diff --git") && !$0.hasPrefix("index ")
        }
        let signed = body.filter { $0.hasPrefix("+") || $0.hasPrefix("-") }
        // Cursor pads the sign with one space ("+ text", "- " for an empty line).
        let cursorStyle = !signed.isEmpty && signed.allSatisfy { $0.count == 1 || $0.dropFirst().hasPrefix(" ") }
        let strip = cursorStyle ? 2 : 1

        var out: [(old: [String], new: [String])] = []
        var old: [String] = []
        var new: [String] = []
        func flush() {
            if !old.isEmpty || !new.isEmpty { out.append((old, new)) }
            old = []
            new = []
        }
        var trailing = lines
        // Drop a single trailing empty line from the final newline.
        if trailing.last == "" { trailing.removeLast() }
        for line in trailing {
            if line.hasPrefix("@@") {
                flush()
                continue
            }
            if line.hasPrefix("--- ") || line.hasPrefix("+++ ") || line.hasPrefix("diff --git")
                || line.hasPrefix("index ") || line.hasPrefix("\\ ") {
                continue
            }
            if line.hasPrefix("+") {
                new.append(String(line.dropFirst(min(strip, line.count))))
            } else if line.hasPrefix("-") {
                old.append(String(line.dropFirst(min(strip, line.count))))
            } else {
                let ctx = line.hasPrefix(" ") ? String(line.dropFirst(min(strip, line.count))) : line
                old.append(ctx)
                new.append(ctx)
            }
        }
        flush()
        return out
    }

    static func hunkSides(_ diffString: String) -> (old: [String], new: [String]) {
        hunks(diffString).reduce(into: (old: [String](), new: [String]())) { acc, h in
            acc.old += h.old
            acc.new += h.new
        }
    }

    /// Rebuild the pre-edit file by swapping each hunk's new side back to its old side.
    static func reverseApply(diffString: String, to modified: String) -> String? {
        let hs = hunks(diffString)
        guard !hs.isEmpty else { return nil }
        var text = modified
        for h in hs.reversed() {
            let newBlock = h.new.joined(separator: "\n")
            let oldBlock = h.old.joined(separator: "\n")
            if newBlock.isEmpty {
                // Pure deletion with no context: only safe when the file is now empty.
                guard text.isEmpty else { return nil }
                text = oldBlock
                continue
            }
            guard let range = text.range(of: newBlock, options: .backwards) else { return nil }
            text.replaceSubrange(range, with: oldBlock)
        }
        return text
    }

    /// 0-based line index where `needle` starts in `haystack`.
    static func lineOffset(of needle: String, in haystack: String) -> Int? {
        guard !needle.isEmpty, let range = haystack.range(of: needle) else { return nil }
        return haystack[..<range.lowerBound].reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }

    static func capped(_ s: EditSnapshot) -> EditSnapshot {
        guard s.original.utf8.count > maxBytes || s.modified.utf8.count > maxBytes else { return s }
        return EditSnapshot(path: s.path, original: "", modified: "", lineOffset: 0, tooLarge: true)
    }

    /// Reads a local file for pre-write capture (nil when missing, binary, or over the cap).
    static func readLocalText(_ path: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber, size.intValue <= maxBytes,
              let data = fm.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Sidecar storage: `Application Support/AiHand/EditSnapshots/<session>/<message>.json`.
enum EditSnapshotStore {
    private static let folder = "EditSnapshots"

    static func directory(sessionID: UUID) -> URL {
        AppSupport.directory(subpath: "\(folder)/\(sessionID.uuidString)")
    }

    static func fileURL(sessionID: UUID, messageID: UUID) -> URL {
        directory(sessionID: sessionID).appendingPathComponent("\(messageID.uuidString).json")
    }

    static func write(_ snapshot: EditSnapshot, sessionID: UUID, messageID: UUID) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL(sessionID: sessionID, messageID: messageID), options: .atomic)
    }

    static func read(sessionID: UUID, messageID: UUID) -> EditSnapshot? {
        let url = AppSupport.directory()
            .appendingPathComponent(folder)
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathComponent("\(messageID.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EditSnapshot.self, from: data)
    }

    static func removeAll(sessionID: UUID) {
        let url = AppSupport.directory()
            .appendingPathComponent(folder)
            .appendingPathComponent(sessionID.uuidString)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
