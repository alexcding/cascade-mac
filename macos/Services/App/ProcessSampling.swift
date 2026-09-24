import Foundation

/// What WebKit holds for the app's pages. `content` is the part suspending pages gives back.
struct WebFootprint: Equatable, Sendable {
    var total: UInt64 = 0
    var content: UInt64 = 0
}

/// What the memory pools read from the process table: the physical footprint a process tree holds,
/// the figure Activity Monitor reports, and the process groups it runs in.
protocol ProcessSampling: Sendable {
    /// Each tree's footprint, its root and every descendant, under the key it was asked for. A
    /// tree that could not be read is left out.
    func footprints(of roots: [String: Int32]) async -> [String: UInt64]
    func webFootprint() async -> WebFootprint
    /// The process group of `root` and of every process below it; nil unless the whole tree could
    /// be read.
    func processGroups(of root: Int32) async -> Set<Int32>?
}
