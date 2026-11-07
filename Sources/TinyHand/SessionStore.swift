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

final class AgentSession: ObservableObject, Identifiable {
    let id: UUID
    let createdAt: Date
    let screenshotPath: String?
    let initialPrompt: String

    @Published var title: String
    @Published var status: AgentSessionStatus
    @Published var messages: [AgentMessage]
    @Published var preview: String
    @Published var chatId: String?
    @Published var errorMessage: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        title: String,
        prompt: String,
        screenshotPath: String?,
        status: AgentSessionStatus = .working
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.initialPrompt = prompt
        self.screenshotPath = screenshotPath
        self.status = status
        self.preview = prompt.isEmpty ? "Annotation" : prompt
        var msgs: [AgentMessage] = []
        msgs.append(AgentMessage(kind: .user, text: prompt.isEmpty ? "(annotation)" : prompt, imagePath: screenshotPath))
        self.messages = msgs
    }

    fileprivate init(snapshot: SessionStore.SessionSnapshot) {
        self.id = snapshot.id
        self.createdAt = snapshot.createdAt
        self.screenshotPath = snapshot.screenshotPath
        self.initialPrompt = snapshot.initialPrompt
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
            errorMessage: errorMessage
        )
    }
}

final class SessionStore: ObservableObject {
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
        scheduleSave()
    }

    func session(id: UUID) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    func remove(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        bags[id] = nil
        if selectedSessionID == id {
            selectedSessionID = nil
        }
        scheduleSave()
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
            // Rewrite file when we normalized working → stopped.
            if hadInFlight {
                scheduleSave()
            }
            Log.write("loaded \(restored.count) persisted session(s)")
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
