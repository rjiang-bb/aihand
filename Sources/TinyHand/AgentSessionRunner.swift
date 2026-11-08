import Foundation

final class AgentSessionRunner {
    private let cli: AgentCLI
    private var process: Process?
    private var stdout: Pipe?
    private var stderr: Pipe?
    private var stdoutBuffer = Data()
    private let bufferLock = NSLock()
    private var currentAssistantID: UUID?
    /// Claude stream-json re-emits full assistant snapshots that include prior `tool_use` blocks.
    private var seenToolUseIDs: Set<String> = []
    private weak var session: AgentSession?
    /// Fired on the main queue after a natural process exit (not interrupt/stop).
    var onFinished: (() -> Void)?

    init(cli: AgentCLI = AgentCLIFactory.make()) {
        self.cli = cli
    }

    var isRunning: Bool { process?.isRunning == true }

    func start(session: AgentSession, workspace: String, prompt: String, imagePath: String?) {
        self.session = session
        guard let exe = cli.resolveExecutable() else {
            DispatchQueue.main.async {
                let msg = "Couldn’t find `\(session.cliKind.commandName)`. \(session.cliKind.installHint)"
                session.status = .failed
                session.errorMessage = msg
                session.preview = msg
                session.messages.append(AgentMessage(kind: .system, text: msg))
            }
            return
        }
        let args = cli.startArguments(
            workspace: workspace,
            prompt: prompt,
            imagePath: imagePath,
            model: session.modelId,
            effort: session.effort
        )
        launch(exe: exe, args: args, session: session)
    }

    func followUp(session: AgentSession, workspace: String, prompt: String, imagePath: String? = nil) {
        self.session = session
        guard let chatId = session.chatId, !chatId.isEmpty else {
            DispatchQueue.main.async {
                session.status = .waiting
                session.errorMessage = "No chat id yet — wait for the first turn to finish, then try again."
                session.messages.append(AgentMessage(kind: .system, text: session.errorMessage ?? ""))
            }
            return
        }
        guard let exe = cli.resolveExecutable() else {
            DispatchQueue.main.async {
                let msg = "Couldn’t find `\(session.cliKind.commandName)`. \(session.cliKind.installHint)"
                session.status = .failed
                session.errorMessage = msg
                session.messages.append(AgentMessage(kind: .system, text: msg))
            }
            return
        }
        let appendUser = {
            session.messages.append(AgentMessage(kind: .user, text: prompt, imagePath: imagePath))
            session.status = .working
            session.preview = prompt
            session.errorMessage = nil
        }
        if Thread.isMainThread {
            appendUser()
        } else {
            DispatchQueue.main.sync(execute: appendUser)
        }
        let args = cli.followUpArguments(
            workspace: workspace,
            chatId: chatId,
            prompt: prompt,
            imagePath: imagePath,
            model: session.modelId,
            effort: session.effort
        )
        launch(exe: exe, args: args, session: session)
    }

    func stop() {
        guard process != nil else { return }
        stopQuietly()
        DispatchQueue.main.async { [weak session] in
            guard let session else { return }
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
        bufferLock.lock()
        stdoutBuffer = Data()
        bufferLock.unlock()
        currentAssistantID = nil
        seenToolUseIDs.removeAll()

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
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            Log.write("agent stderr: \(text)")
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.clearPipeHandlers()
                self?.handleTermination(status: proc.terminationStatus)
            }
        }

        self.process = process
        DispatchQueue.main.async {
            session.status = .working
        }
        do {
            try process.run()
            Log.write("agent launched pid=\(process.processIdentifier) args=\(args.joined(separator: " "))")
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
            let text = extractAssistantText(json)
            if hasTS && hasMC {
                return
            }
            if !text.isEmpty {
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
                let label = toolLabel(json)
                session.messages.append(AgentMessage(kind: .tool, text: label))
                session.preview = label
                currentAssistantID = nil
            }
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
            } else {
                session.status = .finished
                if let result = json["result"] as? String, !result.isEmpty {
                    session.preview = String(result.prefix(120))
                } else {
                    session.preview = "Finished"
                }
            }
            currentAssistantID = nil

        // Codex `codex exec --json` JSONL
        case "thread.started":
            if let tid = json["thread_id"] as? String, !tid.isEmpty {
                session.chatId = tid
            }
        case "turn.started":
            session.status = .working
        case "item.started", "item.updated", "item.completed":
            handleCodexItem(json, completed: type == "item.completed")
        case "turn.completed":
            session.status = .finished
            if session.preview.isEmpty || session.preview == "Working…" {
                session.preview = "Finished"
            }
            currentAssistantID = nil
        case "turn.failed", "error":
            session.status = .failed
            let msg = (json["error"] as? [String: Any]).flatMap { $0["message"] as? String }
                ?? (json["message"] as? String)
                ?? "Codex failed"
            session.errorMessage = msg
            session.preview = msg
            session.messages.append(AgentMessage(kind: .system, text: msg))
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
                let cmd = item["command"] as? String ?? "command"
                let label = "Running \(shortCommand(cmd))"
                session.messages.append(AgentMessage(kind: .tool, text: label))
                session.preview = label
                currentAssistantID = nil
            }
        case "file_change", "file_change_proposed":
            if !completed {
                let path = (item["path"] as? String)
                    ?? (item["changes"] as? [[String: Any]])?.first.flatMap { $0["path"] as? String }
                    ?? "file"
                let label = "Editing \(shortPath(path))"
                session.messages.append(AgentMessage(kind: .tool, text: label))
                session.preview = label
                currentAssistantID = nil
            }
        case "mcp_tool_call":
            if !completed {
                let name = item["tool"] as? String ?? item["name"] as? String ?? "MCP tool"
                let label = "MCP \(name)"
                session.messages.append(AgentMessage(kind: .tool, text: label))
                session.preview = label
                currentAssistantID = nil
            }
        case "web_search":
            if !completed {
                let q = item["query"] as? String ?? "web"
                let label = "Search \(q)"
                session.messages.append(AgentMessage(kind: .tool, text: label))
                session.preview = label
                currentAssistantID = nil
            }
        case "reasoning", "plan_update":
            break
        default:
            if !completed {
                let label = itemType.replacingOccurrences(of: "_", with: " ")
                session.messages.append(AgentMessage(kind: .tool, text: label.capitalized))
                session.preview = label
                currentAssistantID = nil
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
            let label = claudeToolLabel(name: name, input: input)
            session.messages.append(AgentMessage(kind: .tool, text: label))
            session.preview = label
            currentAssistantID = nil
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

    private func handleTermination(status: Int32) {
        process = nil
        guard let session else { return }
        if session.status == .working {
            if status == 0 {
                session.status = .finished
                if session.preview.isEmpty { session.preview = "Finished" }
            } else {
                session.status = .waiting
                let msg = "Agent exited (\(status)). Check that you’re logged in (\(session.cliKind.loginHint))."
                session.errorMessage = msg
                session.preview = msg
                session.messages.append(AgentMessage(kind: .system, text: msg))
            }
        }
        onFinished?()
    }
}

final class AgentSessionManager {
    private let store: SessionStore
    private var runners: [UUID: AgentSessionRunner] = [:]
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
        }
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
        let cliKind = Preferences.agentCLI
        // Prefer the latest session that used this CLI (list is workspace-scoped, mixed CLIs).
        let lastForCLI = store.sessions.first { $0.cliKind == cliKind }
        let favorite = Preferences.favoriteForNewSession(cli: cliKind, lastSession: lastForCLI)
        let session = AgentSession(
            title: title,
            prompt: prompt,
            screenshotPath: screenshotPath,
            workspace: workspace,
            cliKind: cliKind,
            favoriteId: favorite.id,
            modelId: favorite.usesCLIDefaultModel ? nil : favorite.modelId,
            effort: favorite.effort
        )
        store.prepend(session)
        let runner = AgentSessionRunner(cli: AgentCLIFactory.make(cliKind))
        wireRunner(runner, sessionID: session.id)
        runner.start(session: session, workspace: session.workspace, prompt: prompt, imagePath: screenshotPath)
        return session
    }

    /// Empty session titled "New session" — first follow-up starts the agent.
    func createBlankSession() -> AgentSession? {
        let workspace = Preferences.agentWorkspace
        guard !workspace.isEmpty else { return nil }
        let cliKind = Preferences.agentCLI
        let lastForCLI = store.sessions.first { $0.cliKind == cliKind }
        let favorite = Preferences.favoriteForNewSession(cli: cliKind, lastSession: lastForCLI)
        let session = AgentSession(
            title: "New session",
            prompt: "",
            screenshotPath: nil,
            workspace: workspace,
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

    func followUp(sessionID: UUID, text: String, submit: FollowUpSubmit = .sendNow) {
        guard let session = store.session(id: sessionID) else { return }
        let workspace = session.workspace
        guard !workspace.isEmpty else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let runner = runners[sessionID] ?? AgentSessionRunner(cli: AgentCLIFactory.make(session.cliKind))
        wireRunner(runner, sessionID: sessionID)

        let busy = session.status == .working && runner.isRunning
        if busy, submit == .queue {
            session.queuedFollowUps.append(QueuedFollowUp(text: trimmed))
            return
        }

        if busy, submit == .sendNow {
            runner.interruptQuietly()
        }

        // First message in a blank "New session" starts a fresh agent turn.
        let needsStart = (session.chatId == nil || session.chatId?.isEmpty == true) && session.messages.isEmpty
        if needsStart {
            let apply = {
                session.messages.append(AgentMessage(kind: .user, text: trimmed))
                if session.title == "New session" {
                    session.title = String(trimmed.prefix(48))
                }
                session.preview = trimmed
                session.errorMessage = nil
                session.status = .working
            }
            if Thread.isMainThread { apply() } else { DispatchQueue.main.sync(execute: apply) }
            runner.start(session: session, workspace: workspace, prompt: trimmed, imagePath: nil)
            return
        }

        runner.followUp(session: session, workspace: workspace, prompt: trimmed)
    }

    func removeQueuedFollowUp(sessionID: UUID, followUpID: UUID) {
        guard let session = store.session(id: sessionID) else { return }
        session.queuedFollowUps.removeAll { $0.id == followUpID }
    }

    func stop(sessionID: UUID) {
        runners[sessionID]?.stop()
    }

    func runner(for sessionID: UUID) -> AgentSessionRunner? {
        runners[sessionID]
    }

    private func wireRunner(_ runner: AgentSessionRunner, sessionID: UUID) {
        runners[sessionID] = runner
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
        let next = session.queuedFollowUps.removeFirst()
        followUp(sessionID: sessionID, text: next.text, submit: .sendNow)
    }
}
