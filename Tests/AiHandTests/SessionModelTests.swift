import XCTest
@testable import AiHand

final class SessionModelTests: XCTestCase {
    func testWorkspaceNormalization() {
        XCTAssertEqual(SessionStore.normalizedWorkspace("  /tmp/a/../b/ "), "/tmp/b")
        XCTAssertEqual(SessionStore.normalizedWorkspace(""), "")
        XCTAssertTrue(SessionStore.sameWorkspace("/tmp/x/", "/tmp/x"))
        XCTAssertFalse(SessionStore.sameWorkspace("/tmp/x", "/tmp/y"))
    }

    func testGitBranchMatching() {
        XCTAssertTrue(SessionStore.sameGitBranch("main", "main"))
        XCTAssertFalse(SessionStore.sameGitBranch("main", "dev"))
        XCTAssertTrue(SessionStore.sameGitBranch("", "dev"), "legacy sessions match any branch")
        XCTAssertTrue(SessionStore.sameGitBranch(" main ", "main"))
    }

    func testConnectionMatching() {
        let id = UUID()
        XCTAssertTrue(SessionStore.sameConnection(nil, nil))
        XCTAssertTrue(SessionStore.sameConnection(id, id))
        XCTAssertFalse(SessionStore.sameConnection(id, nil))
    }

    func testMessageRoundTripsThroughJSON() throws {
        let m = AgentMessage(kind: .user, text: "hi\n- a", imagePaths: ["/a.png", "/b.mov"], steered: true)
        let back = try JSONDecoder().decode(AgentMessage.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back.text, m.text)
        XCTAssertEqual(back.imagePaths, ["/a.png", "/b.mov"])
        XCTAssertTrue(back.steered)
        XCTAssertEqual(back.id, m.id)
    }

    func testImagePathAccessorMirrorsFirstAttachment() {
        var m = AgentMessage(kind: .user, text: "x", imagePath: "/a.png")
        XCTAssertEqual(m.imagePaths, ["/a.png"])
        m.imagePath = "/b.png"
        XCTAssertEqual(m.imagePaths, ["/b.png"])
        m.imagePath = nil
        XCTAssertTrue(m.imagePaths.isEmpty)
    }

    func testFavoriteRoundTrip() throws {
        let f = AgentFavorite(title: "Fast", cliKind: .claude, modelId: "sonnet", modelTitle: "Sonnet", effort: "low", isBuiltIn: false)
        let back = try JSONDecoder().decode(AgentFavorite.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back, f)
    }
}
