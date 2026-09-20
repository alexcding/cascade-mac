import AppKit
import GhosttyTerminal
import UniformTypeIdentifiers

/// What a paste hands the terminal, read the way Ghostty's macOS app reads a
/// pasteboard: URLs first — a file URL as its shell-escaped path, any other
/// verbatim — then the string. A file copied in Finder carries both its URL and
/// its display name, and taking the string first pastes the name.
///
/// Data with no path of its own — a screenshot, an image copied out of a web
/// page — is written under `TerminalFileStaging.directory` first, so what
/// reaches the shell is always a path it can open. The package stages the same
/// way for its UIKit paste; only the reader differs.
enum TerminalPastePayload {
    /// The pasteboard a paste reads: the general one everywhere but tests,
    /// which must not write a screenshot into the user's own clipboard.
    @MainActor static var clipboard: NSPasteboard = .general

    /// The pasteboard as text, with no side effects. Mirrors the package's
    /// `read_clipboard` reader, so what this sees is what ghostty's own paste
    /// binding would paste.
    static func text(from pasteboard: NSPasteboard) -> String? {
        text(
            string: pasteboard.string(forType: .string),
            urls: (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        )
    }

    static func text(string: String?, urls: [URL]) -> String? {
        if !urls.isEmpty {
            return urls
                .map { $0.isFileURL ? escape($0.path) : $0.absoluteString }
                .joined(separator: " ")
        }
        guard let string, !string.isEmpty else { return nil }
        return string
    }

    /// Bytes a pasteboard offers that deserve a file of their own, read before
    /// the write: staging is asynchronous, and a pasteboard read is not.
    static func stageable(from pasteboard: NSPasteboard) -> Stageable? {
        let items: [StagedItem] = (pasteboard.pasteboardItems ?? []).compactMap { item in
            guard let type = fileType(among: item.types.map(\.rawValue)),
                  let data = item.data(forType: NSPasteboard.PasteboardType(type.identifier))
            else { return nil }
            return StagedItem(data: data, type: type)
        }
        return items.isEmpty ? nil : Stageable(items: items)
    }

    /// Writes what ``stageable(from:)`` read under
    /// `TerminalFileStaging.directory` and answers with escaped, space-joined
    /// paths — or `nil` when nothing could be written.
    @MainActor
    static func stage(_ stageable: Stageable) async -> String? {
        guard let directory = prepareDirectory() else { return nil }
        let items = stageable.items
        let paths = await Task.detached(priority: .userInitiated) {
            items.compactMap { store($0.data, type: $0.type, in: directory) }
        }.value
        return paths.isEmpty ? nil : paths.map(escape).joined(separator: " ")
    }

    /// Pasteboard bytes already read, waiting to be written.
    struct Stageable: Sendable {
        fileprivate let items: [StagedItem]
    }

    /// Characters a POSIX shell would otherwise interpret in a word. Kept
    /// aligned with the package's `TerminalShellEscape`, which is what a paste
    /// of the same file produces.
    private static let escapedCharacters: Set<Character> = [
        "\\", " ", "(", ")", "[", "]", "{", "}", "<", ">", "\"", "'", "`",
        "!", "#", "$", "&", ";", "|", "*", "?", "\t",
    ]

    /// Backslash-escapes every shell-sensitive character — the form a path
    /// takes when typed at a live prompt, not the quoted form a command line
    /// would use.
    static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for character in value {
            if escapedCharacters.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    fileprivate struct StagedItem: Sendable {
        let data: Data
        let type: UTType
    }

    /// The type worth a file among what one item offers, or `nil` when it
    /// carries text, a link, or a path. Mirrors `TerminalFileStaging`'s rule:
    /// images win (a copied photo also registers its URL), text loses (a rich
    /// text or web selection also registers data types that are not text).
    private static func fileType(among identifiers: [String]) -> UTType? {
        let types = identifiers.compactMap(UTType.init)
        if types.contains(where: { $0.conforms(to: .fileURL) }) { return nil }
        if let image = types.first(where: { $0.conforms(to: .image) }) { return image }
        if types.contains(where: { $0.conforms(to: .text) }) { return nil }
        // Dynamic types (`dyn.a…`) are pasteboard bookkeeping.
        return types.first { type in
            !type.isDynamic
                && type.conforms(to: .data)
                && !type.conforms(to: .text)
                && !type.conforms(to: .url)
        }
    }

    /// The staging directory, swept of files older than the package's stale
    /// age first: nothing here can know when the shell that received a path is
    /// done with it, so age is the only safe rule.
    @MainActor
    private static func prepareDirectory() -> URL? {
        TerminalFileStaging.removeStaleFiles()
        let directory = TerminalFileStaging.directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
    }

    /// Writes one staged file, taking the next free name so a second paste of
    /// the same kind cannot overwrite a path a shell is still holding.
    private static func store(_ data: Data, type: UTType, in directory: URL) -> String? {
        store(name: type.conforms(to: .image) ? "image" : "file",
              extension: type.preferredFilenameExtension ?? "bin",
              in: directory) { try data.write(to: $0, options: .withoutOverwriting) }
    }

    private static func store(
        name: String,
        extension fileExtension: String,
        in directory: URL,
        write: (URL) throws -> Void
    ) -> String? {
        for attempt in 0 ..< 100 {
            let suffix = attempt == 0 ? "" : "-\(attempt)"
            let url = directory.appendingPathComponent("\(name)\(suffix).\(fileExtension)")
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try write(url)
                return url.path
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                return nil
            }
        }
        return nil
    }
}
