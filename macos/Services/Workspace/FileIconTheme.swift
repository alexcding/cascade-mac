import Foundation

/// The file extensions and names VS Code's built-in languages claim, which a theme's `languageIds`
/// are keyed by. Vendored by `macos/scripts/vendor-vscode-languages.py`.
struct FileIconLanguages: Decodable, Sendable {
    let extensions: [String: String]
    let filenames: [String: String]

    static let empty = FileIconLanguages(extensions: [:], filenames: [:])

    /// The app's own table; empty if the app was built without it.
    static let bundled: FileIconLanguages = Bundle.main.url(forResource: "VSCodeLanguages", withExtension: "bundle")
        .flatMap { try? load(from: $0.appendingPathComponent("languages.json")) } ?? .empty

    init(extensions: [String: String], filenames: [String: String]) {
        self.extensions = extensions
        self.filenames = filenames
    }

    static func load(from file: URL) throws -> FileIconLanguages {
        try JSONDecoder().decode(FileIconLanguages.self, from: Data(contentsOf: file))
    }
}

/// A VS Code file icon theme, read from its manifest where its extension was unpacked. A name
/// gets its icon in VS Code's order: the whole name, its extensions longest first, its language,
/// then the theme's default. In a light appearance each step asks the theme's `light`
/// associations before its ordinary ones. Only image icons are drawn; a theme that draws with a
/// font has none.
struct FileIconTheme: Sendable {
    enum Failure: LocalizedError {
        case fontGlyphs, noIcons

        var errorDescription: String? {
            switch self {
            case .fontGlyphs: String(localized: "This theme draws its icons with a font, which Cascade cannot show.")
            case .noIcons: String(localized: "This theme has no icons Cascade can show.")
            }
        }
    }

    private struct Associations: Decodable, Sendable {
        var file: String?
        var fileNames: [String: String] = [:]
        var fileExtensions: [String: String] = [:]
        var languageIds: [String: String] = [:]

        enum CodingKeys: CodingKey { case file, fileNames, fileExtensions, languageIds }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            file = try container.decodeIfPresent(String.self, forKey: .file)
            // VS Code matches names and extensions without regard to case.
            fileNames = try Self.lowercased(container.decodeIfPresent([String: String].self, forKey: .fileNames))
            fileExtensions = try Self.lowercased(container.decodeIfPresent([String: String].self, forKey: .fileExtensions))
            languageIds = try container.decodeIfPresent([String: String].self, forKey: .languageIds) ?? [:]
        }

        private static func lowercased(_ map: [String: String]?) -> [String: String] {
            Dictionary((map ?? [:]).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        }
    }

    private struct Manifest: Decodable {
        struct Definition: Decodable { let iconPath: String?; let fontCharacter: String? }
        let iconDefinitions: [String: Definition]
        let light: Associations?
        let base: Associations

        enum CodingKeys: CodingKey { case iconDefinitions, light }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            iconDefinitions = try container.decode([String: Definition].self, forKey: .iconDefinitions)
            light = try container.decodeIfPresent(Associations.self, forKey: .light)
            base = try Associations(from: decoder)
        }
    }

    private let files: [String: URL]
    private let base: Associations
    private let light: Associations?
    private let languages: FileIconLanguages

    /// Reads the manifest at `manifest`; an icon whose file lies outside `root`, the unpacked
    /// extension, is left out.
    init(manifest: URL, root: URL, languages: FileIconLanguages) throws {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true // VS Code reads theme manifests as JSON with comments.
        let theme = try decoder.decode(Manifest.self, from: Data(contentsOf: manifest))
        let folder = manifest.deletingLastPathComponent(), inside = root.standardizedFileURL.path + "/"
        files = theme.iconDefinitions.compactMapValues { definition in
            guard let path = definition.iconPath, !path.isEmpty else { return nil }
            let file = folder.appendingPathComponent(path).standardizedFileURL
            return file.path.hasPrefix(inside) ? file : nil
        }
        if files.isEmpty {
            throw theme.iconDefinitions.values.contains { $0.fontCharacter != nil } ? Failure.fontGlyphs : Failure.noIcons
        }
        base = theme.base
        light = theme.light
        self.languages = languages
    }

    /// The icon a file of this name gets, as an ID in this theme; nil only when the theme has
    /// no default icon.
    func icon(forFile name: String, light isLight: Bool = false) -> String? {
        let name = (name as NSString).lastPathComponent.lowercased()
        // "a.d.ts" has the extensions "d.ts" and "ts"; a leading dot starts one, as in ".gitignore".
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        let extensions = parts.indices.dropFirst().map { parts[$0...].joined(separator: ".") }.filter { !$0.isEmpty }
        let language = languages.filenames[name] ?? extensions.lazy.compactMap { languages.extensions[$0] }.first
        let associations = isLight ? [light, base].compactMap(\.self) : [base]
        let steps: [(Associations) -> String?] = [
            { $0.fileNames[name] },
            { set in extensions.lazy.compactMap { set.fileExtensions[$0] }.first },
            { set in language.flatMap { set.languageIds[$0] } },
            { $0.file },
        ]
        for step in steps {
            // An association naming an icon the theme cannot draw draws nothing in VS Code
            // either, and leaves the name to the next one.
            if let icon = associations.lazy.compactMap(step).first(where: { files[$0] != nil }) { return icon }
        }
        return nil
    }

    /// Where an icon's image is, if the theme can draw it.
    func url(for icon: String) -> URL? { files[icon] }
}
