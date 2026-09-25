import Foundation
import Darwin

/// One copy of Cascade per data folder. The folder holds the database and names the terminal
/// daemon, so two copies on one folder would share both, and whichever quit first would take the
/// other's terminals with it. Copies on different folders share nothing and may run side by side.
///
/// The lock is an `flock` on a file in the folder: the kernel drops it when the process exits,
/// however it exits, so a crash never leaves a copy locked out.
enum InstanceLock {
    enum Outcome: Equatable {
        case acquired
        /// Another copy holds the folder. Its pid, when it wrote one.
        case held(by: pid_t?)
    }

    /// The open lock file, held for the life of the process.
    nonisolated(unsafe) private static var descriptor: Int32 = -1

    static func acquire(in directory: URL) -> Outcome {
        guard descriptor < 0 else { return .acquired }
        let path = directory.appendingPathComponent(".instance.lock").path
        // A folder that cannot be made or a file that cannot be opened is left to the backend to
        // report; refusing to start over it would hide the real error behind a silent exit.
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
        else { return .acquired }
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .acquired }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            defer { close(fd) }
            var buffer = [UInt8](repeating: 0, count: 32)
            let count = pread(fd, &buffer, buffer.count, 0)
            let text = count > 0 ? String(decoding: buffer[..<count], as: UTF8.self) : ""
            return .held(by: pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let pid = Array("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
        ftruncate(fd, 0)
        _ = pwrite(fd, pid, pid.count, 0)
        descriptor = fd
        return .acquired
    }
}
