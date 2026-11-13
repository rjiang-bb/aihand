import XCTest
@testable import AiHand

final class WorkspaceWorktreeSelectionTests: SandboxedTestCase {
    private var repoRoot: URL!
    private var linkedWorktree: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        repoRoot = tempDir.appendingPathComponent("app-repo", isDirectory: true)
        linkedWorktree = tempDir.appendingPathComponent("app-repo-feature", isDirectory: true)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        try runGit(repoRoot, ["init", "-b", "main"])
        try runGit(repoRoot, ["config", "user.email", "test@example.com"])
        try runGit(repoRoot, ["config", "user.name", "Test"])
        try "hello".write(to: repoRoot.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try runGit(repoRoot, ["add", "README"])
        try runGit(repoRoot, ["commit", "-m", "init"])
        try runGit(repoRoot, ["worktree", "add", "-b", "feature", linkedWorktree.path])

        Preferences.agentWorkspaceRefs = [.local(repoRoot.path)]
        Preferences.selectAgentWorkspaceRef(try XCTUnwrap(Preferences.agentWorkspaceRefs.first?.id))
    }

    func testSelectWorkspaceMapsSiblingWorktreeToRegisteredRoot() throws {
        Preferences.selectWorkspace(path: linkedWorktree.path, connectionID: nil)
        XCTAssertEqual(Preferences.agentWorkspaceRefs.count, 1, "must not register the worktree as its own folder")
        XCTAssertEqual(
            SessionStore.normalizedWorkspace(Preferences.agentWorkspaceRoot),
            SessionStore.normalizedWorkspace(repoRoot.path)
        )
        XCTAssertEqual(
            SessionStore.normalizedWorkspace(Preferences.agentWorkspace),
            SessionStore.normalizedWorkspace(linkedWorktree.path)
        )
    }

    func testSelectWorkspaceFallsBackWhenRememberedWorktreeWasDeleted() throws {
        Preferences.selectAgentWorktree(linkedWorktree.path, root: repoRoot.path)
        XCTAssertEqual(
            SessionStore.normalizedWorkspace(Preferences.agentWorkspace),
            SessionStore.normalizedWorkspace(linkedWorktree.path)
        )
        try FileManager.default.removeItem(at: linkedWorktree)
        _ = try runGit(repoRoot, ["worktree", "prune"])

        let id = try XCTUnwrap(Preferences.agentWorkspaceRefs.first?.id)
        Preferences.selectAgentWorkspaceRef(id)
        XCTAssertEqual(
            SessionStore.normalizedWorkspace(Preferences.agentWorkspace),
            SessionStore.normalizedWorkspace(repoRoot.path),
            "deleted remembered worktree must not stay active"
        )
    }

    func testSelectWorkspaceNoOpsForMissingUnrelatedPath() {
        Preferences.selectWorkspace(path: tempDir.appendingPathComponent("nope").path, connectionID: nil)
        XCTAssertEqual(Preferences.agentWorkspaceRefs.count, 1)
        XCTAssertEqual(
            SessionStore.normalizedWorkspace(Preferences.agentWorkspaceRoot),
            SessionStore.normalizedWorkspace(repoRoot.path)
        )
    }

    func testWorktreeSwitchKeepsGitRepoWhileRefreshingBranch() throws {
        let store = SessionStore()
        store.syncFromPreferences()
        store.refreshGitInfo()
        waitUntil("gitRepo seeded") { store.gitRepo != nil }

        Preferences.selectAgentWorktree(linkedWorktree.path, root: repoRoot.path)
        store.syncFromPreferences()
        XCTAssertNotNil(store.gitRepo, "worktree switch must not clear the branch picker")
        XCTAssertEqual(
            SessionStore.normalizedWorkspace(store.currentWorkspace),
            SessionStore.normalizedWorkspace(linkedWorktree.path)
        )
    }

    func testGitCommonDirMatchesRootAndLinkedWorktree() throws {
        let rootCommon = try XCTUnwrap(GitWorkspace.gitCommonDir(in: repoRoot.path))
        let linkCommon = try XCTUnwrap(GitWorkspace.gitCommonDir(in: linkedWorktree.path))
        XCTAssertEqual(rootCommon, linkCommon)
    }

    func testForgetWorktreePathClearsMemory() throws {
        Preferences.selectAgentWorktree(linkedWorktree.path, root: repoRoot.path)
        Preferences.forgetWorktreePath(linkedWorktree.path, root: repoRoot.path)
        let id = try XCTUnwrap(Preferences.agentWorkspaceRefs.first?.id)
        Preferences.selectAgentWorkspaceRef(id)
        XCTAssertEqual(
            SessionStore.normalizedWorkspace(Preferences.agentWorkspace),
            SessionStore.normalizedWorkspace(repoRoot.path)
        )
    }

    // MARK: - Helpers

    @discardableResult
    private func runGit(_ cwd: URL, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd.path] + args
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "WorkspaceWorktreeSelectionTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? stdout : stderr]
            )
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 5, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(label)")
                return
            }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}
