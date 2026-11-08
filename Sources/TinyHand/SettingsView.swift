import AppKit
import ApplicationServices
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, agent, pointers, appearance, drawing, sound, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .agent: return "Agent"
        case .pointers: return "Pointers"
        case .appearance: return "Appearance"
        case .drawing: return "Drawing"
        case .sound: return "Sound"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .agent: return "terminal.fill"
        case .pointers: return "hand.point.up.left.fill"
        case .appearance: return "sparkles"
        case .drawing: return "pencil.tip"
        case .sound: return "speaker.wave.2.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(white: 0.55)
        case .agent: return Color(red: 0.2, green: 0.7, blue: 0.55)
        case .pointers: return Color(red: 0.55, green: 0.42, blue: 0.95)
        case .appearance: return Color(red: 0.95, green: 0.45, blue: 0.6)
        case .drawing: return Color(red: 0.96, green: 0.58, blue: 0.2)
        case .sound: return Color(red: 0.2, green: 0.55, blue: 0.98)
        case .about: return Color(white: 0.45)
        }
    }
}

final class SettingsModel: ObservableObject {
    @Published var section: SettingsSection = .general
    @Published var pinMessage: String?
    @Published private var revision = 0

    var applyToggleShortcut: ((Shortcut) -> Bool)?
    var applyClearShortcut: ((Shortcut) -> Bool)?
    var applySessionsShortcut: ((Shortcut) -> Bool)?
    var onRecording: ((Bool) -> Void)?
    var updater: Updater?
    @Published var shortcutError: String?

    private var observer: Any?
    private var handsObserver: Any?
    @Published var handMessage: String?

    init() {
        observer = NotificationCenter.default.addObserver(forName: Preferences.changed, object: nil, queue: .main) { [weak self] _ in
            self?.revision += 1
        }
        handsObserver = NotificationCenter.default.addObserver(forName: CustomHands.changed, object: nil, queue: .main) { [weak self] _ in
            self?.revision += 1
        }
        HandAsset.preloadThumbnails(PointerStyle.allCases.compactMap(\.assetName)) { [weak self] in
            self?.revision += 1
        }
    }

    struct HandDraft {
        let image: CGImage
        let ink: UInt32
    }

    @Published var makingHand = false
    @Published var handIdea = ""
    @Published var handName = ""
    @Published var draft: HandDraft?
    @Published var draftError: String?
    @Published var promptCopied = false

    func startMakingHand() {
        draft = nil
        draftError = nil
        promptCopied = false
        handMessage = nil
        makingHand = true
    }

    private var copiedReset: DispatchWorkItem?

    func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(HandMaker.prompt(for: handIdea), forType: .string)
        promptCopied = true
        copiedReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.promptCopied = false }
        copiedReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: reset)
    }

    func openChatGPT() {
        var parts = URLComponents(string: "https://chatgpt.com/")
        parts?.queryItems = [URLQueryItem(name: "q", value: HandMaker.prompt(for: handIdea))]
        if let url = parts?.url {
            NSWorkspace.shared.open(url)
        }
    }

    func chooseHandFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .webP, .image]
        panel.allowsMultipleSelection = false
        panel.message = "Pick the PNG of your hand"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        loadDraft(url)
    }

    func loadDraft(_ url: URL) {
        do {
            let made = try HandMaker.make(from: url)
            draft = HandDraft(image: made.image, ink: made.ink)
            draftError = nil
            handName = CustomHands.suggestedName(for: url)
        } catch let problem as HandMaker.Problem {
            draft = nil
            draftError = problem.message
        } catch {
            draft = nil
            draftError = "AiHand couldn't read that file."
        }
    }

    func saveDraft() {
        guard let draft = draft else {
            return
        }
        do {
            let style = try CustomHands.add(draft.image, ink: draft.ink, name: handName)
            if let name = style.assetName {
                _ = HandAsset.thumbnail(name)
            }
            var pinned = Preferences.pinnedStyles
            if pinned.count < Preferences.maxPinned {
                pinned.insert(style, at: max(0, pinned.count - (pinned.last == .laser ? 1 : 0)))
                Preferences.pinnedStyles = pinned
                handMessage = "\(style.title) is in your toolbar."
            } else {
                handMessage = "\(style.title) is ready. Click it to add it to the toolbar."
            }
            PointerStyle.saved = style
            NotificationCenter.default.post(name: Preferences.changed, object: nil)
            self.draft = nil
            handIdea = ""
            makingHand = false
        } catch {
            draftError = "AiHand couldn't save that hand."
        }
    }

    func removeHand(_ style: PointerStyle) {
        let pinned = Preferences.pinnedStyles.filter { $0 != style }
        Preferences.pinnedStyles = pinned.isEmpty ? PointerStyle.defaultPinned : pinned
        if PointerStyle.saved == style {
            PointerStyle.saved = .lavender
        }
        CustomHands.remove(style)
        handMessage = nil
        NotificationCenter.default.post(name: Preferences.changed, object: nil)
        revision += 1
    }

    func refresh() {
        revision += 1
    }

    func binding<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: get, set: { value in
            set(value)
            self.revision += 1
        })
    }

    private var previewSound: TapSound?

    func warmPreview() {
        if previewSound == nil {
            previewSound = TapSound()
        }
        previewSound?.warm()
    }

    func preview(_ choice: TapSoundChoice) {
        if previewSound == nil {
            previewSound = TapSound(choice)
        }
        previewSound?.load(choice)
        previewSound?.play()
    }

    @Published var dragging: PointerStyle?
    @Published private var draftOrder: [PointerStyle]?

    var pinnedOrder: [PointerStyle] {
        draftOrder ?? Preferences.pinnedStyles
    }

    private(set) var baseOrder: [PointerStyle] = []

    func beginDrag(_ style: PointerStyle) {
        dragging = style
        baseOrder = Preferences.pinnedStyles
        draftOrder = baseOrder
        pinMessage = nil
    }

    func setDraft(_ order: [PointerStyle]) {
        guard order != draftOrder else {
            return
        }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            draftOrder = order
        }
    }

    func cancelDrag() {
        draftOrder = nil
        dragging = nil
    }

    func resetToolbar() {
        pinMessage = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            Preferences.pinnedStyles = PointerStyle.defaultPinned
        }
    }

    func resetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings?"
        alert.informativeText = "Shortcuts, toolbar pointers, size, shadow, drawing and sound go back to how they were at first. Open at login and Accessibility stay as they are."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        Preferences.resetAll()
        _ = applyToggleShortcut?(.toggleDefault)
        _ = applyClearShortcut?(.clearDefault)
        _ = applySessionsShortcut?(.sessionsDefault)
        shortcutError = nil
        pinMessage = nil
        revision += 1
    }

    func endDrag() {
        if let order = draftOrder {
            Preferences.pinnedStyles = order
        }
        draftOrder = nil
        dragging = nil
    }

    func pin(_ style: PointerStyle) {
        var pinned = Preferences.pinnedStyles
        if pinned.contains(style) {
            unpin(style)
            return
        }
        if pinned.count >= Preferences.maxPinned {
            pinMessage = "The toolbar is full. Remove one above to add \(style.title)."
            return
        }
        pinned.append(style)
        pinMessage = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            Preferences.pinnedStyles = pinned
        }
    }

    func swap(_ old: PointerStyle, for new: PointerStyle) {
        var pinned = Preferences.pinnedStyles
        guard let i = pinned.firstIndex(of: old), !pinned.contains(new) else {
            return
        }
        pinned[i] = new
        pinMessage = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            Preferences.pinnedStyles = pinned
        }
    }

    func unpin(_ style: PointerStyle) {
        var pinned = Preferences.pinnedStyles
        guard let i = pinned.firstIndex(of: style) else {
            return
        }
        if pinned.count == 1 {
            pinMessage = "Keep at least one pointer in the toolbar."
            return
        }
        pinned.remove(at: i)
        pinMessage = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            Preferences.pinnedStyles = pinned
        }
    }

}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            page
        }
        .ignoresSafeArea()
        .frame(minWidth: 760, minHeight: 540)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                SidebarRow(section: section, selected: model.section == section) {
                    model.section = section
                }
            }
            Spacer()
            HStack(spacing: 8) {
                if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                }
                Text("AiHand").font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
        }
        .padding(.top, 52)
        .padding(.horizontal, 10)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(VisualEffect(material: .sidebar))
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if model.section == .pointers && model.makingHand {
                    Button {
                        model.makingHand = false
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                            Text("Pointers").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .padding(.bottom, -14)
                }
                Text(model.section == .pointers && model.makingHand ? "Make your own hand" : model.section.title)
                    .font(.system(size: 22, weight: .bold))
                    .padding(.top, 6)
                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 48)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch model.section {
        case .general: GeneralPage(model: model)
        case .agent: AgentPage(model: model)
        case .pointers:
            if model.makingHand {
                MakeHandPage(model: model)
            } else {
                PointersPage(model: model)
            }
        case .appearance: AppearancePage(model: model)
        case .drawing: DrawingPage(model: model)
        case .sound: SoundPage(model: model)
        case .about: AboutPage(model: model)
        }
    }
}

private struct GeneralPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !AXIsProcessTrusted() {
                Card(title: "Permission") {
                    Row("Accessibility", detail: "Needed so clicks become taps and you can draw.") {
                        PillButton(title: "Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
            Card(title: "Shortcuts") {
                Row("Turn the pointer on or off") {
                    ShortcutField(shortcut: Preferences.toggleShortcut, model: model) { model.applyToggleShortcut?($0) ?? false }
                }
                Row("Clear the drawing") {
                    ShortcutField(shortcut: Preferences.clearShortcut, model: model) { model.applyClearShortcut?($0) ?? false }
                }
                Row("Open AI sessions panel", detail: "Shows the AI sessions panel without turning the pointer on.") {
                    ShortcutField(shortcut: Preferences.sessionsShortcut, model: model) { model.applySessionsShortcut?($0) ?? false }
                }
            }
            if let error = model.shortcutError {
                Text(error).font(.system(size: 12)).foregroundColor(.red)
            }
            Card(title: "Clicking for real") {
                Row("Hold to use the app", detail: "Clicks, drags and scrolls reach the app.") {
                    Picker("", selection: model.binding({ Preferences.interactKey }, { Preferences.interactKey = $0 })) {
                        ForEach(InteractKey.allCases, id: \.self) { key in
                            Text(key.title).tag(key)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .focusable(false)
                }
                if Preferences.interactKey != .off {
                    Row("While holding", detail: Preferences.interactKeepsHand ? "The hand stays, in menus too." : "The normal cursor comes back, in menus too.") {
                        Picker("", selection: model.binding({ Preferences.interactKeepsHand }, { Preferences.interactKeepsHand = $0 })) {
                            Text("Show the cursor").tag(false)
                            Text("Keep the hand").tag(true)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .focusable(false)
                    }
                }
            }
            Card(title: "Screenshots") {
                Row("Save annotated captures to", detail: Preferences.screenshotsFolder) {
                    PillButton(title: "Choose…") {
                        Preferences.ensureScreenshotsFolder()
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.directoryURL = URL(fileURLWithPath: Preferences.screenshotsFolder)
                        panel.prompt = "Choose"
                        if panel.runModal() == .OK, let url = panel.url {
                            Preferences.screenshotsFolder = url.path
                        }
                    }
                }
            }
            Card(title: "Startup") {
                Row("Open AiHand when you log in") {
                    Toggle("", isOn: model.binding({ Preferences.launchAtLogin }, { Preferences.launchAtLogin = $0 }))
                        .toggleStyle(.switch).labelsHidden().focusable(false)
                }
                if let updater = model.updater {
                    Row("Check for updates automatically") {
                        Toggle("", isOn: model.binding({ updater.automaticallyChecks }, { updater.automaticallyChecks = $0 }))
                            .toggleStyle(.switch).labelsHidden().focusable(false)
                    }
                }
            }
        }
        .onAppear {
            Preferences.ensureScreenshotsFolder()
        }
    }
}

private struct AgentPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Card(title: "CLI") {
                Row("Agent CLI", detail: "Cursor Agent, Claude Code, or Codex. Draw freely, then press Enter to comment or ⌘↩ to send.") {
                    Picker("", selection: model.binding({ Preferences.agentCLI }, { Preferences.agentCLI = $0 })) {
                        ForEach(AgentCLIKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .focusable(false)
                }
            }
            Card(title: "Favorites") {
                AgentFavoritesBlock(model: model)
                    .id(Preferences.agentCLI.rawValue)
            }
            Card(title: "Workspace") {
                WorkspaceFoldersBlock()
            }
        }
    }
}

private struct AgentFavoritesBlock: View {
    @ObservedObject var model: SettingsModel
    @State private var families: [AgentModelFamily] = []
    @State private var draftTitle = ""
    @State private var draftFamilyId = ""
    @State private var draftVariantId = ""
    @State private var refreshing = false
    @State private var isAdding = false
    @State private var titleEdited = false

    private var cli: AgentCLIKind { Preferences.agentCLI }
    private var favorites: [AgentFavorite] { Preferences.favorites(for: cli) }
    private var currentID: UUID { Preferences.currentAgentFavorite.id }
    private var titleFilled: Bool {
        !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedFamily: AgentModelFamily? {
        families.first(where: { $0.id == draftFamilyId }) ?? families.first
    }

    private var selectedVariant: AgentModelVariant? {
        guard let family = selectedFamily else { return nil }
        return family.variants.first(where: { $0.id == draftVariantId }) ?? family.variants.first
    }

    private var suggestedTitle: String {
        guard let family = selectedFamily, let variant = selectedVariant else { return "" }
        if variant.title == "Default" { return family.title }
        return "\(family.title) / \(variant.title)"
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(favorites.enumerated()), id: \.element.id) { index, fav in
                AgentFavoriteRow(
                    favorite: fav,
                    isCurrent: fav.id == currentID,
                    canRemove: !fav.isBuiltIn && favorites.count > 1,
                    onSelect: { Preferences.selectAgentFavorite(fav.id) },
                    onRemove: { Preferences.removeAgentFavorite(fav.id) }
                )
                if index < favorites.count - 1 {
                    divider
                }
            }

            divider

            if isAdding {
                newFavoriteForm
            } else {
                Row(
                    "Add a \(cli.title) preset",
                    detail: "Favorites are per CLI — this list is only for \(cli.title)."
                ) {
                    PillButton(title: "Add favorite") {
                        isAdding = true
                        titleEdited = false
                        refreshModels(force: false)
                    }
                }
            }
        }
        .onAppear {
            Preferences.ensureAgentFavorites()
            if isAdding {
                refreshModels(force: false)
            }
        }
    }

    private var newFavoriteForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("New favorite")
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                TextButton(title: "Cancel") {
                    isAdding = false
                    resetDraft()
                }
            }

            PlainField(
                placeholder: "Title — e.g. Image Gen, Docs",
                text: Binding(
                    get: { draftTitle },
                    set: {
                        draftTitle = $0
                        titleEdited = true
                    }
                ),
                solidBackground: true
            )

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Picker("", selection: $draftFamilyId) {
                        if families.isEmpty {
                            Text("Loading…").tag("")
                        }
                        ForEach(families) { family in
                            Text(family.title).tag(family.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusable(false)
                    .onChange(of: draftFamilyId) { _ in
                        syncVariantToFamily()
                        applySuggestedTitleIfNeeded()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Effort")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Picker("", selection: $draftVariantId) {
                        if let family = selectedFamily {
                            ForEach(family.variants) { variant in
                                Text(variant.title).tag(variant.id)
                            }
                        } else {
                            Text("—").tag("")
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 120, alignment: .leading)
                    .focusable(false)
                    .onChange(of: draftVariantId) { _ in
                        applySuggestedTitleIfNeeded()
                    }
                }
            }

            HStack(alignment: .center, spacing: 10) {
                if let variant = selectedVariant {
                    Text(variant.modelId)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                TextButton(title: refreshing ? "Refreshing…" : "Refresh models") {
                    refreshModels(force: true)
                }
                .fixedSize()
                PillButton(
                    title: "Add favorite",
                    enabled: titleFilled,
                    disabledHelp: "Must fill in title"
                ) { addFavorite() }
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
            .padding(.leading, 14)
    }

    private func syncVariantToFamily() {
        guard let family = selectedFamily else {
            draftVariantId = ""
            return
        }
        if !family.variants.contains(where: { $0.id == draftVariantId }) {
            // Prefer High when available, else first.
            draftVariantId = family.variants.first(where: { $0.title == "High" })?.id
                ?? family.variants.first?.id
                ?? ""
        }
    }

    private func applySuggestedTitleIfNeeded() {
        guard !titleEdited else { return }
        draftTitle = suggestedTitle
    }

    private func refreshModels(force: Bool) {
        refreshing = true
        let kind = cli
        DispatchQueue.global(qos: .userInitiated).async {
            let list = AgentModelCatalog.families(for: kind, forceRefresh: force)
            DispatchQueue.main.async {
                families = list
                if draftFamilyId.isEmpty || !list.contains(where: { $0.id == draftFamilyId }) {
                    draftFamilyId = list.first?.id ?? ""
                }
                syncVariantToFamily()
                applySuggestedTitleIfNeeded()
                refreshing = false
            }
        }
    }

    private func resetDraft() {
        titleEdited = false
        draftFamilyId = families.first?.id ?? ""
        syncVariantToFamily()
        draftTitle = suggestedTitle
    }

    private func addFavorite() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              let family = selectedFamily,
              let variant = selectedVariant else { return }
        let modelTitle: String
        if variant.title == "Default" {
            modelTitle = family.title
        } else {
            modelTitle = "\(family.title) · \(variant.title)"
        }
        Preferences.addAgentFavorite(
            AgentFavorite(
                title: title,
                cliKind: cli,
                modelId: variant.modelId,
                modelTitle: modelTitle,
                effort: variant.effort
            )
        )
        isAdding = false
        resetDraft()
    }
}

private struct AgentFavoriteRow: View {
    let favorite: AgentFavorite
    let isCurrent: Bool
    var canRemove: Bool = true
    let onSelect: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundColor(isCurrent ? Color(red: 0.2, green: 0.55, blue: 0.98) : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(favorite.title).font(.system(size: 13)).foregroundColor(.primary)
                            if isCurrent {
                                Text("Current")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                            }
                        }
                        Text(favorite.detail)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(isCurrent ? "Current favorite for new sessions" : "Use for new sessions")

            if canRemove, hovering || !isCurrent {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0.06)))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Remove favorite")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .background(Color.primary.opacity(hovering ? 0.03 : 0))
        .onHover { hovering = $0 }
    }
}

private struct WorkspaceFoldersBlock: View {
    private var folders: [String] { Preferences.agentWorkspaces }
    private var current: String { Preferences.agentWorkspace }

    var body: some View {
        VStack(spacing: 0) {
            if folders.isEmpty {
                Row("Folders for the agent", detail: "Add at least one. New sessions use the current folder.") {
                    PillButton(title: "Add…") { addFolder() }
                }
            } else {
                ForEach(Array(folders.enumerated()), id: \.element) { index, path in
                    WorkspaceFolderRow(
                        path: path,
                        isCurrent: path == current,
                        onSelect: { Preferences.selectAgentWorkspace(path) },
                        onRemove: { Preferences.removeAgentWorkspace(path) }
                    )
                    if index < folders.count - 1 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.07))
                            .frame(height: 1)
                            .padding(.leading, 14)
                    }
                }
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)
                    .padding(.leading, 14)
                Row("Add another folder", detail: "Sessions use the folder marked Current.") {
                    PillButton(title: "Add…") { addFolder() }
                }
            }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            Preferences.addAgentWorkspace(url.path)
        }
    }
}

private struct WorkspaceFolderRow: View {
    let path: String
    let isCurrent: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    private var title: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundColor(isCurrent ? Color(red: 0.2, green: 0.55, blue: 0.98) : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title).font(.system(size: 13)).foregroundColor(.primary)
                            if isCurrent {
                                Text("Current")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                            }
                        }
                        Text(path)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(isCurrent ? "Current working folder" : "Use as current working folder")

            if hovering || !isCurrent {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0.06)))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Remove folder")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .background(Color.primary.opacity(hovering ? 0.03 : 0))
        .onHover { hovering = $0 }
    }
}

private struct PointersPage: View {
    @ObservedObject var model: SettingsModel
    @State private var rowFrame: CGRect = .zero
    @State private var dragX: CGFloat = 0
    @State private var dragStart = 0
    @State private var floating: Floating?
    @State private var picking = false

    struct Floating {
        let style: PointerStyle
        let point: CGPoint
        let badge: String?
    }

    private var step: CGFloat {
        (rowFrame.width - 20 + 6) / CGFloat(Preferences.maxPinned)
    }

    private func overRow(_ p: CGPoint) -> Bool {
        rowFrame.insetBy(dx: -16, dy: -28).contains(p)
    }

    private func slot(at x: CGFloat, count: Int) -> Int {
        min(max(Int((x - rowFrame.minX - 10) / step), 0), max(0, count - 1))
    }

    private func rowDrag(_ value: DragGesture.Value) {
        let start = CGPoint(x: rowFrame.minX + value.startLocation.x, y: rowFrame.minY + value.startLocation.y)
        let p = CGPoint(x: rowFrame.minX + value.location.x, y: rowFrame.minY + value.location.y)
        if model.dragging == nil {
            let base = Preferences.pinnedStyles
            let i = Int((start.x - rowFrame.minX - 10) / step)
            guard start.x >= rowFrame.minX + 10, base.indices.contains(i) else {
                return
            }
            dragStart = i
            model.beginDrag(base[i])
        }
        guard let style = model.dragging else {
            return
        }
        var order = model.baseOrder.filter { $0 != style }
        if overRow(p) {
            dragX = value.translation.width
            order.insert(style, at: slot(at: p.x, count: order.count + 1))
            floating = nil
        } else if model.baseOrder.count > 1 {
            floating = Floating(style: style, point: p, badge: "minus.circle.fill")
        } else {
            order = model.baseOrder
            floating = Floating(style: style, point: p, badge: nil)
        }
        model.setDraft(order)
    }

    private func dropDrag() {
        let removing = floating?.badge == "minus.circle.fill"
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            dragX = 0
            if floating != nil && !removing {
                model.cancelDrag()
                model.pinMessage = "Keep at least one pointer in the toolbar."
            } else {
                model.endDrag()
            }
            floating = nil
        }
    }

    private func offset(_ style: PointerStyle) -> CGFloat {
        guard model.dragging == style, floating == nil, let i = model.pinnedOrder.firstIndex(of: style) else {
            return 0
        }
        return dragX - CGFloat(i - dragStart) * step
    }

    var body: some View {
        let pinned = model.pinnedOrder
        let full = Preferences.pinnedStyles.count >= Preferences.maxPinned
        VStack(alignment: .leading, spacing: 30) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("In your toolbar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    TextButton(title: "Reset") { model.resetToolbar() }
                }
                .padding(.horizontal, 4)
                HStack(spacing: 6) {
                    ForEach(pinned, id: \.self) { style in
                        let lifted = model.dragging == style
                        ToolbarSlot(style: style, model: model, lifted: lifted)
                            .offset(x: offset(style))
                            .zIndex(lifted ? 1 : 0)
                            .transaction { if lifted { $0.animation = nil } }
                    }
                    if !full {
                        AddSlot(open: $picking)
                            .popover(isPresented: $picking, arrowEdge: .bottom) {
                                PointerPicker(model: model) { picking = false }
                            }
                    }
                    ForEach(0..<max(0, Preferences.maxPinned - pinned.count - 1), id: \.self) { _ in
                        EmptySlot()
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { rowFrame = g.frame(in: .named("pointersPage")) }
                        .onChange(of: g.frame(in: .named("pointersPage"))) { rowFrame = $0 }
                })
                .coordinateSpace(name: "toolbarRow")
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .named("toolbarRow"))
                        .onChanged { rowDrag($0) }
                        .onEnded { _ in dropDrag() }
                )
                Text(full
                     ? "The toolbar is full. Remove a pointer to add another. Drag to reorder."
                     : "Press + to add a pointer. Drag to reorder, or out to remove.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                if let message = model.pinMessage {
                    Text(message).font(.system(size: 12)).foregroundColor(.red).padding(.horizontal, 4)
                }
            }
            YourHands(model: model)
        }
        .coordinateSpace(name: "pointersPage")
        .overlay(alignment: .topLeading) {
            if let f = floating {
                FloatingPointer(style: f.style, badge: f.badge)
                    .position(f.point)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct AddSlot: View {
    @Binding var open: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(hovering || open ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(hovering || open ? 0.09 : 0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Add a pointer")
        .onHover { hovering = $0 }
    }
}

private struct PointerPicker: View {
    @ObservedObject var model: SettingsModel
    let done: () -> Void
    private let columns = [GridItem(.adaptive(minimum: 64, maximum: 72), spacing: 4)]

    var body: some View {
        let pinned = Set(Preferences.pinnedStyles)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section(nil, PointerStyle.builtInHands + [.laser], pinned)
                    if !PointerStyle.customHands.isEmpty {
                        section("Your hands", PointerStyle.customHands, pinned)
                    }
                }
                .padding(12)
            }
            .frame(height: 340)
            Divider()
            Button {
                done()
                model.startMakingHand()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars").font(.system(size: 11))
                    Text("Make your own hand…").font(.system(size: 12))
                    Spacer()
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
        .frame(width: 400)
    }

    private func section(_ title: String?, _ styles: [PointerStyle], _ pinned: Set<PointerStyle>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = title {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary).padding(.leading, 4)
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(styles, id: \.self) { style in
                    PickerCell(style: style, added: pinned.contains(style)) {
                        guard !pinned.contains(style) else {
                            return
                        }
                        model.pin(style)
                        done()
                    }
                }
            }
        }
    }
}

private struct PickerCell: View {
    let style: PointerStyle
    let added: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let icon = pointerIcon(style) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 42, height: 42)
                }
            }
            .frame(width: 62, height: 58)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering && !added ? 0.08 : 0))
            )
            .opacity(added ? 0.35 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(added ? "\(style.title) is already in the toolbar" : style.title)
        .onHover { hovering = $0 }
    }
}

private struct YourHands: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your hands")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                TextButton(title: "Make your own…") { model.startMakingHand() }
            }
            .padding(.horizontal, 4)
            if PointerStyle.customHands.isEmpty {
                Text("Turn any idea into a hand with ChatGPT or another image tool.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            } else {
                HStack(spacing: 6) {
                    ForEach(PointerStyle.customHands, id: \.self) { style in
                        CustomHandChip(style: style, model: model)
                    }
                }
            }
            if let message = model.handMessage {
                Text(message).font(.system(size: 11)).foregroundColor(.secondary).padding(.horizontal, 4)
            }
        }
    }
}

private struct CustomHandChip: View {
    let style: PointerStyle
    @ObservedObject var model: SettingsModel
    @State private var hovering = false
    @State private var swapping = false

    var body: some View {
        let pinned = Preferences.pinnedStyles.contains(style)
        let full = Preferences.pinnedStyles.count >= Preferences.maxPinned
        HStack(spacing: 6) {
            if let icon = pointerIcon(style) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 24, height: 24)
            }
            Text(style.title).font(.system(size: 12)).lineLimit(1)
            Button {
                model.removeHand(style)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0)))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .opacity(hovering ? 1 : 0)
            .help("Delete \(style.title)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(hovering && !pinned ? 0.09 : 0.05)))
        .contentShape(Capsule())
        .onTapGesture {
            guard !pinned else {
                return
            }
            if full {
                swapping = true
            } else {
                model.pin(style)
            }
        }
        .onHover { hovering = $0 }
        .help(pinned ? "\(style.title) is in your toolbar" : "Click to add \(style.title) to the toolbar")
        .popover(isPresented: $swapping, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("The toolbar is full. Swap \(style.title) in for:")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                HStack(spacing: 4) {
                    ForEach(Preferences.pinnedStyles, id: \.self) { old in
                        SwapCell(style: old) {
                            model.swap(old, for: style)
                            swapping = false
                        }
                    }
                }
            }
            .padding(12)
        }
    }
}

private struct SwapCell: View {
    let style: PointerStyle
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let icon = pointerIcon(style) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 32, height: 32)
                }
            }
            .frame(width: 44, height: 44)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(hovering ? 0.1 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Replace \(style.title)")
        .onHover { hovering = $0 }
    }
}
private struct FloatingPointer: View {
    let style: PointerStyle
    let badge: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let icon = pointerIcon(style) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 40, height: 40)
                }
            }
            .frame(width: 58, height: 58)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
            )
            if let badge = badge {
                Image(systemName: badge)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white, badge == "nosign" ? Color.gray : Color.red)
                    .offset(x: 6, y: -6)
            }
        }
        .scaleEffect(1.06)
    }
}

private struct ToolbarSlot: View {
    let style: PointerStyle
    @ObservedObject var model: SettingsModel
    let lifted: Bool
    @State private var hovering = false

    var body: some View {
        slot
    }

    private var slot: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let icon = pointerIcon(style) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 40, height: 40)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                    .shadow(color: .black.opacity(lifted ? 0.22 : 0.08), radius: lifted ? 10 : 2, y: lifted ? 4 : 1)
            )
            .scaleEffect(lifted ? 1.06 : 1)
            if hovering && model.dragging == nil {
                Button {
                    model.unpin(style)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Remove from the toolbar")
                .offset(x: 5, y: -5)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(style.title)
    }
}

private struct EmptySlot: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.035))
            .frame(maxWidth: .infinity)
            .frame(height: 58)
    }
}

private struct AppearancePage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Card(title: "Pointer") {
            Row("Size") {
                HStack(spacing: 10) {
                    Image(systemName: "hand.point.up.left.fill").font(.system(size: 10)).foregroundColor(.secondary)
                    Slider(value: model.binding({ Double(Preferences.pointerSize) }, { Preferences.pointerSize = CGFloat($0) }),
                           in: Double(Preferences.pointerSizeRange.lowerBound)...Double(Preferences.pointerSizeRange.upperBound))
                        .frame(width: 180)
                        .focusable(false)
                    Image(systemName: "hand.point.up.left.fill").font(.system(size: 16)).foregroundColor(.secondary)
                }
            }
            Row("Shadow under the pointer") {
                Toggle("", isOn: model.binding({ Preferences.showShadow }, { Preferences.showShadow = $0 }))
                    .toggleStyle(.switch).labelsHidden().focusable(false)
            }
        }
    }
}

private struct DrawingPage: View {
    @ObservedObject var model: SettingsModel
    private static let choices: [(String, Double)] = [
        ("After 3 seconds", 3),
        ("After 6 seconds", 6),
        ("After 10 seconds", 10),
        ("Keep until cleared", 0),
    ]

    var body: some View {
        Card(title: "Ink") {
            Row("Ink colour", detail: Preferences.inkChoice == .match ? "Matches each pointer." : "All pointers draw in \(Preferences.inkChoice.title.lowercased()).") {
                HStack(spacing: 8) {
                    ForEach(InkChoice.allCases, id: \.self) { choice in
                        InkSwatch(choice: choice, selected: Preferences.inkChoice == choice) {
                            Preferences.inkChoice = choice
                            model.refresh()
                        }
                    }
                }
            }
            Row("Lines fade", detail: "Clear them any time with \(Preferences.clearShortcut.display).") {
                Picker("", selection: model.binding({ Preferences.fadeSeconds }, { Preferences.fadeSeconds = $0 })) {
                    ForEach(DrawingPage.choices, id: \.1) { choice in
                        Text(choice.0).tag(choice.1)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .focusable(false)
            }
            Row("Ink button in the toolbar", detail: "Change the colour while you present.") {
                Toggle("", isOn: model.binding({ Preferences.showInkButton }, { Preferences.showInkButton = $0 }))
                    .toggleStyle(.switch).labelsHidden().focusable(false)
            }
        }
    }
}

private struct SoundPage: View {
    @ObservedObject var model: SettingsModel
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 8)]

    var body: some View {
        let on = Preferences.handSound
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tap sound")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                LazyVGrid(columns: columns, spacing: 8) {
                    SoundTile(title: "Off", symbol: "speaker.slash.fill", selected: !on) {
                        Preferences.handSound = false
                        model.refresh()
                    }
                    ForEach(TapSoundChoice.allCases, id: \.self) { choice in
                        SoundTile(title: choice.title, symbol: "waveform", selected: on && Preferences.tapSound == choice) {
                            Preferences.tapSound = choice
                            Preferences.handSound = true
                            model.preview(choice)
                            model.refresh()
                        }
                    }
                }
                Text("Click a sound to hear it. It plays each time the hand taps.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }
            Card(title: nil) {
                Row("Laser dot taps too", detail: "Off by default, for quiet pointing.") {
                    Toggle("", isOn: model.binding({ Preferences.laserSound }, { Preferences.laserSound = $0 }))
                        .toggleStyle(.switch).labelsHidden().focusable(false)
                        .disabled(!on)
                }
            }
            .opacity(on ? 1 : 0.5)
        }
        .onAppear { model.warmPreview() }
    }
}

private struct InkSwatch: View {
    let choice: InkChoice
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let color = choice.color {
                    Circle().fill(Color(cgColor: color))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(choice == .black ? 0.35 : 0.15), lineWidth: 1))
                } else {
                    Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .blue, .purple, .red], center: .center))
                }
            }
            .frame(width: 20, height: 20)
            .padding(3)
            .overlay(Circle().strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2))
            .scaleEffect(hovering && !selected ? 1.08 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(choice.title)
        .onHover { hovering = $0 }
    }
}

private struct SoundTile: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(selected ? .accentColor : .secondary)
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(hovering ? 0.07 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

private struct AboutPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 72, height: 72)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("AiHand").font(.system(size: 18, weight: .bold))
                    Text("Version \(version)").font(.system(size: 12)).foregroundColor(.secondary)
                    Text("A tiny (AI) hand for your Mac. Free and open source.").font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
                if let updater = model.updater {
                    PillButton(title: "Check for Updates") { updater.checkForUpdates() }
                }
            }
            Card(title: nil) {
                LinkRow(title: "Website", detail: "tinyhand.app", url: "https://tinyhand.app")
                LinkRow(title: "Source code", detail: "github.com/nilbuild/tinyhand", url: "https://github.com/nilbuild/tinyhand")
                LinkRow(title: "Made by", detail: "@nilbuild on X", url: "https://x.com/nilbuild")
                LinkRow(title: "License", detail: "MIT", url: "https://github.com/nilbuild/tinyhand/blob/main/LICENSE")
            }
            HStack {
                Spacer()
                TextButton(title: "Reset all settings…") { model.resetAll() }
            }
        }
    }
}

private struct SidebarRow: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: section.symbol, tint: section.tint)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.1 : hovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

private struct IconTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom))
            .frame(width: 24, height: 24)
            .overlay(Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundColor(.white))
    }
}

private struct Card<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                _VariadicView.Tree(Separated()) {
                    content
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
        }
    }
}

private struct Separated: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
        }
    }
}

private struct Row<Trailing: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let trailing: Trailing

    init(_ title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail = detail {
                    Text(detail).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

private struct LinkRow: View {
    let title: String
    let detail: String
    let url: String
    @State private var hovering = false

    var body: some View {
        Button {
            if let u = URL(string: url) {
                NSWorkspace.shared.open(u)
            }
        } label: {
            HStack {
                Text(title).font(.system(size: 13)).foregroundColor(.primary)
                Spacer()
                Text(detail).font(.system(size: 12)).foregroundColor(.secondary)
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Color.primary.opacity(hovering ? 0.04 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

private struct TextButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(hovering ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

private struct PillButton: View {
    let title: String
    var enabled: Bool = true
    var disabledHelp: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(Color.primary.opacity(enabled ? (hovering ? 0.14 : 0.09) : 0.05))
                )
                .foregroundColor(enabled ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!enabled)
        .help(enabled ? "" : (disabledHelp ?? ""))
        .onHover { hovering = $0 }
    }
}

private struct MakeHandPage: View {
    @ObservedObject var model: SettingsModel
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Step(number: 1, title: "Describe it", detail: "What should your hand look like?") {
                PlainField(placeholder: "e.g. knitted wool in mustard yellow", text: $model.handIdea)
                    .frame(maxWidth: 420)
            }
            Step(number: 2, title: "Make the image", detail: "Open it in ChatGPT, or copy the prompt for another image tool. Download the result as a PNG with a transparent background.") {
                HStack(spacing: 8) {
                    PrimaryButton(title: "Open in ChatGPT", symbol: "arrow.up.right") { model.openChatGPT() }
                    PrimaryButton(title: model.promptCopied ? "Copied" : "Copy prompt", symbol: model.promptCopied ? "checkmark" : "doc.on.doc", primary: false) {
                        model.copyPrompt()
                    }
                }
            }
            Step(number: 3, title: "Add it", detail: nil) {
                if let draft = model.draft {
                    preview(draft)
                } else {
                    dropZone
                }
            }
        }
    }

    private var dropZone: some View {
        Button {
            model.chooseHandFile()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: model.draftError == nil ? "square.and.arrow.down" : "exclamationmark.triangle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(model.draftError == nil ? .secondary : .orange)
                Text(model.draftError ?? "Drop the PNG here, or click to choose it")
                    .font(.system(size: 12))
                    .foregroundColor(model.draftError == nil ? .secondary : .primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if model.draftError != nil {
                    Text("Try again with another image")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .frame(height: 130)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(dropping ? 0.07 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(dropping ? Color.accentColor : Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard let provider = providers.first else {
                return false
            }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else {
                    return
                }
                DispatchQueue.main.async { model.loadDraft(url) }
            }
            return true
        }
    }

    private func preview(_ draft: SettingsModel.HandDraft) -> some View {
        HStack(alignment: .center, spacing: 22) {
            Image(nsImage: NSImage(cgImage: draft.image.cropping(to: CGRect(x: 112, y: 90, width: 800, height: 1000)) ?? draft.image, size: NSSize(width: 144, height: 180)))
                .resizable()
                .interpolation(.high)
                .frame(width: 144, height: 180)
                .padding(.vertical, 10)
                .frame(width: 170)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 0.91, green: 0.81, blue: 0.71))
                )
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                    PlainField(placeholder: "My hand", text: Binding(get: { model.handName }, set: { model.handName = String($0.prefix(16)) }))
                        .frame(width: 220)
                }
                Text("It should show the back of the hand, like the ones in AiHand. If you see the palm, try another image.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300, alignment: .leading)
                HStack(spacing: 10) {
                    PrimaryButton(title: "Add hand", symbol: nil) { model.saveDraft() }
                    TextButton(title: "Use another image") { model.chooseHandFile() }
                }
            }
        }
    }
}

private struct Step<Content: View>: View {
    let number: Int
    let title: String
    let detail: String?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(0.75)))
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let detail = detail {
                        Text(detail).font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
        }
    }
}

private struct PlainField: View {
    let placeholder: String
    @Binding var text: String
    var solidBackground: Bool = false
    @FocusState private var focused: Bool

    private var borderColor: Color {
        if solidBackground && focused {
            return Color(red: 0.2, green: 0.55, blue: 0.98)
        }
        return Color.primary.opacity(solidBackground ? 0.45 : 0.1)
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(solidBackground ? Color(nsColor: .textBackgroundColor) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: solidBackground && focused ? 1.5 : 1)
            )
            .modifier(NoFocusEffect())
    }
}

private struct NoFocusEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

private struct PrimaryButton: View {
    let title: String
    let symbol: String?
    var primary = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol = symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14, height: 14)
                }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(primary ? .white : .primary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(primary
                ? Color.accentColor.opacity(hovering ? 0.88 : 1)
                : Color.primary.opacity(hovering ? 0.14 : 0.09)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}
private struct ShortcutField: NSViewRepresentable {
    let shortcut: Shortcut
    let model: SettingsModel
    let apply: (Shortcut) -> Bool

    func makeNSView(context: Context) -> ShortcutRecorder {
        let r = ShortcutRecorder(shortcut: shortcut)
        r.onRecording = { model.onRecording?($0) }
        r.onChange = { s in
            let ok = apply(s)
            model.shortcutError = ok ? nil : "\(s.display) is already used by another app. Pick a different shortcut."
            return ok
        }
        return r
    }

    func updateNSView(_ nsView: ShortcutRecorder, context: Context) {
        nsView.show(shortcut)
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        if emphasized {
            v.appearance = NSAppearance(named: .vibrantDark)
        }
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
        nsView.state = .active
        if emphasized {
            nsView.appearance = NSAppearance(named: .vibrantDark)
        }
    }
}

private let blankIcon = NSImage(size: NSSize(width: 64, height: 64))

private func pointerIcon(_ style: PointerStyle) -> NSImage? {
    guard let name = style.assetName else {
        return Toolbar.icon(for: style)
    }
    return HandAsset.cachedThumbnail(name) ?? blankIcon
}
