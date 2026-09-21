import SwiftUI

/// SwiftUI owns the menu bar; standard editing items retain the responder chain.
struct CraftCommands: Commands {
    let model: AppViewModel
    let perform: (ShellCommand) -> Void
    let canCheckForUpdates: Bool

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            command(.checkForUpdates)
        }
        CommandGroup(replacing: .newItem) {
            command(.newProject)
            command(.newSession)
            command(.newTab)
            command(.newSidebarTab)
            command(.openFile)
        }
        CommandGroup(replacing: .saveItem) {
            command(.saveFile)
            command(.closePage)
        }
        CommandGroup(after: .pasteboard) {
            command(.findPage)
        }
        CommandGroup(replacing: .toolbar) {
            command(.refresh)
            command(.reloadPage)
            command(.tray)
            Divider()
            // One set of zoom keys: the page when a web page has focus, the code font otherwise.
            command(.biggerFont)
            command(.smallerFont)
            command(.resetFont)
            Divider()
            command(.zoomIn)
            command(.zoomOut)
            command(.resetZoom)
        }
        // Owns Toggle Sidebar and its ⌃⌘S; Focus Sidebar below keeps off it.
        SidebarCommands()
        CommandMenu("Product") {
            command(.runProject)
            command(.stopBuild)
            Divider()
            command(.nextModel)
            command(.previousModel)
        }
        CommandMenu("Go") {
            command(.overview)
            command(.terminal)
            command(.sidebar)
            command(.activity)
            Divider()
            command(.back)
            command(.forward)
            Divider()
            command(.nextPage)
            command(.previousPage)
            ForEach(ShellCommand.tabs, id: \.self) { command($0) }
        }
    }

    private func command(_ command: ShellCommand) -> some View {
        CommandItem(command: command, model: model, perform: perform, canCheckForUpdates: canCheckForUpdates)
    }
}

/// One menu item. Titles and keys both come from the shortcut table, so Settings → Shortcuts and
/// the menu bar cannot disagree. A view of its own, so that reading the table and the model in
/// `body` is what redraws the item when a key is rebound or the command's availability changes.
private struct CommandItem: View {
    let command: ShellCommand
    let model: AppViewModel
    let perform: (ShellCommand) -> Void
    let canCheckForUpdates: Bool

    var body: some View {
        let button = Button(command.title) { perform(command) }
            .disabled(command == .checkForUpdates ? !canCheckForUpdates : !model.canPerform(command))
        if let shortcut = ShortcutRegistry.shared.shortcut(for: command)?.keyboardShortcut { button.keyboardShortcut(shortcut) }
        else { button }
    }
}
