import Foundation
import Observation

/// What holds the icon theme files are drawn with: `ShellStore`, which saves it as a setting.
@MainActor protocol FileIconSelecting: AnyObject {
    var fileIconTheme: String { get }
    func setFileIconTheme(_ id: String)
}

extension ShellStore: FileIconSelecting {}

/// Settings → Text Editor → File Icons: the VS Code icon themes installed from Open VSX by link
/// or ID, beside the one the app ships. Installing one uses it, and removing the one in use —
/// the app's own included — goes back to the app's symbols.
@MainActor @Observable final class FileIconSettingsViewModel {
    private(set) var extensions: [IconThemeLibrary.Extension] = []
    /// What is being installed or removed; nil when nothing is.
    private(set) var working: String?
    /// Why the last install or removal failed, until the link or the theme in use changes.
    private(set) var error: String?
    /// The link or ID typed in the install field.
    var link = "" {
        didSet { if link != oldValue { error = nil } }
    }
    private(set) var retired = false
    @ObservationIgnored private let library: IconThemeLibrary
    @ObservationIgnored private let store: FileIconStore
    /// Counts listings, so one that finishes after a newer one is dropped.
    @ObservationIgnored private var listing = 0

    init(library: IconThemeLibrary, store: FileIconStore) {
        self.library = library
        self.store = store
    }

    var themes: [IconThemeLibrary.Theme] { extensions.flatMap(\.themes) }
    /// Why the theme in use could not be loaded, if it could not.
    var themeError: String? { store.error }

    func refresh() async {
        guard !retired else { return }
        listing += 1
        let current = listing
        await store.prepare()
        let installed = await library.installed()
        guard !retired, current == listing else { return }
        extensions = installed
    }

    /// Uses another installed theme, or none for the empty ID.
    func choose(_ id: String, selection: some FileIconSelecting) {
        guard !retired else { return }
        error = nil
        selection.setFileIconTheme(id)
    }

    /// Installs what the install field names and uses its first theme.
    func install(selection: some FileIconSelecting) async {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !retired, working == nil, !text.isEmpty else { return }
        working = String(localized: "Installing…")
        error = nil
        defer { working = nil }
        // The bundled theme goes in first, and with it the clearing of cut-short installs.
        await store.prepare()
        let installed: IconThemeLibrary.Extension
        do { installed = try await library.install(openVSX: text) } catch {
            if !retired { self.error = error.localizedDescription }
            return
        }
        // Settings may have closed meanwhile; what was installed is used all the same.
        if installed.themes.contains(where: { $0.id == selection.fileIconTheme }) {
            store.select(selection.fileIconTheme, reload: true) // Reinstalled: read it again.
        } else if let first = installed.themes.first {
            selection.setFileIconTheme(first.id)
        }
        guard !retired else { return }
        link = ""
        await refresh()
    }

    /// Removes the extension of the theme in use, and goes back to the app's own symbols.
    func removeSelected(selection: some FileIconSelecting) async {
        guard !retired, working == nil,
              let installed = extensions.first(where: { $0.themes.contains { $0.id == selection.fileIconTheme } }) else { return }
        working = String(localized: "Removing \(installed.name)…")
        error = nil
        defer { working = nil }
        do { try await library.remove(installed.id) } catch {
            if !retired { self.error = error.localizedDescription }
            return
        }
        // Gone even if Settings closed meanwhile, so it is no longer in use either way.
        selection.setFileIconTheme("")
        guard !retired else { return }
        await refresh()
    }

    func retire() { retired = true }
}
