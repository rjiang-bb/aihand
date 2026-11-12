import Foundation

final class AgentSessionRunner {
    private let cli: AgentCLI
    private var process: Process?
    private var stdout: Pipe?
    private var stderr: Pipe?
    private var stdoutBuffer = Data()
    private var stderrText = ""
    private let bufferLock = NSLock()
    private var currentAssistantID: UUID?
    /// Claude stream-json re-emits full assistant snapshots that include prior `tool_use` blocks.
    private var seenToolUseIDs: Set<String> = []
    /// Wall-clock start of the current agent turn (for "Worked for Xs").
    private var turnStartedAt: Date?
    /// When the current thinking/reasoning phase began (for "Thought Xs").
    private var thinkingStartedAt: Date?
    private weak var session: AgentSession?
    /// Fired on the main queue after a natural process exit (not interrupt/stop).
    var onFinished: (() -> Void)?

    init(cli: AgentCLI = AgentCLIFactory.make()) {
        self.cli = cli
    }

    var isRunning: Bool { process?.isRunning == true }

    func start(session: AgentSession, workspace: String, prompt: String, imagePath: String?) {
        start(session: session, workspace: workspace, prompt: prompt, imagePaths: imagePath.map { [$0] } ?? [])
    }

    func start(session: AgentSession, workspace: String, prompt: String, imagePaths: [String]) {
        self.session = session
        let paths = imagePaths.filter { FileManager.default.fileExists(atPath: $0) }
        prepareAndLaunch(session: session, workspace: workspace, imagePaths: paths) { remapped in
            let primary = Self.primaryMediaPath(remapped)
            let enriched = Self.enrichPrompt(prompt, paths: remapped, primary: primary)
            return self.cli.startArguments(
                workspace: workspace,
                prompt: enriched,
                imagePath: primary,
                model: session.modelId,
                effort: session.effort
            )
        }
    }

    func followUp(session: AgentSession, workspace: String, prompt: String, imagePath: String? = nil) {
        followUp(session: session, workspace: workspace, prompt: prompt, imagePaths: imagePath.map { [$0] } ?? [])
    }

    func followUp(
        session: AgentSession,
        workspace: String,
        prompt: String,
        imagePaths: [String],
        steered: Bool = false
    ) {
        self.session = session
        guard let chatId = session.chatId, !chatId.isEmpty else {
            DispatchQueue.main.async {
                session.status = .waiting
                session.errorMessage = "No chat id yet — wait for the first turn to finish, then try again."
                session.messages.append(AgentMessage(kind: .system, text: session.errorMessage ?? ""))
            }
            return
        }
        let paths = imagePaths.filter { FileManager.default.fileExists(atPath: $0) }
        let appendUser = {
            session.messages.append(
                AgentMessage(kind: .user, text: prompt, imagePaths: paths, steered: steered)
            )
            session.status = .working
            self.beginTurnTracking(on: session)
            let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            session.preview = trimmedPrompt.isEmpty && !paths.isEmpty ? "Annotation" : prompt
            session.errorMessage = nil
        }
        if Thread.isMainThread {
            appendUser()
        } else {
            DispatchQueue.main.sync(execute: appendUser)
        }
        prepareAndLaunch(session: session, workspace: workspace, imagePaths: paths) { remapped in
            let primary = Self.primaryMediaPath(remapped)
            let enriched = Self.enrichPrompt(prompt, paths: remapped, primary: primary)
            return self.cli.followUpArguments(
                workspace: workspace,
                chatId: chatId,
                prompt: enriched,
                imagePath: primary,
                model: session.modelId,
                effort: session.effort
            )
        }
    }

    /// Prefer a still for `--image`; otherwise the first path (video → prompt only).
    private static func primaryMediaPath(_ paths: [String]) -> String? {
        paths.first { !Self.isVideoMedia($0) } ?? paths.first
    }

    private static func isVideoMedia(_ path: String) -> Bool {
        switch (path as NSString).pathExtension.lowercased() {
        case "mov", "mp4", "m4v", "webm": return true
        default: return false
        }
    }

    /// Extra attachments beyond the primary are listed in the prompt (CLI takes one `--image`).
    private static func enrichPrompt(_ prompt: String, paths: [String], primary: String?) -> String {
        guard paths.count > 1 else { return prompt }
        var parts: [String] = []
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        for path in paths where path != primary {
            parts.append(
                Self.isVideoMedia(path)
                    ? "Screen recording: \(path)"
                    : "Attached image: \(path)"
            )
        }
        return parts.joined(separator: "\n\n")
    }

    /// Resolve local/remote executable, optionally upload media, then launch.
    private func prepareAndLaunch(
        session: AgentSession,
        workspace: String,
        imagePaths: [String],
        makeArgs: @escaping ([String]) -> [String]
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if let connectionID = session.connectionID {
                guard let connection = Preferences.sshConnection(id: connectionID) else {
                    self.failMissingConnection(session: session)
                    return
                }
                guard let exe = SSHClient.which(connection, session.cliKind.commandName) else {
                    self.failMissingCLI(session: session)
                    return
                }
                var remapped: [String] = []
                for (index, imagePath) in imagePaths.enumerated() {
                    guard FileManager.default.fileExists(atPath: imagePath) else { continue }
                    let ext = (imagePath as NSString).pathExtension
                    let remote = "/tmp/aihand-\(session.id.uuidString)-\(index).\(ext.isEmpty ? "png" : ext)"
                    let upload = SSHClient.upload(connection: connection, localPath: imagePath, remotePath: remote)
                    if upload.ok {
                        remapped.append(remote)
                    } else {
                        Log.write("ssh upload failed: \(upload.stderr)")
                        self.failUpload(session: session, host: connection.hostname, detail: upload.stderr)
                        return
                    }
                }
                let args = AgentCLIRuntime.withPermissionTarget(session.executionTarget) {
                    makeArgs(remapped)
                }
                self.launchRemote(
                    connection: connection,
                    exe: exe,
                    args: args,
                    workspace: workspace,
                    session: session
                )
                return
            }

            guard let exe = self.cli.resolveExecutable() else {
                self.failMissingCLI(session: session)
                return
            }
            let args = AgentCLIRuntime.withPermissionTarget(session.executionTarget) {
                makeArgs(imagePaths)
            }
            self.launch(exe: exe, args: args, session: session)
        }
    }

    private func failMissingCLI(session: AgentSession) {
        DispatchQueue.main.async {
            let msg = "Couldn’t find `\(session.cliKind.commandName)`. \(session.cliKind.installHint)"
            session.status = .failed
            session.errorMessage = msg
            session.preview = msg
            session.messages.append(AgentMessage(kind: .system, text: msg))
        }
    }

    private func failMissingConnection(session: AgentSession) {
        DispatchQueue.main.async {
            let msg = "SSH connection for this session is gone. Re-add it under Settings → Connections."
            session.status = .failed
            session.errorMessage = msg
            session.preview = msg
            session.messages.append(AgentMessage(kind: .system, text: msg))
        }
    }

    private func failUpload(session: AgentSession, host: String, detail: String) {
        DispatchQueue.main.async {
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = trimmed.isEmpty
                ? "Couldn’t upload the screenshot to \(host)."
                : "Couldn’t upload the screenshot to \(host): \(trimmed)"
            session.status = .failed
            session.errorMessage = msg
            session.preview = msg
            session.messages.append(AgentMessage(kind: .system, text: msg))
        }
    }

    func stop() {
        guard process != nil else { return }
        stopQuietly()
        DispatchQueue.main.async { [weak self, weak session] in
            guard let self, let session else { return }
            self.endTurnTracking(emitWorked: false)
            if session.status == .working {
                session.status = .stopped
                session.preview = "Stopped"
                session.messages.append(AgentMessage(kind: .system, text: "Stopped"))
            }
        }
    }

    /// Kill any in-flight run without appending a "Stopped" system message (for steer / follow-up).
    func interruptQuietly() {
        stopQuietly()
    }

    private func launch(exe: String, args: [String], session: AgentSession) {
        stopQuietly()
        resetBuffers()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extras = ["\(home)/.local/bin", "/usr/local/bin", "/opt/homebrew/bin"]
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extras + [path]).joined(separator: ":")
        process.environment = env
        let cwd = session.workspace.isEmpty ? NSHomeDirectory() : session.workspace
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        attachPipes(to: process)
        finishLaunch(process: process, session: session, logArgs: args)
    }

    private func launchRemote(
        connection: SSHConnection,
        exe: String,
        args: [String],
        workspace: String,
        session: AgentSession
    ) {
        stopQuietly()
        resetBuffers()

        // Remote argv: executable + CLI args. Working directory is applied via bash -lc cd.
        var remoteArgv = [exe]
        remoteArgv.append(contentsOf: args)
        let built = SSHClient.makeRemoteProcess(
            connection: connection,
            remoteArgv: remoteArgv,
            remoteWorkingDirectory: workspace.isEmpty ? nil : workspace
        )
        let process = built.process
        attachPipes(to: process)
        finishLaunch(process: process, session: session, logArgs: built.sshArgv)
    }

    private func resetBuffers() {
        bufferLock.lock()
        stdoutBuffer = Data()
        stderrText = ""
        bufferLock.unlock()
        currentAssistantID = nil
        seenToolUseIDs.removeAll()
        // Turn timing is owned by begin/endTurnTracking — keep it across buffer resets mid-turn.
    }

    private func attachPipes(to process: Process) {
        let out = Pipe()
        let err = Pipe()
        stdout = out
        stderr = err
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.consume(data)
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.appendStderr(data)
        }

        process.terminationHandler = { [weak self] proc in
            // The process is gone but its pipes may still hold unread output (the final
            // `result` line, stderr). Drain to EOF *before* handling termination, otherwise the
            // exit races the readability handlers and drops trailing events.
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let restOut = out.fileHandleForReading.readDataToEndOfFile()
            let restErr = err.fileHandleForReading.readDataToEndOfFile()
            if !restOut.isEmpty { self?.consume(restOut) }
            if !restErr.isEmpty { self?.appendStderr(restErr) }
            DispatchQueue.main.async {
                self?.clearPipeHandlers()
                self?.handleTermination(status: proc.terminationStatus)
            }
        }
    }

    private func finishLaunch(process: Process, session: AgentSession, logArgs: [String]) {
        self.process = process
        DispatchQueue.main.async {
            session.status = .working
            // First turn may not go through followUp's beginTurnTracking.
            if self.turnStartedAt == nil {
                self.beginTurnTracking(on: session)
            }
        }
        do {
            try process.run()
            Log.write("agent launched pid=\(process.processIdentifier) args=\(logArgs.joined(separator: " "))")
        } catch {
            clearPipeHandlers()
            DispatchQueue.main.async {
                session.status = .failed
                session.errorMessage = error.localizedDescription
                session.messages.append(AgentMessage(kind: .system, text: error.localizedDescription))
            }
            self.process = nil
        }
    }

    private func stopQuietly() {
        if let process {
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
            }
        }
        clearPipeHandlers()
        self.process = nil
    }

    private func clearPipeHandlers() {
        stdout?.fileHandleForReading.readabilityHandler = nil
        stderr?.fileHandleForReading.readabilityHandler = nil
        stdout = nil
        stderr = nil
    }

    private func appendStderr(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        Log.write("agent stderr: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        bufferLock.lock()
        stderrText.append(text)
        if stderrText.count > 8_000 {
            stderrText = String(stderrText.suffix(6_000))
        }
        bufferLock.unlock()
    }

    private func consume(_ data: Data) {
        var lines: [[String: Any]] = []
        bufferLock.lock()
        stdoutBuffer.append(data)
        while let range = stdoutBuffer.range(of: Data([0x0A])) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...range.lowerBound)
            guard !lineData.isEmpty,
                  let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            lines.append(json)
        }
        bufferLock.unlock()
        guard !lines.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            for json in lines {
                self?.handleEvent(json)
            }
        }
    }

    private func handleEvent(_ json: [String: Any]) {
        guard let session else { return }
        let type = json["type"] as? String ?? ""
        switch type {
        // Cursor Agent stream-json
        case "system":
            if let sid = json["session_id"] as? String, !sid.isEmpty {
                session.chatId = sid
            }
        case "assistant":
            // Cursor: stream deltas via timestamp_ms. Claude: full message snapshots in
            // message.content (text + tool_use). Same envelope shape for text extraction.
            let hasTS = json["timestamp_ms"] != nil
            let hasMC = json["model_call_id"] != nil
            ingestEmbeddedThinking(json)
            let text = extractAssistantText(json)
            if hasTS && hasMC {
                return
            }
            if !text.isEmpty {
                finalizeThinkingIfNeeded()
                session.liveActivity = nil
                if hasTS {
                    appendAssistant(text, replace: true)
                } else {
                    upsertAssistantSnapshot(text)
                }
            }
            ingestEmbeddedToolUses(json)
        case "tool_call":
            let subtype = json["subtype"] as? String ?? ""
            if subtype == "started" {
                finalizeThinkingIfNeeded()
                let label = toolLabel(json)
                session.messages.append(AgentMessage(kind: .tool, text: label))
                session.preview = label
                currentAssistantID = nil
                refreshExploringActivity()
            } else if subtype == "completed" {
                // Brief planning gap between tools.
                session.liveActivity = TurnStatusCopy.planning
            }
        case "thinking":
            // Some Cursor builds emit a top-level thinking event.
            beginThinking()
        case "result":
            if let sid = json["session_id"] as? String, !sid.isEmpty {
                session.chatId = sid
            }
            let isError = json["is_error"] as? Bool ?? false
            if isError {
                session.status = .failed
                let msg = (json["result"] as? String) ?? "Agent failed"
                session.errorMessage = msg
                session.preview = msg
                if session.messages.last?.kind != .system || session.messages.last?.text != msg {
                    session.messages.append(AgentMessage(kind: .system, text: msg))
                }
                endTurnTracking(emitWorked: false)
            } else {
                session.status = .finished
                if let result = json["result"] as? String, !result.isEmpty {
                    session.preview = String(result.prefix(120))
                } else {
                    session.preview = "Finished"
                }
                endTurnTracking(emitWorked: true)
            }
            currentAssistantID = nil

        // Codex `codex exec --json` JSONL
        case "thread.started":
            if let tid = json["thread_id"] as? String, !tid.isEmpty {
                session.chatId = tid
            }
        case "turn.started":
            session.status = .working
            beginTurnTracking(on: session)
        case "item.started", "item.updated", "item.completed":
            handleCodexItem(json, completed: type == "item.completed")
        case "turn.completed":
            session.status = .finished
            if session.preview.isEmpty || session.preview == "Working…" {
                session.preview = "Finished"
            }
            endTurnTracking(emitWorked: true)
            currentAssistantID = nil
        case "turn.failed", "error":
            session.status = .failed
            let msg = (json["error"] as? [String: Any]).flatMap { $0["message"] as? String }
                ?? (json["message"] as? String)
                ?? "Codex failed"
            session.errorMessage = msg
            session.preview = msg
            session.messages.append(AgentMessage(kind: .system, text: msg))
            endTurnTracking(emitWorked: false)
            currentAssistantID = nil

        default:
            break
        }
    }

    private func handleCodexItem(_ json: [String: Any], completed: Bool) {
        guard let session, let item = json["item"] as? [String: Any] else { return }
        let itemType = item["type"] as? String ?? ""
        switch itemType {
        case "agent_message":
            let text = item["text"] as? String ?? ""
            guard !text.isEmpty else { return }
            // Codex emits complete messages on item.completed (and sometimes updated).
            if completed {
                appendAssistant(text, replace: false)
                currentAssistantID = nil
            } else if let id = currentAssistantID,
                      let idx = session.messages.firstIndex(where: { $0.id == id }) {
                session.messages[idx].text = text
                session.preview = String(text.prefix(120))
            } else {
                appendAssistant(text, replace: false)
            }
        case "command_execution":
            if !completed {
                finalizeThinkingIfNeeded()
                let cmd = item["command"] as? String ?? "command"
                let label = "Running \(shortCommand(cmd))"
                session.messages.append(AgentMessage(kind: .tool, text: label))
                session.preview = label
                currentAssistantID = nil
                refreshExploringActivity()
            } else {
                session.liveActivity = TurnStatusCopy.planning
            }
        case "file_change", "file_change_proposed":
            if !completed {
                finalizeThinkingIfNeeded()
                let path = (item["path"] as? String)
                    ?? (item["changes"] as? [[String: Any]])?.first.flatMap { $0["path"] as? String }
                    ?? "file"
                let label = "Editing \(shortPath(path))"
                session.messages.append(AgentMessage(kind: .tool, text: label))
                session.preview = label
                currentAssistantID = nil
                refreshExploringActivity()
            } else {
                session.liveActivity = TurnStatusCopy.planning
            }
        case "mcp_tool_call":
            if !completed {
                finalizeThinkingIfNeeded()
                let name = item["tool"] as? String ?? item["name"] as? String ?? "MCP tool"
                let label = "MCP \(name)"
                session.messages.append(AgentMessage(kind: .tool, text: label))
                session.preview = label
                currentAssistantID = nil
                refreshExploringActivity()
            } else {
                session.liveActivity = TurnStatusCopy.planning
            }
        case "web_search":
            if !completed {
                finalizeThinkingIfNeeded()
                let q = item["query"] as? String ?? "web"
                let label = "Search \(q)"
                session.messages.append(AgentMessage(kind: .tool, text: label))
                session.preview = label
                currentAssistantID = nil
                refreshExploringActivity()
            } else {
                session.liveActivity = TurnStatusCopy.planning
            }
        case "reasoning":
            if !completed {
                beginThinking()
            } else {
                finalizeThinkingIfNeeded()
                session.liveActivity = TurnStatusCopy.planning
            }
        case "plan_update":
            if !completed {
                session.liveActivity = TurnStatusCopy.planning
            }
        default:
            if !completed {
                finalizeThinkingIfNeeded()
                let label = itemType.replacingOccurrences(of: "_", with: " ")
                session.messages.append(AgentMessage(kind: .tool, text: label.capitalized))
                session.preview = label
                currentAssistantID = nil
                refreshExploringActivity()
            }
        }
    }

    private func shortCommand(_ command: String) -> String {
        let oneLine = command
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(oneLine.prefix(80))
    }

    private func appendAssistant(_ text: String, replace: Bool) {
        guard let session else { return }
        if replace {
            if let id = currentAssistantID,
               let idx = session.messages.firstIndex(where: { $0.id == id }) {
                session.messages[idx].text += text
                session.preview = String(session.messages[idx].text.prefix(120))
                return
            }
            let msg = AgentMessage(kind: .assistant, text: text)
            currentAssistantID = msg.id
            session.messages.append(msg)
            session.preview = String(text.prefix(120))
            return
        }
        // Complete message or end-of-turn flush (no timestamp).
        if let id = currentAssistantID,
           let idx = session.messages.firstIndex(where: { $0.id == id }) {
            if session.messages[idx].text.isEmpty {
                session.messages[idx].text = text
                session.preview = String(text.prefix(120))
            }
            // Ignore duplicate final flush when we already streamed content.
            return
        }
        let msg = AgentMessage(kind: .assistant, text: text)
        currentAssistantID = msg.id
        session.messages.append(msg)
        session.preview = String(text.prefix(120))
    }

    /// Claude (and similar) re-send the full assistant text each event — replace, don't append.
    private func upsertAssistantSnapshot(_ text: String) {
        guard let session else { return }
        if let id = currentAssistantID,
           let idx = session.messages.firstIndex(where: { $0.id == id }) {
            if session.messages[idx].text != text {
                session.messages[idx].text = text
                session.preview = String(text.prefix(120))
            }
            return
        }
        let msg = AgentMessage(kind: .assistant, text: text)
        currentAssistantID = msg.id
        session.messages.append(msg)
        session.preview = String(text.prefix(120))
    }

    /// Claude embeds `tool_use` blocks inside assistant messages rather than Cursor's `tool_call`.
    private func ingestEmbeddedToolUses(_ json: [String: Any]) {
        guard let session,
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return }
        for item in content {
            guard (item["type"] as? String) == "tool_use" else { continue }
            let toolID = (item["id"] as? String) ?? UUID().uuidString
            if seenToolUseIDs.contains(toolID) { continue }
            seenToolUseIDs.insert(toolID)
            let name = item["name"] as? String ?? "Tool"
            let input = item["input"] as? [String: Any] ?? [:]
            finalizeThinkingIfNeeded()
            let label = claudeToolLabel(name: name, input: input)
            session.messages.append(AgentMessage(kind: .tool, text: label))
            session.preview = label
            currentAssistantID = nil
            refreshExploringActivity()
        }
    }

    /// Cursor/Claude may embed `thinking` blocks inside assistant message content.
    private func ingestEmbeddedThinking(_ json: [String: Any]) {
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return }
        let hasThinking = content.contains { ($0["type"] as? String) == "thinking" }
        if hasThinking {
            beginThinking()
        }
    }

    private func claudeToolLabel(name: String, input: [String: Any]) -> String {
        let path = (input["file_path"] as? String)
            ?? (input["path"] as? String)
            ?? (input["filePath"] as? String)
        switch name {
        case "Read":
            return "Reading \(shortPath(path ?? "file"))"
        case "Write":
            return "Writing \(shortPath(path ?? "file"))"
        case "Edit", "NotebookEdit":
            return "Editing \(shortPath(path ?? "file"))"
        case "Bash":
            let cmd = input["command"] as? String ?? "command"
            return "Ran \(shortCommand(cmd))"
        case "Grep":
            let pattern = input["pattern"] as? String ?? "…"
            return "Searched \(pattern)"
        case "Glob":
            let pattern = input["pattern"] as? String ?? input["globPattern"] as? String ?? "…"
            return "Glob \(pattern)"
        case "WebSearch":
            let q = input["query"] as? String ?? "web"
            return "Search \(q)"
        case "WebFetch":
            let url = input["url"] as? String ?? "url"
            return "Fetch \(url)"
        default:
            if let path { return "\(name) \(shortPath(path))" }
            return name
        }
    }

    private func extractAssistantText(_ json: [String: Any]) -> String {
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return ""
        }
        return content.compactMap { item -> String? in
            guard (item["type"] as? String) == "text" else { return nil }
            return item["text"] as? String
        }.joined()
    }

    private func toolLabel(_ json: [String: Any]) -> String {
        guard let tool = json["tool_call"] as? [String: Any] else {
            return "Tool"
        }
        if let read = tool["readToolCall"] as? [String: Any],
           let args = read["args"] as? [String: Any],
           let path = args["path"] as? String {
            return "Reading \(shortPath(path))"
        }
        if let write = tool["writeToolCall"] as? [String: Any],
           let args = write["args"] as? [String: Any],
           let path = args["path"] as? String {
            return "Writing \(shortPath(path))"
        }
        if let edit = tool["editToolCall"] as? [String: Any],
           let args = edit["args"] as? [String: Any],
           let path = args["path"] as? String {
            return "Editing \(shortPath(path))"
        }
        if let shell = tool["shellToolCall"] as? [String: Any],
           let args = shell["args"] as? [String: Any],
           let command = args["command"] as? String {
            let oneLine = command
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = oneLine.count > 80 ? String(oneLine.prefix(77)) + "…" : oneLine
            return "Ran \(clipped)"
        }
        if let grep = tool["grepToolCall"] as? [String: Any],
           let args = grep["args"] as? [String: Any],
           let pattern = args["pattern"] as? String {
            return "Searched \(pattern)"
        }
        if let glob = tool["globToolCall"] as? [String: Any],
           let args = glob["args"] as? [String: Any],
           let pattern = args["globPattern"] as? String ?? args["pattern"] as? String {
            return "Glob \(pattern)"
        }
        if let del = tool["deleteToolCall"] as? [String: Any],
           let args = del["args"] as? [String: Any],
           let path = args["path"] as? String {
            return "Deleting \(shortPath(path))"
        }
        if let ls = tool["lsToolCall"] as? [String: Any],
           let args = ls["args"] as? [String: Any],
           let path = args["path"] as? String {
            return "Listed \(shortPath(path))"
        }
        if let fn = tool["function"] as? [String: Any],
           let name = fn["name"] as? String {
            return name
        }
        // Prefer a *ToolCall key over opaque ids like toolCallId.
        if let key = tool.keys.first(where: { $0.hasSuffix("ToolCall") }) {
            let name = key.replacingOccurrences(of: "ToolCall", with: "")
            return name.isEmpty ? "Tool" : name.prefix(1).uppercased() + name.dropFirst()
        }
        return "Tool"
    }

    private func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        var p = path
        if p.hasPrefix(home + "/") {
            p = "~" + p.dropFirst(home.count)
        }
        let ns = p as NSString
        let name = ns.lastPathComponent
        guard !name.isEmpty else { return p }
        let parent = ns.deletingLastPathComponent
        if parent.isEmpty || parent == "." || parent == "~" || parent == "/" {
            return name
        }
        let parentName = (parent as NSString).lastPathComponent
        let two = "\(parentName)/\(name)"
        // Prefer a short tail; keep the full path for expand in the UI via message text.
        return two.count <= 42 ? two : "…/\(name)"
    }

    private func beginTurnTracking(on session: AgentSession) {
        turnStartedAt = Date()
        thinkingStartedAt = nil
        session.liveActivity = TurnStatusCopy.planning
    }

    private func endTurnTracking(emitWorked: Bool) {
        finalizeThinkingIfNeeded()
        if emitWorked, let start = turnStartedAt {
            let text = TurnStatusCopy.worked(seconds: Date().timeIntervalSince(start))
            insertStatusAfterUser(text, atFront: true)
        }
        turnStartedAt = nil
        thinkingStartedAt = nil
        session?.liveActivity = nil
    }

    private func beginThinking() {
        guard thinkingStartedAt == nil else { return }
        thinkingStartedAt = Date()
        session?.liveActivity = TurnStatusCopy.thinkingLive
    }

    private func finalizeThinkingIfNeeded() {
        guard let start = thinkingStartedAt else { return }
        thinkingStartedAt = nil
        let text = TurnStatusCopy.thought(seconds: Date().timeIntervalSince(start))
        insertStatusAfterUser(text, atFront: false)
    }

    /// Status chips sit with the agent turn: after the latest user message (and after any
    /// existing status chips unless `atFront` — used for "Worked for" at the top).
    private func insertStatusAfterUser(_ text: String, atFront: Bool) {
        guard let session else { return }
        guard let userIdx = session.messages.lastIndex(where: { $0.kind == .user }) else {
            session.messages.append(AgentMessage(kind: .status, text: text))
            return
        }
        if atFront {
            session.messages.insert(AgentMessage(kind: .status, text: text), at: userIdx + 1)
            return
        }
        var at = userIdx + 1
        while at < session.messages.count && session.messages[at].kind == .status {
            at += 1
        }
        session.messages.insert(AgentMessage(kind: .status, text: text), at: at)
    }

    private func refreshExploringActivity() {
        guard let session else { return }
        var texts: [String] = []
        for msg in session.messages.reversed() {
            if msg.kind == .user { break }
            if msg.kind == .tool { texts.append(msg.text) }
        }
        texts.reverse()
        session.liveActivity = TurnStatusCopy.exploring(toolTexts: texts) ?? TurnStatusCopy.planning
    }

    private func handleTermination(status: Int32) {
        process = nil
        guard let session else { return }
        if session.status == .working {
            if status == 0 {
                session.status = .finished
                if session.preview.isEmpty { session.preview = "Finished" }
                endTurnTracking(emitWorked: true)
            } else {
                session.status = .waiting
                bufferLock.lock()
                let err = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                bufferLock.unlock()
                var msg = "Agent exited (\(status)). Check that you’re logged in (\(session.cliKind.loginHint))."
                if !err.isEmpty {
                    let snippet = err.count > 400 ? String(err.suffix(400)) : err
                    msg += "\n\n\(snippet)"
                }
                session.errorMessage = msg
                session.preview = msg
                session.messages.append(AgentMessage(kind: .system, text: msg))
                endTurnTracking(emitWorked: false)
            }
        }
        onFinished?()
    }
}

final class AgentSessionManager {
    private let store: SessionStore
    private var runners: [UUID: AgentSessionRunner] = [:]
    /// CLI kind the stored runner was built for — recreate when Settings switches agents.
    private var runnerCLIKinds: [UUID: AgentCLIKind] = [:]
    /// Fired on the main queue when a turn finishes idle (`.finished`, no queued follow-ups).
    var onSessionCompleted: ((AgentSession) -> Void)?

    init(store: SessionStore) {
        self.store = store
        store.onDiscard = { [weak self] discarded in
            self?.cleanupRunners(for: discarded)
        }
    }

    private func cleanupRunners(for discarded: [AgentSession]) {
        for session in discarded {
            if let runner = runners.removeValue(forKey: session.id) {
                runner.stop()
            }
            runnerCLIKinds.removeValue(forKey: session.id)
        }
    }

    /// Reuse the live runner only while it still matches the session’s Settings CLI.
    private func runner(for session: AgentSession) -> AgentSessionRunner {
        if let existing = runners[session.id], runnerCLIKinds[session.id] == session.cliKind {
            return existing
        }
        runners[session.id]?.stop()
        let fresh = AgentSessionRunner(cli: AgentCLIFactory.make(session.cliKind))
        wireRunner(fresh, sessionID: session.id, cliKind: session.cliKind)
        return fresh
    }

    func startFromAnnotation(prompt: String, screenshotPath: String?) -> AgentSession? {
        let workspace = Preferences.agentWorkspace
        guard !workspace.isEmpty else { return nil }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Text-only sessions need a prompt; annotated captures can rely on the image alone.
        if screenshotPath == nil, trimmed.isEmpty { return nil }
        let title: String
        if trimmed.isEmpty {
            title = "Annotation"
        } else {
            title = String(trimmed.prefix(48))
        }
        let target = Preferences.runtimeAgentTarget
        let cliKind = Preferences.agentCLI(for: target)
        let favorite = Preferences.favoriteForNewSession(cli: cliKind, target: target)
        let session = AgentSession(
            title: title,
            prompt: prompt,
            screenshotPath: screenshotPath,
            workspace: workspace,
            // SSH: Preferences.agentGitBranch stays empty (no sync remote git); use probed branch.
            gitBranch: Preferences.agentWorkspaceConnectionID != nil
                ? store.currentGitBranch
                : Preferences.agentGitBranch,
            connectionID: Preferences.agentWorkspaceConnectionID,
            cliKind: cliKind,
            favoriteId: favorite.id,
            modelId: favorite.usesCLIDefaultModel ? nil : favorite.modelId,
            effort: favorite.effort
        )
        store.prepend(session)
        let runner = runner(for: session)
        runner.start(session: session, workspace: session.workspace, prompt: prompt, imagePath: screenshotPath)
        return session
    }

    /// Empty session titled "New session" — first follow-up starts the agent.
    func createBlankSession() -> AgentSession? {
        let workspace = Preferences.agentWorkspace
        guard !workspace.isEmpty else { return nil }
        let target = Preferences.runtimeAgentTarget
        let cliKind = Preferences.agentCLI(for: target)
        let favorite = Preferences.favoriteForNewSession(cli: cliKind, target: target)
        let session = AgentSession(
            title: "New session",
            prompt: "",
            screenshotPath: nil,
            workspace: workspace,
            gitBranch: Preferences.agentWorkspaceConnectionID != nil
                ? store.currentGitBranch
                : Preferences.agentGitBranch,
            connectionID: Preferences.agentWorkspaceConnectionID,
            cliKind: cliKind,
            favoriteId: favorite.id,
            modelId: favorite.usesCLIDefaultModel ? nil : favorite.modelId,
            effort: favorite.effort,
            status: .waiting,
            blank: true
        )
        store.prepend(session)
        return session
    }

    func followUp(
        sessionID: UUID,
        text: String,
        submit: FollowUpSubmit = .sendNow,
        imagePath: String? = nil,
        imagePaths: [String] = []
    ) {
        guard let session = store.session(id: sessionID) else { return }
        // Composer / Settings stay aligned — pull Current favorite before argv is built.
        session.syncModelFromSettings()
        let workspace = session.workspace
        guard !workspace.isEmpty else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths: [String] = {
            if !imagePaths.isEmpty { return imagePaths }
            if let imagePath { return [imagePath] }
            return []
        }()
        // Annotated screenshots / pasted media can omit the prompt; text-only cannot.
        guard !trimmed.isEmpty || !paths.isEmpty else { return }
        let prompt = trimmed

        let runner = runner(for: session)

        let busy = session.status == .working && runner.isRunning
        // Queue is text-only — media follow-ups always send now.
        if busy, submit == .queue, paths.isEmpty {
            session.queuedFollowUps.append(QueuedFollowUp(text: prompt))
            return
        }

        let steered = busy
        if busy {
            runner.interruptQuietly()
        }

        // First message in a blank "New session" starts a fresh agent turn.
        let needsStart = (session.chatId == nil || session.chatId?.isEmpty == true) && session.messages.isEmpty
        if needsStart {
            let preview = prompt.isEmpty ? "Annotation" : prompt
            let apply = {
                session.messages.append(AgentMessage(kind: .user, text: prompt, imagePaths: paths))
                if session.title == "New session" {
                    session.title = String(preview.prefix(48))
                }
                session.preview = preview
                session.errorMessage = nil
                session.status = .working
            }
            if Thread.isMainThread { apply() } else { DispatchQueue.main.sync(execute: apply) }
            runner.start(session: session, workspace: workspace, prompt: prompt, imagePaths: paths)
            return
        }

        runner.followUp(
            session: session,
            workspace: workspace,
            prompt: prompt,
            imagePaths: paths,
            steered: steered
        )
    }

    func removeQueuedFollowUp(sessionID: UUID, followUpID: UUID) {
        guard let session = store.session(id: sessionID) else { return }
        session.queuedFollowUps.removeAll { $0.id == followUpID }
        if session.editingFollowUpID == followUpID {
            session.editingFollowUpID = nil
        }
        resumeQueueIfNeeded(sessionID: sessionID)
    }

    /// Write composer text back onto a queued item and resume draining.
    func confirmQueuedFollowUpEdit(sessionID: UUID, followUpID: UUID, text: String) {
        guard let session = store.session(id: sessionID) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = session.queuedFollowUps.firstIndex(where: { $0.id == followUpID }) else { return }
        // Reassign the array so `@Published` + struct elements reliably update.
        var items = session.queuedFollowUps
        items[idx].text = trimmed
        session.queuedFollowUps = items
        session.editingFollowUpID = nil
        resumeQueueIfNeeded(sessionID: sessionID)
    }

    /// Leave edit mode without changing the queue item, then resume draining.
    func cancelQueuedFollowUpEdit(sessionID: UUID) {
        guard let session = store.session(id: sessionID) else { return }
        session.editingFollowUpID = nil
        resumeQueueIfNeeded(sessionID: sessionID)
    }

    /// Attempt to dequeue the next runnable follow-up if the turn is idle.
    func resumeQueueIfNeeded(sessionID: UUID) {
        drainQueue(sessionID: sessionID)
    }

    func stop(sessionID: UUID) {
        runners[sessionID]?.stop()
    }

    func runner(for sessionID: UUID) -> AgentSessionRunner? {
        runners[sessionID]
    }

    private func wireRunner(_ runner: AgentSessionRunner, sessionID: UUID, cliKind: AgentCLIKind) {
        runners[sessionID] = runner
        runnerCLIKinds[sessionID] = cliKind
        runner.onFinished = { [weak self] in
            guard let self else { return }
            self.drainQueue(sessionID: sessionID)
            guard let session = self.store.session(id: sessionID),
                  session.status == .finished,
                  session.queuedFollowUps.isEmpty else { return }
            self.onSessionCompleted?(session)
        }
    }

    private func drainQueue(sessionID: UUID) {
        guard let session = store.session(id: sessionID) else { return }
        guard session.status != .working else { return }
        guard !session.queuedFollowUps.isEmpty else { return }

        if let editingID = session.editingFollowUpID {
            if let editIdx = session.queuedFollowUps.firstIndex(where: { $0.id == editingID }) {
                // Hold the edited item and everything after it; earlier items still run.
                guard editIdx > 0 else { return }
            } else {
                // Stale edit target (removed / reordered away).
                session.editingFollowUpID = nil
            }
        }

        // Need a chat id before dequeuing — otherwise followUp bails and the item is lost.
        if session.chatId == nil || session.chatId?.isEmpty == true {
            return
        }

        let next = session.queuedFollowUps.removeFirst()
        followUp(sessionID: sessionID, text: next.text, submit: .sendNow)
    }
}
