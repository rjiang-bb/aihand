import Foundation

final class AgentSessionRunner {
    private let cli: AgentCLI
    private var process: Process?
    private var stdout: Pipe?
    private var stderr: Pipe?
    private var stdoutBuffer = Data()
    private let bufferLock = NSLock()
    private var currentAssistantID: UUID?
    private weak var session: AgentSession?
    private var onFinished: (() -> Void)?

    init(cli: AgentCLI = AgentCLIFactory.make()) {
        self.cli = cli
    }

    var isRunning: Bool { process?.isRunning == true }

    func start(session: AgentSession, workspace: String, prompt: String, imagePath: String?) {
        self.session = session
        guard let exe = cli.resolveExecutable() else {
            DispatchQueue.main.async {
                session.status = .failed
                session.errorMessage = "Couldn’t find `\(Preferences.agentCLI.commandName)`. Install the Cursor CLI."
                session.preview = session.errorMessage ?? ""
                session.messages.append(AgentMessage(kind: .system, text: session.errorMessage ?? ""))
            }
            return
        }
        let args = cli.startArguments(workspace: workspace, prompt: prompt, imagePath: imagePath)
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
                session.status = .failed
                session.errorMessage = "Couldn’t find `\(Preferences.agentCLI.commandName)`."
                session.messages.append(AgentMessage(kind: .system, text: session.errorMessage ?? ""))
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
        let args = cli.followUpArguments(workspace: workspace, chatId: chatId, prompt: prompt, imagePath: imagePath)
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extras = ["\(home)/.local/bin", "/usr/local/bin", "/opt/homebrew/bin"]
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extras + [path]).joined(separator: ":")
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: Preferences.agentWorkspace.isEmpty
            ? NSHomeDirectory()
            : Preferences.agentWorkspace)

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
        case "system":
            if let sid = json["session_id"] as? String, !sid.isEmpty {
                session.chatId = sid
            }
        case "assistant":
            let hasTS = json["timestamp_ms"] != nil
            let hasMC = json["model_call_id"] != nil
            // Streaming deltas: timestamp present, model_call_id absent.
            // Also accept complete assistant messages without those fields when not streaming.
            let text = extractAssistantText(json)
            guard !text.isEmpty else { return }
            if hasTS && hasMC {
                return
            }
            if hasTS || (!hasTS && !hasMC) {
                appendAssistant(text, replace: hasTS)
            }
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
            } else {
                session.status = .finished
                if let result = json["result"] as? String, !result.isEmpty {
                    session.preview = String(result.prefix(120))
                } else {
                    session.preview = "Finished"
                }
            }
            currentAssistantID = nil
        default:
            break
        }
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
        if let key = tool.keys.first {
            return key.replacingOccurrences(of: "ToolCall", with: "")
        }
        return "Tool"
    }

    private func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
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
                let msg = "Agent exited (\(status)). Check that you’re logged in (`agent login`)."
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

    init(store: SessionStore) {
        self.store = store
    }

    func startFromAnnotation(prompt: String, screenshotPath: String) -> AgentSession? {
        let workspace = Preferences.agentWorkspace
        guard !workspace.isEmpty else { return nil }
        let title: String
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = "Annotation"
        } else {
            title = String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
        }
        let session = AgentSession(title: title, prompt: prompt, screenshotPath: screenshotPath)
        store.prepend(session)
        let runner = AgentSessionRunner()
        runners[session.id] = runner
        runner.start(session: session, workspace: workspace, prompt: prompt, imagePath: screenshotPath)
        return session
    }

    func followUp(sessionID: UUID, text: String) {
        guard let session = store.session(id: sessionID) else { return }
        let workspace = Preferences.agentWorkspace
        guard !workspace.isEmpty else { return }
        let runner = runners[sessionID] ?? AgentSessionRunner()
        runners[sessionID] = runner
        runner.interruptQuietly()
        runner.followUp(session: session, workspace: workspace, prompt: text)
    }

    func stop(sessionID: UUID) {
        runners[sessionID]?.stop()
    }

    func runner(for sessionID: UUID) -> AgentSessionRunner? {
        runners[sessionID]
    }
}
