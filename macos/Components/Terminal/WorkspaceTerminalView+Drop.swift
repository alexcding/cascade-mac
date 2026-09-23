import AppKit
import GhosttyTerminal

/// A drop of files or an image, typed as its paths the way ⌘V types a copied one.
extension WorkspaceTerminalView {
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: TerminalDrop.types) != nil ? .copy : []
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let content = TerminalDrop.read(sender.draggingPasteboard) else { return false }
        window?.makeFirstResponder(self)
        TerminalDrop.deliver(content) { [weak self] text in _ = self?.paste(text: text) }
        return true
    }
}
