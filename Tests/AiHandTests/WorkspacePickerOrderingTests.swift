import XCTest
@testable import AiHand

final class WorkspacePickerOrderingTests: SandboxedTestCase {
    func testPickerHeightCapsAtFiveFolders() {
        let four = SessionsListMetrics.pickerHeight(folderCount: 4, expanded: true)
        let five = SessionsListMetrics.pickerHeight(folderCount: 5, expanded: true)
        let six = SessionsListMetrics.pickerHeight(folderCount: 6, expanded: true)
        let twelve = SessionsListMetrics.pickerHeight(folderCount: 12, expanded: true)
        XCTAssertLessThan(four, five)
        XCTAssertEqual(five, six)
        XCTAssertEqual(five, twelve)
        XCTAssertEqual(
            SessionsListMetrics.pickerFolderListHeight(folderCount: 12),
            SessionsListMetrics.pickerFolderListHeight(
                folderCount: WorkspacePickerOrdering.maxVisibleRows
            )
        )
        XCTAssertEqual(WorkspacePickerOrdering.maxVisibleRows, 5)
    }

    func testSortsByMostRecentSessionActivity() {
        let older = AgentWorkspaceRef.local("/tmp/older", id: UUID())
        let newer = AgentWorkspaceRef.local("/tmp/newer", id: UUID())
        let oldSession = AgentSession(
            createdAt: Date(timeIntervalSince1970: 100),
            title: "old",
            prompt: "p",
            screenshotPath: nil,
            workspace: older.path,
            gitBranch: "",
            connectionID: nil,
            cliKind: .cursor,
            status: .finished,
            blank: true
        )
        let newSession = AgentSession(
            createdAt: Date(timeIntervalSince1970: 200),
            title: "new",
            prompt: "p",
            screenshotPath: nil,
            workspace: newer.path,
            gitBranch: "",
            connectionID: nil,
            cliKind: .cursor,
            status: .finished,
            blank: true
        )
        let sorted = WorkspacePickerOrdering.sorted(
            refs: [older, newer],
            sessions: [oldSession, newSession],
            lastUsedAt: [:]
        )
        XCTAssertEqual(sorted.map(\.id), [newer.id, older.id])
    }

    func testLastUsedBeatsStaleSessionActivity() {
        let a = AgentWorkspaceRef.local("/tmp/a", id: UUID())
        let b = AgentWorkspaceRef.local("/tmp/b", id: UUID())
        let sessionOnA = AgentSession(
            createdAt: Date(timeIntervalSince1970: 50),
            title: "a",
            prompt: "p",
            screenshotPath: nil,
            workspace: a.path,
            gitBranch: "",
            connectionID: nil,
            cliKind: .cursor,
            status: .finished,
            blank: true
        )
        let sorted = WorkspacePickerOrdering.sorted(
            refs: [a, b],
            sessions: [sessionOnA],
            lastUsedAt: [b.id: Date(timeIntervalSince1970: 999)]
        )
        XCTAssertEqual(sorted.map(\.id), [b.id, a.id])
    }

    func testWorktreeSessionCountsTowardRoot() {
        let root = AgentWorkspaceRef.local("/tmp/repo", id: UUID())
        let other = AgentWorkspaceRef.local("/tmp/other", id: UUID())
        let worktreeSession = AgentSession(
            createdAt: Date(timeIntervalSince1970: 300),
            title: "wt",
            prompt: "p",
            screenshotPath: nil,
            workspace: "/tmp/repo/.worktrees/feature",
            gitBranch: "feature",
            connectionID: nil,
            cliKind: .cursor,
            status: .working,
            blank: true
        )
        XCTAssertTrue(WorkspacePickerOrdering.belongs(worktreeSession, to: root))
        XCTAssertFalse(WorkspacePickerOrdering.belongs(worktreeSession, to: other))
        let sorted = WorkspacePickerOrdering.sorted(
            refs: [other, root],
            sessions: [worktreeSession],
            lastUsedAt: [:]
        )
        XCTAssertEqual(sorted.first?.id, root.id)
    }

    func testTouchLastUsedPersists() {
        let id = UUID()
        Preferences.touchAgentWorkspaceLastUsed(id)
        let dates = Preferences.agentWorkspaceLastUsedDates()
        XCTAssertNotNil(dates[id])
        XCTAssertGreaterThan(dates[id]!.timeIntervalSince1970, 0)
    }
}
