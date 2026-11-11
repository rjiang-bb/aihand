import XCTest
@testable import AiHand

final class SessionsOpenChatPersistenceTests: SandboxedTestCase {
    func testEncodeDecodeRoundTrip() {
        let a = UUID()
        let b = UUID()
        let map = [
            "local|/Users/rui/Code/aihand": a,
            "remote|/home/proj": b,
        ]
        let encoded = SessionsOpenChatPersistence.encode(map)
        XCTAssertEqual(encoded["local|/Users/rui/Code/aihand"], a.uuidString)
        XCTAssertEqual(SessionsOpenChatPersistence.decode(encoded), map)
    }

    func testDecodeSkipsInvalidUUIDs() {
        let id = UUID()
        let decoded = SessionsOpenChatPersistence.decode([
            "local|/tmp/a": id.uuidString,
            "local|/tmp/b": "not-a-uuid",
        ])
        XCTAssertEqual(decoded, ["local|/tmp/a": id])
    }

    func testPreferencesSurvivesRelaunchStyleReload() {
        let id = UUID()
        let key = "local|/Users/rui/Code/aihand"
        Preferences.openChatByWorkspace = [key: id.uuidString]
        XCTAssertEqual(Preferences.openChatByWorkspace[key], id.uuidString)
        XCTAssertEqual(
            SessionsOpenChatPersistence.decode(Preferences.openChatByWorkspace)[key],
            id
        )
        Preferences.openChatByWorkspace = [:]
        XCTAssertTrue(Preferences.openChatByWorkspace.isEmpty)
    }
}
