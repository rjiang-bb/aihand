import AppKit
import SwiftUI

@MainActor
final class SkillAutocompleteController: ObservableObject {
    @Published var matches: [AgentSkill] = []
    @Published var selectedIndex: Int = 0
    @Published private(set) var isActive: Bool = false

    private var skills: [AgentSkill] = []
    private var keyMonitor: Any?
    private var workspace: String = ""
    private var connectionID: UUID?
    private var cli: AgentCLIKind = Preferences.agentCLI(for: Preferences.runtimeAgentTarget)
    /// Bumped on every dismiss so in-flight skill scans can't reopen a dismissed picker.
    private var dismissGeneration: Int = 0
    /// After a pick, ignore `/<name>` until the user starts a new `/` token.
    private var committedSkillName: String?
    var readText: () -> String = { "" }
    var writeText: (String) -> Void = { _ in }
    /// Host replaces the `/query` with the chosen skill (same path as click).
    var onPick: ((AgentSkill) -> Void)?

    func configure(
        workspace: String,
        connectionID: UUID? = Preferences.agentWorkspaceConnectionID,
        cli: AgentCLIKind = Preferences.agentCLI(for: Preferences.runtimeAgentTarget)
    ) {
        if self.workspace != workspace || self.connectionID != connectionID || self.cli != cli {
            self.workspace = workspace
            self.connectionID = connectionID
            self.cli = cli
            skills = []
            refreshSkills()
        } else if skills.isEmpty {
            refreshSkills()
        }
    }

    func refreshSkills() {
        let ws = workspace
        let conn = connectionID
        let kind = cli
        let gen = dismissGeneration
        if conn != nil {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let list = SkillCatalog.skills(
                    workspace: ws.isEmpty ? nil : ws,
                    connectionID: conn,
                    cli: kind
                )
                DispatchQueue.main.async {
                    guard let self, self.workspace == ws, self.connectionID == conn, self.cli == kind else { return }
                    self.skills = list
                    guard self.dismissGeneration == gen else { return }
                    let text = self.readText()
                    if SkillCatalog.slashQuery(in: text) != nil {
                        self.update(text: text)
                    }
                }
            }
            return
        }
        skills = SkillCatalog.skills(
            workspace: ws.isEmpty ? nil : ws,
            connectionID: nil,
            cli: kind
        )
    }

    func update(text: String) {
        // Keep / reopen the catalog even if teardown cleared the in-memory list.
        if skills.isEmpty {
            refreshSkills()
        }

        guard let slash = SkillCatalog.slashQuery(in: text) else {
            // No active `/token` — drop commit lock so the next `/` can open the picker.
            committedSkillName = nil
            dismiss(clearCommit: false)
            return
        }

        // Bare `/` always opens the picker (new token).
        if slash.query.isEmpty {
            committedSkillName = nil
        } else if let committed = committedSkillName, slash.query == committed {
            // Still sitting on the just-picked `/name` (space lost) — stay dismissed.
            dismiss(clearCommit: false)
            return
        } else if let committed = committedSkillName, !committed.hasPrefix(slash.query) {
            // Diverged from the committed name — allow suggestions again.
            committedSkillName = nil
        } else if let committed = committedSkillName,
                  slash.query.count < committed.count,
                  committed.hasPrefix(slash.query) {
            // User is backspacing the committed name — allow suggestions.
            committedSkillName = nil
        }

        matches = SkillCatalog.matches(query: slash.query, in: skills)
        if selectedIndex >= matches.count {
            selectedIndex = max(0, matches.count - 1)
        }
        isActive = !matches.isEmpty
        if isActive {
            installKeyMonitor()
        } else {
            removeKeyMonitor()
        }
    }

    /// Hide the list without wiping the skill cache.
    func clear() {
        dismiss(clearCommit: false)
    }

    private func dismiss(clearCommit: Bool) {
        dismissGeneration &+= 1
        if clearCommit { committedSkillName = nil }
        matches = []
        selectedIndex = 0
        if isActive { isActive = false }
        removeKeyMonitor()
    }

    func apply(_ skill: AgentSkill, to text: inout String) {
        let token = ComposerFileChipToken.serializeSkill(skill.name)
        if let range = SkillCatalog.slashQuery(in: text)?.range {
            text.replaceSubrange(range, with: token + " ")
        } else if text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") {
            text += token + " "
        } else {
            text += " " + token + " "
        }
        committedSkillName = skill.name
        // Defer emptying matches so SwiftUI can finish the Button / ScrollView tear-down.
        isActive = false
        removeKeyMonitor()
        dismissGeneration &+= 1
        let gen = dismissGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.dismissGeneration == gen else { return }
            self.matches = []
            self.selectedIndex = 0
        }
    }

    func applySelected(to text: inout String) {
        guard matches.indices.contains(selectedIndex) else { return }
        apply(matches[selectedIndex], to: &text)
    }

    func applySelectedFromMonitor() {
        let skill = matches.indices.contains(selectedIndex) ? matches[selectedIndex] : nil
        isActive = false
        removeKeyMonitor()
        guard let skill else { return }
        onPick?(skill)
    }

    func moveSelection(delta: Int) {
        guard !matches.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), matches.count - 1)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActive, !self.matches.isEmpty else { return event }
            switch Int(event.keyCode) {
            case 126: // up
                Task { @MainActor in self.moveSelection(delta: -1) }
                return nil
            case 125: // down
                Task { @MainActor in self.moveSelection(delta: 1) }
                return nil
            case 48: // tab
                Task { @MainActor in self.applySelectedFromMonitor() }
                return nil
            case 36, 76: // return
                if event.modifierFlags.contains(.shift) { return event }
                Task { @MainActor in self.applySelectedFromMonitor() }
                return nil
            case 53: // escape
                Task { @MainActor in
                    self.committedSkillName = nil
                    self.clear()
                }
                return nil
            default:
                return event
            }
        }
    }

    func teardown() {
        // Keep `skills` cached — wiping it made the 2nd `/` show an empty picker.
        committedSkillName = nil
        clear()
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }
}

struct SkillSuggestionList: View {
    @ObservedObject var controller: SkillAutocompleteController
    var query: String
    var onSelect: (AgentSkill) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(controller.matches.enumerated()), id: \.element.id) { index, skill in
                        Button {
                            onSelect(skill)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "hexagon.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18, height: 18)
                                    .padding(.top, 1)
                                VStack(alignment: .leading, spacing: 2) {
                                    highlightedName(skill.name, query: query)
                                        .font(.system(size: 14, weight: .semibold))
                                    if !skill.description.isEmpty {
                                        Text(skill.description)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(index == controller.selectedIndex ? Color.accentColor.opacity(0.16) : Color.clear)
                            )
                        }
                        .buttonStyle(.pointerPlain)
                        .id(index)
                    }
                }
            }
            .frame(maxHeight: 240)
            .onChange(of: controller.selectedIndex) { index in
                proxy.scrollTo(index, anchor: nil)
            }
        }
        .padding(4)
        .frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.28), radius: 16, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }

    private func highlightedName(_ name: String, query: String) -> Text {
        let q = query.lowercased()
        guard !q.isEmpty, let range = name.range(of: q, options: .caseInsensitive) else {
            return Text(name).foregroundColor(.primary)
        }
        var attributed = AttributedString(name)
        if let start = AttributedString.Index(range.lowerBound, within: attributed),
           let end = AttributedString.Index(range.upperBound, within: attributed) {
            attributed[start..<end].foregroundColor = .accentColor
        }
        return Text(attributed)
    }
}
