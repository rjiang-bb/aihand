import AppKit
import Combine
import Foundation

enum AgentSessionStatus: String, Equatable {
    case working
    case finished
    case waiting
    case stopped
    case failed
}

enum AgentMessageKind: Equatable {
    case user
    case assistant
    case tool
    case system
}

struct AgentMessage: Identifiable, Equatable {
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
}

final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published var selectedSessionID: UUID?
    private var bags: [UUID: AnyCancellable] = [:]

    var selectedSession: AgentSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    func prepend(_ session: AgentSession) {
        sessions.insert(session, at: 0)
        bags[session.id] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
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
    }
}
