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
    private(set) var usageAgent: String
    private(set) var defaultAgent: SessionAgent
    private(set) var gitClient: String
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
    @ObservationIgnored var documentStyleChanged: () -> Void = {}
    @ObservationIgnored var terminalStyleChanged: () -> Void = {}
    private(set) var settingsError: String?
    private(set) var acknowledging: Set<String> = []
    @ObservationIgnored private var service: (any ShellDataServing)?
    @ObservationIgnored private var trayTask: Task<Void, Never>?
    @ObservationIgnored private var usageTask: Task<Void, Never>?
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var settingsWrite: Task<Void, Never>?
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var settingsRevision = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var pendingSettings: [String: String]
    @ObservationIgnored private var pendingReviewOpens: [String: (repo: String, number: Int)] = [:]

    public init(preferences: UserDefaults = .standard, notifications: NotificationStore? = nil) {
        self.notifications = notifications ?? NotificationStore()
        self.preferences = preferences
        pendingSettings = preferences.dictionary(forKey: "native.pendingSettings") as? [String: String] ?? [:]
        appearance = AppAppearance(rawValue: preferences.string(forKey: "native.theme") ?? "auto") ?? .system
        usageAgent = preferences.string(forKey: "native.usageAgent") == "codex" ? "codex" : "claude"
        defaultAgent = SessionAgent(rawValue: preferences.string(forKey: "native.defaultCli") ?? "claude") ?? .claude
        activityNotify = preferences.string(forKey: "native.activityNotify") != "off"
        reviewSound = preferences.string(forKey: "native.reviewSound") ?? "system"
        gitClient = preferences.string(forKey: "native.gitClient") ?? ""
        let command = preferences.string(forKey: "native.gitClientCmd") ?? ""
        gitClientCommand = command; gitClientCommandDraft = command
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
        // A saved name this build has no theme for reads as Default, as it does when synced.
        func savedTheme(_ key: String, dark: Bool) -> String {
            let name = preferences.string(forKey: "native.\(key)") ?? ""
            return CodeTheme.has(name, dark: dark) ? name : ""
        }
        editorStyle = EditorStyle(darkTheme: savedTheme("editorThemeDark", dark: true),
                                  lightTheme: savedTheme("editorThemeLight", dark: false),
                                  showMinimap: preferences.string(forKey: "native.editorMinimap") != "off")
    }

    private(set) var pendingReviews: [TrayPR] = []
    public var pendingReviewCount: Int { pendingReviews.count }

    public func applyAppearance() { onAction(.applyAppearance(appearance)) }

    func connect(_ service: any ShellDataServing) {
        generation += 1
        self.service = service
        let opened = pendingReviewOpens.values
        pendingReviewOpens.removeAll()
        for review in opened { acknowledgeReview(repo: review.repo, number: review.number) }
        for key in pendingSettings.keys.sorted() {
            if let value = pendingSettings[key] { saveSetting(key, value: value) }
        }
        refresh()
        loadSettings()
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

    // The view task supplies visibility/cancellation; scheduling stays in the model.
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
            } catch { if generation == currentGeneration { trayError = "Could not mark review opened: \(error.localizedDescription)" } }
        }
    }

    func setActivityNotify(_ enabled: Bool) {
        activityNotify = enabled
        let value = enabled ? "on" : "off"
        preferences.set(value, forKey: "native.activityNotify")
        saveSetting("activityNotify", value: value)
    }

    func setReviewSound(_ value: String) {
        reviewSound = value
        preferences.set(value, forKey: "native.reviewSound")
        saveSetting("reviewSound", value: value)
    }

    public func setAppearance(_ value: AppAppearance) {
        appearance = value
        preferences.set(value.rawValue, forKey: "native.theme")
        saveSetting("theme", value: value.rawValue)
    }

    func setUsageAgent(_ value: String) {
        usageAgent = value == "codex" ? "codex" : "claude"
        preferences.set(usageAgent, forKey: "native.usageAgent")
        saveSetting("usageAgent", value: usageAgent)
    }

    func setDefaultAgent(_ value: SessionAgent) {
        defaultAgent = value
        preferences.set(value.rawValue, forKey: "native.defaultCli")
        saveSetting("defaultCli", value: value.rawValue)
    }

    var gitClientCommandDirty: Bool { gitClientCommandDraft != gitClientCommand }
    func setGitClient(_ value: String) {
        guard value.isEmpty || value == "custom" || ExternalTool.gitClients.contains(where: { $0.id == value }) else { return }
        gitClient = value
        preferences.set(value, forKey: "native.gitClient")
        saveSetting("gitClient", value: value)
    }
    func saveGitClientCommand() {
        do {
            if !gitClientCommandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try WorkspaceLaunchCommand.tokenize(gitClientCommandDraft)
            }
            gitClientCommand = gitClientCommandDraft
            gitClientCommandError = nil
            preferences.set(gitClientCommand, forKey: "native.gitClientCmd")
            saveSetting("gitClientCmd", value: gitClientCommand)
        } catch { gitClientCommandError = error.localizedDescription }
    }
    func revertGitClientCommand() { gitClientCommandDraft = gitClientCommand; gitClientCommandError = nil }

    func font(_ kind: CodeFontKind) -> CodeFont { kind == .term ? terminalCodeFont : documentCodeFont }
    func setFont(_ kind: CodeFontKind, family: String? = nil, size: Int? = nil) {
        if let family, !CodeFont.validFamily(family) { settingsError = "The font family contains unsupported characters."; return }
        let previous = font(kind)
        let next = CodeFont(family: family ?? previous.family, size: size ?? previous.size)
        guard previous != next else { return }
        if kind == .term { terminalCodeFont = next } else { documentCodeFont = next }
        for (suffix, value, changed) in [("family", next.family, next.family != previous.family), ("size", String(next.size), next.size != previous.size)] where changed {
            let key = "\(kind.rawValue)_font_\(suffix)"
            preferences.set(value, forKey: "native.\(key)")
            saveSetting(key, value: value, debounce: true)
        }
    }

    /// Everything a terminal surface is configured from, assembled from the stored preferences.
    var terminalStyle: TerminalStyle {
        TerminalStyle(font: terminalCodeFont, thicken: terminalFontThicken,
                      thickenStrength: terminalFontThickenStrength,
                      darkTheme: terminalDarkTheme, lightTheme: terminalLightTheme,
                      keybinds: terminalKeybinds)
    }
    /// Replaces the whole list. A malformed entry is refused with the reason and nothing is
    /// stored; the caller keeps its drafts so the row can be fixed. Returns whether it applied.
    @discardableResult
    func setTerminalKeybinds(_ keybinds: [String]) -> Bool {
        settingsError = nil
        let cleaned = keybinds.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let bad = cleaned.first(where: { TerminalStyle.keybindProblem($0) != nil }) {
            settingsError = "Keybind “\(bad)”: \(TerminalStyle.keybindProblem(bad)!)"
            return false
        }
        guard cleaned != terminalKeybinds else { return true }
        terminalKeybinds = cleaned
        let value = TerminalStyle.keybindsSetting(cleaned)
        preferences.set(value, forKey: "native.terminalKeybinds")
        saveSetting("terminalKeybinds", value: value)
        return true
    }
    func setTerminalFontThicken(_ enabled: Bool) {
        guard enabled != terminalFontThicken else { return }
        terminalFontThicken = enabled
        preferences.set(enabled ? "on" : "off", forKey: "native.terminalThicken")
        saveSetting("terminalThicken", value: enabled ? "on" : "off")
    }
    func setTerminalFontThickenStrength(_ value: Int) {
        let next = TerminalStyle.clampThickenStrength(value)
        guard next != terminalFontThickenStrength else { return }
        terminalFontThickenStrength = next
        preferences.set(String(next), forKey: "native.terminalThickenStrength")
        saveSetting("terminalThickenStrength", value: String(next), debounce: true)
    }
    func setTerminalTheme(dark: String? = nil, light: String? = nil) {
        for (value, key, isDark) in [(dark, "terminalThemeDark", true), (light, "terminalThemeLight", false)] {
            guard let value, value != (isDark ? terminalDarkTheme : terminalLightTheme) else { continue }
            guard value.isEmpty || TerminalStyle.hasTheme(value) else {
                settingsError = "No terminal theme named \(value)."
                continue
            }
            if isDark { terminalDarkTheme = value } else { terminalLightTheme = value }
            preferences.set(value, forKey: "native.\(key)")
            saveSetting(key, value: value)
        }
    }
    func setEditorTheme(dark: String? = nil, light: String? = nil) {
        for (value, key, isDark) in [(dark, "editorThemeDark", true), (light, "editorThemeLight", false)] {
            guard let value, value != (isDark ? editorStyle.darkTheme : editorStyle.lightTheme) else { continue }
            guard value.isEmpty || CodeTheme.has(value, dark: isDark) else {
                settingsError = "No editor theme named \(value)."
                continue
            }
            if isDark { editorStyle.darkTheme = value } else { editorStyle.lightTheme = value }
            preferences.set(value, forKey: "native.\(key)")
            saveSetting(key, value: value)
        }
    }
    func setEditorMinimap(_ shown: Bool) {
        guard shown != editorStyle.showMinimap else { return }
        editorStyle.showMinimap = shown
        preferences.set(shown ? "on" : "off", forKey: "native.editorMinimap")
        saveSetting("editorMinimap", value: shown ? "on" : "off")
    }

    private func saveSetting(_ key: String, value: String, debounce: Bool = false) {
        pendingSettings[key] = value
        preferences.set(pendingSettings, forKey: "native.pendingSettings")
        settingsRevision += 1
        let revision = settingsRevision
        guard let service else { settingsError = "Preference saved locally; connect to sync it."; return }
        let previous = settingsWrite
        settingsWrite = Task {
            await previous?.value // Preserve rapid user changes in their original order.
            do {
                try Task.checkCancellation()
                if debounce {
                    guard pendingSettings[key] == value else { return }
                    try await Task.sleep(for: .milliseconds(250))
                    guard pendingSettings[key] == value else { return }
                }
                try await service.setSetting(key, value: value)
                if pendingSettings[key] == value {
                    pendingSettings.removeValue(forKey: key)
                    preferences.set(pendingSettings, forKey: "native.pendingSettings")
                }
                if settingsRevision == revision {
                    settingsError = pendingSettings.isEmpty ? nil : "Some preferences are saved locally; reconnect to sync them."
                }
            } catch { if !Task.isCancelled && settingsRevision == revision { settingsError = error.localizedDescription } }
        }
    }

    func loadSettings() {
        guard settingsTask == nil, let service else { return }
        let revision = settingsRevision
        settingsTask = Task {
            defer { settingsTask = nil }
            // Wait for our writes before accepting a snapshot of the settings.
            await settingsWrite?.value
            do {
                let settings: [String: String?] = try await service.settings()
                try Task.checkCancellation()
                guard revision == settingsRevision else { return }
                if pendingSettings["theme"] == nil {
                    appearance = AppAppearance(rawValue: (settings["theme"] ?? nil) ?? "auto") ?? .system
                }
                if pendingSettings["usageAgent"] == nil {
                    usageAgent = (settings["usageAgent"] ?? nil) == "codex" ? "codex" : "claude"
                }
                if pendingSettings["activityNotify"] == nil { activityNotify = (settings["activityNotify"] ?? nil) != "off" }
                if pendingSettings["reviewSound"] == nil { reviewSound = (settings["reviewSound"] ?? nil) ?? "system" }
                if pendingSettings["defaultCli"] == nil { defaultAgent = SessionAgent(rawValue: (settings["defaultCli"] ?? nil) ?? "claude") ?? .claude }
                if pendingSettings["gitClient"] == nil { gitClient = (settings["gitClient"] ?? nil) ?? "" }
                if pendingSettings["gitClientCmd"] == nil {
                    let dirty = gitClientCommandDirty
                    gitClientCommand = (settings["gitClientCmd"] ?? nil) ?? ""
                    if !dirty { gitClientCommandDraft = gitClientCommand }
                }
                for kind in CodeFontKind.allCases {
                    let previous = font(kind)
                    let familyKey = "\(kind.rawValue)_font_family", sizeKey = "\(kind.rawValue)_font_size"
                    let family = pendingSettings[familyKey] == nil ? (settings[familyKey] ?? nil) ?? "" : previous.family
                    let size = pendingSettings[sizeKey] == nil ? Int((settings[sizeKey] ?? nil) ?? "") ?? kind.defaultSize : previous.size
                    let value = CodeFont(family: family, size: size)
                    if kind == .term { terminalCodeFont = value } else { documentCodeFont = value }
                    preferences.set(value.family, forKey: "native.\(familyKey)")
                    preferences.set(String(value.size), forKey: "native.\(sizeKey)")
                }
                if pendingSettings["terminalThicken"] == nil { terminalFontThicken = (settings["terminalThicken"] ?? nil) != "off" }
                if pendingSettings["terminalThickenStrength"] == nil {
                    terminalFontThickenStrength = TerminalStyle.clampThickenStrength((settings["terminalThickenStrength"] ?? nil))
                }
                if pendingSettings["terminalThemeDark"] == nil { terminalDarkTheme = (settings["terminalThemeDark"] ?? nil) ?? "" }
                if pendingSettings["terminalThemeLight"] == nil { terminalLightTheme = (settings["terminalThemeLight"] ?? nil) ?? "" }
                if pendingSettings["terminalKeybinds"] == nil { terminalKeybinds = TerminalStyle.keybinds(fromSetting: settings["terminalKeybinds"] ?? nil) }
                // A name this build has no theme for reads as Default, so the picker always has a row for it.
                for (key, dark) in [("editorThemeDark", true), ("editorThemeLight", false)] where pendingSettings[key] == nil {
                    let stored = (settings[key] ?? nil) ?? "", name = CodeTheme.has(stored, dark: dark) ? stored : ""
                    if dark { editorStyle.darkTheme = name } else { editorStyle.lightTheme = name }
                }
                if pendingSettings["editorMinimap"] == nil { editorStyle.showMinimap = (settings["editorMinimap"] ?? nil) != "off" }
                preferences.set(appearance.rawValue, forKey: "native.theme")
                preferences.set(usageAgent, forKey: "native.usageAgent")
                preferences.set(activityNotify ? "on" : "off", forKey: "native.activityNotify")
                preferences.set(reviewSound, forKey: "native.reviewSound")
                preferences.set(defaultAgent.rawValue, forKey: "native.defaultCli")
                preferences.set(gitClient, forKey: "native.gitClient")
                preferences.set(gitClientCommand, forKey: "native.gitClientCmd")
                preferences.set(terminalFontThicken ? "on" : "off", forKey: "native.terminalThicken")
                preferences.set(String(terminalFontThickenStrength), forKey: "native.terminalThickenStrength")
                preferences.set(terminalDarkTheme, forKey: "native.terminalThemeDark")
                preferences.set(terminalLightTheme, forKey: "native.terminalThemeLight")
                // Written only once the key exists somewhere: an untouched install keeps
                // following the shipped defaults instead of freezing today's pair into prefs.
                if (settings["terminalKeybinds"] ?? nil) != nil || pendingSettings["terminalKeybinds"] != nil {
                    preferences.set(TerminalStyle.keybindsSetting(terminalKeybinds), forKey: "native.terminalKeybinds")
                }
                preferences.set(editorStyle.darkTheme, forKey: "native.editorThemeDark")
                preferences.set(editorStyle.lightTheme, forKey: "native.editorThemeLight")
                preferences.set(editorStyle.showMinimap ? "on" : "off", forKey: "native.editorMinimap")
                if pendingSettings.isEmpty { settingsError = nil }
            } catch { if !Task.isCancelled { settingsError = error.localizedDescription } }
        }
    }

    func stop() async {
        generation += 1
        acknowledging.removeAll()
        trayTask?.cancel(); usageTask?.cancel(); settingsTask?.cancel()
        await trayTask?.value; await usageTask?.value; await settingsTask?.value
        await settingsWrite?.value
        await notifications.stop()
        trayTask = nil; usageTask = nil; settingsTask = nil; settingsWrite = nil
        service = nil
    }
}
