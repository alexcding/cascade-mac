import Foundation
import GhosttyTerminal

/// A shell keeps its creation identity through app rebuilds and reconnects.
/// The daemon copies terminfo before spawning, then returns the durable path.
struct PtyTerminalProfile: Codable, Sendable {
    let version: String
    let terminfoDirectory: String
    var resourcesDirectory: String? = nil

    func validate() throws {
        guard !version.isEmpty, version.utf8.count <= 128,
              version.utf8.allSatisfy({ (0x21...0x7e).contains($0) }),
              terminfoDirectory.hasPrefix("/"), !terminfoDirectory.contains("\0") else {
            throw PtyError.connection("The terminal creation profile is invalid.")
        }
        if let resourcesDirectory, !resourcesDirectory.hasPrefix("/") || resourcesDirectory.contains("\0") {
            throw PtyError.connection("The terminal shell-resource profile is invalid.")
        }
    }

    static func current() throws -> Self {
        guard let version = InMemoryTerminalSession.runtimeVersion,
              let directory = GhosttyRuntimeResources.terminfoDirectoryURL,
              let resources = GhosttyRuntimeResources.directoryURL,
              FileManager.default.isReadableFile(atPath: directory.appendingPathComponent("78/xterm-ghostty").path) else {
            throw PtyError.connection("The native terminal version or bundled terminfo is missing. Rebuild the app before creating a terminal.")
        }
        let profile = Self(version: version, terminfoDirectory: directory.path, resourcesDirectory: resources.path)
        try profile.validate()
        return profile
    }
}
