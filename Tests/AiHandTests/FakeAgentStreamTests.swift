import XCTest
@testable import AiHand

/// Stream parsing, model/effort flags, concurrency and persistence — against the fake agent.
final class FakeAgentStreamTests: FakeAgentTestCase {
    private func run(_ lines: [String], stderr: String? = nil, exit code: Int = 0) throws -> AgentSession {
        script(lines, stderr: stderr, exit: code)
        let s = try send("go")
        waitUntil("run ends") { s.status != .working }
        return s
    }

    private func tools(_ s: AgentSession) -> [String] { s.messages.filter { $0.kind == .tool }.map(\.text) }

    // MARK: Cursor stream

    func testCursorToolLabels() throws {
        func call(_ k: String, _ a: String) -> String {
            #"{"type":"tool_call","subtype":"started","tool_call":{"\#(k)":{"args":\#(a)}}}"#
        }
        let s = try run([
            #"{"type":"system","session_id":"c1"}"#,
            call("readToolCall", #"{"path":"/w/Sources/a.swift"}"#),
            call("editToolCall", #"{"path":"/w/Sources/b.swift"}"#),
            call("shellToolCall", #"{"command":"swift build"}"#),
            call("grepToolCall", #"{"pattern":"TODO"}"#),
            call("globToolCall", #"{"globPattern":"**/*.swift"}"#),
            call("deleteToolCall", #"{"path":"/w/old.txt"}"#),
            call("lsToolCall", #"{"path":"/w/Sources"}"#),
            #"{"type":"result","is_error":false,"result":"ok","session_id":"c1"}"#,
        ])
        let t = tools(s)
        XCTAssertEqual(t.count, 7, "\(t)")
        guard t.count == 7 else { return }
        XCTAssertTrue(t[0].hasPrefix("Reading") && t[0].contains("a.swift"), t[0])
        XCTAssertTrue(t[1].contains("b.swift"), t[1])
        XCTAssertTrue(t[2].contains("swift build"), t[2])
        XCTAssertTrue(t[3].contains("TODO"), t[3])
        XCTAssertTrue(t[4].contains("**/*.swift"), t[4])
        XCTAssertTrue(t[5].contains("old.txt"), t[5])
        XCTAssertTrue(t[6].contains("Sources"), t[6])
    }

    func testEditCompletionRewritesLabelWithDiffStats() throws {
        let s = try run([
            #"{"type":"tool_call","subtype":"started","tool_call":{"editToolCall":{"args":{"path":"/w/Sources/VideoDestinationPicker.swift"}}}}"#,
            #"{"type":"tool_call","subtype":"completed","tool_call":{"editToolCall":{"args":{"path":"/w/Sources/VideoDestinationPicker.swift"},"result":{"success":{"path":"/w/Sources/VideoDestinationPicker.swift","linesAdded":85,"linesRemoved":22}}}}}"#,
            #"{"type":"tool_call","subtype":"started","tool_call":{"editToolCall":{"args":{"path":"/w/Sources/SoftChrome.swift"}}}}"#,
            #"{"type":"tool_call","subtype":"completed","tool_call":{"editToolCall":{"args":{"path":"/w/Sources/SoftChrome.swift"},"result":{"success":{"path":"/w/Sources/SoftChrome.swift","linesAdded":5,"linesRemoved":0}}}}}"#,
            #"{"type":"result","is_error":false,"result":"ok","session_id":"c"}"#,
        ])
        let t = tools(s)
        XCTAssertEqual(t.count, 2, "\(t)")
        XCTAssertEqual(t[0], "Edited Sources/VideoDestinationPicker.swift +85 -22")
        XCTAssertEqual(t[1], "Edited Sources/SoftChrome.swift +5")
        let sum = TurnEditCopy.summarize(toolTexts: t)
        XCTAssertEqual(sum?.fileCount, 2)
        XCTAssertEqual(sum?.added, 90)
        XCTAssertEqual(sum?.removed, 22)
    }

    func testCursorLongShellCommandIsClippedToOneLine() throws {
        let long = String(repeating: "x", count: 200)
        let s = try run([
            #"{"type":"tool_call","subtype":"started","tool_call":{"shellToolCall":{"args":{"command":"echo a\#\nb \#(long)"}}}}"#,
            #"{"type":"result","is_error":false,"result":"ok","session_id":"c"}"#,
        ])
        let label = try XCTUnwrap(tools(s).first)
        XCTAssertFalse(label.contains("\n"))
        XCTAssertLessThan(label.count, 120)
        XCTAssertTrue(label.hasSuffix("…"))
    }

    func testCursorStreamingAssistantSnapshotsMergeIntoOneBubble() throws {
        let s = try run([
            #"{"type":"assistant","timestamp_ms":1,"message":{"content":[{"type":"text","text":"Hel"}]}}"#,
            #"{"type":"assistant","timestamp_ms":2,"message":{"content":[{"type":"text","text":"lo"}]}}"#,
            #"{"type":"result","is_error":false,"result":"Hello","session_id":"c"}"#,
        ])
        let a = s.messages.filter { $0.kind == .assistant }
        XCTAssertEqual(a.count, 1, "deltas coalesce: \(a.map(\.text))")
        XCTAssertEqual(a.first?.text, "Hello")
    }

    func testToolCallsBreakAssistantBubbles() throws {
        let s = try run([
            #"{"type":"assistant","timestamp_ms":1,"message":{"content":[{"type":"text","text":"before"}]}}"#,
            #"{"type":"tool_call","subtype":"started","tool_call":{"readToolCall":{"args":{"path":"/w/a"}}}}"#,
            #"{"type":"assistant","timestamp_ms":2,"message":{"content":[{"type":"text","text":"after"}]}}"#,
            #"{"type":"result","is_error":false,"result":"after","session_id":"c"}"#,
        ])
        let kinds = s.messages.filter { $0.kind != .user && $0.kind != .status }.map(\.kind)
        XCTAssertEqual(kinds, [.assistant, .tool, .assistant])
        XCTAssertTrue(s.messages.contains { $0.kind == .status && $0.text.hasPrefix("Worked for") })
        XCTAssertNil(s.liveActivity)
    }

    func testSuccessfulResultEmitsWorkedForStatusChip() throws {
        let s = try run([
            #"{"type":"assistant","timestamp_ms":1,"message":{"content":[{"type":"text","text":"ok"}]}}"#,
            #"{"type":"result","is_error":false,"result":"ok","session_id":"c"}"#,
        ])
        let chips = s.messages.filter { $0.kind == .status }.map(\.text)
        XCTAssertEqual(chips.count, 1, "\(chips)")
        XCTAssertTrue(chips[0].hasPrefix("Worked for"), chips[0])
        // Chip sits right after the user turn.
        XCTAssertEqual(s.messages[1].kind, .status)
    }

    func testCodexReasoningEmitsThoughtChip() throws {
        let s = try run([
            #"{"type":"thread.started","thread_id":"t1"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.started","item":{"type":"reasoning"}}"#,
            #"{"type":"item.completed","item":{"type":"reasoning"}}"#,
            #"{"type":"item.completed","item":{"type":"agent_message","text":"done"}}"#,
            #"{"type":"turn.completed"}"#,
        ])
        let status = s.messages.filter { $0.kind == .status }.map(\.text)
        XCTAssertTrue(status.contains { $0.hasPrefix("Thought") }, "\(status)")
        XCTAssertTrue(status.contains { $0.hasPrefix("Worked for") }, "\(status)")
        XCTAssertNil(s.liveActivity)
    }

    func testToolCallsSetExploringLiveActivityThenClearOnResult() throws {
        use(.cursor, mode: "slow")
        let s = try send("go")
        waitUntil("tool landed") { s.messages.contains { $0.kind == .tool } }
        XCTAssertEqual(s.liveActivity, "Exploring 1 file")
        waitUntil("run ends") { s.status != .working }
        XCTAssertNil(s.liveActivity)
        XCTAssertTrue(s.messages.contains { $0.kind == .status && $0.text.hasPrefix("Worked for") })
    }

    func testInProgressEditsSetEditingLiveActivity() throws {
        try? FileManager.default.removeItem(at: fakeDir.appendingPathComponent("lines.txt"))
        let exe = fakeDir.appendingPathComponent("fake-agent")
        let body = """
        #!/bin/bash
        echo '{"type":"system","session_id":"c"}'
        echo '{"type":"tool_call","subtype":"started","tool_call":{"editToolCall":{"args":{"path":"/w/a.swift"}}}}'
        echo '{"type":"tool_call","subtype":"completed","tool_call":{"editToolCall":{"args":{"path":"/w/a.swift"},"result":{"success":{"path":"/w/a.swift","linesAdded":79,"linesRemoved":0}}}}}'
        echo '{"type":"tool_call","subtype":"started","tool_call":{"editToolCall":{"args":{"path":"/w/b.swift"}}}}'
        sleep 1.5
        echo '{"type":"result","is_error":false,"result":"ok","session_id":"c"}'
        """
        try body.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let s = try send("go")
        waitUntil("editing live activity") { s.liveActivity == "Editing 2 files +79" }
        waitUntil("run ends") { s.status != .working }
        XCTAssertNil(s.liveActivity)
    }

    func testGarbageAndBlankLinesAreIgnored() throws {
        let s = try run([
            "", "not json at all", "{broken", "[1,2,3]",
            #"{"type":"assistant","timestamp_ms":1,"message":{"content":[{"type":"text","text":"still works"}]}}"#,
            #"{"type":"result","is_error":false,"result":"fine","session_id":"c"}"#,
        ])
        XCTAssertEqual(s.status, .finished)
        XCTAssertEqual(s.messages.filter { $0.kind == .assistant }.map(\.text), ["still works"])
    }

    func testCleanExitWithoutResultStillEnds() throws {
        let s = try run([#"{"type":"system","session_id":"c9"}"#])
        XCTAssertNotEqual(s.status, .working, "a clean exit must never leave the session spinning")
        XCTAssertEqual(s.chatId, "c9")
    }

    func testStderrNoiseDoesNotFailASuccessfulRun() throws {
        let s = try run([#"{"type":"result","is_error":false,"result":"yay","session_id":"c"}"#],
                        stderr: "warning: something harmless")
        XCTAssertEqual(s.status, .finished)
        XCTAssertNil(s.errorMessage)
    }

    func testNonZeroExitWithoutStderrStillExplains() throws {
        let s = try run([], exit: 3)
        XCTAssertEqual(s.status, .waiting)
        XCTAssertTrue(s.errorMessage?.contains("exited (3)") == true, s.errorMessage ?? "")
    }

    // MARK: Claude / Codex streams

    func testClaudeToolLabels() throws {
        use(.claude)
        func tool(_ name: String, _ input: String) -> String {
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"\#(name)","name":"\#(name)","input":\#(input)}]}}"#
        }
        let s = try run([
            #"{"type":"system","subtype":"init","session_id":"cl1"}"#,
            tool("Read", #"{"file_path":"/w/x.swift"}"#),
            tool("Bash", #"{"command":"ls -la"}"#),
            tool("Grep", #"{"pattern":"needle"}"#),
            tool("Glob", #"{"pattern":"*.md"}"#),
            tool("WebSearch", #"{"query":"swift concurrency"}"#),
            #"{"type":"result","is_error":false,"result":"done","session_id":"cl1"}"#,
        ])
        let t = tools(s)
        XCTAssertEqual(t.count, 5, "\(t)")
        guard t.count == 5 else { return }
        XCTAssertTrue(t[0].contains("x.swift"))
        XCTAssertTrue(t[1].contains("ls -la"))
        XCTAssertTrue(t[2].contains("needle"))
        XCTAssertTrue(t[3].contains("*.md"))
        XCTAssertTrue(t[4].contains("swift concurrency"))
        XCTAssertEqual(s.chatId, "cl1")
    }

    func testClaudeErrorResultFails() throws {
        use(.claude)
        let s = try run([#"{"type":"result","is_error":true,"result":"rate limited","session_id":"c"}"#])
        XCTAssertEqual(s.status, .failed)
        XCTAssertEqual(s.errorMessage, "rate limited")
    }

    func testCodexItemTypes() throws {
        use(.codex)
        let s = try run([
            #"{"type":"thread.started","thread_id":"th1"}"#,
            #"{"type":"item.started","item":{"type":"command_execution","command":"npm test"}}"#,
            #"{"type":"item.started","item":{"type":"file_change","path":"/w/Sources/c.swift"}}"#,
            #"{"type":"item.started","item":{"type":"mcp_tool_call","tool":"lookup"}}"#,
            #"{"type":"item.started","item":{"type":"web_search","query":"swiftpm plugins"}}"#,
            #"{"type":"item.completed","item":{"type":"agent_message","text":"Finished."}}"#,
            #"{"type":"turn.completed"}"#,
        ])
        let t = tools(s)
        XCTAssertEqual(t.count, 4, "\(t)")
        guard t.count == 4 else { return }
        XCTAssertTrue(t[0].hasPrefix("Running") && t[0].contains("npm test"))
        XCTAssertTrue(t[1].hasPrefix("Editing") && t[1].contains("c.swift"))
        XCTAssertEqual(t[2], "MCP lookup")
        XCTAssertEqual(t[3], "Search swiftpm plugins")
        XCTAssertEqual(s.messages.last { $0.kind == .assistant }?.text, "Finished.")
        XCTAssertEqual(s.chatId, "th1")
        XCTAssertEqual(s.status, .finished)
    }

    func testCodexTurnFailedMarksFailed() throws {
        use(.codex)
        let s = try run([
            #"{"type":"thread.started","thread_id":"th"}"#,
            #"{"type":"turn.failed","error":{"message":"context too long"}}"#,
        ])
        XCTAssertEqual(s.status, .failed)
        XCTAssertTrue(s.errorMessage?.contains("context too long") == true, s.errorMessage ?? "")
    }

    // MARK: Model / effort

    func testModelAndEffortReachFollowUpArgs() throws {
        let cases: [(AgentCLIKind, [String])] = [
            (.cursor, ["--model", "gpt-5[effort=high]"]),
            (.claude, ["--model", "gpt-5", "--effort", "high"]),
            (.codex, ["-c", "model_reasoning_effort=high"]),
        ]
        for (kind, expected) in cases {
            use(kind)
            resetCalls()
            let fav = AgentFavorite(
                title: "High",
                cliKind: kind,
                modelId: "gpt-5",
                modelTitle: "GPT-5",
                effort: "high",
                isBuiltIn: false
            )
            Preferences.addAgentFavorite(fav)
            let s = try send("first")
            waitUntil("\(kind) first") { s.status == .finished }
            waitIdle(s)
            // Follow-ups take model/effort from Settings Current, not a frozen session field.
            s.applyFavorite(fav)
            manager.followUp(sessionID: s.id, text: "again")
            waitUntil("\(kind) second") { self.calls == 2 && s.status == .finished }
            let a = args(2)
            for pair in expected {
                XCTAssertTrue(a.contains(pair), "\(kind): missing \(pair) in \(a)")
            }
        }
    }

    func testNoModelFlagsWhenUnset() throws {
        let s = try send("hi")
        waitUntil("done") { s.status == .finished }
        XCTAssertFalse(args(1).contains("--model"))
    }

    // MARK: Concurrency, persistence

    func testTwoSessionsRunIndependently() throws {
        use(.cursor, mode: "slow")
        let a = try send("one")
        let b = try send("two")
        XCTAssertNotEqual(a.id, b.id)
        waitUntil("both finished") { a.status == .finished && b.status == .finished }
        XCTAssertEqual(calls, 2)
        XCTAssertNotEqual(a.chatId, b.chatId, "each run gets its own chat id")
        XCTAssertEqual(Set([args(1).last, args(2).last]), ["one", "two"])
        XCTAssertEqual(store.allSessions.count, 2)
    }

    func testStopOneSessionLeavesTheOtherRunning() throws {
        use(.cursor, mode: "slow")
        let a = try send("one")
        let b = try send("two")
        waitUntil("both live") { self.calls == 2 }
        manager.stop(sessionID: a.id)
        waitUntil("a stopped") { a.status == .stopped }
        waitUntil("b finished") { b.status == .finished }
    }

    func testFollowUpAfterStopResumesTheSameChat() throws {
        use(.cursor, mode: "slow")
        let s = try send("first")
        waitUntil("chat id") { s.chatId != nil && s.status == .working }
        let id = try XCTUnwrap(s.chatId)
        manager.stop(sessionID: s.id)
        waitUntil("stopped") { s.status == .stopped }
        setMode("ok")
        manager.followUp(sessionID: s.id, text: "continue")
        waitUntil("resumed") { self.calls == 2 && s.status == .finished }
        let a = args(2)
        XCTAssertEqual(a[a.firstIndex(of: "--resume")! + 1], id)
    }

    func testFinishedSessionSurvivesRestartAndCanBeResumed() throws {
        let s = try send("remember me")
        waitUntil("finished") { s.status == .finished }
        store.saveNow()

        let reloadedStore = SessionStore()
        let back = try XCTUnwrap(reloadedStore.session(id: s.id))
        XCTAssertEqual(back.chatId, "chat-1")
        XCTAssertEqual(back.status, .finished)
        XCTAssertTrue(back.messages.contains { $0.text == "Hello from fake" })

        let m2 = AgentSessionManager(store: reloadedStore)
        m2.followUp(sessionID: back.id, text: "and again")
        waitUntil("resumed") { self.calls == 2 && back.status == .finished }
        let a = args(2)
        XCTAssertEqual(a[a.firstIndex(of: "--resume")! + 1], "chat-1")
        XCTAssertEqual(a.last, "and again")
    }

    func testSessionRunningAtQuitIsNotLeftWorkingAfterReload() throws {
        use(.cursor, mode: "slow")
        let s = try send("long")
        waitUntil("working") { s.status == .working }
        store.saveNow()
        let back = try XCTUnwrap(SessionStore().session(id: s.id))
        XCTAssertNotEqual(back.status, .working, "no process survives a restart")
    }

    func testMultiImageFollowUpListsEveryAttachment() throws {
        let s = try send("first")
        waitUntil("first") { s.status == .finished }
        let a = try write("one.png"), b = try write("two.png")
        manager.followUp(sessionID: s.id, text: "compare", imagePaths: [a.path, b.path])
        waitUntil("second") { self.calls == 2 && s.status == .finished }
        let prompt = try XCTUnwrap(args(2).last)
        XCTAssertTrue(prompt.contains("Attached image"), prompt)
        XCTAssertTrue(prompt.contains(a.path) && prompt.contains(b.path))
        XCTAssertEqual(s.messages.last { $0.kind == .user }?.imagePaths, [a.path, b.path])
    }

    func testMissingImageFilesAreDropped() throws {
        let s = try send("first")
        waitUntil("first") { s.status == .finished }
        manager.followUp(sessionID: s.id, text: "look", imagePaths: ["/nonexistent/x.png"])
        waitUntil("second") { self.calls == 2 && s.status == .finished }
        XCTAssertFalse(args(2).contains("--image"))
    }
}
