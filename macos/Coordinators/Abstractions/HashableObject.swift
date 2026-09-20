import Foundation

/// Reference types that hash and compare by identity, so a coordinator or view model can
/// sit inside a `Hashable` `Destination` without exposing its state to equality.
protocol HashableObject: AnyObject, Hashable {}

extension HashableObject {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
