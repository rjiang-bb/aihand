import XCTest
@testable import AiHand

final class SessionPersistenceTests: SandboxedTestCase {
    private func session(_ title: String, workspace: String = "/tmp/ws", status: AgentSessionStatus = .finished) -> AgentSession {
        AgentSession(title: title, prompt: title, screenshotPath: nil, workspace: workspace,
                     gitBranch: "main", connectionID: nil, cliKind: .cursor, status: status)
    }

    func testSessionsSurviveRelaunch() throws {
        let store = SessionStore()
        let a = session("alpha")
        a.messages = [AgentMessage(kind: .user, text: "hi"), AgentMessage(kind: .assistant, text: "- ok")]
        a.chatId = "chat-1"
        store.prepend(a)
        store.prepend(session("beta"))
        store.saveNow()

        let reloaded = SessionStore()
        XCTAssertEqual(reloaded.allSessions.map(\.title), ["beta", "alpha"])
        let back = try XCTUnwrap(reloaded.session(id: a.id))
        XCTAssertEqual(back.chatId, "chat-1")
        XCTAssertEqual(back.messages.map(\.text), ["hi", "- ok"])
        XCTAssertEqual(back.workspace, "/tmp/ws")
        XCTAssertEqual(back.cliKind, .cursor)
    }

    func testInFlightRunsAreMarkedStoppedOnSave() {
        let store = SessionStore()
        let s = session("running", status: .working)
        store.prepend(s)
        store.saveNow()
        XCTAssertEqual(s.status, .stopped)
        XCTAssertEqual(s.messages.last?.text, "Stopped (app quit)")

        let reloaded = SessionStore()
        XCTAssertEqual(reloaded.session(id: s.id)?.status, .stopped)
    }

    func testRemoveDeletesAndPersists() {
        let store = SessionStore()
        let a = session("a"), b = session("b")
        store.prepend(a); store.prepend(b)
        store.remove(a.id)
        store.saveNow()
        XCTAssertEqual(SessionStore().allSessions.map(\.id), [b.id])
    }

    func testRemoveDeletesAttachedFiles() throws {
        let shot = try write("shot.png")
        let store = SessionStore()
        let s = AgentSession(title: "t", prompt: "p", screenshotPath: shot.path, workspace: "/tmp/ws",
                             gitBranch: "", connectionID: nil, cliKind: .cursor, status: .finished)
        store.prepend(s)
        store.remove(s.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shot.path))
    }

    func testOverflowIsTrimmedPerWorkspaceOldestFirst() {
        let store = SessionStore()
        var discarded: [AgentSession] = []
        store.onDiscard = { discarded += $0 }
        for i in 0..<(SessionStore.maxSessions + 3) { store.prepend(session("s\(i)")) }
        store.prepend(session("other", workspace: "/tmp/other"))
        let inWS = store.allSessions.filter { $0.workspace == "/tmp/ws" }
        XCTAssertEqual(inWS.count, SessionStore.maxSessions)
        XCTAssertEqual(inWS.first?.title, "s\(SessionStore.maxSessions + 2)", "newest kept")
        XCTAssertEqual(Set(discarded.map(\.title)), ["s0", "s1", "s2"], "oldest dropped")
        XCTAssertEqual(store.allSessions.filter { $0.workspace == "/tmp/other" }.count, 1)
    }

    func testLegacyFileWithoutWorkspaceStillLoads() throws {
        let id = UUID()
        let json = """
        {"sessions":[{"id":"\(id.uuidString)","createdAt":"2026-01-01T00:00:00Z","initialPrompt":"p",
        "title":"old","status":"finished","messages":[],"preview":""}]}
        """
        let dir = AppSupport.directory()
        try json.write(to: dir.appendingPathComponent("sessions.json"), atomically: true, encoding: .utf8)
        let store = SessionStore()
        XCTAssertEqual(store.session(id: id)?.title, "old")
    }

    func testCorruptFileDoesNotCrashAndStartsEmpty() throws {
        try "not json".write(to: AppSupport.directory().appendingPathComponent("sessions.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(SessionStore().allSessions.isEmpty)
    }

    func testScopeMatchingHidesOtherWorkspaces() {
        let store = SessionStore()
        XCTAssertTrue(store.matchesCurrentScope(session("x", workspace: store.currentWorkspace)) || store.currentWorkspace.isEmpty)
        XCTAssertFalse(store.matchesCurrentScope(session("y", workspace: "/definitely/elsewhere")))
    }
}

final class FavoritesAndPreferencesTests: SandboxedTestCase {
    func testBuiltInFavoriteAlwaysExistsPerCLI() {
        for kind in AgentCLIKind.allCases {
            let favs = Preferences.favorites(for: kind, target: .local)
            XCTAssertTrue(favs.contains { $0.isBuiltIn }, "\(kind) needs a built-in Default")
        }
    }

    func testAddSelectAndCycleFavoritesWraps() throws {
        let kind = AgentCLIKind.cursor
        let one = AgentFavorite(title: "One", cliKind: kind, modelId: "m1", modelTitle: "M1", effort: nil, isBuiltIn: false)
        let two = AgentFavorite(title: "Two", cliKind: kind, modelId: "m2", modelTitle: "M2", effort: "high", isBuiltIn: false)
        Preferences.addAgentFavorite(one)
        Preferences.addAgentFavorite(two)
        let favs = Preferences.favorites(for: kind, target: .local)
        XCTAssertGreaterThanOrEqual(favs.count, 3)

        let s = AgentSession(title: "t", prompt: "p", screenshotPath: nil, workspace: "/tmp/ws",
                             gitBranch: "", connectionID: nil, cliKind: kind, status: .finished)
        var seen: [UUID] = []
        for _ in 0..<favs.count { seen.append(try XCTUnwrap(s.cycleFavorite()).id) }
        XCTAssertEqual(Set(seen), Set(favs.map(\.id)), "cycle visits every favorite once")
        XCTAssertEqual(try XCTUnwrap(s.cycleFavorite()).id, seen[0], "then wraps")
        XCTAssertEqual(s.favoriteId, seen[0])
    }

    func testApplyFavoriteSetsModelAndEffort() {
        let kind = AgentCLIKind.claude
        Preferences.setAgentCLI(kind, for: .local)
        let fav = AgentFavorite(title: "Deep", cliKind: kind, modelId: "opus", modelTitle: "Opus", effort: "max", isBuiltIn: false)
        Preferences.addAgentFavorite(fav)
        let s = AgentSession(title: "t", prompt: "p", screenshotPath: nil, workspace: "/tmp/ws",
                             gitBranch: "", connectionID: nil, cliKind: kind, status: .finished)
        s.applyFavorite(fav)
        XCTAssertEqual(s.modelId, "opus")
        XCTAssertEqual(s.effort, "max")
        XCTAssertEqual(Preferences.currentAgentFavoriteID(for: kind, target: .local), fav.id)
    }

    func testFavoriteForOtherCLIIsIgnored() {
        Preferences.setAgentCLI(.cursor, for: .local)
        let fav = AgentFavorite(title: "X", cliKind: .codex, modelId: "o3", modelTitle: "o3", effort: nil, isBuiltIn: false)
        Preferences.addAgentFavorite(fav)
        let s = AgentSession(title: "t", prompt: "p", screenshotPath: nil, workspace: "/tmp/ws",
                             gitBranch: "", connectionID: nil, cliKind: .cursor, status: .finished)
        s.applyFavorite(fav)
        XCTAssertNil(s.modelId)
        XCTAssertNil(s.favoriteId)
    }

    func testApplyFavoriteFollowsSettingsCLIAndClearsChatId() {
        Preferences.setAgentCLI(.claude, for: .local)
        let fav = AgentFavorite(
            title: "Sonnet",
            cliKind: .claude,
            modelId: "claude-sonnet-5",
            modelTitle: "Sonnet",
            effort: "medium",
            isBuiltIn: false
        )
        Preferences.addAgentFavorite(fav)
        let s = AgentSession(title: "t", prompt: "p", screenshotPath: nil, workspace: "/tmp/ws",
                             gitBranch: "", connectionID: nil, cliKind: .cursor, status: .finished)
        s.chatId = "cursor-chat"
        s.applyFavorite(fav)
        XCTAssertEqual(s.cliKind, .claude)
        XCTAssertNil(s.chatId, "switching agent CLI cannot resume the prior chat id")
        XCTAssertEqual(s.modelId, "claude-sonnet-5")
        XCTAssertEqual(s.effort, "medium")
        XCTAssertEqual(Preferences.currentAgentFavoriteID(for: .claude, target: .local), fav.id)
    }

    func testSyncModelFromSettingsMatchesAgentPrefs() {
        Preferences.setAgentCLI(.claude, for: .local)
        let fav = AgentFavorite(
            title: "Deep",
            cliKind: .claude,
            modelId: "opus",
            modelTitle: "Opus",
            effort: "max",
            isBuiltIn: false
        )
        Preferences.addAgentFavorite(fav)
        Preferences.setCurrentAgentFavoriteID(fav.id, for: .claude, target: .local)
        let s = AgentSession(title: "t", prompt: "p", screenshotPath: nil, workspace: "/tmp/ws",
                             gitBranch: "", connectionID: nil, cliKind: .cursor, status: .finished)
        s.syncModelFromSettings()
        XCTAssertEqual(s.cliKind, .claude)
        XCTAssertEqual(s.favoriteId, fav.id)
        XCTAssertEqual(s.modelId, "opus")
    }

    func testFavoriteForNewSessionIgnoresLastSessionModel() {
        Preferences.setAgentCLI(.cursor, for: .local)
        let kept = AgentFavorite(
            title: "Keep",
            cliKind: .cursor,
            modelId: "keep-me",
            modelTitle: "Keep",
            effort: nil,
            isBuiltIn: false
        )
        let other = AgentFavorite(
            title: "Other",
            cliKind: .cursor,
            modelId: "other-me",
            modelTitle: "Other",
            effort: nil,
            isBuiltIn: false
        )
        Preferences.addAgentFavorite(kept)
        Preferences.addAgentFavorite(other)
        Preferences.setCurrentAgentFavoriteID(kept.id, for: .cursor, target: .local)
        let last = AgentSession(title: "t", prompt: "p", screenshotPath: nil, workspace: "/tmp/ws",
                                gitBranch: "", connectionID: nil, cliKind: .cursor,
                                favoriteId: other.id, modelId: "other-me", status: .finished)
        let picked = Preferences.favoriteForNewSession(cli: .cursor, lastSession: last, target: .local)
        XCTAssertEqual(picked.id, kept.id, "new sessions use Settings Current, not the previous chat")
    }

    func testPreferencesWriteToTheSandboxSuiteNotStandard() {
        let marker = Shortcut(keyCode: 5, modifiers: 256, display: "⌘Y")
        Preferences.toggleShortcut = marker
        XCTAssertEqual(Preferences.toggleShortcut, marker)
        XCTAssertNotEqual(UserDefaults.standard.object(forKey: "shortcut.toggle") as? NSObject, marker as AnyObject as? NSObject)
    }
}
