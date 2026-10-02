import Foundation
import Observation

/// What the address field is searching in the worktree: the typed text and the files matching it.
/// One per workspace context; the field opens a match itself (`BrowserAddressSuggestions`). The root is handed in with each query rather than stored, because
/// the session that names the worktree belongs to the app, not to the context.
@MainActor @Observable final class FileSearchViewModel {
    struct Result: Identifiable, Equatable {
        /// Absolute, so it opens as is.
        let path: String
        /// Worktree-relative, as listed.
        let relative: String
        var id: String { path }
        var name: String { (relative as NSString).lastPathComponent }
        var folder: String { (relative as NSString).deletingLastPathComponent }
    }
    var query = "" { didSet { if oldValue != query { edited = true } } }
    private(set) var results: [Result] = []
    /// False until the text is typed into: focusing the field must not list the whole worktree.
    private(set) var edited = false
    private(set) var retired = false
    /// Resolved per search, so a reconnect is picked up without rebuilding the model.
    @ObservationIgnored var service: () -> (any FileSearchService)? = { nil }
    @ObservationIgnored private var task: Task<Void, Never>? { didSet { oldValue?.cancel() } }

    /// Once per keystroke, from the view's `onChange`; never from a body.
    func search(in root: String?) {
        guard !retired else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard edited, !text.isEmpty, !text.hasPrefix("/"), let root, !root.isEmpty, let service = service() else {
            task = nil; results = []; return
        }
        task = Task { [weak self] in
            // Typing settles before the worktree is listed.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            // A failed listing clears the list: the last query's matches must not sit under new text.
            let files = (try? await service.files(in: root, matching: text)) ?? []
            guard !Task.isCancelled else { return }
            self?.results = files.map { .init(path: (root as NSString).appendingPathComponent($0), relative: $0) }
        }
    }

    /// Leaving the field drops the text: a file tab shows its file, never a stale query.
    func reset() {
        task = nil; results = []; query = ""; edited = false
    }

    func retire() { retired = true; reset() }
}
