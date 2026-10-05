import Darwin
import Foundation
import UniformTypeIdentifiers

/// What a chat page may name of the disk. The page draws what an agent wrote, so a path it asks
/// to open or reveal is untrusted: it is followed only inside the chat's own folder (its working
/// folder, or a session's worktree), after `..` and every symbolic link are resolved, and a file
/// that would run something when opened is shown in Finder rather than opened.
enum ChatFileAccess {
    /// The page's reads of its folder (`@` search, file-reference previews, which references name
    /// a file). The backend reads them inside the folder the call names: a chat's own when the
    /// call names a chat it has (`threadId`), else the call's `cwd`.
    static let folderMethods: Set<String> = [
        "projects.searchEntries", "projects.readFile", "projects.resolveWorkspaceFileReferences",
    ]

    /// `path` (absolute, or relative to `root`) as the real file it names, when that is `root` or
    /// inside it; nil for anything outside, anything missing, and a chat with no folder.
    static func confined(_ path: String, to root: String) -> String? {
        guard !root.isEmpty, root.hasPrefix("/"), !path.isEmpty, let base = real(root) else { return nil }
        let absolute = path.hasPrefix("/") ? path : (root as NSString).appendingPathComponent(path)
        guard let target = real(absolute) else { return nil }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return target == base || target.hasPrefix(prefix) ? target : nil
    }

    /// The path with `.`, `..` and every symbolic link resolved, as the kernel resolves them; nil
    /// for a path that does not exist.
    static func real(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Extensions that run something, or send the opener somewhere else, when opened in their
    /// default app: Terminal's `.command`/`.terminal`/`.tool`, installers, scripts, and the
    /// location files that point at another file or app.
    private static let runnable: Set<String> = [
        "app", "command", "terminal", "tool", "sh", "bash", "zsh", "csh", "ksh", "tcsh", "fish",
        "pkg", "mpkg", "dmg", "workflow", "action", "scpt", "scptd", "applescript", "osax",
        "prefpane", "saver", "qlgenerator", "kext", "plugin", "bundle", "framework", "xpc", "appex",
        "jar", "webloc", "inetloc", "fileloc", "url", "mobileconfig", "terminalprofile", "itermcolors",
    ]

    /// Whether opening `path` in its default app could run something: an app or other bundle, an
    /// executable file, a script Terminal would run, or a type the system marks executable.
    static func runsWhenOpened(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        if runnable.contains(url.pathExtension.lowercased()) { return true }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isExecutableKey, .contentTypeKey])
        if values?.isPackage == true { return true }
        if values?.isDirectory == true { return false }
        if values?.isExecutable == true || FileManager.default.isExecutableFile(atPath: path) { return true }
        if let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension),
           [.executable, .application, .bundle, .package, .unixExecutable, .shellScript, .appleScript, .osaScript]
            .contains(where: { type.conforms(to: $0) }) {
            return true
        }
        return false
    }
}
