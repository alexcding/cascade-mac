import Foundation

/// Whether a bundle is the packaged app `bundle-backend.sh` produces. The backend is linked into
/// the executable, so the bundled PTY daemon is what distinguishes it from a bare Xcode build.
enum PackagedBundle {
    static func isPackaged(_ bundle: URL, fileManager: FileManager = .default) -> Bool {
        bundle.pathExtension == "app"
            && fileManager.isExecutableFile(atPath: bundle.appendingPathComponent("Contents/Helpers/craft-ptyd").path)
    }
}
