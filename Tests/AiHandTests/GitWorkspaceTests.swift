import XCTest
@testable import AiHand

final class GitWorkspaceTests: XCTestCase {
    func testBranchNamePlaceholderMatchesWorktreeFieldCopy() {
        XCTAssertEqual(GitWorkspace.branchNamePlaceholder, "worktree-branch-name")
    }
}
