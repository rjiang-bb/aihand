import XCTest
@testable import AiHand

/// Runs the real `AgentSessionManager` / `AgentSessionRunner` against a fake CLI that records
/// its argv + cwd and prints canned stream-json. Exercises the whole send path (args, launch,
/// parsing, status, follow-up, queue, steer, failures) without a real agent.
class FakeAgentTestCase: SandboxedTestCase {
    var fakeDir: URL!
    var workspace: URL!
    var store: SessionStore!
    var manager: AgentSessionManager!

    static let script = #"""
    #!/bin/bash
    d="${FAKE_AGENT_DIR:?}"
    # Atomic call numbering (concurrent launches): claim the first free slot via mkdir.
    n=1; while ! mkdir "$d/slot-$n" 2>/dev/null; do n=$((n+1)); done
    echo "$n" > "$d/count"
    printf '%s\0' "$@" > "$d/args-$n.bin"
    pwd > "$d/cwd-$n.txt"
    kind=$(cat "$d/kind" 2>/dev/null || echo cursor)
    mode=$(cat "$d/mode" 2>/dev/null || echo ok)
    id="chat-$n"
    if [ -f "$d/lines.txt" ]; then
      cat "$d/lines.txt"
      [ -f "$d/stderr.txt" ] && cat "$d/stderr.txt" >&2
      exit "$(cat "$d/exit" 2>/dev/null || echo 0)"
    fi
    if [ "$mode" = "fail" ]; then echo "boom: not logged in" >&2; exit 2; fi
    case "$kind" in
      cursor)
        echo "{\"type\":\"system\",\"session_id\":\"$id\"}"
        echo '{"type":"assistant","timestamp_ms":1,"message":{"content":[{"type":"text","text":"Hello from fake"}]}}'
        echo '{"type":"tool_call","subtype":"started","tool_call":{"readToolCall":{"args":{"path":"/w/a.swift"}}}}'
        [ "$mode" = "slow" ] && sleep 1.5
        if [ "$mode" = "error" ]; then
          echo "{\"type\":\"result\",\"is_error\":true,\"result\":\"model exploded\",\"session_id\":\"$id\"}"
        else
          echo "{\"type\":\"result\",\"is_error\":false,\"result\":\"All done $n\",\"session_id\":\"$id\"}"
        fi ;;
      claude)
        echo "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$id\"}"
        echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Hello from fake"},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/w/a.swift"}}]}}'
        [ "$mode" = "slow" ] && sleep 1.5
        echo "{\"type\":\"result\",\"is_error\":false,\"result\":\"All done $n\",\"session_id\":\"$id\"}" ;;
      codex)
        echo "{\"type\":\"thread.started\",\"thread_id\":\"$id\"}"
        echo '{"type":"turn.started"}'
        echo '{"type":"item.completed","item":{"type":"agent_message","text":"Hello from fake"}}'
        [ "$mode" = "slow" ] && sleep 1.5
        echo '{"type":"turn.completed"}' ;;
    esac
    """#

    override func setUpWithError() throws {
        try super.setUpWithError()
        fakeDir = tempDir.appendingPathComponent("fake", isDirectory: true)
        workspace = tempDir.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let exe = fakeDir.appendingPathComponent("fake-agent")
        let body = Self.script.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : String($0) }.joined(separator: "\n")
        try body.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        setenv("FAKE_AGENT_DIR", fakeDir.path, 1)
        for kind in AgentCLIKind.allCases { AgentPathLookup.overrides[kind.commandName] = exe.path }
        Preferences.addAgentWorkspace(workspace.path)
        use(.cursor)
        store = SessionStore()
        manager = AgentSessionManager(store: store)
    }

    override func tearDownWithError() throws {
        AgentPathLookup.overrides = [:]
        unsetenv("FAKE_AGENT_DIR")
        try super.tearDownWithError()
    }

    func use(_ kind: AgentCLIKind, mode: String = "ok") {
        Preferences.setAgentCLI(kind, for: Preferences.runtimeAgentTarget)
        try? kind.rawValue.write(to: fakeDir.appendingPathComponent("kind"), atomically: true, encoding: .utf8)
        setMode(mode)
    }

    /// Replace the canned output with exact stdout lines (and optional stderr / exit code).
    func script(_ lines: [String], stderr: String? = nil, exit code: Int = 0) {
        try? (lines.joined(separator: "\n") + "\n").write(to: fakeDir.appendingPathComponent("lines.txt"), atomically: true, encoding: .utf8)
        if let stderr { try? stderr.write(to: fakeDir.appendingPathComponent("stderr.txt"), atomically: true, encoding: .utf8) }
        try? String(code).write(to: fakeDir.appendingPathComponent("exit"), atomically: true, encoding: .utf8)
    }

    func setMode(_ mode: String) {
        try? mode.write(to: fakeDir.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    }

    /// Forget recorded calls (count + argv/cwd files) so a new scenario starts at call 1.
    func resetCalls() {
        for f in (try? FileManager.default.contentsOfDirectory(atPath: fakeDir.path)) ?? []
        where f == "count" || f.hasPrefix("slot-") || f.hasPrefix("args-") || f.hasPrefix("cwd-") {
            try? FileManager.default.removeItem(at: fakeDir.appendingPathComponent(f))
        }
    }

    /// Wait for the session's process to be fully gone, not just for its final event.
    func waitIdle(_ s: AgentSession) {
        waitUntil("process exit") { self.manager.runner(for: s.id)?.isRunning != true }
    }

    var calls: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: fakeDir.path)) ?? []).filter { $0.hasPrefix("slot-") }.count
    }

    func args(_ n: Int) -> [String] {
        guard let data = try? Data(contentsOf: fakeDir.appendingPathComponent("args-\(n).bin")) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    func cwd(_ n: Int) -> String {
        ((try? String(contentsOf: fakeDir.appendingPathComponent("cwd-\(n).txt"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Spin the main run loop until `condition` or timeout.
    @discardableResult
    func waitUntil(_ label: String = "", timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                   _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTFail("timed out waiting for \(label)", file: file, line: line)
        return false
    }

    func send(_ prompt: String, image: String? = nil) throws -> AgentSession {
        try XCTUnwrap(manager.startFromAnnotation(prompt: prompt, screenshotPath: image))
    }
}

final class FakeAgentSendTests: FakeAgentTestCase {
    func testCursorAnnotationSendEndToEnd() throws {
        let shot = try write("shot.png")
        let s = try send("fix the padding", image: shot.path)
        XCTAssertEqual(s.status, .working)
        waitUntil("finished") { s.status == .finished }

        let a = args(1)
        XCTAssertEqual(a.first, "-p")
        XCTAssertEqual(a[a.firstIndex(of: "--workspace")! + 1], workspace.path.replacingOccurrences(of: "/private", with: ""), "workspace passed through")
        XCTAssertEqual(a[a.firstIndex(of: "--image")! + 1], shot.path)
        XCTAssertEqual(a[a.count - 2], "--")
        XCTAssertTrue(a.last!.hasPrefix("fix the padding"))
        XCTAssertTrue(a.last!.contains(shot.path), "screenshot path is also in the prompt text")
        XCTAssertEqual(s.chatId, "chat-1")
        XCTAssertEqual(s.preview, "All done 1")
        XCTAssertTrue(s.messages.contains { $0.kind == .assistant && $0.text == "Hello from fake" })
        XCTAssertTrue(s.messages.contains { $0.kind == .tool && $0.text.hasPrefix("Reading") })
        XCTAssertEqual(s.title, "fix the padding")
        XCTAssertTrue(store.allSessions.contains { $0.id == s.id })
    }

    func testAgentRunsInTheSessionWorkspace() throws {
        let s = try send("hi")
        waitUntil("finished") { s.status == .finished }
        XCTAssertEqual((cwd(1) as NSString).resolvingSymlinksInPath, (workspace.path as NSString).resolvingSymlinksInPath)
    }

    func testDashLeadingPromptSurvivesAsAPositional() throws {
        let s = try send("- a\n  - nested\n--help")
        waitUntil("finished") { s.status == .finished }
        let a = args(1)
        XCTAssertEqual(a[a.count - 2], "--")
        XCTAssertEqual(a.last, "- a\n  - nested\n--help", "multi-line prompt arrives as one argv element")
    }

    func testClaudeAndCodexParsing() throws {
        for kind in [AgentCLIKind.claude, .codex] {
            use(kind)
            resetCalls()
            let s = try send("do it")
            waitUntil("\(kind) finished") { s.status == .finished }
            XCTAssertEqual(s.chatId, "chat-1", "\(kind)")
            XCTAssertTrue(s.messages.contains { $0.kind == .assistant && $0.text == "Hello from fake" }, "\(kind)")
            XCTAssertEqual(s.cliKind, kind)
            let a = args(1)
            XCTAssertEqual(a[a.count - 2], "--", "\(kind)")
            XCTAssertEqual(a.last, "do it", "\(kind)")
            if kind == .claude {
                XCTAssertTrue(s.messages.contains { $0.kind == .tool && $0.text.hasPrefix("Reading") })
                XCTAssertTrue(a.contains("--verbose"))
            } else {
                XCTAssertEqual(a.first, "exec")
                XCTAssertTrue(a.contains("--json"))
            }
        }
    }

    func testImageIsForwardedForCodexButVideoIsPromptOnly() throws {
        use(.codex)
        let png = try write("a.png"), mov = try write("a.mov")
        let s1 = try send("look", image: png.path)
        waitUntil("png finished") { s1.status == .finished }
        let a1 = args(1)
        XCTAssertEqual(a1[a1.firstIndex(of: "--image")! + 1], png.path)
        XCTAssertLessThan(a1.firstIndex(of: "--image")!, a1.firstIndex(of: "--")!)

        let s2 = try send("watch", image: mov.path)
        waitUntil("mov finished") { s2.status == .finished }
        let a2 = args(2)
        XCTAssertFalse(a2.contains("--image"))
        XCTAssertTrue(a2.last!.contains(mov.path), "video path goes in the prompt")
    }

    func testSendWithoutAWorkspaceDoesNothing() {
        Preferences.removeAgentWorkspace(workspace.path)
        XCTAssertNil(manager.startFromAnnotation(prompt: "hi", screenshotPath: nil))
        XCTAssertEqual(calls, 0)
    }

    func testEmptyTextOnlySendIsRejectedButScreenshotOnlyIsAllowed() throws {
        XCTAssertNil(manager.startFromAnnotation(prompt: "  ", screenshotPath: nil))
        let shot = try write("s.png")
        let s = try XCTUnwrap(manager.startFromAnnotation(prompt: "", screenshotPath: shot.path))
        XCTAssertEqual(s.title, "Annotation")
        waitUntil("finished") { s.status == .finished }
        XCTAssertTrue(args(1).last!.contains("annotated screenshot"), "default instruction when no prompt")
    }
}

final class FakeAgentFollowUpTests: FakeAgentTestCase {
    func testFollowUpResumesTheChat() throws {
        for kind in AgentCLIKind.allCases {
            use(kind)
            resetCalls()
            let s = try send("first")
            waitUntil("\(kind) first") { s.status == .finished }
            waitIdle(s)
            manager.followUp(sessionID: s.id, text: "second")
            XCTAssertEqual(s.messages.last { $0.kind == .user }?.text, "second", "user turn appended immediately")
            XCTAssertEqual(s.status, .working)
            waitUntil("\(kind) second") { self.calls == 2 && s.status == .finished }
            let a = args(2)
            let resumeIdx = try XCTUnwrap(a.firstIndex(of: "--resume") ?? a.firstIndex(of: "resume"), "\(kind)")
            XCTAssertEqual(a[resumeIdx + 1], "chat-1", "\(kind)")
            XCTAssertEqual(a.last, "second")
            XCTAssertEqual(s.chatId, "chat-2", "\(kind): chat id updated from the new turn")
        }
    }

    func testFollowUpWithMediaAttachesIt() throws {
        let s = try send("first")
        waitUntil("first") { s.status == .finished }
        let img = try write("later.png")
        manager.followUp(sessionID: s.id, text: "", imagePaths: [img.path])
        waitUntil("second") { self.calls == 2 && s.status == .finished }
        let a = args(2)
        XCTAssertEqual(a[a.firstIndex(of: "--image")! + 1], img.path)
        XCTAssertEqual(s.messages.last { $0.kind == .user }?.imagePaths, [img.path])
        XCTAssertEqual(s.preview, "All done 2")
    }

    func testEmptyFollowUpIsIgnored() throws {
        let s = try send("first")
        waitUntil("first") { s.status == .finished }
        manager.followUp(sessionID: s.id, text: "   ")
        XCTAssertEqual(calls, 1)
    }

    func testBlankSessionFirstMessageStartsAFreshTurn() throws {
        let s = try XCTUnwrap(manager.createBlankSession())
        XCTAssertEqual(s.title, "New session")
        XCTAssertEqual(s.status, .waiting)
        manager.followUp(sessionID: s.id, text: "build a thing")
        XCTAssertEqual(s.title, "build a thing")
        waitUntil("finished") { s.status == .finished }
        let a = args(1)
        XCTAssertFalse(a.contains("--resume"), "first message starts, doesn't resume")
        XCTAssertEqual(a.last, "build a thing")
        XCTAssertEqual(s.messages.filter { $0.kind == .user }.count, 1)
    }

    func testQueuedFollowUpRunsAfterTheCurrentTurn() throws {
        use(.cursor, mode: "slow")
        let s = try send("first")
        waitUntil("working with a live runner") { self.calls == 1 && s.status == .working }
        manager.followUp(sessionID: s.id, text: "queued one", submit: .queue)
        XCTAssertEqual(s.queuedFollowUps.map(\.text), ["queued one"])
        XCTAssertEqual(calls, 1, "not sent while busy")
        setMode("ok")
        waitUntil("queue drained") { self.calls == 2 && s.status == .finished && s.queuedFollowUps.isEmpty }
        XCTAssertEqual(args(2).last, "queued one")
        XCTAssertEqual(s.messages.filter { $0.kind == .user }.last?.steered, false, "queued sends aren't steers")
    }

    func testQueuedFollowUpWithMediaDoesNotSteer() throws {
        use(.cursor, mode: "slow")
        let s = try send("first")
        waitUntil("working with a live runner") { self.calls == 1 && s.status == .working }
        let img = try write("queued-media.png")
        manager.followUp(sessionID: s.id, text: "with pic", submit: .queue, imagePaths: [img.path])
        XCTAssertEqual(s.queuedFollowUps.map(\.text), ["with pic"])
        XCTAssertEqual(s.queuedFollowUps.first?.imagePaths, [img.path])
        XCTAssertEqual(calls, 1, "Enter+media while working must queue, not steer")
        setMode("ok")
        waitUntil("queue drained") { self.calls == 2 && s.status == .finished && s.queuedFollowUps.isEmpty }
        let a = args(2)
        XCTAssertEqual(a[a.firstIndex(of: "--image")! + 1], img.path)
        XCTAssertTrue(a.last?.hasPrefix("with pic") == true)
        let drained = try XCTUnwrap(s.messages.last { $0.kind == .user })
        XCTAssertEqual(drained.steered, false, "drained queue item is not a steer")
        XCTAssertEqual(drained.imagePaths, [img.path])
    }

    func testQueuedFollowUpCanBeRemoved() throws {
        use(.cursor, mode: "slow")
        let s = try send("first")
        waitUntil("working") { self.calls == 1 && s.status == .working }
        manager.followUp(sessionID: s.id, text: "never", submit: .queue)
        let id = try XCTUnwrap(s.queuedFollowUps.first?.id)
        manager.removeQueuedFollowUp(sessionID: s.id, followUpID: id)
        XCTAssertTrue(s.queuedFollowUps.isEmpty)
        waitUntil("finished") { s.status == .finished }
        XCTAssertEqual(calls, 1)
    }

    func testEditingQueueHoldsEditedAndLaterItems() throws {
        use(.cursor, mode: "slow")
        let s = try send("first")
        waitUntil("working") { self.calls == 1 && s.status == .working }
        manager.followUp(sessionID: s.id, text: "A", submit: .queue)
        manager.followUp(sessionID: s.id, text: "B", submit: .queue)
        manager.followUp(sessionID: s.id, text: "C", submit: .queue)
        let bID = try XCTUnwrap(s.queuedFollowUps.first(where: { $0.text == "B" })?.id)
        s.editingFollowUpID = bID
        setMode("ok")
        // A drains; B+C stay held while B is being edited.
        waitUntil("A drained") {
            self.calls == 2 && s.queuedFollowUps.map(\.text) == ["B", "C"]
        }
        XCTAssertEqual(s.editingFollowUpID, bID)
        XCTAssertEqual(args(2).last, "A")
        // Still held — no further drain while editing B (now first).
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.3))
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(s.queuedFollowUps.map(\.text), ["B", "C"])
    }

    func testConfirmQueueEditUpdatesTextAndResumes() throws {
        use(.cursor, mode: "slow")
        let s = try send("first")
        waitUntil("working") { self.calls == 1 && s.status == .working }
        manager.followUp(sessionID: s.id, text: "A", submit: .queue)
        manager.followUp(sessionID: s.id, text: "B", submit: .queue)
        let bID = try XCTUnwrap(s.queuedFollowUps.first(where: { $0.text == "B" })?.id)
        s.editingFollowUpID = bID
        setMode("ok")
        waitUntil("A drained") { self.calls == 2 && s.queuedFollowUps.map(\.text) == ["B"] }
        manager.confirmQueuedFollowUpEdit(sessionID: s.id, followUpID: bID, text: "B-edited")
        XCTAssertNil(s.editingFollowUpID)
        waitUntil("edited B drained") { self.calls == 3 && s.queuedFollowUps.isEmpty && s.status == .finished }
        XCTAssertEqual(args(3).last, "B-edited")
    }

    func testCancelQueueEditKeepsOriginalAndResumes() throws {
        use(.cursor, mode: "slow")
        let s = try send("first")
        waitUntil("working") { self.calls == 1 && s.status == .working }
        manager.followUp(sessionID: s.id, text: "A", submit: .queue)
        manager.followUp(sessionID: s.id, text: "B", submit: .queue)
        let bID = try XCTUnwrap(s.queuedFollowUps.first(where: { $0.text == "B" })?.id)
        s.editingFollowUpID = bID
        setMode("ok")
        waitUntil("A drained") { self.calls == 2 && s.queuedFollowUps.map(\.text) == ["B"] }
        manager.cancelQueuedFollowUpEdit(sessionID: s.id)
        XCTAssertNil(s.editingFollowUpID)
        waitUntil("original B drained") { self.calls == 3 && s.queuedFollowUps.isEmpty && s.status == .finished }
        XCTAssertEqual(args(3).last, "B")
    }

    func testEditingFirstQueueItemBlocksDrainUntilConfirm() throws {
        use(.cursor, mode: "slow")
        let s = try send("first")
        waitUntil("working") { self.calls == 1 && s.status == .working }
        manager.followUp(sessionID: s.id, text: "held", submit: .queue)
        manager.followUp(sessionID: s.id, text: "later", submit: .queue)
        let heldID = try XCTUnwrap(s.queuedFollowUps.first?.id)
        s.editingFollowUpID = heldID
        setMode("ok")
        // Wait until the process is gone — status flips to finished on the result JSON
        // before termination/`onFinished`, and confirming too early races the drain.
        waitUntil("turn idle") {
            s.status == .finished
                && s.chatId != nil
                && self.manager.runner(for: s.id)?.isRunning != true
        }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.15))
        XCTAssertEqual(calls, 1, "nothing drains while first queued item is edited")
        XCTAssertEqual(s.editingFollowUpID, heldID)
        XCTAssertEqual(s.queuedFollowUps.map(\.text), ["held", "later"])
        manager.confirmQueuedFollowUpEdit(sessionID: s.id, followUpID: heldID, text: "held-now")
        waitUntil("held-now launched") { self.calls >= 2 }
        XCTAssertEqual(args(2).last, "held-now")
        waitUntil("queue drained after confirm") {
            self.calls == 3 && s.queuedFollowUps.isEmpty && s.status == .finished
        }
        XCTAssertEqual(args(3).last, "later")
    }

    func testSendNowWhileBusySteersByInterrupting() throws {
        use(.cursor, mode: "slow")
        let s = try send("first")
        waitUntil("working with chat id") { s.chatId != nil && s.status == .working }
        setMode("ok")
        manager.followUp(sessionID: s.id, text: "actually do this instead", submit: .sendNow)
        waitUntil("steered run done") { self.calls == 2 && s.status == .finished }
        XCTAssertEqual(s.messages.last { $0.kind == .user }?.steered, true)
        XCTAssertEqual(args(2).last, "actually do this instead")
        XCTAssertFalse(s.messages.contains { $0.text == "Stopped" }, "steer interrupts quietly")
        XCTAssertEqual(s.preview, "All done 2")
    }

    func testStopMarksTheSessionStopped() throws {
        use(.cursor, mode: "slow")
        let s = try send("first")
        waitUntil("working") { self.calls == 1 && s.status == .working }
        manager.stop(sessionID: s.id)
        waitUntil("stopped") { s.status == .stopped }
        XCTAssertEqual(s.preview, "Stopped")
        XCTAssertEqual(s.messages.last?.text, "Stopped")
    }

    func testFollowUpBeforeAnyChatIdExplainsWhy() throws {
        let s = AgentSession(title: "t", prompt: "p", screenshotPath: nil, workspace: workspace.path, gitBranch: "",
                             connectionID: nil, cliKind: .cursor, status: .finished)
        s.messages = [AgentMessage(kind: .user, text: "p")]
        store.prepend(s)
        manager.followUp(sessionID: s.id, text: "more")
        waitUntil("explanation") { s.status == .waiting }
        XCTAssertTrue(s.errorMessage?.contains("No chat id") == true)
        XCTAssertEqual(calls, 0)
    }

    func testSessionCompletionCallbackFiresOnceWhenIdle() throws {
        var completed: [UUID] = []
        manager.onSessionCompleted = { completed.append($0.id) }
        let s = try send("hi")
        waitUntil("completed") { !completed.isEmpty }
        XCTAssertEqual(completed, [s.id])
    }
}

final class FakeAgentFailureTests: FakeAgentTestCase {
    func testNonZeroExitSurfacesStderrAndLoginHint() throws {
        use(.cursor, mode: "fail")
        let s = try send("hi")
        waitUntil("waiting") { s.status == .waiting }
        let msg = try XCTUnwrap(s.errorMessage)
        XCTAssertTrue(msg.contains("exited (2)"), msg)
        XCTAssertTrue(msg.contains("boom: not logged in"), "stderr is shown")
        XCTAssertTrue(msg.contains("agent login"), "login hint is shown")
        XCTAssertEqual(s.messages.last?.kind, .system)
    }

    func testAgentReportedErrorMarksTheSessionFailed() throws {
        use(.cursor, mode: "error")
        let s = try send("hi")
        waitUntil("failed") { s.status == .failed }
        XCTAssertEqual(s.errorMessage, "model exploded")
        XCTAssertEqual(s.preview, "model exploded")
    }

    func testMissingCLIFailsWithInstallHint() throws {
        AgentPathLookup.overrides["agent"] = ""
        let s = try send("hi")
        waitUntil("failed") { s.status == .failed }
        XCTAssertTrue(s.errorMessage?.contains("Couldn’t find `agent`") == true, s.errorMessage ?? "")
        XCTAssertTrue(s.errorMessage?.contains("Install the Cursor CLI") == true)
        XCTAssertEqual(calls, 0)
    }

    func testRecoversAfterAFailureWithAFollowUp() throws {
        use(.cursor, mode: "error")
        let s = try send("hi")
        waitUntil("failed") { s.status == .failed }
        setMode("ok")
        manager.followUp(sessionID: s.id, text: "try again")
        waitUntil("recovered") { s.status == .finished && self.calls == 2 }
        XCTAssertNil(s.errorMessage)
    }
}
