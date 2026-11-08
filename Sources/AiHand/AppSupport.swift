import Foundation

/// Application Support paths under the AiHand brand.
enum AppSupport {
    private static let brand = "AiHand"

    static func directory(subpath: String = "") -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        var dir = root.appendingPathComponent(brand, isDirectory: true)
        if !subpath.isEmpty {
            dir = dir.appendingPathComponent(subpath, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
