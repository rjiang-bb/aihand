import Foundation

/// Saved SSH machine reachable via a user-authored `ssh …` command line.
struct SSHConnection: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    /// Stored display label (legacy may be `user@host`; UI prefers `hostname`).
    var label: String
    /// Original text the user entered (e.g. `ssh -A user@devhost.com`).
    var commandLine: String
    /// Arguments after the `ssh` token (flags + destination).
    var argv: [String]

    var destination: String {
        argv.last ?? label
    }

    /// Host only — strips `user@` and trailing `:port` (non-IPv6).
    var hostname: String {
        Self.hostname(from: destination)
    }

    static func hostname(from destination: String) -> String {
        var host = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = host.lastIndex(of: "@") {
            host = String(host[host.index(after: at)...])
        }
        if host.hasPrefix("[") {
            if let end = host.firstIndex(of: "]") {
                return String(host[host.index(after: host.startIndex)..<end])
            }
            return host
        }
        if let colon = host.lastIndex(of: ":"),
           host[host.index(after: colon)...].allSatisfy(\.isNumber) {
            host = String(host[..<colon])
        }
        return host
    }

    static func make(fromCommandLine raw: String) throws -> SSHConnection {
        let parsed = try SSHCommandParser.parse(raw)
        let host = hostname(from: parsed.label)
        return SSHConnection(
            id: UUID(),
            label: host,
            commandLine: parsed.normalizedCommandLine,
            argv: parsed.argv
        )
    }
}

enum SSHCommandParseError: LocalizedError {
    case empty
    case missingSSH
    case missingDestination
    case incompleteFlag(String)

    var errorDescription: String? {
        switch self {
        case .empty: return "Enter an ssh command."
        case .missingSSH: return "Command must start with ssh."
        case .missingDestination: return "Missing host (e.g. user@devhost.com)."
        case .incompleteFlag(let f): return "Flag \(f) needs a value."
        }
    }
}

enum SSHCommandParser {
    /// Flags that take a following argument.
    private static let valueFlags: Set<String> = [
        "-p", "-i", "-l", "-F", "-J", "-o", "-b", "-c", "-D", "-e", "-L", "-R", "-W", "-w",
        "-B", "-E", "-I", "-m", "-O", "-Q", "-S"
    ]

    struct Parsed {
        var argv: [String]
        var label: String
        var normalizedCommandLine: String
    }

    static func parse(_ raw: String) throws -> Parsed {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SSHCommandParseError.empty }

        let tokens = tokenize(trimmed)
        guard let first = tokens.first else { throw SSHCommandParseError.empty }
        let rest: [String]
        if first == "ssh" || first.hasSuffix("/ssh") {
            rest = Array(tokens.dropFirst())
        } else if first.contains("@") || (!first.hasPrefix("-") && tokens.count == 1) {
            // Allow bare `user@host` / host — treat as `ssh user@host`.
            rest = tokens
        } else {
            throw SSHCommandParseError.missingSSH
        }
        guard !rest.isEmpty else { throw SSHCommandParseError.missingDestination }

        var argv: [String] = []
        var i = 0
        while i < rest.count {
            let tok = rest[i]
            if tok == "--" {
                argv.append(contentsOf: rest[(i + 1)...])
                break
            }
            if tok.hasPrefix("-"), tok.count == 2, valueFlags.contains(tok) {
                guard i + 1 < rest.count else { throw SSHCommandParseError.incompleteFlag(tok) }
                argv.append(tok)
                argv.append(rest[i + 1])
                i += 2
                continue
            }
            if tok.hasPrefix("-"), tok.count > 2, !tok.hasPrefix("--") {
                // Combined short flags like -p22 or -oFoo=bar — keep as-is when glued.
                let flag = String(tok.prefix(2))
                if valueFlags.contains(flag), tok.count > 2 {
                    argv.append(flag)
                    argv.append(String(tok.dropFirst(2)))
                    i += 1
                    continue
                }
            }
            if tok.hasPrefix("-o"), tok.count > 2, !valueFlags.contains(tok) {
                argv.append(tok)
                i += 1
                continue
            }
            argv.append(tok)
            i += 1
        }

        guard let destination = argv.last, !destination.hasPrefix("-"), !destination.isEmpty else {
            throw SSHCommandParseError.missingDestination
        }
        // Destination must be last; strip any trailing junk already handled.
        let label = destination
        let normalized = (["ssh"] + argv).joined(separator: " ")
        return Parsed(argv: argv, label: label, normalizedCommandLine: normalized)
    }

    private static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escape = false
        for ch in input {
            if escape {
                current.append(ch)
                escape = false
                continue
            }
            if ch == "\\" && !inSingle {
                escape = true
                continue
            }
            if ch == "'" && !inDouble {
                inSingle.toggle()
                continue
            }
            if ch == "\"" && !inSingle {
                inDouble.toggle()
                continue
            }
            if ch.isWhitespace && !inSingle && !inDouble {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

/// Local vs a saved SSH connection — used for agent settings editing and workspace identity.
enum AgentExecutionTarget: Codable, Equatable, Hashable {
    case local
    case ssh(UUID)

    var storageKey: String {
        switch self {
        case .local: return "local"
        case .ssh(let id): return id.uuidString
        }
    }

    var connectionID: UUID? {
        switch self {
        case .local: return nil
        case .ssh(let id): return id
        }
    }

    init(connectionID: UUID?) {
        if let connectionID {
            self = .ssh(connectionID)
        } else {
            self = .local
        }
    }
}

/// Registered agent folder — local path or path on an SSH machine.
struct AgentWorkspaceRef: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    /// `nil` = this Mac.
    var connectionID: UUID?
    /// Absolute path on that machine.
    var path: String

    var target: AgentExecutionTarget { AgentExecutionTarget(connectionID: connectionID) }

    var displayName: String {
        // Pure string op — `URL(fileURLWithPath:)` stats the path, and `/home` is autofs on macOS.
        (path as NSString).lastPathComponent
    }

    static func local(_ path: String, id: UUID = UUID()) -> AgentWorkspaceRef {
        AgentWorkspaceRef(id: id, connectionID: nil, path: path)
    }

    static func ssh(connectionID: UUID, path: String, id: UUID = UUID()) -> AgentWorkspaceRef {
        AgentWorkspaceRef(id: id, connectionID: connectionID, path: path)
    }
}
