import Foundation

/// The sidebar's saved tabs: the pages kept open beside the sessions. Window state, so the app's
/// own: one JSON file in the shape the backend used to answer with (`{"tabs":[…],"active":…}`),
/// so a list an earlier version left in the backend is adopted as it is, once, on the first
/// connect. Every change is written whole; the list is small and the file is the truth.
@MainActor final class TabStore {
    /// The file: the list, and whether the list an earlier version kept in the backend has been
    /// adopted into it. A tab opened before that import lands writes the file too, so the file
    /// alone is not proof; the flag is.
    private struct File: Codable {
        let tabs: [SavedTab]
        let active: String?
        var imported: Bool? = nil
    }

    private(set) var saved = SavedTabs(tabs: [], active: nil)
    /// Why the last write failed, for the app to show; nil while writes succeed.
    private(set) var lastError: String?
    private let fileURL: URL?
    /// True until the backend's list has been adopted: the first connect imports it.
    private(set) var needsImport = true

    init(fileURL: URL?) {
        self.fileURL = fileURL
        // No file: nothing saved on this Mac yet, and the backend's list is adopted on connect.
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            // A file this build wrote that no longer reads. The import happened; adopting the
            // backend's old list again would bury every tab opened or closed since. The file is
            // kept aside for a look, and the list starts empty.
            needsImport = false
            lastError = String(localized: "The saved tabs could not be read and were set aside.")
            let aside = fileURL.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            return
        }
        saved = SavedTabs(tabs: file.tabs, active: file.active)
        needsImport = !(file.imported ?? false)
    }

    var tabs: [SavedTab] { saved.tabs }

    /// Takes over what an earlier version kept in the backend, once. Tabs opened here before the
    /// import landed stay, after the imported ones.
    func adopt(_ imported: SavedTabs) {
        guard needsImport else { return }
        let known = Set(imported.tabs.map(\.id))
        let tabs = imported.tabs + saved.tabs.filter { !known.contains($0.id) }
        saved = SavedTabs(tabs: tabs, active: saved.active ?? imported.active)
        needsImport = false
        write()
    }

    /// Opening a page always makes a new tab: the same URL may be open several times. A request
    /// carrying an id (a draft tab getting its first address) keeps it. The opened tab is active.
    func open(_ request: OpenPageRequest) throws -> SavedTabs {
        guard safeWebURL(request.url) != nil else {
            throw BackendError.operation(String(localized: "A web address is required to open a tab."))
        }
        guard ["github", "issue", "jira", "web"].contains(request.kind) else {
            throw BackendError.operation(String(localized: "Unknown tab kind: \(request.kind)"))
        }
        let id = request.id.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString.lowercased()
        var tabs = saved.tabs
        if !tabs.contains(where: { $0.id == id }) {
            // A page that has not said its title yet is listed by its address, as before.
            tabs.append(SavedTab(id: id, kind: request.kind, title: request.title.isEmpty ? request.url : request.title, url: request.url,
                                 category: request.category, paneView: "term", login: request.login,
                                 standalone: request.inTab))
        }
        return commit(tabs, active: id)
    }

    /// A title change alone.
    func rename(_ id: String, title: String) -> SavedTabs {
        var tabs = saved.tabs
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return saved }
        tabs[index].title = title
        return commit(tabs, active: saved.active)
    }

    /// Pins a tab into the grid under Dashboard, or returns it to the Tabs list.
    func pin(_ id: String, _ pinned: Bool) -> SavedTabs {
        var tabs = saved.tabs
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return saved }
        tabs[index].pinned = pinned
        return commit(tabs, active: saved.active)
    }

    /// Places the listed tabs first, in the given order; tabs not listed keep their relative order
    /// after them. Unknown ids are ignored, and a repeated id keeps its first place.
    func reorder(_ order: [String]) -> SavedTabs {
        var ordered: [SavedTab] = []
        for id in order + saved.tabs.map(\.id) {
            guard let tab = saved.tabs.first(where: { $0.id == id }), !ordered.contains(where: { $0.id == id }) else { continue }
            ordered.append(tab)
        }
        return commit(ordered, active: saved.active)
    }

    func close(_ id: String) -> SavedTabs {
        commit(saved.tabs.filter { $0.id != id }, active: saved.active == id ? nil : saved.active)
    }

    private func commit(_ tabs: [SavedTab], active: String?) -> SavedTabs {
        saved = SavedTabs(tabs: tabs, active: active)
        write()
        return saved
    }

    private func write() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(File(tabs: saved.tabs, active: saved.active, imported: !needsImport)).write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = String(localized: "Could not save tabs: \(error.localizedDescription)")
        }
    }
}
