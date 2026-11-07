import Foundation

protocol AgentCLI {
    var displayName: String { get }
    func resolveExecutable() -> String?
    func startArguments(workspace: String, prompt: String, imagePath: String?) -> [String]
    func followUpArguments(workspace: String, chatId: String, prompt: String, imagePath: String?) -> [String]
}

struct CursorAgentCLI: AgentCLI {
    var displayName: String { "Cursor Agent" }

    func resolveExecutable() -> String? {
        let candidates = [
            NSString(string: "~/.local/bin/agent").expandingTildeInPath,
            "/usr/local/bin/agent",
            "/opt/homebrew/bin/agent"
        ]
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        if let fromPath = which("agent") {
            return fromPath
        }
        return nil
    }

    func startArguments(workspace: String, prompt: String, imagePath: String?) -> [String] {
        var args = [
            "-p",
            "--force",
            "--trust",
            "--workspace", workspace,
            "--output-format", "stream-json",
            "--stream-partial-output"
        ]
        if let imagePath {
            args += ["--image", imagePath]
        }
        args.append(composePrompt(prompt, imagePath: imagePath))
        return args
    }

    func followUpArguments(workspace: String, chatId: String, prompt: String, imagePath: String?) -> [String] {
        var args = [
            "-p",
            "--force",
            "--trust",
            "--workspace", workspace,
            "--resume", chatId,
            "--output-format", "stream-json",
            "--stream-partial-output"
        ]
        if let imagePath {
            args += ["--image", imagePath]
        }
        args.append(prompt)
        return args
    }

    private func composePrompt(_ prompt: String, imagePath: String?) -> String {
        var parts: [String] = []
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append(trimmed)
        } else {
            parts.append("Look at the annotated screenshot and figure out what needs to change.")
        }
        if let imagePath {
            parts.append("Annotated screenshot: \(imagePath)")
        }
        return parts.joined(separator: "\n\n")
    }

    private func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extras = ["\(home)/.local/bin", "/usr/local/bin", "/opt/homebrew/bin"]
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

enum AgentCLIFactory {
    static func make(_ kind: AgentCLIKind = Preferences.agentCLI) -> AgentCLI {
        switch kind {
        case .cursor: return CursorAgentCLI()
        }
    }
}
