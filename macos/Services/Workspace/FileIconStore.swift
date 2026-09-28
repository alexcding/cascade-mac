import AppKit
import Observation

/// The file icon theme chosen in Settings, for every view that draws a file. `theme` is nil
/// while none is chosen or loaded, and views then keep their own symbols. Observable, so a view
/// that asked for an icon redraws when the theme changes.
@MainActor @Observable final class FileIconStore {
    static let shared = FileIconStore(library: .standard)

    private(set) var theme: FileIconTheme?
    /// The `fileIconTheme` setting last applied; empty for none.
    private(set) var selection = ""
    /// Why the chosen theme could not be loaded, if it could not.
    private(set) var error: String?
    @ObservationIgnored let library: IconThemeLibrary
    @ObservationIgnored private var images: [String: NSImage?] = [:]
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var preparing: Task<Void, Never>?

    init(library: IconThemeLibrary) {
        self.library = library
    }

    /// Installs the app's own theme the first time, once, before anything reads the library.
    func prepare() async {
        if preparing == nil { preparing = Task { [library] in await library.installBundledTheme() } }
        await preparing?.value
    }

    /// Loads the theme a `fileIconTheme` setting names; `reload` rereads it even if it is the
    /// one already shown, as after reinstalling it.
    func select(_ id: String, reload: Bool = false) {
        guard id != selection || reload else { return }
        selection = id
        loading?.cancel()
        guard !id.isEmpty else { show(nil, error: nil); return }
        loading = Task { [library] in
            await prepare()
            let result: Result<FileIconTheme, any Error>
            do { result = .success(try await library.theme(id)) } catch { result = .failure(error) }
            guard !Task.isCancelled, selection == id else { return }
            switch result {
            case .success(let theme): show(theme, error: nil)
            case .failure(let failure): show(nil, error: failure.localizedDescription)
            }
        }
    }

    /// The image the current theme gives a file of this name, loaded once per icon.
    func image(forFile name: String, light: Bool) -> NSImage? {
        guard let theme, let icon = theme.icon(forFile: name, light: light) else { return nil }
        if let image = images[icon] { return image }
        let image = theme.url(for: icon).flatMap(NSImage.init(contentsOf:))
        images[icon] = image
        return image
    }

    private func show(_ theme: FileIconTheme?, error: String?) {
        images = [:]
        self.theme = theme
        self.error = error
    }
}
