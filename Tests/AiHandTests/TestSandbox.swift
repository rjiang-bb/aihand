import Foundation
import XCTest
@testable import AiHand

/// Isolates a test from the user's real preferences and Application Support.
class SandboxedTestCase: XCTestCase {
    private(set) var tempDir: URL!
    private var savedDefaults: UserDefaults!
    private var savedRoot: URL?
    private var savedSkillHome: URL?
    private var suiteName: String!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aihand-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        savedDefaults = Preferences.defaults
        savedRoot = AppSupport.rootOverride
        savedSkillHome = SkillCatalog.homeDirectoryOverride
        suiteName = "aihand.tests.\(UUID().uuidString)"
        Preferences.defaults = UserDefaults(suiteName: suiteName)!
        AppSupport.rootOverride = tempDir.appendingPathComponent("support", isDirectory: true)
        // Empty fake home so SkillCatalog never scans the developer's real ~/.codex / plugins.
        SkillCatalog.homeDirectoryOverride = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: SkillCatalog.homeDirectoryOverride!, withIntermediateDirectories: true
        )
        WorkspaceFileCatalog.invalidate()
        SkillCatalog.invalidate()
    }

    override func tearDownWithError() throws {
        Preferences.defaults.removePersistentDomain(forName: suiteName)
        Preferences.defaults = savedDefaults
        AppSupport.rootOverride = savedRoot
        SkillCatalog.homeDirectoryOverride = savedSkillHome
        SkillCatalog.invalidate()
        try? FileManager.default.removeItem(at: tempDir)
    }

    @discardableResult
    func write(_ relative: String, _ contents: String = "x", under base: URL? = nil) throws -> URL {
        let url = (base ?? tempDir).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
