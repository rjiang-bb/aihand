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
            "--force",
            "--trust",
            "--workspace", workspace,
            "--output-format", "stream-json",
            "--stream-partial-output"
        ]
        appendCursorModel(&args, model: model, effort: effort)
        if let imagePath, Self.shouldPassImageFlag(imagePath) {
            args += ["--image", imagePath]
        }
        // Screenshots also get the path in text; videos rely on the path (no --image).
        args.append(composePrompt(prompt, imagePath: imagePath, includeImagePathInText: true))
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
            "--force",
            "--trust",
            "--workspace", workspace,
            "--resume", chatId,
            "--output-format", "stream-json",
            "--stream-partial-output"
        ]
        appendCursorModel(&args, model: model, effort: effort)
        if let imagePath, Self.shouldPassImageFlag(imagePath) {
            args += ["--image", imagePath]
        }
        if let imagePath, Self.isVideoMedia(imagePath) {
            args.append(composePrompt(prompt, imagePath: imagePath, includeImagePathInText: true))
        } else {
            args.append(prompt)
        }
        return args
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
        // flag; --dangerously-skip-permissions matches Cursor `--force` for unattended runs.
        // --verbose is required for useful stream-json assistant/tool events.
        var args = [
            "-p",
            "--verbose",
            "--output-format", "stream-json",
            "--dangerously-skip-permissions"
        ]
        if let model, !model.isEmpty {
            args += ["--model", model]
        }
        if let effort, !effort.isEmpty {
            args += ["--effort", effort]
        }
        // No native --image; include the path in the prompt text.
        args.append(composePrompt(prompt, imagePath: imagePath, includeImagePathInText: true))
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
            "--dangerously-skip-permissions",
            "--resume", chatId
        ]
        if let model, !model.isEmpty {
            args += ["--model", model]
        }
        if let effort, !effort.isEmpty {
            args += ["--effort", effort]
        }
        if let imagePath {
            args.append(composePrompt(prompt, imagePath: imagePath, includeImagePathInText: true))
        } else {
            args.append(prompt)
        }
        return args
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
        // `codex exec` is the non-interactive entry point. workspace-write matches Cursor's
        // auto-approve editing intent without full --yolo. --skip-git-repo-check allows
        // arbitrary folders chosen in Settings.
        var args = [
            "exec",
            "--json",
            "--sandbox", "workspace-write",
            "--skip-git-repo-check",
            "-C", workspace
        ]
        if let model, !model.isEmpty {
            args += ["-m", model]
        }
        if let effort, !effort.isEmpty {
            args += ["-c", "model_reasoning_effort=\(effort)"]
        }
        if let imagePath, Self.shouldPassImageFlag(imagePath) {
            args += ["--image", imagePath]
            args.append(composePrompt(prompt, imagePath: imagePath, includeImagePathInText: false))
        } else {
            // Video (or unknown): path in prompt so Codex can open the file.
            args.append(composePrompt(prompt, imagePath: imagePath, includeImagePathInText: true))
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
        var args = [
            "exec",
            "--json",
            "--sandbox", "workspace-write",
            "--skip-git-repo-check",
            "-C", workspace
        ]
        if let model, !model.isEmpty {
            args += ["-m", model]
        }
        if let effort, !effort.isEmpty {
            args += ["-c", "model_reasoning_effort=\(effort)"]
        }
        args += ["resume", chatId]
        if let imagePath, Self.shouldPassImageFlag(imagePath) {
            args += ["--image", imagePath]
            args.append(prompt)
        } else if let imagePath {
            args.append(composePrompt(prompt, imagePath: imagePath, includeImagePathInText: true))
        } else {
            args.append(prompt)
        }
        return args
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
