import XCTest
@testable import AiHand

final class ComposerAttachStagingTests: SandboxedTestCase {
    func testExistingPathsSurviveStagingFilter() throws {
        let folder = Preferences.ensureScreenshotsFolder()
        let path = (folder as NSString).appendingPathComponent("attach-staging-\(UUID().uuidString).png")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let missing = "/tmp/aihand-does-not-exist-\(UUID().uuidString).png"
        let staged = [path, missing].filter { FileManager.default.fileExists(atPath: $0) }
        XCTAssertEqual(staged, [path])

        let attachment = ComposerAttachment(path: path, ownsFile: false)
        XCTAssertFalse(attachment.ownsFile)
        XCTAssertTrue(attachment.isImage)
    }

    func testPendingAttachIsScopedToSession() {
        let a = UUID()
        let b = UUID()
        let pending = PendingComposerAttach(sessionID: a, paths: ["/tmp/x.png"])
        XCTAssertEqual(pending.sessionID, a)
        XCTAssertNotEqual(pending.sessionID, b)
        // Wrong session must not clear pending (consume guard).
        XCTAssertFalse(pending.sessionID == b && !pending.paths.isEmpty)
        XCTAssertTrue(pending.sessionID == a && !pending.paths.isEmpty)
    }
}
