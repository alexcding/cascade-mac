import Foundation

extension FileManager {
    /// Moves a store's file it could not read out of the way as `<file>.broken` (or `.broken-2`,
    /// and so on: an earlier copy is never thrown away), for a look, and frees the path. `false`
    /// when it could not be moved, in which case the path is still not the store's to write.
    func setAsideBroken(_ fileURL: URL) -> Bool {
        var aside = fileURL.appendingPathExtension("broken")
        var attempt = 1
        while fileExists(atPath: aside.path) {
            attempt += 1
            aside = fileURL.appendingPathExtension("broken-\(attempt)")
        }
        return (try? moveItem(at: fileURL, to: aside)) != nil
    }
}
