import AppKit
import GhosttyTerminal

/// The paste that has no path to paste.
extension WorkspaceTerminalView {
    /// Cmd+V, for the one case the package's paste cannot serve.
    ///
    /// Text and file URLs stay on ghostty's own paste binding — the pipeline
    /// where the `read_clipboard` callback and paste protection live — so this
    /// steps in only for a clipboard holding nothing but bytes: a screenshot,
    /// an image copied out of a web page. Those are staged as a file and the
    /// path takes the text path instead. A program's own clipboard read must
    /// never write a file, which is why that work belongs to a host keystroke
    /// and not to the callback.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "v",
              TerminalPastePayload.text(from: TerminalPastePayload.clipboard) == nil,
              let pending = TerminalPastePayload.stageable(from: TerminalPastePayload.clipboard)
        else { return super.performKeyEquivalent(with: event) }
        Task { @MainActor [weak self] in
            guard let paths = await TerminalPastePayload.stage(pending) else { return }
            _ = self?.paste(text: paths)
        }
        return true
    }
}
