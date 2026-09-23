import Observation

/// Whether `change` invalidates what `read` observed: whether a SwiftUI view that reads the same
/// properties would be redrawn by it. An `@Observable` property notifies on every write, equal
/// value or not, so this is how a test catches a write that changes nothing.
@MainActor func invalidates(_ read: () -> Void, by change: () -> Void) -> Bool {
    final class Flag: @unchecked Sendable { var fired = false }
    let flag = Flag()
    withObservationTracking(read, onChange: { flag.fired = true })
    change()
    return flag.fired
}
