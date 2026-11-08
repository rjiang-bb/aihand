import Foundation

/// Application Support / Documents paths under the AiHand brand, with one-time
/// migration from the legacy TinyHand folder names.
enum AppSupport {
    private static let brand = "AiHand"
    private static let legacyBrand = "TinyHand"

    static func directory(subpath: String = "") -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        migrateIfNeeded(from: root.appendingPathComponent(legacyBrand, isDirectory: true),
                        to: root.appendingPathComponent(brand, isDirectory: true))
        var dir = root.appendingPathComponent(brand, isDirectory: true)
        if !subpath.isEmpty {
            dir = dir.appendingPathComponent(subpath, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func migrateDocumentsFolderIfNeeded() {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        migrateIfNeeded(
            from: home.appendingPathComponent("tinyhand", isDirectory: true),
            to: home.appendingPathComponent(brand, isDirectory: true)
        )
    }

    private static func migrateIfNeeded(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: new.path),
              fm.fileExists(atPath: old.path) else { return }
        try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: old, to: new)
    }
}
