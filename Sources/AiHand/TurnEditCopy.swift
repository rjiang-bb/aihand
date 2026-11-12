import Foundation

/// Cursor-style file-edit chip copy: `Edited path +N -M` and `Edited N files +X -Y`.
enum TurnEditCopy {
    struct Stat: Equatable {
        var path: String
        var added: Int
        var removed: Int

        var hasDiff: Bool { added > 0 || removed > 0 }
    }

    /// In-progress / completed file-edit tool rows (and Thought chips nested with them).
    static func isFileEditTool(_ text: String) -> Bool {
        text.hasPrefix("Editing ")
            || text.hasPrefix("Edited ")
            || text.hasPrefix("Writing ")
            || text.hasPrefix("Wrote ")
    }

    static func line(path: String, added: Int, removed: Int) -> String {
        var out = "Edited \(path)"
        if added > 0 { out += " +\(added)" }
        if removed > 0 { out += " -\(removed)" }
        return out
    }

    static func parse(_ text: String) -> Stat? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["Edited ", "Editing ", "Wrote ", "Writing "]
        guard let prefix = prefixes.first(where: { t.hasPrefix($0) }) else { return nil }
        var rest = String(t.dropFirst(prefix.count))
        var added = 0
        var removed = 0
        // Trailing " +N" / " -M" (order flexible).
        while true {
            if let m = rest.range(of: #" \+(\d+)$"#, options: .regularExpression) {
                added = Int(rest[m].dropFirst(2)) ?? 0
                rest = String(rest[..<m.lowerBound])
                continue
            }
            if let m = rest.range(of: #" -(\d+)$"#, options: .regularExpression) {
                removed = Int(rest[m].dropFirst(2)) ?? 0
                rest = String(rest[..<m.lowerBound])
                continue
            }
            break
        }
        let path = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return Stat(path: path, added: added, removed: removed)
    }

    /// Still mid-edit (`Editing` / `Writing`) vs finished (`Edited` / `Wrote`).
    static func isInProgressEdit(_ text: String) -> Bool {
        text.hasPrefix("Editing ") || text.hasPrefix("Writing ")
    }

    /// Unique paths + summed +/- across edit rows (ignores Thought / non-edits).
    static func summarize(toolTexts: [String]) -> (fileCount: Int, added: Int, removed: Int)? {
        var paths = Set<String>()
        var added = 0
        var removed = 0
        var any = false
        for text in toolTexts {
            guard let stat = parse(text) else { continue }
            any = true
            paths.insert(stat.path)
            added += stat.added
            removed += stat.removed
        }
        guard any else { return nil }
        return (paths.count, added, removed)
    }

    /// Live / group header: `Editing 2 files +79` while any row is in progress, else `Edited…`.
    static func activityHeader(toolTexts: [String]) -> String? {
        guard let sum = summarize(toolTexts: toolTexts) else { return nil }
        let inProgress = toolTexts.contains(where: isInProgressEdit)
        return header(
            fileCount: sum.fileCount,
            added: sum.added,
            removed: sum.removed,
            inProgress: inProgress
        )
    }

    static func header(fileCount: Int, added: Int, removed: Int, inProgress: Bool = false) -> String {
        let verb = inProgress ? "Editing" : "Edited"
        let noun = fileCount == 1 ? "file" : "files"
        var out = "\(verb) \(max(0, fileCount)) \(noun)"
        if added > 0 { out += " +\(added)" }
        if removed > 0 { out += " -\(removed)" }
        return out
    }
}
