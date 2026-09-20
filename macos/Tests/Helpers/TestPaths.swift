import Foundation

enum TestPaths {
    /// Locate fixtures independently of the test file's folder depth.
    static let checkout: URL = {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("macos/Craft.xcodeproj/project.pbxproj").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        preconditionFailure("Cannot find the Craft checkout for integration fixtures")
    }()
}
