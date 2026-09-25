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

    /// ⌘V in the composer: copied files, or a screenshot staged as one. Nothing for text, which
    /// the message field pastes itself.
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

/// The composer's files, each removable until the message is sent.
struct ChatAttachmentStrip: View {
    let attachments: [ChatAttachment]
    let remove: @MainActor (ChatAttachment.ID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { file in
                    HStack(spacing: 5) {
                        Image(systemName: Self.isImage(file.name) ? "photo" : "doc")
                            .foregroundStyle(Theme.textSecondary)
                        Text(file.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180, alignment: .leading)
                        Button { remove(file.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                        .help("Remove \(file.name)")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.paneBackground, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: Theme.Size.hairline))
                    .help(ChatAttachmentReader.unescape(file.path))
                }
            }
        }
    }

    private static func isImage(_ name: String) -> Bool {
        UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .image) ?? false
    }
}

/// ⌘V while the message field has the keyboard, for what the field cannot paste itself.
@MainActor final class ChatPasteMonitor {
    private var monitor: Any?

    func start(_ handle: @escaping @MainActor (NSEvent) -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Caps Lock, Fn and the like do not make it another shortcut.
            guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
            return handle(event) ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
