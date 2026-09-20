import Foundation

/// Palette defaults, foreground/background/cursor and the native color scheme.
/// The fixed wire shape is shared with the pinned native bridge and Rust helper.
struct PtyAppearance: Codable, Equatable, Sendable {
    let values: [UInt32]
    func validate() throws {
        guard values.count == 260, values.prefix(258).allSatisfy({ $0 <= 0xFFFFFF }),
              values[258] <= 0xFFFFFF || values[258] == UInt32.max,
              values[259] <= 1 else {
            throw PtyError.connection("The terminal returned invalid configured colors.")
        }
    }
}
