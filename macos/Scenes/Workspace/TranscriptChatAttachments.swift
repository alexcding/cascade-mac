import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// How files reach the chat's composer: picked, dropped, or pasted. Each is read the way the
/// terminal reads the same drop or paste (`TerminalPastePayload`), so what the message later pastes
/// into the terminal is exactly what a drop onto the terminal would have typed.
enum ChatAttachmentReader {
    static func files(_ urls: [URL]) -> [ChatAttachment] {
        urls.filter(\.isFileURL).map { ChatAttachment(path: TerminalPastePayload.escape($0.path), name: $0.lastPathComponent) }
    }

    /// Splits a paste of escaped, space-joined paths back into its files.
    static func files(pasted text: String) -> [ChatAttachment] {
        var paths: [String] = [], current = "", escaped = false
        for character in text {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { current.append(character); escaped = true; continue }
            if character == " " {
                if !current.isEmpty { paths.append(current) }
                current = ""
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { paths.append(current) }
        return paths.map { ChatAttachment(path: $0, name: (unescape($0) as NSString).lastPathComponent) }
    }

    static func unescape(_ path: String) -> String {
        var result = "", escaped = false
        for character in path {
            if !escaped, character == "\\" { escaped = true; continue }
            escaped = false
            result.append(character)
        }
        return result
    }

    /// Files a paste or a drop would bring: copied or dragged files, or image data with no file of
    /// its own. Text, and a link, are the field's to insert as text.
    static func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return !urls.isEmpty || (TerminalPastePayload.text(from: pasteboard) == nil && TerminalPastePayload.stageable(from: pasteboard) != nil)
    }

    /// A paste or a drop onto the message field: copied files, or a screenshot staged as one.
    /// Nothing for text, which the field inserts itself.
    @MainActor static func paste(from pasteboard: NSPasteboard, into chat: TranscriptChatModel) -> Bool {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            chat.attach(files(urls))
            return true
        }
        guard TerminalPastePayload.text(from: pasteboard) == nil,
              let pending = TerminalPastePayload.stageable(from: pasteboard) else { return false }
        chat.attach { await TerminalPastePayload.stage(pending).map { files(pasted: $0) } ?? [] }
        return true
    }

    static let dropTypes: [UTType] = [.fileURL, .image]

    /// A drop onto the composer: files by path, and an image with no file of its own (one dragged
    /// off a web page, or the screenshot thumbnail) staged first, as the terminal stages it.
    @MainActor static func drop(_ providers: [NSItemProvider], into chat: TranscriptChatModel) -> Bool {
        var accepted = false
        for provider in providers {
            // A file first: an image dragged off a web page also offers its web address.
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                chat.attach {
                    let url: URL? = await withCheckedContinuation { done in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
                    }
                    return url.map { files([$0]) } ?? []
                }
            } else if let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .image) }) {
                accepted = true
                chat.attach {
                    let data: Data? = await withCheckedContinuation { done in
                        _ = provider.loadDataRepresentation(for: type) { data, _ in done.resume(returning: data) }
                    }
                    guard let data else { return [] }
                    return await TerminalPastePayload.stage(TerminalPastePayload.stageable(data: data, type: type)).map { files(pasted: $0) } ?? []
                }
            }
        }
        return accepted
    }
}
