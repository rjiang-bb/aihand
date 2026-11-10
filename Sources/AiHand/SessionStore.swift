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
    /// Attached media paths (screenshots / pasted images / videos).
    var imagePaths: [String]
    /// True when this user turn interrupted an in-flight run (⌘↩ / steer).
    var steered: Bool
    var createdAt: Date

    /// First attachment — kept for call sites that only need one path.
    var imagePath: String? {
        get { imagePaths.first }
        set {
            if let newValue {
                if imagePaths.isEmpty {
                    imagePaths = [newValue]
                } else {
                    imagePaths[0] = newValue
                }
            } else {
                imagePaths = []
            }
        }
    }

    init(
        id: UUID = UUID(),
        kind: AgentMessageKind,
        text: String,
        imagePath: String? = nil,
        imagePaths: [String] = [],
        steered: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        if !imagePaths.isEmpty {
            self.imagePaths = imagePaths
        } else if let imagePath {
            self.imagePaths = [imagePath]
        } else {
            self.imagePaths = []
        }
        self.steered = steered
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, text, imagePath, imagePaths, steered, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(AgentMessageKind.self, forKey: .kind)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        steered = try c.decodeIfPresent(Bool.self, forKey: .steered) ?? false
        if let paths = try c.decodeIfPresent([String].self, forKey: .imagePaths), !paths.isEmpty {
            imagePaths = paths
        } else if let one = try c.decodeIfPresent(String.self, forKey: .imagePath) {
            imagePaths = [one]
        } else {
            imagePaths = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(text, forKey: .text)
        try c.encode(createdAt, forKey: .createdAt)
        if steered {
            try c.encode(true, forKey: .steered)
        }
        if imagePaths.count == 1 {
            try c.encode(imagePaths[0], forKey: .imagePath)
        } else if imagePaths.count > 1 {
            try c.encode(imagePaths, forKey: .imagePaths)
            try c.encode(imagePaths[0], forKey: .imagePath)
        }
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
    /// Git branch (or worktree branch) when the session was created; empty for non-git folders.
    let gitBranch: String
    /// SSH machine for this workspace (`nil` = this Mac).
    let connectionID: UUID?
    /// Denormalized host label for list badges (`user@host`).
    let connectionLabel: String?

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

    var executionTarget: AgentExecutionTarget {
        AgentExecutionTarget(connectionID: connectionID)
    }

    /// Apply a favorite to this session and mark it Current for this CLI.
    func applyFavorite(_ fav: AgentFavorite) {
        guard fav.cliKind == cliKind else { return }
        favoriteId = fav.id
        modelId = fav.usesCLIDefaultModel ? nil : fav.modelId
        effort = fav.effort.flatMap { $0.isEmpty ? nil : $0 }
        Preferences.setCurrentAgentFavoriteID(fav.id, for: cliKind, target: executionTarget)
    }

    /// Cycle to the next favorite for this session’s CLI (wraps).
    @discardableResult
    func cycleFavorite() -> AgentFavorite? {
        let favs = Preferences.favorites(for: cliKind, target: executionTarget)
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
        gitBranch: String = Preferences.agentGitBranch,
        connectionID: UUID? = Preferences.agentWorkspaceConnectionID,
        connectionLabel: String? = nil,
        cliKind: AgentCLIKind = Preferences.agentCLI(for: Preferences.runtimeAgentTarget),
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
        self.gitBranch = gitBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        self.connectionID = connectionID
        if let connectionLabel, !connectionLabel.isEmpty {
            self.connectionLabel = connectionLabel
        } else if let connectionID {
            self.connectionLabel = Preferences.sshConnection(id: connectionID)?.hostname
        } else {
            self.connectionLabel = nil
        }
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
        self.gitBranch = (snapshot.gitBranch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.connectionID = snapshot.connectionID
        self.connectionLabel = snapshot.connectionLabel
            ?? snapshot.connectionID.flatMap { Preferences.sshConnection(id: $0)?.hostname }
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
            gitBranch: gitBranch.isEmpty ? nil : gitBranch,
            connectionID: connectionID,
            connectionLabel: connectionLabel,
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
        /// Optional; missing values match any branch for that workspace path.
        var gitBranch: String?
        /// Optional; missing means local (this Mac).
        var connectionID: UUID?
        var connectionLabel: String?
        var favoriteId: UUID?
        var modelId: String?
        var effort: String?
    }

    private struct StoreFile: Codable {
        var sessions: [SessionSnapshot]
    }

    /// All sessions across every workspace. Prefer `sessions` for the UI list.
    @Published private(set) var allSessions: [AgentSession] = []
    /// Active working directory (root or worktree) whose sessions are shown.
    @Published private(set) var currentWorkspace: String = ""
    /// Registered folder selected in the workspace picker.
    @Published private(set) var workspaceRoot: String = ""
    /// SSH connection for the current workspace (`nil` = local).
    @Published private(set) var currentConnectionID: UUID?
    /// Git branch for `currentWorkspace` (empty when not a repo).
    @Published private(set) var currentGitBranch: String = ""
    /// Worktrees for the current registered root; nil when the root is not a git repo.
    @Published private(set) var gitRepo: GitRepoInfo?
    /// Folders from Settings — kept in sync so the panel picker refreshes.
    @Published private(set) var workspaceFolders: [String] = []
    /// Full workspace refs (local + SSH) for the panel picker.
    @Published private(set) var workspaceRefs: [AgentWorkspaceRef] = []
    @Published var selectedSessionID: UUID?
    private var bags: [UUID: AnyCancellable] = [:]
    private var prefsObserver: Any?
    private var saveWork: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "net.penguinlabs.aihand.sessions", qos: .utility)
    private var gitRefreshWork: DispatchWorkItem?
    /// Polls branch / dirty stats while the sessions panel is visible.
    private var gitPollTimer: Timer?
    /// Bookkeeping queue for probes — never blocks, so it stays responsive while SSH is slow.
    private let gitProbeState = DispatchQueue(label: "net.penguinlabs.aihand.gitprobe.state", qos: .userInitiated)
    /// Where the (blocking) `inspect` calls run. Concurrent so a slow/hung probe for the previous
    /// folder can’t make the one you just clicked wait behind it.
    private let gitProbeWork = DispatchQueue(
        label: "net.penguinlabs.aihand.gitprobe.work",
        qos: .userInitiated,
        attributes: .concurrent
    )
    /// Guarded by `gitProbeState`: at most one probe per (machine, root) at a time; a poll that
    /// lands mid-probe coalesces into a single follow-up.
    private var gitProbeInFlight = Set<String>()
    private var gitProbePending: [String: GitProbeRequest] = [:]

    /// Everything a probe needs, captured on the main thread when it’s scheduled.
    private struct GitProbeRequest {
        var root: String
        var connectionID: UUID?
        /// Resolved SSH connection (`nil` for local, or when the saved connection is gone).
        var connection: SSHConnection?
        var activePath: String

        var flightKey: String { "\(connectionID?.uuidString ?? "local")|\(root)" }
    }

    /// Sessions for the current working directory + branch (panel list / ⌘1…9).
    var sessions: [AgentSession] {
        allSessions.filter { matchesCurrentScope($0) }
    }

    func matchesCurrentScope(_ session: AgentSession) -> Bool {
        Self.sameConnection(session.connectionID, currentConnectionID)
            && Self.sameWorkspace(session.workspace, currentWorkspace)
            && Self.sameGitBranch(session.gitBranch, currentGitBranch)
    }

    static func sameConnection(_ a: UUID?, _ b: UUID?) -> Bool {
        a == b
    }

    static func sameGitBranch(_ a: String, _ b: String) -> Bool {
        let left = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = b.trimmingCharacters(in: .whitespacesAndNewlines)
        // Legacy sessions (no branch) stay visible on whatever branch shares their path.
        if left.isEmpty || right.isEmpty { return true }
        return left == right
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

    /// In-progress (working/waiting) and finished counts for a workspace path.
    func sessionCounts(for workspace: String, connectionID: UUID? = nil) -> (inProgress: Int, succeeded: Int) {
        let list = allSessions.filter {
            Self.sameConnection($0.connectionID, connectionID)
                && Self.sameWorkspace($0.workspace, workspace)
        }
        let inProgress = list.filter { $0.status == .working || $0.status == .waiting }.count
        let succeeded = list.filter { $0.status == .finished }.count
        return (inProgress, succeeded)
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
        gitPollTimer?.invalidate()
        if let prefsObserver {
            NotificationCenter.default.removeObserver(prefsObserver)
        }
    }

    static func normalizedWorkspace(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // `isDirectory:` is required: without it Foundation stats the path to decide, and on macOS
        // `/home` is an autofs mount — every `/home/...` (SSH) path cost ~30–50ms on the main
        // thread, and this runs per session on every filter/render pass (seconds per click).
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
    }

    static func sameWorkspace(_ a: String, _ b: String) -> Bool {
        normalizedWorkspace(a) == normalizedWorkspace(b)
    }

    /// Re-filter the panel when Settings changes folders or the current working folder.
    func syncFromPreferences(clearSelectionIfNeeded: Bool = true) {
        // Keep Settings’ paths as-is so selectAgentWorkspace can match them.
        let refs = Preferences.agentWorkspaceRefs
        let folders = refs.map(\.path)
        let nextRoot = Self.normalizedWorkspace(Preferences.agentWorkspaceRoot)
        let next = Self.normalizedWorkspace(Preferences.agentWorkspace)
        let nextConnection = Preferences.agentWorkspaceConnectionID
        let foldersChanged = folders != workspaceFolders || refs != workspaceRefs
        let rootChanged = nextRoot != workspaceRoot || nextConnection != currentConnectionID
        let currentChanged = next != currentWorkspace
        guard foldersChanged || rootChanged || currentChanged else {
            scheduleGitRefresh(forRoot: nextRoot.isEmpty ? next : nextRoot)
            return
        }
        if foldersChanged {
            workspaceFolders = folders
            workspaceRefs = refs
        }
        if rootChanged {
            workspaceRoot = nextRoot
            currentConnectionID = nextConnection
        }
        if currentChanged {
            currentWorkspace = next
            if clearSelectionIfNeeded,
               let id = selectedSessionID,
               let session = allSessions.first(where: { $0.id == id }),
               !matchesCurrentScope(session) {
                selectedSessionID = nil
            }
        }
        // Drop stale git UI immediately so switching to a huge SSH repo doesn’t wait on probes.
        if rootChanged || currentChanged {
            gitRepo = nil
            currentGitBranch = ""
            restartGitPollingIfNeeded()
        }
        scheduleGitRefresh(forRoot: nextRoot.isEmpty ? next : nextRoot, force: rootChanged || currentChanged)
    }

    /// Refresh worktree list (+ local diff stats) for the registered root (async).
    func refreshGitInfo() {
        scheduleGitRefresh(forRoot: workspaceRoot.isEmpty ? currentWorkspace : workspaceRoot, force: true)
    }

    /// Keep branch / worktree list fresh while the sessions panel is on screen.
    func setGitPollingEnabled(_ enabled: Bool) {
        if enabled {
            refreshGitInfo()
            startGitPollingTimer()
        } else {
            gitPollTimer?.invalidate()
            gitPollTimer = nil
        }
    }

    private func restartGitPollingIfNeeded() {
        guard gitPollTimer != nil else { return }
        startGitPollingTimer()
    }

    private func startGitPollingTimer() {
        gitPollTimer?.invalidate()
        // SSH metadata is cheap but still a network hop — don’t hammer every 2s.
        let interval: TimeInterval = currentConnectionID == nil ? 2.0 : 20.0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshGitInfo()
        }
        RunLoop.main.add(timer, forMode: .common)
        gitPollTimer = timer
    }

    private func scheduleGitRefresh(forRoot root: String, force: Bool = false) {
        let key = Self.normalizedWorkspace(root)
        // Capture on the main thread — the probe itself runs on background queues and must not
        // read `@Published` state or hit UserDefaults for a root the user may have left already.
        let connectionID = currentConnectionID
        let request = GitProbeRequest(
            root: key,
            connectionID: connectionID,
            connection: connectionID.flatMap { Preferences.sshConnection(id: $0) },
            activePath: currentWorkspace
        )
        gitRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.startGitProbe(request)
        }
        gitRefreshWork = work
        // Debounce rapid workspace flips; force path still waits a tick so UI can settle.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + (force ? 0.05 : 0.12),
            execute: work
        )
    }

    /// One probe per root at a time. A poll that lands mid-probe coalesces into a single follow-up
    /// instead of queueing behind every tick. Different roots probe concurrently, so switching
    /// folders never waits on a slow probe for the folder you just left.
    private func startGitProbe(_ request: GitProbeRequest) {
        gitProbeState.async { [weak self] in
            guard let self else { return }
            let flightKey = request.flightKey
            guard !self.gitProbeInFlight.contains(flightKey) else {
                self.gitProbePending[flightKey] = request
                return
            }
            self.gitProbeInFlight.insert(flightKey)
            self.gitProbeWork.async { [weak self] in
                self?.runGitProbe(request)
            }
        }
    }

    /// Blocking (SSH / git). Runs on `gitProbeWork`, never on main.
    private func runGitProbe(_ request: GitProbeRequest) {
        let key = request.root
        let connection = request.connection
        let activePath = request.activePath
        // A saved SSH connection that no longer exists must not fall back to a local probe of a remote path.
        let missingConnection = request.connectionID != nil && connection == nil
        // SSH: metadata only (one remote shell). Full diffs hang on large trees.
        let detail: GitWorkspace.InspectDetail = connection == nil ? .full : .metadata
        let info = (key.isEmpty || missingConnection)
            ? nil
            : GitWorkspace.inspect(path: key, connection: connection, detail: detail)
        // Resolve branch off the main thread — never SSH from `DispatchQueue.main`.
        let branch: String
        if let entry = info?.entry(forPath: activePath) {
            branch = entry.branch
        } else if let info, info.worktrees.count == 1 {
            branch = info.worktrees[0].branch
        } else if info == nil {
            branch = ""
        } else if connection == nil {
            branch = GitWorkspace.currentBranch(in: activePath, connection: nil) ?? ""
        } else {
            // Remote branch should already be in porcelain; skip another SSH hop.
            branch = ""
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Apply only if this root is still the one being shown (the user may have switched).
            if key == self.probedRootKey && request.connectionID == self.currentConnectionID {
                self.applyGitInfo(info, branch: branch)
            }
        }
        gitProbeState.async { [weak self] in
            guard let self else { return }
            let flightKey = request.flightKey
            self.gitProbeInFlight.remove(flightKey)
            if let next = self.gitProbePending.removeValue(forKey: flightKey) {
                self.startGitProbe(next)
            }
        }
    }

    private var probedRootKey: String {
        Self.normalizedWorkspace(workspaceRoot.isEmpty ? currentWorkspace : workspaceRoot)
    }

    private func applyGitInfo(_ info: GitRepoInfo?, branch: String) {
        // Avoid redraw churn when polling finds nothing new.
        guard gitRepo != info || currentGitBranch != branch else { return }
        gitRepo = info
        currentGitBranch = branch
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
            for path in message.imagePaths { paths.insert(path) }
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
