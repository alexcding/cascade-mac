import Foundation

/// The app was called TaskHub before it was Craft. Everything it had stored was filed under that
/// name, so the first launch as Craft carries it across rather than starting empty.
enum LegacyIdentity {
    static let bundleIdentifier = "com.alexcding.taskhub"
    /// The durable database under every name it has had. The backend renames the one it finds.
    private static let databases = ["craft.db", "taskhub.db", "config.db"]

    /// The default data folder, with the old one's contents carried into it. The old path stays
    /// behind as a link: a status line or hook installed earlier points into it, and keeps working
    /// until it is installed again.
    static let supportDirectory = supportDirectory(home: FileManager.default.homeDirectoryForCurrentUser)

    static func supportDirectory(home: URL, fileManager: FileManager = .default) -> URL {
        let support = home.appendingPathComponent("Library/Application Support")
        let current = support.appendingPathComponent("Craft"), legacy = support.appendingPathComponent("TaskHub")
        func holdsData(_ folder: URL) -> Bool {
            databases.contains { fileManager.fileExists(atPath: folder.appendingPathComponent($0).path) }
        }
        // `attributesOfItem` does not follow links, so the link left by an earlier move is not a folder.
        // The new folder existing proves nothing: a status line or a run with `--data-dir` can have
        // made it. Only a database in it means there is nothing left to carry. A move that fails
        // leaves the old folder untouched and is tried again on the next launch.
        guard (try? fileManager.attributesOfItem(atPath: legacy.path))?[.type] as? FileAttributeType == .typeDirectory,
              holdsData(legacy), !holdsData(current) else { return current }
        if !fileManager.fileExists(atPath: current.path) {
            guard (try? fileManager.moveItem(at: legacy, to: current)) != nil else { return current }
        } else {
            // Whatever the new folder already has wins; everything else comes across.
            for item in (try? fileManager.contentsOfDirectory(atPath: legacy.path)) ?? []
            where !fileManager.fileExists(atPath: current.appendingPathComponent(item).path) {
                try? fileManager.moveItem(at: legacy.appendingPathComponent(item), to: current.appendingPathComponent(item))
            }
            guard (try? fileManager.contentsOfDirectory(atPath: legacy.path))?.isEmpty == true,
                  (try? fileManager.removeItem(at: legacy)) != nil else { return current }
        }
        try? fileManager.createSymbolicLink(at: legacy, withDestinationURL: current)
        return current
    }

    /// Preferences are filed by bundle identifier, so the new identifier starts with none. Copies
    /// the old ones once, never over a value already set under the new name. Finding none is not
    /// "done": they are looked for again next launch.
    static func carryDefaults(into defaults: UserDefaults = .standard, from domain: String = bundleIdentifier) {
        let done = "legacyIdentity.defaultsCarried"
        guard !defaults.bool(forKey: done), let old = defaults.persistentDomain(forName: domain) else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: done)
    }
}
