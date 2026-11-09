import Foundation

struct SSHRunResult {
    var ok: Bool
    var status: Int32
    var stdout: String
    var stderr: String
}

/// Runs remote commands / uploads via `/usr/bin/ssh` and `/usr/bin/scp`, with optional ControlMaster multiplexing.
enum SSHClient {
    private static let lock = NSLock()
    private static var mastersStarted = Set<UUID>()

    /// macOS Unix-domain sockets max out around ~104 bytes; keep ControlPath short.
    private static func controlPath(for id: UUID) -> String {
        let short = String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        return "/tmp/ah-\(short)"
    }

    /// Options shared by validate / run / scp so multiplexed sessions reuse one login.
    private static func multiplexOptions(for connection: SSHConnection, master: Bool) -> [String] {
        let path = controlPath(for: connection.id)
        var opts = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(path)",
            "-o", "ControlPersist=10m",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        if master {
            opts += ["-o", "ConnectTimeout=10"]
        }
        return opts
    }

    @discardableResult
    static func ensureMaster(_ connection: SSHConnection) -> SSHRunResult {
        lock.lock()
        let already = mastersStarted.contains(connection.id)
        lock.unlock()
        if already {
            // Probe existing master.
            let probe = runSSH(
                connection: connection,
                extraOptions: multiplexOptions(for: connection, master: false) + ["-O", "check"],
                remoteCommand: nil,
                timeoutHint: false
            )
            if probe.ok { return probe }
        }
        let result = runSSH(
            connection: connection,
            extraOptions: multiplexOptions(for: connection, master: true) + ["-fN"],
            remoteCommand: nil,
            timeoutHint: true
        )
        if result.ok || result.status == 0 {
            lock.lock()
            mastersStarted.insert(connection.id)
            lock.unlock()
        }
        return result
    }

    static func closeMaster(_ connection: SSHConnection) {
        _ = runSSH(
            connection: connection,
            extraOptions: multiplexOptions(for: connection, master: false) + ["-O", "exit"],
            remoteCommand: nil,
            timeoutHint: false
        )
        lock.lock()
        mastersStarted.remove(connection.id)
        lock.unlock()
        try? FileManager.default.removeItem(atPath: controlPath(for: connection.id))
    }

    static func closeAllMasters() {
        lock.lock()
        let ids = mastersStarted
        lock.unlock()
        for id in ids {
            if let conn = Preferences.sshConnection(id: id) {
                closeMaster(conn)
            } else {
                lock.lock()
                mastersStarted.remove(id)
                lock.unlock()
                try? FileManager.default.removeItem(atPath: controlPath(for: id))
            }
        }
    }

    /// Validates connectivity; starts a ControlMaster on success.
    static func validate(_ connection: SSHConnection) -> SSHRunResult {
        let result = runSSH(
            connection: connection,
            extraOptions: [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=10",
                "-o", "StrictHostKeyChecking=accept-new"
            ] + multiplexOptions(for: connection, master: true),
            remoteCommand: ["true"],
            timeoutHint: true
        )
        if result.ok {
            lock.lock()
            mastersStarted.insert(connection.id)
            lock.unlock()
        }
        return result
    }

    static func run(_ connection: SSHConnection, remoteCommand: [String]) -> SSHRunResult {
        _ = ensureMaster(connection)
        return runSSH(
            connection: connection,
            extraOptions: multiplexOptions(for: connection, master: false),
            remoteCommand: remoteCommand,
            timeoutHint: false
        )
    }

    /// Convenience: run a remote shell string with `bash -lc`.
    static func runShell(_ connection: SSHConnection, _ script: String) -> SSHRunResult {
        run(connection, remoteCommand: ["bash", "-lc", script])
    }

    static func remoteHome(_ connection: SSHConnection) -> String? {
        let result = run(connection, remoteCommand: ["bash", "-lc", "printf %s \"$HOME\""])
        let home = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.ok && !home.isEmpty ? home : nil
    }

    /// Expand `~` and resolve to an absolute path on the remote host.
    static func resolvePath(_ connection: SSHConnection, _ path: String) -> (path: String?, error: String?) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, "Path is empty.") }
        // Single-quoting kills tilde expansion (`cd '~'` looks for a literal "~" dir),
        // so expand ~ via $HOME before quoting the remainder.
        let script: String
        if trimmed == "~" || trimmed == "~/" {
            script = "cd \"$HOME\" && pwd -P"
        } else if trimmed.hasPrefix("~/") {
            let rest = String(trimmed.dropFirst(2))
            script = "cd \"$HOME\"/\(shellEscape(rest)) && pwd -P"
        } else {
            script = "cd \(shellEscape(trimmed)) && pwd -P"
        }
        let result = run(connection, remoteCommand: ["bash", "-lc", script])
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.ok, !out.isEmpty {
            return (out, nil)
        }
        let detail = [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return (nil, detail ?? "Could not resolve path.")
    }

    static func directoryExists(_ connection: SSHConnection, path: String) -> Bool {
        resolvePath(connection, path).path != nil
    }

    static func readFile(_ connection: SSHConnection, path: String, maxBytes: Int = 64_000) -> String? {
        let escaped = shellEscape(path)
        let result = run(connection, remoteCommand: ["bash", "-lc", "head -c \(maxBytes) \(escaped)"])
        guard result.ok else { return nil }
        return result.stdout
    }

    static func which(_ connection: SSHConnection, _ name: String) -> String? {
        let extras = "$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$HOME/.npm-global/bin"
        let script = "export PATH=\"\(extras):$PATH\"; command -v \(shellEscape(name))"
        let result = run(connection, remoteCommand: ["bash", "-lc", script])
        let line = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.ok && !line.isEmpty ? line : nil
    }

    /// Upload a local file to a remote absolute path.
    static func upload(connection: SSHConnection, localPath: String, remotePath: String) -> SSHRunResult {
        _ = ensureMaster(connection)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        var args: [String] = multiplexOptions(for: connection, master: false)
        // scp options that mirror ssh: -P for port, -i, -o, …
        args = scpArgs(fromSSHArgv: connection.argv, multiplex: args)
        args.append(localPath)
        args.append("\(connection.destination):\(remotePath)")
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return SSHRunResult(ok: false, status: -1, stdout: "", stderr: error.localizedDescription)
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return SSHRunResult(
            ok: process.terminationStatus == 0,
            status: process.terminationStatus,
            stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Build a Process configured to run a remote command with streaming pipes (for agent runners).
    static func makeRemoteProcess(
        connection: SSHConnection,
        remoteArgv: [String],
        remoteWorkingDirectory: String?
    ) -> (process: Process, sshArgv: [String]) {
        _ = ensureMaster(connection)
        var remote = remoteArgv
        if let cwd = remoteWorkingDirectory, !cwd.isEmpty {
            remote = ["bash", "-lc", "cd \(shellEscape(cwd)) && exec \(remoteArgv.map(shellEscape).joined(separator: " "))"]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = multiplexOptions(for: connection, master: false)
        args.append(contentsOf: connection.argv)
        args.append("--")
        // One argv token: ssh joins command words with spaces for the remote shell (no quoting).
        args.append(remoteShellCommand(remote))
        process.arguments = args
        return (process, args)
    }

    // MARK: - Internals

    /// Quote argv so OpenSSH’s space-joined remote command still preserves words.
    /// Without this, `bash -lc cd /tmp && pwd` becomes `bash -lc cd` (cd → $HOME).
    private static func remoteShellCommand(_ argv: [String]) -> String {
        argv.map(shellEscape).joined(separator: " ")
    }

    private static func runSSH(
        connection: SSHConnection,
        extraOptions: [String],
        remoteCommand: [String]?,
        timeoutHint: Bool
    ) -> SSHRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = extraOptions
        if timeoutHint, !args.contains("-o") || !args.contains(where: { $0.contains("ConnectTimeout") }) {
            // already included in callers when needed
        }
        args.append(contentsOf: connection.argv)
        if let remoteCommand {
            args.append("--")
            args.append(remoteShellCommand(remoteCommand))
        }
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return SSHRunResult(ok: false, status: -1, stdout: "", stderr: error.localizedDescription)
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return SSHRunResult(
            ok: process.terminationStatus == 0,
            status: process.terminationStatus,
            stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Map ssh argv (with -p) onto scp argv (with -P).
    private static func scpArgs(fromSSHArgv argv: [String], multiplex: [String]) -> [String] {
        var out = multiplex
        var i = 0
        // Drop destination from argv when building scp option list.
        let opts = Array(argv.dropLast())
        while i < opts.count {
            let tok = opts[i]
            if tok == "-p", i + 1 < opts.count {
                out.append("-P")
                out.append(opts[i + 1])
                i += 2
                continue
            }
            if tok.hasPrefix("-p"), tok.count > 2, tok.dropFirst(2).allSatisfy(\.isNumber) {
                out.append("-P")
                out.append(String(tok.dropFirst(2)))
                i += 1
                continue
            }
            // Skip ControlMaster-related already in multiplex; pass -i/-o/-F/-J/-l through.
            if tok == "-o", i + 1 < opts.count {
                out.append(tok)
                out.append(opts[i + 1])
                i += 2
                continue
            }
            if ["-i", "-F", "-J", "-l", "-c", "-o"].contains(tok), i + 1 < opts.count {
                out.append(tok)
                out.append(opts[i + 1])
                i += 2
                continue
            }
            if tok.hasPrefix("-") {
                out.append(tok)
            }
            i += 1
        }
        return out
    }

    static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
