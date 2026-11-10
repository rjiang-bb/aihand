import XCTest
@testable import AiHand

/// Argument construction for every CLI. Permission flags come from user prefs, so these
/// assert on the stable structure (prompt placement, `--`, images, resume, model).
final class AgentCLITests: XCTestCase {
    private let clis: [AgentCLI] = [CursorAgentCLI(), ClaudeAgentCLI(), CodexAgentCLI()]

    private func dashDashIndex(_ args: [String]) -> Int? { args.firstIndex(of: "--") }

    func testPromptIsAlwaysLastAfterDoubleDash() {
        for cli in clis {
            for prompt in ["hello", "- a\n  - nested", "--help", "-x"] {
                let start = cli.startArguments(workspace: "/w", prompt: prompt, imagePath: nil, model: nil, effort: nil)
                let follow = cli.followUpArguments(workspace: "/w", chatId: "c1", prompt: prompt, imagePath: nil, model: nil, effort: nil)
                for args in [start, follow] {
                    XCTAssertEqual(args.last, prompt, "\(cli.displayName) prompt must be last")
                    XCTAssertEqual(dashDashIndex(args), args.count - 2, "\(cli.displayName) needs `--` right before the prompt")
                }
            }
        }
    }

    func testImageFlagComesBeforeDoubleDashAndVideoIsNeverPassedAsImage() {
        for cli in clis {
            let png = cli.startArguments(workspace: "/w", prompt: "p", imagePath: "/tmp/a.png", model: nil, effort: nil)
            if cli.kind != .claude {
                let i = png.firstIndex(of: "--image")
                XCTAssertNotNil(i, "\(cli.displayName) should pass --image for stills")
                if let i, let d = dashDashIndex(png) { XCTAssertLessThan(i, d) }
            }
            XCTAssertTrue(png.last!.contains("/tmp/a.png") || cli.kind == .codex,
                          "\(cli.displayName) mentions the path in the prompt (Codex gets --image instead)")

            let mov = cli.startArguments(workspace: "/w", prompt: "p", imagePath: "/tmp/a.mov", model: nil, effort: nil)
            XCTAssertFalse(mov.contains("--image"), "\(cli.displayName) must not pass video via --image")
            XCTAssertTrue(mov.last!.contains("/tmp/a.mov"))
        }
    }

    func testVideoDetection() {
        for ext in ["mov", "MP4", "m4v", "webm"] { XCTAssertTrue(CursorAgentCLI.isVideoMedia("/x/y.\(ext)")) }
        for ext in ["png", "jpg", "heic", ""] { XCTAssertFalse(CursorAgentCLI.isVideoMedia("/x/y.\(ext)")) }
    }

    func testEmptyPromptWithMediaGetsAnInstruction() {
        let cli = CursorAgentCLI()
        XCTAssertTrue(cli.composePrompt("  ", imagePath: "/a.png", includeImagePathInText: true).contains("annotated screenshot"))
        XCTAssertTrue(cli.composePrompt("", imagePath: "/a.mov", includeImagePathInText: true).contains("screen recording"))
        XCTAssertEqual(cli.composePrompt("do it", imagePath: nil, includeImagePathInText: true), "do it")
    }

    func testResumeUsesChatId() {
        let cursor = CursorAgentCLI().followUpArguments(workspace: "/w", chatId: "abc", prompt: "p", imagePath: nil, model: nil, effort: nil)
        XCTAssertEqual(cursor[cursor.firstIndex(of: "--resume")! + 1], "abc")
        let claude = ClaudeAgentCLI().followUpArguments(workspace: "/w", chatId: "abc", prompt: "p", imagePath: nil, model: nil, effort: nil)
        XCTAssertEqual(claude[claude.firstIndex(of: "--resume")! + 1], "abc")
        let codex = CodexAgentCLI().followUpArguments(workspace: "/w", chatId: "abc", prompt: "p", imagePath: nil, model: nil, effort: nil)
        XCTAssertEqual(codex[codex.firstIndex(of: "resume")! + 1], "abc")
    }

    func testModelAndEffortFlags() {
        let cursor = CursorAgentCLI().startArguments(workspace: "/w", prompt: "p", imagePath: nil, model: "gpt-5", effort: "high")
        XCTAssertEqual(cursor[cursor.firstIndex(of: "--model")! + 1], "gpt-5[effort=high]")
        let cursorAuto = CursorAgentCLI().startArguments(workspace: "/w", prompt: "p", imagePath: nil, model: "auto", effort: nil)
        XCTAssertFalse(cursorAuto.contains("--model"))

        let claude = ClaudeAgentCLI().startArguments(workspace: "/w", prompt: "p", imagePath: nil, model: "opus", effort: "max")
        XCTAssertEqual(claude[claude.firstIndex(of: "--model")! + 1], "opus")
        XCTAssertEqual(claude[claude.firstIndex(of: "--effort")! + 1], "max")

        let codex = CodexAgentCLI().startArguments(workspace: "/w", prompt: "p", imagePath: nil, model: "o3", effort: "low")
        XCTAssertEqual(codex[codex.firstIndex(of: "-m")! + 1], "o3")
        XCTAssertTrue(codex.contains("model_reasoning_effort=low"))
        XCTAssertEqual(codex[codex.firstIndex(of: "-C")! + 1], "/w")
        XCTAssertEqual(codex.first, "exec")
    }

    func testCursorAlwaysTrustsWorkspace() {
        let args = CursorAgentCLI().startArguments(workspace: "/w", prompt: "p", imagePath: nil, model: nil, effort: nil)
        XCTAssertTrue(args.contains("--trust"))
        XCTAssertEqual(args[args.firstIndex(of: "--workspace")! + 1], "/w")
    }
}
