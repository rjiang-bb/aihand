import AppKit
import Combine
import Foundation

enum AgentSessionStatus: String, Codable, Equatable {
    case working
    case finished
    case waiting
    case stopped
    case failed
}

enum AgentMessageKind: String, Codable, Equatable {
    case user
    case assistant
    case tool
    case system
}

struct AgentMessage: Identifiable, Equatable, Codable {
    let id: UUID
    var kind: AgentMessageKind
    var text: String
    var imagePath: String?
    var createdAt: Date

    init(id: UUID = UUID(), kind: AgentMessageKind, text: String, imagePath: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imagePath = imagePath
        self.createdAt = createdAt
    }
}

/// Follow-up waiting for the current turn to finish (Enter while working).
struct QueuedFollowUp: Identifiable, Equatable {
    let id: UUID
    var text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

enum FollowUpSubmit: Equatable {
    /// Wait until the current turn finishes, then run (Enter while working).
    case queue
    /// Interrupt and send now / steer (⌘↩ or send button while working).
    case sendNow
}

final class AgentSession: ObservableObject, Identifiable {
    let id: UUID
    let createdAt: Date
    let screenshotPath: String?
    let initialPrompt: String
    let cliKind: AgentCLIKind

    @Published var title: String
    @Published var status: AgentSessionStatus
    @Published var messages: [AgentMessage]
    @Published var preview: String
    @Published var chatId: String?
    @Published var errorMessage: String?
    /// Pending follow-ups; not persisted across relaunch.
    @Published var queuedFollowUps: [QueuedFollowUp] = []

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        title: String,
        prompt: String,
        screenshotPath: String?,
        cliKind: AgentCLIKind = Preferences.agentCLI,
        status: AgentSessionStatus = .working,
        blank: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.initialPrompt = prompt
        self.screenshotPath = screenshotPath
        self.cliKind = cliKind
        self.status = status
        if blank {
            self.preview = ""
            self.messages = []
        } else {
            self.preview = prompt.isEmpty ? "Annotation" : prompt
            self.messages = [
                AgentMessage(kind: .user, text: prompt.isEmpty ? "(annotation)" : prompt, imagePath: screenshotPath)
            ]
        }
    }

    /// Untouched New-session draft — no user message yet.
    var isBlankDraft: Bool {
        messages.isEmpty && status == .waiting
    }

    fileprivate init(snapshot: SessionStore.SessionSnapshot) {
        self.id = snapshot.id
        self.createdAt = snapshot.createdAt
        self.screenshotPath = snapshot.screenshotPath
        self.initialPrompt = snapshot.initialPrompt
        self.cliKind = snapshot.cliKind ?? .cursor
        self.title = snapshot.title
        // In-flight processes don't survive relaunch.
        if snapshot.status == .working {
            self.status = .stopped
            self.preview = snapshot.preview.isEmpty ? "Stopped" : snapshot.preview
            self.errorMessage = snapshot.errorMessage
            var msgs = snapshot.messages
            if msgs.last?.kind != .system || msgs.last?.text != "Stopped (app quit)" {
                msgs.append(AgentMessage(kind: .system, text: "Stopped (app quit)"))
            }
            self.messages = msgs
        } else {
            self.status = snapshot.status
            self.preview = snapshot.preview
            self.errorMessage = snapshot.errorMessage
            self.messages = snapshot.messages
        }
        self.chatId = snapshot.chatId
    }

    fileprivate var snapshot: SessionStore.SessionSnapshot {
        SessionStore.SessionSnapshot(
            id: id,
            createdAt: createdAt,
            screenshotPath: screenshotPath,
            initialPrompt: initialPrompt,
            title: title,
            status: status,
            messages: messages,
            preview: preview,
            chatId: chatId,
            errorMessage: errorMessage,
            cliKind: cliKind
        )
    }
}

final class SessionStore: ObservableObject {
    /// Hard cap for the sessions list (also matches ⌘1…⌘9 shortcuts).
    static let maxSessions = 9

    /// Called after older sessions are dropped past `maxSessions`.
    var onDiscard: (([AgentSession]) -> Void)?

    struct SessionSnapshot: Codable {
        var id: UUID
        var createdAt: Date
        var screenshotPath: String?
        var initialPrompt: String
        var title: String
        var status: AgentSessionStatus
        var messages: [AgentMessage]
        var preview: String
        var chatId: String?
        var errorMessage: String?
        /// Optional for backwards compatibility with older sessions.json files.
        var cliKind: AgentCLIKind?
    }

    private struct StoreFile: Codable {
        var sessions: [SessionSnapshot]
    }

    @Published private(set) var sessions: [AgentSession] = []
    @Published var selectedSessionID: UUID?
    private var bags: [UUID: AnyCancellable] = [:]
    private var saveWork: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "com.kamranahmed.tinyhand.sessions", qos: .utility)

    var selectedSession: AgentSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    /// Still running or blocked on the user.
    var activeCount: Int {
        sessions.filter { $0.status == .working || $0.status == .waiting }.count
    }

    /// Successfully finished sessions.
    var completedCount: Int {
        sessions.filter { $0.status == .finished }.count
    }

    init() {
        load()
    }

    func prepend(_ session: AgentSession) {
        sessions.insert(session, at: 0)
        observe(session)
        discardOverflow()
        scheduleSave()
    }

    func session(id: UUID) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    func remove(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        sessions.removeAll { $0.id == id }
        bags[id] = nil
        if selectedSessionID == id {
            selectedSessionID = nil
        }
        cleanupFiles(for: session)
        onDiscard?([session])
        scheduleSave()
    }

    /// Drop sessions past the cap (oldest at the end of the list).
    @discardableResult
    private func discardOverflow() -> [AgentSession] {
        guard sessions.count > Self.maxSessions else { return [] }
        let overflow = Array(sessions.suffix(from: Self.maxSessions))
        sessions = Array(sessions.prefix(Self.maxSessions))
        for session in overflow {
            bags[session.id] = nil
            if selectedSessionID == session.id {
                selectedSessionID = nil
            }
            cleanupFiles(for: session)
        }
        if !overflow.isEmpty {
            onDiscard?(overflow)
            Log.write("discarded \(overflow.count) session(s) past limit of \(Self.maxSessions)")
        }
        return overflow
    }

    private func cleanupFiles(for session: AgentSession) {
        var paths = Set<String>()
        if let path = session.screenshotPath { paths.insert(path) }
        for message in session.messages {
            if let path = message.imagePath { paths.insert(path) }
        }
        let fm = FileManager.default
        for path in paths {
            guard fm.fileExists(atPath: path) else { continue }
            do {
                try fm.removeItem(atPath: path)
            } catch {
                Log.write("session file cleanup failed: \(error.localizedDescription)")
            }
        }
    }

    /// Flush immediately (call on quit). Marks in-flight runs as stopped first.
    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        for session in sessions where session.status == .working {
            session.status = .stopped
            if session.preview.isEmpty { session.preview = "Stopped" }
            if session.messages.last?.text != "Stopped (app quit)" {
                session.messages.append(AgentMessage(kind: .system, text: "Stopped (app quit)"))
            }
        }
        persist()
    }

    private func observe(_ session: AgentSession) {
        bags[session.id] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.scheduleSave()
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.persist()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private static var fileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = root.appendingPathComponent("TinyHand", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }

    private func load() {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(StoreFile.self, from: data)
            let hadInFlight = file.sessions.contains { $0.status == .working }
            let restored = file.sessions.map(AgentSession.init(snapshot:))
            sessions = restored
            for session in restored {
                observe(session)
            }
            let discarded = discardOverflow()
            // Rewrite file when we normalized working → stopped or trimmed overflow.
            if hadInFlight || !discarded.isEmpty {
                scheduleSave()
            }
            Log.write("loaded \(sessions.count) persisted session(s)")
        } catch {
            Log.write("session load failed: \(error.localizedDescription)")
        }
    }

    private func persist() {
        let snapshots = sessions.map(\.snapshot)
        let file = StoreFile(sessions: snapshots)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(file)
            let url = Self.fileURL
            try saveQueue.sync {
                try data.write(to: url, options: [.atomic])
            }
        } catch {
            Log.write("session save failed: \(error.localizedDescription)")
        }
    }
}
