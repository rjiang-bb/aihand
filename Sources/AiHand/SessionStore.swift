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
    /// Working directory this session belongs to.
    let workspace: String

    /// Favorite used for this session (updated when the composer picker changes).
    @Published var favoriteId: UUID?
    /// CLI `--model` id when a favorite (or explicit pick) was set; nil = CLI default.
    @Published var modelId: String?
    /// Separate effort level when the CLI supports it.
    @Published var effort: String?

    @Published var title: String
    @Published var status: AgentSessionStatus
    @Published var messages: [AgentMessage]
    @Published var preview: String
    @Published var chatId: String?
    @Published var errorMessage: String?
    /// Pending follow-ups; not persisted across relaunch.
    @Published var queuedFollowUps: [QueuedFollowUp] = []

    /// Apply a favorite to this session and mark it Current for this CLI.
    func applyFavorite(_ fav: AgentFavorite) {
        guard fav.cliKind == cliKind else { return }
        favoriteId = fav.id
        modelId = fav.usesCLIDefaultModel ? nil : fav.modelId
        effort = fav.effort.flatMap { $0.isEmpty ? nil : $0 }
        Preferences.setCurrentAgentFavoriteID(fav.id, for: cliKind)
    }

    /// Cycle to the next favorite for this session’s CLI (wraps).
    @discardableResult
    func cycleFavorite() -> AgentFavorite? {
        let favs = Preferences.favorites(for: cliKind)
        guard !favs.isEmpty else { return nil }
        let idx = favs.firstIndex(where: { $0.id == favoriteId }) ?? -1
        let next = favs[(idx + 1) % favs.count]
        applyFavorite(next)
        return next
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        title: String,
        prompt: String,
        screenshotPath: String?,
        workspace: String = Preferences.agentWorkspace,
        cliKind: AgentCLIKind = Preferences.agentCLI,
        favoriteId: UUID? = nil,
        modelId: String? = nil,
        effort: String? = nil,
        status: AgentSessionStatus = .working,
        blank: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.initialPrompt = prompt
        self.screenshotPath = screenshotPath
        self.workspace = SessionStore.normalizedWorkspace(workspace)
        self.cliKind = cliKind
        self.favoriteId = favoriteId
        self.modelId = modelId.flatMap { $0.isEmpty ? nil : $0 }
        self.effort = effort.flatMap { $0.isEmpty ? nil : $0 }
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
        let migratedWorkspace = snapshot.workspace?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.workspace = SessionStore.normalizedWorkspace(
            migratedWorkspace.isEmpty ? Preferences.agentWorkspace : migratedWorkspace
        )
        self.favoriteId = snapshot.favoriteId
        self.modelId = snapshot.modelId.flatMap { $0.isEmpty ? nil : $0 }
        self.effort = snapshot.effort.flatMap { $0.isEmpty ? nil : $0 }
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
            cliKind: cliKind,
            workspace: workspace,
            favoriteId: favoriteId,
            modelId: modelId,
            effort: effort
        )
    }
}

final class SessionStore: ObservableObject {
    /// Soft cap per workspace (UI paginates at 10; ⌘1…⌘9 still target the current page).
    static let maxSessions = 100

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
        /// Optional for backwards compatibility; missing values migrate to the current workspace.
        var workspace: String?
        var favoriteId: UUID?
        var modelId: String?
        var effort: String?
    }

    private struct StoreFile: Codable {
        var sessions: [SessionSnapshot]
    }

    /// All sessions across every workspace. Prefer `sessions` for the UI list.
    @Published private(set) var allSessions: [AgentSession] = []
    /// Working directory whose sessions are shown in the panel.
    @Published private(set) var currentWorkspace: String = ""
    /// Folders from Settings — kept in sync so the panel picker refreshes.
    @Published private(set) var workspaceFolders: [String] = []
    @Published var selectedSessionID: UUID?
    private var bags: [UUID: AnyCancellable] = [:]
    private var prefsObserver: Any?
    private var saveWork: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "net.penguinlabs.aihand.sessions", qos: .utility)

    /// Sessions for the current working directory (panel list / ⌘1…9).
    var sessions: [AgentSession] {
        allSessions.filter { Self.sameWorkspace($0.workspace, currentWorkspace) }
    }

    var selectedSession: AgentSession? {
        allSessions.first { $0.id == selectedSessionID }
    }

    /// Still running or blocked on the user (current workspace — menu badge).
    var activeCount: Int {
        sessions.filter { $0.status == .working || $0.status == .waiting }.count
    }

    /// Successfully finished sessions (current workspace — menu badge).
    var completedCount: Int {
        sessions.filter { $0.status == .finished }.count
    }

    init() {
        syncFromPreferences(clearSelectionIfNeeded: false)
        load()
        prefsObserver = NotificationCenter.default.addObserver(
            forName: Preferences.changed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncFromPreferences()
        }
    }

    deinit {
        if let prefsObserver {
            NotificationCenter.default.removeObserver(prefsObserver)
        }
    }

    static func normalizedWorkspace(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    static func sameWorkspace(_ a: String, _ b: String) -> Bool {
        normalizedWorkspace(a) == normalizedWorkspace(b)
    }

    /// Re-filter the panel when Settings changes folders or the current working folder.
    func syncFromPreferences(clearSelectionIfNeeded: Bool = true) {
        // Keep Settings’ paths as-is so selectAgentWorkspace can match them.
        let folders = Preferences.agentWorkspaces
        let next = Self.normalizedWorkspace(Preferences.agentWorkspace)
        let foldersChanged = folders != workspaceFolders
        let currentChanged = next != currentWorkspace
        guard foldersChanged || currentChanged else { return }
        if foldersChanged {
            workspaceFolders = folders
        }
        if currentChanged {
            currentWorkspace = next
            if clearSelectionIfNeeded,
               let id = selectedSessionID,
               let session = allSessions.first(where: { $0.id == id }),
               !Self.sameWorkspace(session.workspace, next) {
                selectedSessionID = nil
            }
        }
    }

    /// Back-compat name used by older call sites / mental model.
    func syncWorkspaceFilter() {
        syncFromPreferences()
    }

    func prepend(_ session: AgentSession) {
        allSessions.insert(session, at: 0)
        observe(session)
        discardOverflow()
        scheduleSave()
    }

    func session(id: UUID) -> AgentSession? {
        allSessions.first { $0.id == id }
    }

    func remove(_ id: UUID) {
        guard let session = allSessions.first(where: { $0.id == id }) else { return }
        allSessions.removeAll { $0.id == id }
        bags[id] = nil
        if selectedSessionID == id {
            selectedSessionID = nil
        }
        cleanupFiles(for: session)
        onDiscard?([session])
        scheduleSave()
    }

    /// Drop sessions past the cap per workspace (oldest at the end of that workspace’s list).
    @discardableResult
    private func discardOverflow() -> [AgentSession] {
        var overflow: [AgentSession] = []
        var kept: [AgentSession] = []
        var counts: [String: Int] = [:]
        for session in allSessions {
            let key = Self.normalizedWorkspace(session.workspace)
            let count = counts[key, default: 0]
            if count < Self.maxSessions {
                kept.append(session)
                counts[key] = count + 1
            } else {
                overflow.append(session)
            }
        }
        guard !overflow.isEmpty else { return [] }
        allSessions = kept
        for session in overflow {
            bags[session.id] = nil
            if selectedSessionID == session.id {
                selectedSessionID = nil
            }
            cleanupFiles(for: session)
        }
        onDiscard?(overflow)
        Log.write("discarded \(overflow.count) session(s) past limit of \(Self.maxSessions) per workspace")
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
        for session in allSessions where session.status == .working {
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
        AppSupport.directory().appendingPathComponent("sessions.json")
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
            let missingWorkspace = file.sessions.contains {
                ($0.workspace ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let restored = file.sessions.map(AgentSession.init(snapshot:))
            allSessions = restored
            for session in restored {
                observe(session)
            }
            let discarded = discardOverflow()
            // Rewrite when we normalized working → stopped, migrated workspace, or trimmed overflow.
            if hadInFlight || missingWorkspace || !discarded.isEmpty {
                scheduleSave()
            }
            Log.write("loaded \(allSessions.count) persisted session(s) (\(sessions.count) for current workspace)")
        } catch {
            Log.write("session load failed: \(error.localizedDescription)")
        }
    }

    private func persist() {
        let snapshots = allSessions.map(\.snapshot)
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
