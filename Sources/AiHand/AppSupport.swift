import Foundation

/// Application Support paths under the AiHand brand.
enum AppSupport {
    private static let brand = "AiHand"

    /// Tests point this at a temp dir so they never touch the real Application Support.
    static var rootOverride: URL?

    static func directory(subpath: String = "") -> URL {
        let root = rootOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        var dir = root.appendingPathComponent(brand, isDirectory: true)
        if !subpath.isEmpty {
            dir = dir.appendingPathComponent(subpath, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
