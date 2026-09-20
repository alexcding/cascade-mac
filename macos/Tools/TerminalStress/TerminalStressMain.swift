import AppKit
import Darwin
import Foundation

@MainActor private final class StressDelegate: NSObject, NSApplicationDelegate {
    private var task: Task<Void, Never>?
    func applicationDidFinishLaunching(_ notification: Notification) {
        task = Task {
            do {
                let args = ProcessInfo.processInfo.arguments
                func argument(_ name: String) -> String? {
                    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
                    return args[index + 1]
                }
                let seconds = Double(argument("--seconds") ?? "10") ?? 0
                let root = URL(fileURLWithPath: argument("--root") ?? FileManager.default.currentDirectoryPath)
                let report = URL(fileURLWithPath: argument("--report") ?? "/tmp/craft-terminal-stress.json")
                let helper = argument("--helper").map { URL(fileURLWithPath: $0) }
                _ = try await TerminalStressHarness.run(seconds: seconds, root: root, reportURL: report, helperURL: helper)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data(("Terminal stress failed: " + error.localizedDescription + "\n").utf8))
                exit(1)
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        task?.cancel()
        return .terminateCancel // The task drains and stops only its own fixtures.
    }
}

@main struct TerminalStressMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = StressDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
