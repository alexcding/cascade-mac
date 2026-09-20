import Foundation

/// Navigation coordination, record-ios style. A coordinator owns a `root` destination and
/// a `path` of pushed destinations, turns `Route`s into `Destination`s, and handles the
/// `Action`s its view models and child coordinators emit, forwarding what it does not own.
///
/// Conforming types are `@MainActor`: navigation state mutates on the main thread only.
@MainActor
protocol Coordinatable: HashableObject, Identifiable {
    /// The destinations pushed above `root`, in order.
    var path: [Destination] { get set }

    /// What the coordinator shows at the base of its hierarchy. For scene-style
    /// coordinators, assigning `root` switches the visible scene.
    var root: Destination { get set }

    /// The destination the user is looking at, drilling through child coordinators.
    var visibleDestination: Destination { get }

    /// Navigates to a route by building its destination and pushing it.
    func navigate(to route: Route)

    /// Builds the destination for a route and wires its action closure back to `handle`.
    func makeDestination(for route: Route) -> Destination

    /// Handles an action from a view model or child coordinator, or forwards it up.
    func handle(_ action: Action)
}

extension Coordinatable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    var visibleDestination: Destination { (path.last ?? root).visibleDestination }

    func popToRoot() { path.removeAll() }

    @discardableResult
    func pop() -> Destination? { path.popLast() }

    func navigate(to route: Route) { path.append(makeDestination(for: route)) }
}
