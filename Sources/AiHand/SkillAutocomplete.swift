import AppKit
import SwiftUI

@MainActor
final class SkillAutocompleteController: ObservableObject {
    @Published var matches: [AgentSkill] = []
    @Published var selectedIndex: Int = 0
    @Published private(set) var isActive: Bool = false

    private var skills: [AgentSkill] = []
    private var queryRange: Range<String.Index>?
    private var keyMonitor: Any?
    private var workspace: String = ""
    private var connectionID: UUID?
    var readText: () -> String = { "" }
    var writeText: (String) -> Void = { _ in }

    func configure(workspace: String, connectionID: UUID? = Preferences.agentWorkspaceConnectionID) {
        if self.workspace != workspace || self.connectionID != connectionID {
            self.workspace = workspace
            self.connectionID = connectionID
            refreshSkills()
        } else if skills.isEmpty {
            refreshSkills()
        }
    }

    func refreshSkills() {
        skills = SkillCatalog.skills(
            workspace: workspace.isEmpty ? nil : workspace,
            connectionID: connectionID
        )
    }

    func update(text: String) {
        guard let slash = SkillCatalog.slashQuery(in: text) else {
            clear()
            return
        }
        queryRange = slash.range
        matches = SkillCatalog.matches(query: slash.query, in: skills)
        if selectedIndex >= matches.count {
            selectedIndex = max(0, matches.count - 1)
        }
        isActive = !matches.isEmpty
        if isActive {
            installKeyMonitor()
        } else {
            // Keep monitor if user might keep typing after a failed filter — remove when idle.
            if matches.isEmpty { /* stay ready */ }
        }
    }

    func clear() {
        matches = []
        queryRange = nil
        selectedIndex = 0
        isActive = false
        removeKeyMonitor()
    }

    func apply(_ skill: AgentSkill, to text: inout String) {
        if let range = queryRange ?? SkillCatalog.slashQuery(in: text)?.range {
            text.replaceSubrange(range, with: "/\(skill.name) ")
        } else {
            text = "/\(skill.name) "
        }
        clear()
    }

    func applySelected(to text: inout String) {
        guard matches.indices.contains(selectedIndex) else { return }
        apply(matches[selectedIndex], to: &text)
    }

    func applySelectedFromMonitor() {
        var text = readText()
        applySelected(to: &text)
        writeText(text)
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
            case 36, 76: // return — Shift+Return inserts a newline (handled elsewhere)
                if event.modifierFlags.contains(.shift) { return event }
                Task { @MainActor in self.applySelectedFromMonitor() }
                return nil
            case 53: // escape
                Task { @MainActor in self.clear() }
                return nil
            default:
                return event
            }
        }
    }

    func teardown() {
        removeKeyMonitor()
        matches = []
        queryRange = nil
        selectedIndex = 0
        isActive = false
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
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 240)
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
