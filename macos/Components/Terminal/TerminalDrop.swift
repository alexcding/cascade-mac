import AppKit
import GhosttyTerminal

/// A drop onto a terminal, read the way ⌘V reads the clipboard (`TerminalPastePayload`): dropped
/// files type their shell-escaped paths, and an image with no file of its own — one dragged off a
/// web page — is staged under `TerminalFileStaging.directory` first. A promised file, such as the
/// screenshot thumbnail's, is written there by its source. Whatever arrives is typed as a paste,
/// so an agent that attaches a pasted image path, as Claude Code does, gets the image.
enum TerminalDrop {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    enum Content {
        case text(String)
        case stage(TerminalPastePayload.Stageable)
        case promised([NSFilePromiseReceiver])
    }

    /// What can be read now: the dragging pasteboard is only valid during the drop itself.
    static func read(_ pasteboard: NSPasteboard) -> Content? {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if let text = TerminalPastePayload.text(string: nil, urls: files) { return .text(text) }
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            return .promised(receivers)
        }
        return TerminalPastePayload.stageable(from: pasteboard).map(Content.stage)
    }

    /// Types the drop through `paste` once any file it needs is written; nothing when none could be.
    /// A promise is called in before this returns, while the drop is still being performed, as
    /// AppKit expects; the rest is written off the main thread.
    @MainActor static func deliver(_ content: Content, to paste: @escaping @MainActor (String) -> Void) {
        switch content {
        case .text(let text): paste(text)
        case .stage(let stageable): Task { if let text = await TerminalPastePayload.stage(stageable) { paste(text) } }
        case .promised(let receivers): receive(receivers) { if let text = $0 { paste(text) } }
        }
    }

    /// Asks each promise's source to write its files, in a folder of this drop's own so a promised
    /// name never collides; the staging sweep removes the folder with the files' age.
    @MainActor private static func receive(_ receivers: [NSFilePromiseReceiver], completion: @escaping @MainActor (String?) -> Void) {
        TerminalFileStaging.removeStaleFiles()
        let destination = TerminalFileStaging.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)) != nil
        else { return completion(nil) }
        let drop = PromisedDrop(receivers: receivers.count, completion: completion)
        for (index, receiver) in receivers.enumerated() {
            // On the main queue, as this function is: the reader keeps its isolation, and the
            // drop's counts are only ever touched there.
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: .main) { url, error in
                // `fileNames` is empty until the promise is called in, so it is read as each file
                // lands. A legacy promise names several files on one receiver.
                drop.arrived(error == nil ? url.path : nil, from: index, expecting: receiver.fileNames.count)
            }
        }
        // A source that promises more than it writes must not leave the drop waiting forever.
        Task { try? await Task.sleep(for: .seconds(30)); drop.finish() }
    }

    /// One drop's promised files as they land, finished once every receiver has delivered all it named.
    @MainActor private final class PromisedDrop {
        private var paths: [String] = []
        private var reported: [Int]
        private var waiting: Int
        private var completion: (@MainActor (String?) -> Void)?

        init(receivers: Int, completion: @escaping @MainActor (String?) -> Void) {
            reported = Array(repeating: 0, count: receivers); waiting = receivers; self.completion = completion
        }

        func arrived(_ path: String?, from receiver: Int, expecting count: Int) {
            guard completion != nil else { return }
            if let path { paths.append(path) }
            reported[receiver] += 1
            guard reported[receiver] == max(1, count) else { return }
            waiting -= 1
            if waiting == 0 { finish() }
        }

        func finish() {
            guard let completion else { return }
            self.completion = nil
            completion(paths.isEmpty ? nil : paths.map(TerminalPastePayload.escape).joined(separator: " "))
        }
    }
}
