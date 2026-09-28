import Foundation

/// Where the app keeps its data.
enum DataDirectory {
    /// The default data folder.
    static let standard = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cascade")

    /// The data folder this run was given, if any. A run with its own folder shares nothing with the
    /// installed app — not the database, not the terminal daemon — so it may run beside it.
    static var explicit: String? {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count { return args[i + 1] }
        return ProcessInfo.processInfo.environment["CASCADE_DATA_DIR"]
    }
}
