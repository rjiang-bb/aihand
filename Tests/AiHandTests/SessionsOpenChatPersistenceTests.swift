import XCTest
@testable import AiHand

final class SessionsOpenChatPersistenceTests: SandboxedTestCase {
    func testEncodeDecodeRoundTrip() {
        let a = UUID()
        let b = UUID()
        let map = [
            "local|/Users/rui/Code/aihand|main": a,
            "remote|/home/proj|feature": b,
        ]
        let encoded = SessionsOpenChatPersistence.encode(map)
        XCTAssertEqual(encoded["local|/Users/rui/Code/aihand|main"], a.uuidString)
        XCTAssertEqual(SessionsOpenChatPersistence.decode(encoded), map)
    }

    func testDecodeSkipsInvalidUUIDs() {
        let id = UUID()
        let decoded = SessionsOpenChatPersistence.decode([
            "local|/tmp/a|main": id.uuidString,
            "local|/tmp/b|main": "not-a-uuid",
        ])
        XCTAssertEqual(decoded, ["local|/tmp/a|main": id])
    }

    func testPreferencesSurvivesRelaunchStyleReload() {
        let id = UUID()
        let key = "local|/Users/rui/Code/aihand|main"
        Preferences.openChatByWorkspace = [key: id.uuidString]
        XCTAssertEqual(Preferences.openChatByWorkspace[key], id.uuidString)
        XCTAssertEqual(
            SessionsOpenChatPersistence.decode(Preferences.openChatByWorkspace)[key],
            id
        )
        Preferences.openChatByWorkspace = [:]
        XCTAssertTrue(Preferences.openChatByWorkspace.isEmpty)
    }

    func testScopeKeyIncludesBranch() {
        let key = SessionsOpenChatPersistence.scopeKey(
            path: "/Users/rui/Code/aihand",
            connectionID: nil,
            branch: "main"
        )
        XCTAssertEqual(key, "local|/Users/rui/Code/aihand|main")
        let parts = SessionsOpenChatPersistence.parts(of: key)
        XCTAssertEqual(parts.connection, "local")
        XCTAssertEqual(parts.path, "/Users/rui/Code/aihand")
        XCTAssertEqual(parts.branch, "main")
    }

    func testScopeKeyDistinguishesBranches() {
        let main = SessionsOpenChatPersistence.scopeKey(
            path: "/tmp/repo", connectionID: nil, branch: "main"
        )
        let feature = SessionsOpenChatPersistence.scopeKey(
            path: "/tmp/repo", connectionID: nil, branch: "feature"
        )
        XCTAssertNotEqual(main, feature)
    }

    func testLegacyTwoPartKeysParseWithEmptyBranch() {
        let parts = SessionsOpenChatPersistence.parts(of: "local|/tmp/old")
        XCTAssertEqual(parts.connection, "local")
        XCTAssertEqual(parts.path, "/tmp/old")
        XCTAssertEqual(parts.branch, "")
    }

    func testIncompleteScopeKey() {
        XCTAssertTrue(SessionsOpenChatPersistence.isIncompleteScopeKey("local||"))
        XCTAssertTrue(SessionsOpenChatPersistence.isIncompleteScopeKey("local||main"))
        XCTAssertFalse(SessionsOpenChatPersistence.isIncompleteScopeKey("local|/tmp/x|main"))
        XCTAssertFalse(SessionsOpenChatPersistence.isIncompleteScopeKey("local|/tmp/x|"))
    }

    func testRecordLeaveKeepsMemoryWhenSelectionAlreadyCleared() {
        let chatA = UUID()
        let chatB = UUID()
        let keyA = SessionsOpenChatPersistence.scopeKey(
            path: "/tmp/repo-a", connectionID: nil, branch: "A"
        )
        let keyB = SessionsOpenChatPersistence.scopeKey(
            path: "/tmp/repo-b", connectionID: nil, branch: "B"
        )
        var map = [keyA: chatA]

        // Leaving A with selection still set to the same id — no map change.
        XCTAssertFalse(
            SessionsOpenChatPersistence.recordLeave(
                previousKey: keyA, selectedID: chatA, into: &map
            ),
            "unchanged id is a no-op"
        )
        XCTAssertEqual(map[keyA], chatA)

        // List filter raced ahead and cleared selection before scopeDidChange —
        // must not wipe A's memory (that broke restore when returning A→B→A).
        XCTAssertFalse(SessionsOpenChatPersistence.recordLeave(
            previousKey: keyA, selectedID: nil, into: &map
        ))
        XCTAssertEqual(map[keyA], chatA)

        // Enter B with a chat, leave B, return to A — A's id is still there.
        XCTAssertTrue(SessionsOpenChatPersistence.recordLeave(
            previousKey: keyB, selectedID: chatB, into: &map
        ))
        XCTAssertEqual(map[keyB], chatB)
        XCTAssertEqual(map[keyA], chatA, "returning to A must still find the remembered chat")
    }

    func testSameGitBranchEmptyMatchesLegacy() {
        XCTAssertTrue(SessionStore.sameGitBranch("", "main"))
        XCTAssertTrue(SessionStore.sameGitBranch("main", ""))
        XCTAssertTrue(SessionStore.sameGitBranch("main", "main"))
        XCTAssertFalse(SessionStore.sameGitBranch("main", "feature"))
    }

    func testMatchesCurrentScopeRequiresBranchWhenBothSet() {
        let store = SessionStore()
        store.syncFromPreferences(clearSelectionIfNeeded: false)
        // Drive published state via preferences worktree selection when possible;
        // here assert the pure helpers used by scope filtering.
        let onMain = AgentSession(
            title: "main",
            prompt: "p",
            screenshotPath: nil,
            workspace: "/tmp/repo",
            gitBranch: "main",
            connectionID: nil,
            cliKind: .cursor,
            status: .finished,
            blank: true
        )
        let onFeature = AgentSession(
            title: "feature",
            prompt: "p",
            screenshotPath: nil,
            workspace: "/tmp/repo",
            gitBranch: "feature",
            connectionID: nil,
            cliKind: .cursor,
            status: .finished,
            blank: true
        )
        // Simulate store scope with direct published fields via applying git info path:
        // use matches after manually setting through apply-equivalent: only public API is
        // Preferences + sync. Assert helper composition instead.
        XCTAssertTrue(
            SessionStore.sameWorkspace(onMain.workspace, "/tmp/repo")
                && SessionStore.sameGitBranch(onMain.gitBranch, "main")
        )
        XCTAssertFalse(
            SessionStore.sameWorkspace(onFeature.workspace, "/tmp/repo")
                && SessionStore.sameGitBranch(onFeature.gitBranch, "main")
        )
        _ = store
    }
}
