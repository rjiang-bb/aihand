import AppKit
import SwiftUI

@MainActor
final class FileAutocompleteController: ObservableObject {
    @Published var matches: [WorkspaceFileEntry] = []
    @Published var selectedIndex: Int = 0
    @Published private(set) var isActive: Bool = false

    private var entries: [WorkspaceFileEntry] = []
    private var keyMonitor: Any?
    private var workspace: String = ""
    private var connectionID: UUID?
    /// Bumped on every `clear()` so in-flight index loads can't reopen a dismissed picker.
    private var dismissGeneration: Int = 0
    var readText: () -> String = { "" }
    var writeText: (String) -> Void = { _ in }
    /// Called after a pick — host should attach a chip (not insert plain `@path` text).
    var onPick: ((WorkspaceFileEntry) -> Void)?
    /// Called when Esc dismisses the picker without inserting.
    var onDismiss: (() -> Void)?

    func configure(workspace: String, connectionID: UUID? = Preferences.agentWorkspaceConnectionID) {
        if self.workspace != workspace || self.connectionID != connectionID {
            self.workspace = workspace
            self.connectionID = connectionID
            entries = []
            refreshEntries()
        } else if entries.isEmpty {
            refreshEntries()
        }
    }

    func refreshEntries() {
        let ws = workspace
        let conn = connectionID
        let gen = dismissGeneration
        if conn != nil || !ws.isEmpty {
            // Indexing (especially SSH / large trees) stays off the composer thread.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let list = WorkspaceFileCatalog.entries(
                    workspace: ws.isEmpty ? nil : ws,
                    connectionID: conn
                )
                DispatchQueue.main.async {
                    guard let self, self.workspace == ws, self.connectionID == conn else { return }
                    self.entries = list
                    // Don't resurrect a picker the user just dismissed / picked from.
                    guard self.dismissGeneration == gen else { return }
                    let text = self.readText()
                    if WorkspaceFileCatalog.atQuery(in: text) != nil {
                        self.update(text: text)
                    }
                }
            }
            return
        }
        entries = []
    }

    func update(text: String) {
        if entries.isEmpty {
            refreshEntries()
        }
        guard let at = WorkspaceFileCatalog.atQuery(in: text) else {
            clear()
            return
        }
        matches = WorkspaceFileCatalog.matches(query: at.query, in: entries)
        if selectedIndex >= matches.count {
            selectedIndex = max(0, matches.count - 1)
        }
        // Keep the popover open for `@` even while the index is still loading.
        isActive = true
        installKeyMonitor()
    }

    func clear() {
        dismissGeneration &+= 1
        matches = []
        selectedIndex = 0
        isActive = false
        removeKeyMonitor()
    }

    /// Remove the active `@…` query from the draft (chips carry the reference).
    func apply(_ entry: WorkspaceFileEntry, to text: inout String) {
        // Always resolve against the live string — stale String.Index from an older
        // draft left `@…` in place and kept the picker stuck on old matches.
        if let range = WorkspaceFileCatalog.atQuery(in: text)?.range {
            text.replaceSubrange(range, with: "")
        }
        clear()
    }

    func applySelected(to text: inout String) -> WorkspaceFileEntry? {
        guard matches.indices.contains(selectedIndex) else { return nil }
        let entry = matches[selectedIndex]
        apply(entry, to: &text)
        return entry
    }

    func applySelectedFromMonitor() {
        let entry = matches.indices.contains(selectedIndex) ? matches[selectedIndex] : nil
        // Dismiss first so a slow index refresh can't flash the list back open.
        clear()
        guard let entry else { return }
        onPick?(entry)
    }

    func moveSelection(delta: Int) {
        guard !matches.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), matches.count - 1)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActive else { return event }
            switch Int(event.keyCode) {
            case 126: // up
                guard !self.matches.isEmpty else { return event }
                Task { @MainActor in self.moveSelection(delta: -1) }
                return nil
            case 125: // down
                guard !self.matches.isEmpty else { return event }
                Task { @MainActor in self.moveSelection(delta: 1) }
                return nil
            case 48: // tab
                guard !self.matches.isEmpty else { return event }
                Task { @MainActor in self.applySelectedFromMonitor() }
                return nil
            case 36, 76: // return — while @ is open, never send the draft
                if event.modifierFlags.contains(.shift) { return event }
                if !self.matches.isEmpty {
                    Task { @MainActor in self.applySelectedFromMonitor() }
                }
                return nil
            case 53: // escape
                Task { @MainActor in
                    self.clear()
                    self.onDismiss?()
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    func teardown() {
        // Keep `entries` cached — wiping forced a cold index on the next `@`.
        clear()
    }
}

struct FileSuggestionList: View {
    @ObservedObject var controller: FileAutocompleteController
    var query: String
    var onSelect: (WorkspaceFileEntry) -> Void

    var body: some View {
        Group {
            if controller.matches.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(query.isEmpty ? "Indexing workspace…" : "No matching files")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(controller.matches.enumerated()), id: \.element.id) { index, entry in
                            Button {
                                onSelect(entry)
                            } label: {
                                HStack(alignment: .center, spacing: 10) {
                                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18, height: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        highlightedName(entry.name, query: query)
                                            .font(.system(size: 14, weight: .semibold))
                                        if !entry.parentPath.isEmpty {
                                            Text(entry.parentPath)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    if entry.isDirectory {
                                        Text("Folder")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
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
        // Highlight against the basename; if query has `/`, use the last segment.
        let needle = (q as NSString).lastPathComponent
        guard !needle.isEmpty, let range = name.range(of: needle, options: .caseInsensitive) else {
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
