import Foundation

protocol AgentCLI {
    var kind: AgentCLIKind { get }
    var displayName: String { get }
    func resolveExecutable() -> String?
    func startArguments(
        workspace: String,
        prompt: String,
        imagePath: String?,
        model: String?,
        effort: String?
    ) -> [String]
    func followUpArguments(
        workspace: String,
        chatId: String,
        prompt: String,
        imagePath: String?,
        model: String?,
        effort: String?
    ) -> [String]
}

extension AgentCLI {
    static func isVideoMedia(_ path: String) -> Bool {
        switch (path as NSString).pathExtension.lowercased() {
        case "mov", "mp4", "m4v", "webm": return true
        default: return false
        }
    }

    /// `--image` is for raster stills; video paths go in the prompt so the agent can open the file.
    static func shouldPassImageFlag(_ path: String) -> Bool {
        !isVideoMedia(path)
    }

    /// Append a positional prompt after `--` so clap never treats a leading `-`
    /// (lists, flags, `--help` jokes) as an option, and so a greedy flag like
    /// Codex `--image` (num_args=1..) can't swallow the prompt as another path.
    func appendPromptArg(_ args: inout [String], _ prompt: String) {
        args.append("--")
        args.append(prompt)
    }

    func composePrompt(_ prompt: String, imagePath: String?, includeImagePathInText: Bool) -> String {
        var parts: [String] = []
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let video = imagePath.map(Self.isVideoMedia) ?? false
        if !trimmed.isEmpty {
            parts.append(trimmed)
        } else if imagePath != nil {
            parts.append(
                video
                    ? "Watch this screen recording and figure out what needs to change."
                    : "Look at the annotated screenshot and figure out what needs to change."
            )
        }
        if includeImagePathInText, let imagePath {
            parts.append(video ? "Screen recording: \(imagePath)" : "Annotated screenshot: \(imagePath)")
        }
        return parts.joined(separator: "\n\n")
    }
}

enum AgentPathLookup {
    static func resolve(_ name: String, extraCandidates: [String] = []) -> String? {
        let home = NSHomeDirectory()
        let candidates = extraCandidates + [
            "\(home)/.local/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "\(home)/.npm-global/bin/\(name)",
            "\(home)/.nvm/current/bin/\(name)"
        ]
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return which(name)
    }

    static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extras = ["\(home)/.local/bin", "/usr/local/bin", "/opt/homebrew/bin", "\(home)/.npm-global/bin"]
        let path = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extras + [path]).joined(separator: ":")
        process.environment = env
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let line = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty else {
            return nil
        }
        return line
    }
}

struct CursorAgentCLI: AgentCLI {
    var kind: AgentCLIKind { .cursor }
    var displayName: String { AgentCLIKind.cursor.title }

    func resolveExecutable() -> String? {
        AgentPathLookup.resolve("agent")
    }

    func startArguments(
        workspace: String,
        prompt: String,
        imagePath: String?,
        model: String?,
        effort: String?
    ) -> [String] {
        var args = [
            "-p",
            "--workspace", workspace,
            "--output-format", "stream-json",
            "--stream-partial-output"
        ]
        appendPermissionFlags(&args)
        appendCursorModel(&args, model: model, effort: effort)
        if let imagePath, Self.shouldPassImageFlag(imagePath) {
            args += ["--image", imagePath]
        }
        // Screenshots also get the path in text; videos rely on the path (no --image).
        appendPromptArg(&args, composePrompt(prompt, imagePath: imagePath, includeImagePathInText: true))
        return args
    }

    func followUpArguments(
        workspace: String,
        chatId: String,
        prompt: String,
        imagePath: String?,
        model: String?,
        effort: String?
    ) -> [String] {
        var args = [
            "-p",
            "--workspace", workspace,
            "--resume", chatId,
            "--output-format", "stream-json",
            "--stream-partial-output"
        ]
        appendPermissionFlags(&args)
        appendCursorModel(&args, model: model, effort: effort)
        if let imagePath, Self.shouldPassImageFlag(imagePath) {
            args += ["--image", imagePath]
        }
        // Match start: empty prompt + screenshot still needs a usable instruction + path.
        appendPromptArg(
            &args,
            composePrompt(prompt, imagePath: imagePath, includeImagePathInText: imagePath != nil)
        )
        return args
    }

    private func appendPermissionFlags(_ args: inout [String]) {
        // Workspace is chosen in Settings; always trust it for unattended annotate runs.
        args.append("--trust")
        switch Preferences.cursorPermissionMode(for: AgentCLIRuntime.permissionTarget) {
        case .force:
            args.append("--force")
        case .sandboxed:
            args += ["--force", "--sandbox", "enabled"]
        case .autoReview:
            args.append("--auto-review")
        }
    }

    private func appendCursorModel(_ args: inout [String], model: String?, effort: String?) {
        guard let model, !model.isEmpty, model != "auto" else { return }
        // Prefer a bare discovered id; if a separate effort was saved, use bracket override.
        if let effort, !effort.isEmpty, !model.contains("[") {
            args += ["--model", "\(model)[effort=\(effort)]"]
        } else {
            args += ["--model", model]
        }
    }
}

/// Claude Code CLI via `claude -p` (print / Agent SDK mode).
/// Docs: https://code.claude.com/docs/en/cli-reference
struct ClaudeAgentCLI: AgentCLI {
    var kind: AgentCLIKind { .claude }
    var displayName: String { AgentCLIKind.claude.title }

    func resolveExecutable() -> String? {
        AgentPathLookup.resolve("claude")
    }

    func startArguments(
        workspace: String,
        prompt: String,
        imagePath: String?,
        model: String?,
        effort: String?
    ) -> [String] {
        // Workspace is the process cwd (set by AgentSessionRunner). Claude has no --workspace
        // flag. --verbose is required for useful stream-json assistant/tool events.
        var args = [
            "-p",
            "--verbose",
            "--output-format", "stream-json"
        ]
        appendPermissionFlags(&args)
        if let model, !model.isEmpty {
            args += ["--model", model]
        }
        if let effort, !effort.isEmpty {
            args += ["--effort", effort]
        }
        // No native --image; include the path in the prompt text.
        appendPromptArg(&args, composePrompt(prompt, imagePath: imagePath, includeImagePathInText: true))
        return args
    }

    func followUpArguments(
        workspace: String,
        chatId: String,
        prompt: String,
        imagePath: String?,
        model: String?,
        effort: String?
    ) -> [String] {
        var args = [
            "-p",
            "--verbose",
            "--output-format", "stream-json",
            "--resume", chatId
        ]
        appendPermissionFlags(&args)
        if let model, !model.isEmpty {
            args += ["--model", model]
        }
        if let effort, !effort.isEmpty {
            args += ["--effort", effort]
        }
        if let imagePath {
            appendPromptArg(&args, composePrompt(prompt, imagePath: imagePath, includeImagePathInText: true))
        } else {
            appendPromptArg(&args, prompt)
        }
        return args
    }

    private func appendPermissionFlags(_ args: inout [String]) {
        switch Preferences.claudePermissionMode(for: AgentCLIRuntime.permissionTarget) {
        case .bypass:
            args.append("--dangerously-skip-permissions")
        case .acceptEdits:
            args += ["--permission-mode", "acceptEdits"]
        case .auto:
            args += ["--permission-mode", "auto"]
        case .dontAsk:
            args += ["--permission-mode", "dontAsk"]
        case .plan:
            args += ["--permission-mode", "plan"]
        }
    }
}

/// OpenAI Codex CLI via `codex exec` (non-interactive JSONL).
/// Docs: https://learn.chatgpt.com/docs/codex/cli · https://learn.chatgpt.com/docs/non-interactive-mode
struct CodexAgentCLI: AgentCLI {
    var kind: AgentCLIKind { .codex }
    var displayName: String { AgentCLIKind.codex.title }

    func resolveExecutable() -> String? {
        AgentPathLookup.resolve("codex")
    }

    func startArguments(
        workspace: String,
        prompt: String,
        imagePath: String?,
        model: String?,
        effort: String?
    ) -> [String] {
        // `codex exec` is the non-interactive entry point. --skip-git-repo-check allows
        // arbitrary folders chosen in Settings.
        var args = baseExecArguments(workspace: workspace, model: model, effort: effort)
        if let imagePath, Self.shouldPassImageFlag(imagePath) {
            // `--image` is greedy (num_args=1..). Put it before `--` so clap can't
            // eat the prompt as another image path (openai/codex#30106 / #40545),
            // and `--` so a list prompt starting with `-` isn't a flag.
            args += ["--image", imagePath]
            appendPromptArg(
                &args,
                composePrompt(prompt, imagePath: imagePath, includeImagePathInText: false)
            )
        } else {
            // Video (or unknown): path in prompt so Codex can open the file.
            appendPromptArg(
                &args,
                composePrompt(prompt, imagePath: imagePath, includeImagePathInText: true)
            )
        }
        return args
    }

    func followUpArguments(
        workspace: String,
        chatId: String,
        prompt: String,
        imagePath: String?,
        model: String?,
        effort: String?
    ) -> [String] {
        var args = baseExecArguments(workspace: workspace, model: model, effort: effort)
        args += ["resume", chatId]
        if let imagePath, Self.shouldPassImageFlag(imagePath) {
            args += ["--image", imagePath]
            appendPromptArg(
                &args,
                composePrompt(prompt, imagePath: imagePath, includeImagePathInText: false)
            )
        } else if let imagePath {
            appendPromptArg(
                &args,
                composePrompt(prompt, imagePath: imagePath, includeImagePathInText: true)
            )
        } else {
            appendPromptArg(&args, prompt)
        }
        return args
    }

    private func baseExecArguments(workspace: String, model: String?, effort: String?) -> [String] {
        var args = [
            "exec",
            "--json",
            "--skip-git-repo-check",
            "-C", workspace
        ]
        appendPermissionFlags(&args)
        if let model, !model.isEmpty {
            args += ["-m", model]
        }
        if let effort, !effort.isEmpty {
            args += ["-c", "model_reasoning_effort=\(effort)"]
        }
        return args
    }

    private func appendPermissionFlags(_ args: inout [String]) {
        // `codex exec` no longer takes `-a` / `--ask-for-approval` (clap rejects it → exit 2).
        switch Preferences.codexPermissionMode(for: AgentCLIRuntime.permissionTarget) {
        case .workspaceWrite:
            // Matches Cursor's auto-approve editing intent without full --yolo.
            args += ["--sandbox", "workspace-write"]
        case .readOnly:
            args += ["--sandbox", "read-only"]
        case .fullAccess:
            // Unattended: skip approvals + sandbox (AiHand has no TTY for prompts).
            args.append("--dangerously-bypass-approvals-and-sandbox")
        }
    }
}

/// Target whose permission prefs apply while building CLI argv (set per launch).
enum AgentCLIRuntime {
    // Recursive: `withPermissionTarget` holds the lock while `body` reads `permissionTarget`.
    private static let lock = NSRecursiveLock()
    private static var _permissionTarget: AgentExecutionTarget = .local

    static var permissionTarget: AgentExecutionTarget {
        lock.lock()
        defer { lock.unlock() }
        return _permissionTarget
    }

    /// Hold the lock while `body` reads permission prefs so concurrent launches don't cross wires.
    static func withPermissionTarget<T>(_ target: AgentExecutionTarget, _ body: () -> T) -> T {
        lock.lock()
        let previous = _permissionTarget
        _permissionTarget = target
        defer {
            _permissionTarget = previous
            lock.unlock()
        }
        return body()
    }
}

enum AgentCLIFactory {
    static func make(_ kind: AgentCLIKind = Preferences.agentCLI) -> AgentCLI {
        switch kind {
        case .cursor: return CursorAgentCLI()
        case .claude: return ClaudeAgentCLI()
        case .codex: return CodexAgentCLI()
        }
    }
}
