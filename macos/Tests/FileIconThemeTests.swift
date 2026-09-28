import AppKit
import Foundation
import Testing

private let svgBody = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" fill="#f00"/></svg>
"""

/// The URLs an injected `fetch` was asked for, which it may be asked for off the main thread.
private final class FetchedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL] = []
    /// Records a URL and returns how many have been asked for, this one included.
    @discardableResult func append(_ url: URL) -> Int { lock.lock(); defer { lock.unlock() }; values.append(url); return values.count }
    var all: [URL] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Writes an `extension/` folder for a `.vsix` package into a fresh temp directory and returns it.
@discardableResult
private func writeExtension(
    publisher: String = "pub", name: String = "name", version: String = "1.0.0",
    manifest: String? = nil, nls: [String: String]? = nil, iconNames: [String] = ["icon"],
    symlink: Bool = false
) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cascade-vsix-\(UUID().uuidString)")
    let ext = root.appendingPathComponent("extension")
    try FileManager.default.createDirectory(at: ext.appendingPathComponent("theme"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: ext.appendingPathComponent("icons"), withIntermediateDirectories: true)
    let package = manifest ?? """
    {
        "publisher": "\(publisher)",
        "name": "\(name)",
        "displayName": "%name%",
        "version": "\(version)",
        "contributes": { "iconThemes": [ { "id": "main", "label": "Main", "path": "./theme/icons.json" } ] }
    }
    """
    try package.write(to: ext.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    if let nls {
        let data = try JSONSerialization.data(withJSONObject: nls)
        try data.write(to: ext.appendingPathComponent("package.nls.json"))
    }
    var definitions: [String: Any] = [:]
    for icon in iconNames {
        try svgBody.write(to: ext.appendingPathComponent("icons/\(icon).svg"), atomically: true, encoding: .utf8)
        definitions[icon] = ["iconPath": "../icons/\(icon).svg"]
    }
    let theme: [String: Any] = ["iconDefinitions": definitions, "file": iconNames.first ?? ""]
    let themeData = try JSONSerialization.data(withJSONObject: theme)
    try themeData.write(to: ext.appendingPathComponent("theme/icons.json"))
    if symlink {
        try? FileManager.default.removeItem(at: ext.appendingPathComponent("icons/link.svg"))
        try FileManager.default.createSymbolicLink(atPath: ext.appendingPathComponent("icons/link.svg").path, withDestinationPath: "/etc/hosts")
    }
    return root
}

/// Packs a written extension folder into a `.vsix` at a fresh temp path.
private func pack(_ extensionRoot: URL) throws -> URL {
    let vsix = FileManager.default.temporaryDirectory.appendingPathComponent("cascade-pack-\(UUID().uuidString).vsix")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.arguments = ["-r", "-y", "-q", vsix.path, "extension"]
    process.currentDirectoryURL = extensionRoot
    try process.run()
    process.waitUntilExit()
    return vsix
}

private func buildVSIX(
    publisher: String = "pub", name: String = "name", version: String = "1.0.0",
    manifest: String? = nil, nls: [String: String]? = nil, iconNames: [String] = ["icon"], symlink: Bool = false
) throws -> URL {
    let root = try writeExtension(publisher: publisher, name: name, version: version, manifest: manifest, nls: nls, iconNames: iconNames, symlink: symlink)
    defer { try? FileManager.default.removeItem(at: root) }
    return try pack(root)
}

// MARK: - FileIconTheme

@Test func fileIconThemeResolvesByNameExtensionLanguageThenDefault() throws {
    let root = try writeExtension()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = root.appendingPathComponent("extension/theme/icons.json")
    let theme = try JSONSerialization.jsonObject(with: try Data(contentsOf: manifest)) as! [String: Any]
    var definitions = theme["iconDefinitions"] as! [String: Any]
    for icon in ["npm", "git", "dts", "ts_lang", "file"] {
        try svgBody.write(to: root.appendingPathComponent("extension/icons/\(icon).svg"), atomically: true, encoding: .utf8)
        definitions[icon] = ["iconPath": "../icons/\(icon).svg"]
    }
    var updated = theme
    updated["iconDefinitions"] = definitions
    updated["file"] = "file"
    updated["fileNames"] = ["package.json": "npm", ".gitignore": "git"]
    updated["fileExtensions"] = ["d.ts": "dts"]
    updated["languageIds"] = ["typescript": "ts_lang"]
    try JSONSerialization.data(withJSONObject: updated).write(to: manifest)

    let languages = FileIconLanguages(extensions: ["ts": "typescript"], filenames: [:])
    let icon = try FileIconTheme(manifest: manifest, root: root, languages: languages)
    #expect(icon.icon(forFile: "package.json") == "npm")
    #expect(icon.icon(forFile: "/a/Package.JSON") == "npm")
    #expect(icon.icon(forFile: "index.d.ts") == "dts")
    #expect(icon.icon(forFile: "index.ts") == "ts_lang")
    #expect(icon.icon(forFile: ".gitignore") == "git")
    for name in ["README", "notes.unknown", "trailing."] {
        #expect(icon.icon(forFile: name) == "file")
    }
}

@Test func fileIconThemeLightAssociationsFallBackToBase() throws {
    let root = try writeExtension(iconNames: ["file", "base-config", "light-config"])
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = root.appendingPathComponent("extension/theme/icons.json")
    let payload: [String: Any] = [
        "iconDefinitions": [
            "file": ["iconPath": "../icons/file.svg"],
            "base-config": ["iconPath": "../icons/base-config.svg"],
            "light-config": ["iconPath": "../icons/light-config.svg"],
        ],
        "file": "file",
        "fileExtensions": ["ext": "base-config"],
        "light": [
            "fileExtensions": ["ext": "light-config"],
            "file": "undefined-light-file",
        ],
    ]
    try JSONSerialization.data(withJSONObject: payload).write(to: manifest)
    let theme = try FileIconTheme(manifest: manifest, root: root, languages: .empty)
    #expect(theme.icon(forFile: "a.ext", light: true) == "light-config")
    #expect(theme.icon(forFile: "a.ext", light: false) == "base-config")
    #expect(theme.icon(forFile: "README", light: true) == "file")
}

@Test func fileIconThemePrefersTheLongestExtension() throws {
    let root = try writeExtension(iconNames: ["file", "dts", "ts"])
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = root.appendingPathComponent("extension/theme/icons.json")
    let payload: [String: Any] = [
        "iconDefinitions": [
            "file": ["iconPath": "../icons/file.svg"],
            "dts": ["iconPath": "../icons/dts.svg"],
            "ts": ["iconPath": "../icons/ts.svg"],
        ],
        "file": "file",
        "fileExtensions": ["ts": "ts", "d.ts": "dts"],
    ]
    try JSONSerialization.data(withJSONObject: payload).write(to: manifest)
    let theme = try FileIconTheme(manifest: manifest, root: root, languages: .empty)
    #expect(theme.icon(forFile: "index.d.ts") == "dts")
    #expect(theme.icon(forFile: "index.ts") == "ts")
}

@Test func fileIconThemeAsksBothVariantsOfAStepBeforeTheNext() throws {
    let root = try writeExtension(iconNames: ["file", "base-ext", "light-lang"])
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = root.appendingPathComponent("extension/theme/icons.json")
    let payload: [String: Any] = [
        "iconDefinitions": [
            "file": ["iconPath": "../icons/file.svg"],
            "base-ext": ["iconPath": "../icons/base-ext.svg"],
            "light-lang": ["iconPath": "../icons/light-lang.svg"],
        ],
        "file": "file",
        "fileExtensions": ["ext": "base-ext"],
        "light": ["languageIds": ["lang": "light-lang"]],
    ]
    try JSONSerialization.data(withJSONObject: payload).write(to: manifest)
    let languages = FileIconLanguages(extensions: ["ext": "lang", "other": "lang"], filenames: [:])
    let theme = try FileIconTheme(manifest: manifest, root: root, languages: languages)
    // The base extension comes before the light language.
    #expect(theme.icon(forFile: "a.ext", light: true) == "base-ext")
    // The light language comes before the base default.
    #expect(theme.icon(forFile: "a.other", light: true) == "light-lang")
    #expect(theme.icon(forFile: "a.other", light: false) == "file")
}

@Test func fileIconThemeDropsIconsOutsideTheExtensionRoot() throws {
    let root = try writeExtension()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = root.appendingPathComponent("extension/theme/icons.json")
    let payload: [String: Any] = [
        "iconDefinitions": [
            "outside": ["iconPath": "../../../outside.svg"],
            "icon": ["iconPath": "../icons/icon.svg"],
        ],
        "file": "icon",
    ]
    try JSONSerialization.data(withJSONObject: payload).write(to: manifest)
    let theme = try FileIconTheme(manifest: manifest, root: root, languages: .empty)
    #expect(theme.url(for: "outside") == nil)
    #expect(theme.url(for: "icon") != nil)
}

@Test func fileIconThemeThrowsForFontOnlyOrEmptyDefinitions() throws {
    let root = try writeExtension()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = root.appendingPathComponent("extension/theme/icons.json")
    try JSONSerialization.data(withJSONObject: ["iconDefinitions": ["glyph": ["fontCharacter": "\\e001"]]])
        .write(to: manifest)
    do {
        _ = try FileIconTheme(manifest: manifest, root: root, languages: .empty)
        Issue.record("expected .fontGlyphs")
    } catch FileIconTheme.Failure.fontGlyphs {
    } catch { Issue.record("unexpected error \(error)") }

    try JSONSerialization.data(withJSONObject: ["iconDefinitions": [String: Any]()]).write(to: manifest)
    do {
        _ = try FileIconTheme(manifest: manifest, root: root, languages: .empty)
        Issue.record("expected .noIcons")
    } catch FileIconTheme.Failure.noIcons {
    } catch { Issue.record("unexpected error \(error)") }
}

@Test func fileIconThemeManifestAllowsCommentsAndTrailingCommas() throws {
    let root = try writeExtension()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = root.appendingPathComponent("extension/theme/icons.json")
    let json = """
    {
        // a comment
        "iconDefinitions": {
            "icon": { "iconPath": "../icons/icon.svg" },
        },
        "file": "icon",
    }
    """
    try json.write(to: manifest, atomically: true, encoding: .utf8)
    let theme = try FileIconTheme(manifest: manifest, root: root, languages: .empty)
    #expect(theme.icon(forFile: "anything") == "icon")
}

@Test func fileIconLanguagesLoadsTheVendoredTable() throws {
    let languages = try FileIconLanguages.load(from: TestPaths.checkout
        .appendingPathComponent("macos/Resources/VSCodeLanguages.bundle/languages.json"))
    #expect(languages.extensions["swift"] == "swift")
    #expect(languages.extensions["rs"] == "rust")
    #expect(languages.extensions["ts"] == "typescript")
    #expect(!languages.filenames.isEmpty)
}

// MARK: - IconThemeLibrary

private func tempLibrary(fetch: @escaping @Sendable (URL) async throws -> URL = IconThemeLibrary.download) -> (IconThemeLibrary, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cascade-icon-lib-\(UUID().uuidString)")
    return (IconThemeLibrary(root: root, fetch: fetch), root)
}

@Test func installingAVSIXRegistersItsExtensionAndTheme() async throws {
    let (library, root) = tempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let vsix = try buildVSIX(nls: ["name": "Name"])
    defer { try? FileManager.default.removeItem(at: vsix) }
    let installed = try await library.install(package: vsix)
    #expect(installed.id == "pub.name")
    #expect(installed.name == "Name")
    #expect(installed.themes.map(\.id) == ["pub.name/main"])
    let list = await library.installed()
    #expect(list.map(\.id) == ["pub.name"])
    let theme = try await library.theme("pub.name/main", languages: .empty)
    #expect(theme.icon(forFile: "anything") != nil)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("pub.name/package.json").path))
    let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(!entries.contains { $0.hasPrefix(".incoming") })
}

@Test func reinstallingAVSIXReplacesTheExtension() async throws {
    let (library, root) = tempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try buildVSIX(version: "1.0.0")
    defer { try? FileManager.default.removeItem(at: first) }
    _ = try await library.install(package: first)
    let second = try buildVSIX(version: "2.0.0")
    defer { try? FileManager.default.removeItem(at: second) }
    let installed = try await library.install(package: second)
    #expect(installed.version == "2.0.0")
    let list = await library.installed()
    #expect(list.count == 1)
    #expect(list.first?.version == "2.0.0")
}

@Test func packageWithoutIconThemesIsRejected() async throws {
    let (library, root) = tempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = """
    { "publisher": "pub", "name": "name", "version": "1.0.0" }
    """
    let vsix = try buildVSIX(manifest: manifest)
    defer { try? FileManager.default.removeItem(at: vsix) }
    await #expect(throws: IconThemeLibrary.Failure.notAnIconTheme) {
        _ = try await library.install(package: vsix)
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("pub.name").path))
}

@Test func packageWithASymlinkIsRejectedAsUnsafe() async throws {
    let (library, root) = tempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let vsix = try buildVSIX(symlink: true)
    defer { try? FileManager.default.removeItem(at: vsix) }
    await #expect(throws: IconThemeLibrary.Failure.unsafePackage) {
        _ = try await library.install(package: vsix)
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("pub.name").path))
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    #expect(!entries.contains { $0.hasPrefix(".incoming") })
}

@Test func isValidIDAcceptsPublisherDotNameOnly() {
    #expect(IconThemeLibrary.isValidID("PKief.material-icon-theme"))
    #expect(IconThemeLibrary.isValidID("vscode-icons-team.vscode-icons"))
    for bad in ["", "nodot", "../x.y", "a..b", "a/b.c", ".a.b"] {
        #expect(!IconThemeLibrary.isValidID(bad))
    }
}

@Test func isSafeRejectsAbsoluteAndEscapingEntries() {
    #expect(!IconThemeLibrary.isSafe(entries: ["/abs"]))
    #expect(!IconThemeLibrary.isSafe(entries: ["../x"]))
    #expect(!IconThemeLibrary.isSafe(entries: ["extension/../../x"]))
    #expect(IconThemeLibrary.isSafe(entries: ["extension/a/b.svg", "[Content_Types].xml"]))
}

@Test func installFromOpenVSXFetchesTheListingThenTheDownload() async throws {
    let (rawLibrary, root) = tempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let urls = FetchedURLs()
    let vsix = try buildVSIX()
    defer { try? FileManager.default.removeItem(at: vsix) }
    var library = rawLibrary
    library.fetch = { url in
        if urls.append(url) == 1 {
            let listing = FileManager.default.temporaryDirectory.appendingPathComponent("cascade-listing-\(UUID().uuidString)")
            try Data(#"{"files":{"download":"https://example.test/p.vsix"}}"#.utf8).write(to: listing)
            return listing
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("cascade-download-\(UUID().uuidString).vsix")
        try FileManager.default.copyItem(at: vsix, to: copy)
        return copy
    }
    let installed = try await library.install(openVSX: "pub.name")
    #expect(installed.id == "pub.name")
    #expect(urls.all.first?.absoluteString == "https://open-vsx.org/api/pub/name")
    #expect(urls.all.count == 2)
}

@Test func installFromOpenVSXReportsNotFoundOnHTTP404() async throws {
    var (library, root) = tempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    library.fetch = { _ in throw IconThemeLibrary.Failure.http(404) }
    await #expect(throws: IconThemeLibrary.Failure.notFound("pub.name")) {
        _ = try await library.install(openVSX: "pub.name")
    }
}

@Test func installFromOpenVSXRejectsABadIDWithoutFetching() async throws {
    var (library, root) = tempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let urls = FetchedURLs()
    library.fetch = { url in urls.append(url); throw IconThemeLibrary.Failure.notFound("x") }
    await #expect(throws: IconThemeLibrary.Failure.badID("bad id")) {
        _ = try await library.install(openVSX: "bad id")
    }
    #expect(urls.all.isEmpty)
}

@Test func removingAnExtensionDeletesIt() async throws {
    let (library, root) = tempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let vsix = try buildVSIX()
    defer { try? FileManager.default.removeItem(at: vsix) }
    _ = try await library.install(package: vsix)
    try await library.remove("pub.name")
    let list = await library.installed()
    #expect(list.isEmpty)
}

@Test func extensionIDsComeFromLinksOrIDs() {
    #expect(IconThemeLibrary.extensionID(from: "https://marketplace.visualstudio.com/items?itemName=wayou.vscode-icons-mac") == "wayou.vscode-icons-mac")
    #expect(IconThemeLibrary.extensionID(from: "https://open-vsx.org/extension/PKief/material-icon-theme") == "PKief.material-icon-theme")
    #expect(IconThemeLibrary.extensionID(from: "https://open-vsx.org/extension/PKief/material-icon-theme/5.38.1") == "PKief.material-icon-theme")
    #expect(IconThemeLibrary.extensionID(from: "vscode:extension/pub.name") == "pub.name")
    #expect(IconThemeLibrary.extensionID(from: "  pub.name\n") == "pub.name")
    for text in ["https://example.com/items?itemName=pub.name", "https://marketplace.visualstudio.com/items", "hello", ""] {
        #expect(IconThemeLibrary.extensionID(from: text) == nil, "\(text)")
    }
}

@Test func aPackageThatOutgrowsItsDeclaredSizeIsRejected() async throws {
    let (library, root) = tempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try writeExtension()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data(count: 1 << 20).write(to: folder.appendingPathComponent("extension/big.bin"))
    let vsix = try pack(folder)
    defer { try? FileManager.default.removeItem(at: vsix) }
    // Declare 10 bytes for the megabyte of zeros, in its central directory entry and local header.
    var bytes = [UInt8](try Data(contentsOf: vsix))
    func uint(_ at: Int, _ width: Int) -> Int { (0..<width).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) } }
    func put(_ at: Int, _ value: UInt32) { for i in 0..<4 { bytes[at + i] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(i))) } }
    var patched = false
    for at in 0..<(bytes.count - 46) where bytes[at..<(at + 4)].elementsEqual([0x50, 0x4b, 0x01, 0x02]) {
        let length = uint(at + 28, 2)
        guard String(decoding: bytes[(at + 46)..<(at + 46 + length)], as: UTF8.self) == "extension/big.bin" else { continue }
        put(at + 24, 10)
        put(uint(at + 42, 4) + 22, 10)
        patched = true
    }
    #expect(patched)
    try Data(bytes).write(to: vsix)
    await #expect(throws: IconThemeLibrary.Failure.tooLarge) { _ = try await library.install(package: vsix) }
    let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    #expect(left.isEmpty, "\(left)")
}

// MARK: - FileIconSettingsViewModel

@MainActor
private final class FakeSelection: FileIconSelecting {
    private(set) var fileIconTheme: String

    init(fileIconTheme: String = "") { self.fileIconTheme = fileIconTheme }

    func setFileIconTheme(_ id: String) { fileIconTheme = id }
}

/// A fetch that answers Open VSX's listing and then serves `vsix` as the download.
private func openVSX(serving vsix: URL, into urls: FetchedURLs = FetchedURLs()) -> @Sendable (URL) async throws -> URL {
    { url in
        urls.append(url)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cascade-fetch-\(UUID().uuidString)")
        if url.host == "open-vsx.org" {
            try Data(#"{"files":{"download":"https://example.test/p.vsix"}}"#.utf8).write(to: file)
        } else {
            try FileManager.default.copyItem(at: vsix, to: file)
        }
        return file
    }
}

@MainActor
private func viewModel(fetch: @escaping @Sendable (URL) async throws -> URL) -> (FileIconSettingsViewModel, URL) {
    let (library, root) = tempLibrary(fetch: fetch)
    return (FileIconSettingsViewModel(library: library, store: FileIconStore(library: library)), root)
}

@MainActor @Test func installingUsesTheInstalledTheme() async throws {
    let vsix = try buildVSIX()
    defer { try? FileManager.default.removeItem(at: vsix) }
    let (model, root) = viewModel(fetch: openVSX(serving: vsix))
    defer { try? FileManager.default.removeItem(at: root) }
    for current in ["", "other.theme/x"] {
        let selection = FakeSelection(fileIconTheme: current)
        model.link = "pub.name"
        await model.install(selection: selection)
        #expect(selection.fileIconTheme == "pub.name/main")
        #expect(model.link.isEmpty)
        #expect(model.extensions.count == 1)
        #expect(model.working == nil && model.error == nil)
    }
}

@MainActor @Test func aMarketplaceLinkInstallsTheSameExtensionFromOpenVSX() async throws {
    let vsix = try buildVSIX()
    defer { try? FileManager.default.removeItem(at: vsix) }
    let urls = FetchedURLs()
    let (model, root) = viewModel(fetch: openVSX(serving: vsix, into: urls))
    defer { try? FileManager.default.removeItem(at: root) }
    let selection = FakeSelection()
    model.link = "https://marketplace.visualstudio.com/items?itemName=pub.name"
    await model.install(selection: selection)
    #expect(urls.all.first?.absoluteString == "https://open-vsx.org/api/pub/name")
    #expect(!urls.all.contains { $0.host?.contains("visualstudio") == true })
    #expect(selection.fileIconTheme == "pub.name/main")
}

@MainActor @Test func removingTheThemeInUseGoesBackToNone() async throws {
    let vsix = try buildVSIX()
    defer { try? FileManager.default.removeItem(at: vsix) }
    let (model, root) = viewModel(fetch: openVSX(serving: vsix))
    defer { try? FileManager.default.removeItem(at: root) }
    let selection = FakeSelection()
    model.link = "pub.name"
    await model.install(selection: selection)
    await model.removeSelected(selection: selection)
    #expect(selection.fileIconTheme == "")
    #expect(model.extensions.isEmpty)
}

@MainActor @Test func removingWithNoInstalledThemeInUseRemovesNothing() async throws {
    let vsix = try buildVSIX()
    defer { try? FileManager.default.removeItem(at: vsix) }
    let (model, root) = viewModel(fetch: openVSX(serving: vsix))
    defer { try? FileManager.default.removeItem(at: root) }
    let selection = FakeSelection()
    model.link = "pub.name"
    await model.install(selection: selection)
    selection.setFileIconTheme("")
    await model.removeSelected(selection: selection)
    #expect(model.extensions.count == 1)
}

@MainActor @Test func aFailingInstallSetsErrorAndLeavesSelectionUnchanged() async throws {
    let (model, root) = viewModel(fetch: { _ in throw IconThemeLibrary.Failure.http(500) })
    defer { try? FileManager.default.removeItem(at: root) }
    let selection = FakeSelection(fileIconTheme: "other.theme/x")
    model.link = "pub.name"
    await model.install(selection: selection)
    #expect(model.error != nil)
    #expect(model.link == "pub.name")
    #expect(selection.fileIconTheme == "other.theme/x")
}

@MainActor @Test func anInstallErrorClearsWhenTheLinkOrTheThemeChanges() async throws {
    let (model, root) = viewModel(fetch: { _ in throw IconThemeLibrary.Failure.http(500) })
    defer { try? FileManager.default.removeItem(at: root) }
    let selection = FakeSelection(fileIconTheme: "other.theme/x")
    model.link = "pub.name"
    await model.install(selection: selection)
    #expect(model.error != nil)
    model.link = "pub.nam"
    #expect(model.error == nil)
    model.link = "pub.name"
    await model.install(selection: selection)
    #expect(model.error != nil)
    model.choose("", selection: selection)
    #expect(model.error == nil)
    #expect(selection.fileIconTheme == "")
}

@MainActor @Test func aRetiredModelMakesNoFetchCall() async throws {
    let urls = FetchedURLs()
    let (model, root) = viewModel(fetch: { url in urls.append(url); throw IconThemeLibrary.Failure.notFound("x") })
    defer { try? FileManager.default.removeItem(at: root) }
    model.retire()
    model.link = "pub.name"
    await model.install(selection: FakeSelection())
    #expect(urls.all.isEmpty)
}

@Test func theBundledThemeIsInstalledOnceAndStaysRemoved() async throws {
    var (library, root) = tempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let vsix = try buildVSIX()
    defer { try? FileManager.default.removeItem(at: vsix) }
    library.bundledPackage = vsix
    await library.installBundledTheme()
    #expect(await library.installed().map(\.id) == ["pub.name"])
    try await library.remove("pub.name")
    await library.installBundledTheme()
    #expect(await library.installed().isEmpty)
}

@Test func withoutItsPackageTheBundledThemeInstallsNothing() async {
    var (library, root) = tempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    library.bundledPackage = nil
    await library.installBundledTheme()
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test func anInstallCutShortIsClearedAtTheNextLaunch() async throws {
    var (library, root) = tempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let vsix = try buildVSIX()
    defer { try? FileManager.default.removeItem(at: vsix) }
    library.bundledPackage = nil
    _ = try await library.install(package: vsix)
    let leftover = root.appendingPathComponent(".incoming-\(UUID().uuidString)/extension")
    try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
    await library.installBundledTheme()
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["pub.name"])
}

@MainActor @Test func aShellStoreLoadsItsThemeIntoOnlyTheStoreItIsGiven() throws {
    let suite = "file-icons-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let chosen = "pub.name-\(UUID().uuidString.lowercased())/main"
    preferences.set(chosen, forKey: "native.fileIconTheme")
    // Without a store of its own, the app's is left alone.
    _ = ShellStore(preferences: preferences)
    #expect(FileIconStore.shared.selection != chosen)
    let (library, root) = tempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileIconStore(library: library)
    let shell = NativeShellFeatureFactory(preferences: preferences, fileIcons: store).shell(notifications: NotificationStore())
    #expect(store.selection == chosen)
    shell.setFileIconTheme("")
    #expect(store.selection == "")
    #expect(FileIconStore.shared.selection != chosen)
}
