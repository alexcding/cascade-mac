import Foundation
import Observation

// Independent tasks keep a slow usage source out of the PR/sidebar refresh path.
@MainActor @Observable public final class ShellStore {
    enum Action { case applyAppearance(AppAppearance) }
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    @ObservationIgnored var actionBinding = UUID()
    public let notifications: NotificationStore
    private(set) var activityNotify: Bool
    private(set) var reviewSound: String
    private(set) var prs: [TrayPR] = []
    private(set) var trayError: String?
    private(set) var trayLoading = false
    private(set) var trayUpdated: Date?
    private(set) var usage: UsageSnapshot?
    private(set) var usageError: String?
    private(set) var usageLoading = false
    public private(set) var appearance: AppAppearance {
        didSet { if oldValue != appearance { documentStyleChanged(); applyAppearance() } }
    }
    /// Settings → Appearance: the window's backdrop, under the sidebar alone or every column.
    /// Terminals follow it.
    private(set) var windowBackdrop: WindowBackdrop {
        didSet {
            guard oldValue != windowBackdrop else { return }
            windowBackgroundChanged()
            if oldValue.isTranslucent != windowBackdrop.isTranslucent { terminalStyleChanged() }
        }
    }
    private(set) var usageAgent: String
    private(set) var defaultAgent: SessionAgent
    private(set) var gitClient: String
    /// The installed icon theme files are drawn with, as `<extension>/<theme>`; empty for none.
    private(set) var fileIconTheme: String {
        didSet { if oldValue != fileIconTheme { fileIcons?.select(fileIconTheme) } }
    }
    private(set) var gitClientCommand: String
    var gitClientCommandDraft: String
    private(set) var gitClientCommandError: String?
    private(set) var terminalCodeFont: CodeFont {
        didSet { if oldValue != terminalCodeFont { terminalStyleChanged() } }
    }
    private(set) var terminalFontThicken: Bool {
        didSet { if oldValue != terminalFontThicken { terminalStyleChanged() } }
    }
    private(set) var terminalFontThickenStrength: Int {
        didSet { if oldValue != terminalFontThickenStrength { terminalStyleChanged() } }
    }
    private(set) var terminalDarkTheme: String {
        didSet { if oldValue != terminalDarkTheme { terminalStyleChanged() } }
    }
    private(set) var terminalLightTheme: String {
        didSet { if oldValue != terminalLightTheme { terminalStyleChanged() } }
    }
    private(set) var terminalKeybinds: [String] {
        didSet { if oldValue != terminalKeybinds { terminalStyleChanged() } }
    }
    private(set) var documentCodeFont: CodeFont {
        didSet { if oldValue != documentCodeFont { documentStyleChanged() } }
    }
    /// The file editor's themes and preview; the code font beside them is `documentCodeFont`.
    private(set) var editorStyle: EditorStyle {
        didSet { if oldValue != editorStyle { documentStyleChanged() } }
    }
    /// Settings → Terminal: what the sessions' agents may hold before the least recently used idle
    /// one is stopped.
    private(set) var sessionMemoryLimit: MemoryLimit {
        didSet { if oldValue != sessionMemoryLimit { memoryLimitsChanged() } }
    }
    /// Settings → Browser: what web pages may hold before the least recently viewed hidden one is
    /// suspended.
    private(set) var pageMemoryLimit: MemoryLimit {
        didSet { if oldValue != pageMemoryLimit { memoryLimitsChanged() } }
    }
    @ObservationIgnored var documentStyleChanged: () -> Void = {}
    @ObservationIgnored var terminalStyleChanged: () -> Void = {}
    @ObservationIgnored var windowBackgroundChanged: () -> Void = {}
    @ObservationIgnored var memoryLimitsChanged: () -> Void = {}
    private(set) var settingsError: String?
    private(set) var acknowledging: Set<String> = []
    @ObservationIgnored private var service: (any ShellDataServing)?
    @ObservationIgnored private var trayTask: Task<Void, Never>?
    @ObservationIgnored private var usageTask: Task<Void, Never>?
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let preferences: UserDefaults
    /// Where the chosen icon theme is loaded for the app's views; nil where nothing draws files.
    @ObservationIgnored private let fileIcons: FileIconStore?
    @ObservationIgnored private var pendingReviewOpens: [String: (repo: String, number: Int)] = [:]

    init(preferences: UserDefaults = .standard, notifications: NotificationStore? = nil, fileIcons: FileIconStore? = nil) {
        self.notifications = notifications ?? NotificationStore()
        self.preferences = preferences
        self.fileIcons = fileIcons
        // The code minimap's switch, from before the editor dropped it.
        preferences.removeObject(forKey: "native.editorMinimap")
        let saved = SavedPreferences(preferences)
        appearance = saved.appearance
        windowBackdrop = saved.windowBackdrop
        usageAgent = saved.usageAgent
        defaultAgent = saved.defaultAgent
        activityNotify = saved.activityNotify
        reviewSound = saved.reviewSound
        gitClient = saved.gitClient
        fileIconTheme = saved.fileIconTheme
        gitClientCommand = saved.gitClientCommand; gitClientCommandDraft = saved.gitClientCommand
        terminalCodeFont = saved.terminalCodeFont; documentCodeFont = saved.documentCodeFont
        terminalFontThicken = saved.terminalFontThicken
        terminalFontThickenStrength = saved.terminalFontThickenStrength
        terminalDarkTheme = saved.terminalDarkTheme
        terminalLightTheme = saved.terminalLightTheme
        terminalKeybinds = saved.terminalKeybinds
        sessionMemoryLimit = saved.sessionMemoryLimit
        pageMemoryLimit = saved.pageMemoryLimit
        editorStyle = saved.editorStyle
        fileIcons?.select(fileIconTheme)
    }

    /// Re-reads every preference-backed value, after the one-time import wrote what an earlier
    /// version kept in the backend. The observers propagate what changed; an edited git client
    /// command draft is kept.
    private func reloadPreferences() {
        let saved = SavedPreferences(preferences)
        let draftClean = gitClientCommandDraft == gitClientCommand
        appearance = saved.appearance
        windowBackdrop = saved.windowBackdrop
        usageAgent = saved.usageAgent
        defaultAgent = saved.defaultAgent
        activityNotify = saved.activityNotify
        reviewSound = saved.reviewSound
        gitClient = saved.gitClient
        fileIconTheme = saved.fileIconTheme
        gitClientCommand = saved.gitClientCommand
        if draftClean { gitClientCommandDraft = saved.gitClientCommand }
        terminalCodeFont = saved.terminalCodeFont; documentCodeFont = saved.documentCodeFont
        terminalFontThicken = saved.terminalFontThicken
        terminalFontThickenStrength = saved.terminalFontThickenStrength
        terminalDarkTheme = saved.terminalDarkTheme
        terminalLightTheme = saved.terminalLightTheme
        terminalKeybinds = saved.terminalKeybinds
        sessionMemoryLimit = saved.sessionMemoryLimit
        pageMemoryLimit = saved.pageMemoryLimit
        editorStyle = saved.editorStyle
    }

    /// Every preference-backed value, read from `UserDefaults` in one place: what `init` starts
    /// from and what a one-time import re-reads.
    private struct SavedPreferences {
        let appearance: AppAppearance
        let windowBackdrop: WindowBackdrop
        let usageAgent: String
        let defaultAgent: SessionAgent
        let activityNotify: Bool
        let reviewSound: String
        let gitClient: String
        let fileIconTheme: String
        let gitClientCommand: String
        let terminalCodeFont: CodeFont
        let documentCodeFont: CodeFont
        let terminalFontThicken: Bool
        let terminalFontThickenStrength: Int
        let terminalDarkTheme: String
        let terminalLightTheme: String
        let terminalKeybinds: [String]
        let sessionMemoryLimit: MemoryLimit
        let pageMemoryLimit: MemoryLimit
        let editorStyle: EditorStyle

        init(_ preferences: UserDefaults) {
            appearance = AppAppearance(rawValue: preferences.string(forKey: "native.theme") ?? "auto") ?? .system
            windowBackdrop = WindowBackdrop(
                isTranslucent: preferences.string(forKey: "native.windowTranslucent") == "on",
                opacity: WindowBackdrop.clampOpacity(preferences.string(forKey: "native.windowBackdropOpacity")))
            usageAgent = AgentDrivers.driver(for: preferences.string(forKey: "native.usageAgent")).cli
            defaultAgent = preferences.string(forKey: "native.defaultCli").flatMap(SessionAgent.init(rawValue:)) ?? .primary
            activityNotify = preferences.string(forKey: "native.activityNotify") != "off"
            reviewSound = preferences.string(forKey: "native.reviewSound") ?? "system"
            gitClient = preferences.string(forKey: "native.gitClient") ?? ""
            // Never chosen: the bundled theme. Chosen None: empty.
            fileIconTheme = preferences.string(forKey: "native.fileIconTheme") ?? IconThemeLibrary.bundledTheme
            gitClientCommand = preferences.string(forKey: "native.gitClientCmd") ?? ""
            func savedFont(_ kind: CodeFontKind) -> CodeFont {
                CodeFont(kind, settings: ["\(kind.rawValue)_font_family": preferences.string(forKey: "native.\(kind.rawValue)_font_family") ?? "",
                                         "\(kind.rawValue)_font_size": preferences.string(forKey: "native.\(kind.rawValue)_font_size") ?? String(kind.defaultSize)])
            }
            terminalCodeFont = savedFont(.term); documentCodeFont = savedFont(.diff)
            // Thickening defaults on: without it libghostty renders noticeably thinner than the
            // standalone Ghostty app, which is the state this setting exists to correct.
            terminalFontThicken = preferences.string(forKey: "native.terminalThicken") != "off"
            terminalFontThickenStrength = TerminalStyle.clampThickenStrength(preferences.string(forKey: "native.terminalThickenStrength"))
            terminalDarkTheme = preferences.string(forKey: "native.terminalThemeDark") ?? ""
            terminalLightTheme = preferences.string(forKey: "native.terminalThemeLight") ?? ""
            terminalKeybinds = TerminalStyle.keybinds(fromSetting: preferences.string(forKey: "native.terminalKeybinds"))
            sessionMemoryLimit = MemoryLimit(setting: preferences.string(forKey: "native.sessionMemoryLimit"))
            pageMemoryLimit = MemoryLimit(setting: preferences.string(forKey: "native.pageMemoryLimit"))
            // A saved name this build has no theme for reads as Default, as it does when synced.
            func savedTheme(_ key: String, dark: Bool) -> String {
                let name = preferences.string(forKey: "native.\(key)") ?? ""
                return CodeTheme.has(name, dark: dark) ? name : ""
            }
            editorStyle = EditorStyle(darkTheme: savedTheme("editorThemeDark", dark: true),
                                      lightTheme: savedTheme("editorThemeLight", dark: false))
        }
    }

    private(set) var pendingReviews: [TrayPR] = []
    public var pendingReviewCount: Int { pendingReviews.count }

    public func applyAppearance() { onAction(.applyAppearance(appearance)) }

    /// Whether the preferences an earlier version kept in the backend are still to be adopted.
    var needsLegacyPreferenceImport: Bool { !preferences.bool(forKey: "native.legacyPreferencesImported") }

    /// The preference keys the backend's settings table used to hold for the app, as `SavedPreferences`
    /// reads them. The table also held page-tab snapshots and the backend's own settings, which
    /// are not preferences and are left where they are.
    private static let importedPreferenceKeys: Set<String> = [
        "theme", "usageAgent", "defaultCli", "activityNotify", "reviewSound", "gitClient", "fileIconTheme",
        "gitClientCmd", "term_font_family", "term_font_size", "diff_font_family", "diff_font_size",
        "terminalThicken", "terminalThickenStrength", "terminalThemeDark", "terminalThemeLight", "terminalKeybinds",
        "sessionMemoryLimit", "pageMemoryLimit", "editorThemeDark", "editorThemeLight",
    ]

    /// Adopts, once, what an earlier version kept in the backend: the boards' assignee filters,
    /// which lived only there, and every other preference for which this Mac has no value of its
    /// own. Those were mirrored here as they were set, so on the Mac they were set on nothing
    /// changes; a data directory carried to a new Mac brings its theme, fonts and terminal
    /// settings along, as it did when the backend was read on every connect.
    func importLegacyPreferences(_ settings: [String: String?]) {
        guard needsLegacyPreferenceImport else { return }
        var adopted = false
        for (key, value) in settings {
            // An empty icon theme is a choice, "None"; an empty anything else is nothing to adopt.
            guard let value, !value.isEmpty || key == "fileIconTheme" else { continue }
            let local: String
            if key.hasPrefix("board_filter_") {
                local = "native.boardFilter.\(key.dropFirst("board_filter_".count))"
            } else if Self.importedPreferenceKeys.contains(key) {
                local = "native.\(key)"
            } else {
                continue
            }
            if preferences.string(forKey: local) == nil {
                preferences.set(value, forKey: local)
                adopted = true
            }
        }
        preferences.set(true, forKey: "native.legacyPreferencesImported")
        if adopted { reloadPreferences() }
    }

    func connect(_ service: any ShellDataServing) {
        generation += 1
        self.service = service
        let opened = pendingReviewOpens.values
        pendingReviewOpens.removeAll()
        for review in opened { acknowledgeReview(repo: review.repo, number: review.number) }
        refresh()
    }

    func refresh() {
        refreshPending = true
        guard trayTask == nil, let service else { return }
        trayLoading = true
        trayTask = Task {
            defer { trayTask = nil; trayLoading = false }
            while refreshPending && !Task.isCancelled {
                refreshPending = false
                do {
                    try await loadReviews(from: service)
                } catch { if !Task.isCancelled { trayError = error.localizedDescription } }
            }
        }
    }

    private func loadReviews(from service: any ShellDataServing) async throws {
        let result = try await service.reviews()
        try Task.checkCancellation()
        var seen: Set<String> = []
        let prs = result.filter { seen.insert($0.id).inserted }
        if self.prs != prs { self.prs = prs }
        let pending = prs.filter(\.pendingReview)
        if pendingReviews != pending { pendingReviews = pending }
        notifications.receiveReviews(prs, sound: reviewSound)
        trayError = nil
        trayUpdated = Date()
    }

    func refreshUsage() {
        guard usageTask == nil, let service else { return }
        usageLoading = true
        usageTask = Task {
            defer { usageTask = nil; usageLoading = false }
            do {
                let value: UsageSnapshot = try await service.usage()
                try Task.checkCancellation()
                usage = value
                usageError = nil
            } catch { if !Task.isCancelled { usageError = error.localizedDescription } }
        }
    }

    /// The window the menu-bar item shows for the agent the usage panel follows: the session, or the
    /// week on a plan with no session limit (some Codex plans report only a weekly window).
    var menuBarUsage: (window: UsageSnapshot.Window, weekly: Bool)? {
        let limits = usage?.limits(of: usageAgent)
        if let session = limits?.session { return (session, false) }
        return limits?.weekly.map { ($0, true) }
    }

    // The app's task supplies cancellation; scheduling stays in the model.
    func watchUsage() async {
        while !Task.isCancelled {
            refreshUsage()
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }

    func acknowledge(_ pr: TrayPR) {
        guard pr.pendingReview else { return }
        acknowledgeReview(repo: pr.repo, number: pr.number)
    }

    public func acknowledgeReview(repo: String, number: Int) {
        let id = "\(repo)#\(number)"
        guard let service else {
            // A notification click can launch the app before backend readiness.
            pendingReviewOpens[id] = (repo, number)
            return
        }
        guard acknowledging.insert(id).inserted else { return }
        let currentGeneration = generation
        Task {
            defer { if generation == currentGeneration { acknowledging.remove(id) } }
            do {
                try await service.acknowledgeReview(repo: repo, number: number)
                guard generation == currentGeneration else { return }
                if let index = prs.firstIndex(where: { $0.id == id }) { prs[index].reviewPending = false }
                pendingReviews.removeAll { $0.id == id }
                refresh()
            } catch { if generation == currentGeneration { trayError = String(localized: "Could not mark review opened: \(error.localizedDescription)") } }
        }
    }

    func setActivityNotify(_ enabled: Bool) {
        activityNotify = enabled
        let value = enabled ? "on" : "off"
        preferences.set(value, forKey: "native.activityNotify")
        settingsError = nil
    }

    func setReviewSound(_ value: String) {
        reviewSound = value
        preferences.set(value, forKey: "native.reviewSound")
        settingsError = nil
    }

    public func setAppearance(_ value: AppAppearance) {
        appearance = value
        preferences.set(value.rawValue, forKey: "native.theme")
        settingsError = nil
    }

    func setWindowTranslucent(_ enabled: Bool) {
        guard enabled != windowBackdrop.isTranslucent else { return }
        windowBackdrop.isTranslucent = enabled
        preferences.set(enabled ? "on" : "off", forKey: "native.windowTranslucent")
        settingsError = nil
    }

    func setWindowBackdropOpacity(_ value: Double) {
        let next = WindowBackdrop.clampOpacity(value)
        guard next != windowBackdrop.opacity else { return }
        windowBackdrop.opacity = next
        preferences.set(String(next), forKey: "native.windowBackdropOpacity")
        settingsError = nil
    }

    func setUsageAgent(_ value: String) {
        usageAgent = AgentDrivers.driver(for: value).cli
        preferences.set(usageAgent, forKey: "native.usageAgent")
        settingsError = nil
    }

    func setDefaultAgent(_ value: SessionAgent) {
        defaultAgent = value
        preferences.set(value.rawValue, forKey: "native.defaultCli")
        settingsError = nil
    }

    var gitClientCommandDirty: Bool { gitClientCommandDraft != gitClientCommand }
    func setGitClient(_ value: String) {
        guard value.isEmpty || value == "custom" || ExternalTool.gitClients.contains(where: { $0.id == value }) else { return }
        gitClient = value
        preferences.set(value, forKey: "native.gitClient")
        settingsError = nil
    }
    /// Draws files with an installed icon theme, `<extension>/<theme>`, or with none when empty.
    func setFileIconTheme(_ id: String) {
        fileIconTheme = id
        preferences.set(id, forKey: "native.fileIconTheme")
        settingsError = nil
    }
    func saveGitClientCommand() {
        do {
            if !gitClientCommandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try WorkspaceLaunchCommand.tokenize(gitClientCommandDraft)
            }
            gitClientCommand = gitClientCommandDraft
            gitClientCommandError = nil
            preferences.set(gitClientCommand, forKey: "native.gitClientCmd")
            settingsError = nil
        } catch { gitClientCommandError = error.localizedDescription }
    }
    func revertGitClientCommand() { gitClientCommandDraft = gitClientCommand; gitClientCommandError = nil }

    func font(_ kind: CodeFontKind) -> CodeFont { kind == .term ? terminalCodeFont : documentCodeFont }
    func setFont(_ kind: CodeFontKind, family: String? = nil, size: Int? = nil) {
        if let family, !CodeFont.validFamily(family) { settingsError = String(localized: "The font family contains unsupported characters."); return }
        let previous = font(kind)
        let next = CodeFont(family: family ?? previous.family, size: size ?? previous.size)
        guard previous != next else { return }
        if kind == .term { terminalCodeFont = next } else { documentCodeFont = next }
        for (suffix, value, changed) in [("family", next.family, next.family != previous.family), ("size", String(next.size), next.size != previous.size)] where changed {
            let key = "\(kind.rawValue)_font_\(suffix)"
            preferences.set(value, forKey: "native.\(key)")
            settingsError = nil
        }
    }

    /// Everything a terminal surface is configured from, assembled from the stored preferences.
    var terminalStyle: TerminalStyle {
        TerminalStyle(font: terminalCodeFont, thicken: terminalFontThicken,
                      thickenStrength: terminalFontThickenStrength,
                      darkTheme: terminalDarkTheme, lightTheme: terminalLightTheme,
                      keybinds: terminalKeybinds,
                      backgroundOpacity: windowBackdrop.isTranslucent ? 0 : 1)
    }
    /// Replaces the whole list. A malformed entry is refused with the reason and nothing is
    /// stored; the caller keeps its drafts so the row can be fixed. Returns whether it applied.
    @discardableResult
    func setTerminalKeybinds(_ keybinds: [String]) -> Bool {
        settingsError = nil
        let cleaned = keybinds.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let bad = cleaned.first(where: { TerminalStyle.keybindProblem($0) != nil }) {
            settingsError = String(localized: "Keybind “\(bad)”: \(TerminalStyle.keybindProblem(bad)!)")
            return false
        }
        guard cleaned != terminalKeybinds else { return true }
        terminalKeybinds = cleaned
        let value = TerminalStyle.keybindsSetting(cleaned)
        preferences.set(value, forKey: "native.terminalKeybinds")
        settingsError = nil
        return true
    }
    func setSessionMemoryLimit(_ value: MemoryLimit) {
        guard value != sessionMemoryLimit else { return }
        sessionMemoryLimit = value
        preferences.set(value.rawValue, forKey: "native.sessionMemoryLimit")
        settingsError = nil
    }
    func setPageMemoryLimit(_ value: MemoryLimit) {
        guard value != pageMemoryLimit else { return }
        pageMemoryLimit = value
        preferences.set(value.rawValue, forKey: "native.pageMemoryLimit")
        settingsError = nil
    }
    func setTerminalFontThicken(_ enabled: Bool) {
        guard enabled != terminalFontThicken else { return }
        terminalFontThicken = enabled
        preferences.set(enabled ? "on" : "off", forKey: "native.terminalThicken")
        settingsError = nil
    }
    func setTerminalFontThickenStrength(_ value: Int) {
        let next = TerminalStyle.clampThickenStrength(value)
        guard next != terminalFontThickenStrength else { return }
        terminalFontThickenStrength = next
        preferences.set(String(next), forKey: "native.terminalThickenStrength")
        settingsError = nil
    }
    func setTerminalTheme(dark: String? = nil, light: String? = nil) {
        for (value, key, isDark) in [(dark, "terminalThemeDark", true), (light, "terminalThemeLight", false)] {
            guard let value, value != (isDark ? terminalDarkTheme : terminalLightTheme) else { continue }
            guard value.isEmpty || TerminalStyle.hasTheme(value) else {
                settingsError = String(localized: "No terminal theme named \(value).")
                continue
            }
            if isDark { terminalDarkTheme = value } else { terminalLightTheme = value }
            preferences.set(value, forKey: "native.\(key)")
            settingsError = nil
        }
    }
    func setEditorTheme(dark: String? = nil, light: String? = nil) {
        for (value, key, isDark) in [(dark, "editorThemeDark", true), (light, "editorThemeLight", false)] {
            guard let value, value != (isDark ? editorStyle.darkTheme : editorStyle.lightTheme) else { continue }
            guard value.isEmpty || CodeTheme.has(value, dark: isDark) else {
                settingsError = String(localized: "No editor theme named \(value).")
                continue
            }
            if isDark { editorStyle.darkTheme = value } else { editorStyle.lightTheme = value }
            preferences.set(value, forKey: "native.\(key)")
            settingsError = nil
        }
    }

    func stop() async {
        generation += 1
        acknowledging.removeAll()
        trayTask?.cancel(); usageTask?.cancel()
        await trayTask?.value; await usageTask?.value
        await notifications.stop()
        trayTask = nil; usageTask = nil
        service = nil
    }
}
