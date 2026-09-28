import Foundation

/// The VS Code icon theme extensions installed in Settings. Each is unpacked into a folder of its
/// own under `root`, named by its ID (`publisher.name`): the `.vsix` package's `extension/` folder
/// as it was. Packages come from Open VSX, the open registry VS Code-compatible editors use; a VS
/// Code Marketplace link only names the extension, since Marketplace extensions may be installed
/// only in Microsoft's own products. The app ships one theme, `bundledTheme`, installed on first
/// launch and removable like any other.
struct IconThemeLibrary: Sendable {
    struct Theme: Identifiable, Hashable, Sendable {
        /// `<extension ID>/<theme ID>`: what the `fileIconTheme` setting holds.
        let id: String
        let label: String
        let manifest: URL
    }

    struct Extension: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let version: String
        let folder: URL
        let themes: [Theme]
    }

    enum Failure: LocalizedError, Equatable {
        case badID(String), notFound(String), notAnIconTheme, unreadable, unsafePackage, tooLarge, http(Int)

        var errorDescription: String? {
            switch self {
            case .badID(let text): String(localized: "‘\(text)’ is not a VS Code Marketplace or Open VSX link, or an extension ID like publisher.name.")
            case .notFound(let id): String(localized: "Open VSX has no extension ‘\(id)’. Themes only on the VS Code Marketplace cannot be installed.")
            case .notAnIconTheme: String(localized: "This extension has no file icon theme.")
            case .unreadable: String(localized: "This package could not be read.")
            case .unsafePackage: String(localized: "This package has files outside its own folder, or links, so it was not installed.")
            case .tooLarge: String(localized: "This package is too large to be an icon theme.")
            case .http(let status): String(localized: "The download failed (HTTP \(status)).")
            }
        }
    }

    static let registry = URL(string: "https://open-vsx.org/api/")!
    static let maxPackage = 100 << 20
    static let maxUnpacked = 500 << 20
    static let maxFile = 50 << 20
    static let maxFiles = 20_000

    /// The theme the app ships and uses until someone chooses another, from
    /// `macos/scripts/vendor-default-icon-theme.py`.
    static let bundledTheme = "vscode-icons-team.vscode-icons/vscode-icons"

    let root: URL
    /// Fetches a URL into a file of its own, which the caller deletes.
    var fetch: @Sendable (URL) async throws -> URL = IconThemeLibrary.download
    /// The package of `bundledTheme`; nil where the app's resources are not, as in tests.
    var bundledPackage: URL? = Bundle.main.url(forResource: "DefaultIconTheme", withExtension: "vsix")

    /// The library in this run's data folder.
    static var standard: IconThemeLibrary {
        let data = DataDirectory.explicit.map(URL.init(fileURLWithPath:)) ?? DataDirectory.standard
        return IconThemeLibrary(root: data.appendingPathComponent("IconThemes"))
    }

    static func isValidID(_ id: String) -> Bool {
        id.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_-]*\.[A-Za-z0-9][A-Za-z0-9_.-]*/) != nil && !id.contains("..")
    }

    /// The extension ID a pasted VS Code Marketplace or Open VSX link, `vscode:extension/` link or
    /// bare `publisher.name` names; nil if it names none.
    static func extensionID(from text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var id = text
        if text.hasPrefix("vscode:extension/") {
            id = String(text.dropFirst("vscode:extension/".count))
        } else if let url = URL(string: text), let host = url.host?.lowercased() {
            if host == "marketplace.visualstudio.com" {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "itemName" }?.value ?? ""
            } else if host == "open-vsx.org" || host == "www.open-vsx.org" {
                // open-vsx.org/extension/<namespace>/<name>[/<version>]
                let parts = url.pathComponents.filter { $0 != "/" }
                id = parts.count >= 3 && parts[0] == "extension" ? "\(parts[1]).\(parts[2])" : ""
            } else {
                return nil
            }
        }
        return isValidID(id) ? id : nil
    }

    /// Whether every entry of a package unpacks inside the folder it is unpacked into.
    static func isSafe(entries: [Substring]) -> Bool {
        entries.allSatisfy { !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }
    }

    /// Installs the bundled theme the first time; a marker keeps it removed once someone removes
    /// it. A failed install is tried again at the next launch. Run once a launch before anything
    /// installs, it also clears what an install cut short left behind.
    func installBundledTheme() async {
        removeStaging()
        guard let package = bundledPackage else { return }
        let marker = root.appendingPathComponent(".bundled-\(Self.bundledTheme.prefix { $0 != "/" })")
        guard !FileManager.default.fileExists(atPath: marker.path), (try? await install(package: package)) != nil else { return }
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }

    /// The installed extensions, by name.
    func installed() async -> [Extension] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return folders.compactMap { try? Self.read($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// An installed theme, by the ID the `fileIconTheme` setting holds.
    func theme(_ id: String, languages: FileIconLanguages = .bundled) async throws -> FileIconTheme {
        let extensionID = String(id.prefix { $0 != "/" })
        guard Self.isValidID(extensionID) else { throw Failure.badID(extensionID) }
        let installed = try Self.read(root.appendingPathComponent(extensionID))
        guard let theme = installed.themes.first(where: { $0.id == id }) else { throw Failure.notFound(id) }
        return try FileIconTheme(manifest: theme.manifest, root: installed.folder, languages: languages)
    }

    /// Downloads from Open VSX the extension a link or ID names, and installs it.
    func install(openVSX text: String) async throws -> Extension {
        guard let id = Self.extensionID(from: text), let dot = id.firstIndex(of: ".") else {
            throw Failure.badID(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let listingURL = Self.registry.appendingPathComponent(String(id[..<dot])).appendingPathComponent(String(id[id.index(after: dot)...]))
        let listing: URL
        do { listing = try await fetch(listingURL) } catch Failure.http(404) { throw Failure.notFound(id) }
        defer { try? FileManager.default.removeItem(at: listing) }
        struct Listing: Decodable { struct Files: Decodable { let download: URL }; let files: Files }
        guard let download = (try? JSONDecoder().decode(Listing.self, from: Data(contentsOf: listing)))?.files.download,
              download.scheme == "https" else { throw Failure.notFound(id) }
        let package = try await fetch(download)
        defer { try? FileManager.default.removeItem(at: package) }
        return try await install(package: package)
    }

    /// Unpacks a `.vsix` package, replacing an installed copy of the same extension. Only plain
    /// files inside its `extension/` folder are written, each no larger than the package says.
    func install(package file: URL) async throws -> Extension {
        let fm = FileManager.default
        guard let size = try fm.attributesOfItem(atPath: file.path)[.size] as? Int, size <= Self.maxPackage else { throw Failure.tooLarge }
        let archive: ZipArchive
        do { archive = try ZipArchive(contentsOf: file) } catch { throw Failure.unreadable }
        let files = archive.entries.filter { $0.name.hasPrefix("extension/") && !$0.isDirectory }
        guard Self.isSafe(entries: files.map { Substring($0.name) }), !files.contains(where: \.isLink) else { throw Failure.unsafePackage }
        guard files.contains(where: { $0.name == "extension/package.json" }) else { throw Failure.notAnIconTheme }
        guard files.count <= Self.maxFiles, files.allSatisfy({ $0.size <= Self.maxFile }),
              files.reduce(0, { $0 + $1.size }) <= Self.maxUnpacked else { throw Failure.tooLarge }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".incoming-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        for entry in files {
            let target = staging.appendingPathComponent(entry.name)
            let contents: Data
            do { contents = try archive.contents(of: entry) } catch ZipArchive.Failure.tooLarge { throw Failure.tooLarge } catch { throw Failure.unreadable }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: target)
        }
        let folder = staging.appendingPathComponent("extension")
        let package = try Self.read(folder)
        guard Self.isValidID(package.id) else { throw Failure.badID(package.id) }
        // One theme the app can draw is enough; one it cannot says why when chosen.
        var failures: [any Error] = []
        for theme in package.themes {
            do { _ = try FileIconTheme(manifest: theme.manifest, root: folder, languages: .empty) } catch { failures.append(error) }
        }
        if failures.count == package.themes.count, let first = failures.first { throw first }

        let destination = root.appendingPathComponent(package.id), previous = staging.appendingPathComponent("previous")
        let replacing = fm.fileExists(atPath: destination.path)
        if replacing { try fm.moveItem(at: destination, to: previous) }
        do { try fm.moveItem(at: folder, to: destination) } catch {
            if replacing { try? fm.moveItem(at: previous, to: destination) }
            throw error
        }
        return try Self.read(destination)
    }

    func remove(_ id: String) async throws {
        guard Self.isValidID(id) else { throw Failure.badID(id) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(id))
    }

    /// Removes the staging folders of installs the app quit or crashed during.
    private func removeStaging() {
        let fm = FileManager.default
        for folder in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where folder.hasPrefix(".incoming-") {
            try? fm.removeItem(at: root.appendingPathComponent(folder))
        }
    }

    /// An unpacked extension, from its `package.json`. Only themes whose manifest lies inside
    /// the folder count.
    private static func read(_ folder: URL) throws -> Extension {
        struct Package: Decodable {
            struct Contributes: Decodable { let iconThemes: [Entry]? }
            struct Entry: Decodable { let id: String; let label: String?; let path: String }
            let publisher: String, name: String, displayName: String?, version: String?, contributes: Contributes?
        }
        let package = try JSONDecoder().decode(Package.self, from: Data(contentsOf: folder.appendingPathComponent("package.json")))
        let names = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: folder.appendingPathComponent("package.nls.json")))) ?? [:]
        // "%key%" names a string in package.nls.json.
        func text(_ value: String?) -> String? {
            guard let value, value.count > 2, value.hasPrefix("%"), value.hasSuffix("%") else { return value }
            return names[String(value.dropFirst().dropLast())]
        }
        let id = "\(package.publisher).\(package.name)", inside = folder.standardizedFileURL.path + "/"
        let themes = (package.contributes?.iconThemes ?? []).compactMap { entry -> Theme? in
            let manifest = folder.appendingPathComponent(entry.path).standardizedFileURL
            guard manifest.path.hasPrefix(inside) else { return nil }
            return Theme(id: "\(id)/\(entry.id)", label: text(entry.label) ?? entry.id, manifest: manifest)
        }
        guard !themes.isEmpty else { throw Failure.notAnIconTheme }
        return Extension(id: id, name: text(package.displayName) ?? package.name, version: package.version ?? "", folder: folder, themes: themes)
    }

    static let download: @Sendable (URL) async throws -> URL = { url in
        let (file, response) = try await URLSession.shared.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw Failure.http(status)
        }
        let own = FileManager.default.temporaryDirectory.appendingPathComponent("cascade-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: file, to: own)
        return own
    }
}
