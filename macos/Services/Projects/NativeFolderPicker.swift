import AppKit

@MainActor enum NativeFolderPicker {
    static func choose() async -> String? {
        guard let window = NSApp.keyWindow else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose Workspace"
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.url?.path : nil
    }
}
