import Foundation
import GhosttyTerminal

struct PtyGeometry: Codable, Sendable, Equatable {
    let cols: UInt16
    let rows: UInt16
    let cellWidthPixels: UInt32
    let cellHeightPixels: UInt32

    init(_ viewport: InMemoryTerminalViewport) {
        cols = viewport.columns; rows = viewport.rows
        cellWidthPixels = viewport.cellWidthPixels; cellHeightPixels = viewport.cellHeightPixels
    }

    func validate() throws {
        guard cols > 0, rows > 0, cols <= 4096, rows <= 4096,
              UInt32(cols) * UInt32(rows) <= 1024 * 1024,
              cellWidthPixels > 0, cellHeightPixels > 0,
              UInt64(cols) * UInt64(cellWidthPixels) <= UInt16.max,
              UInt64(rows) * UInt64(cellHeightPixels) <= UInt16.max else {
            throw PtyError.connection("The terminal geometry exceeds the supported grid or pixel dimensions.")
        }
    }
}
