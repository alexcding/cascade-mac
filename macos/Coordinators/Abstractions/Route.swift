import Foundation

/// Where navigation can go. Routes are separate from the `Action`s view models emit: a
/// coordinator translates an action into a route, then builds the route's `Destination`.
/// Deep links are chains of routes; each coordinator consumes its prefix.
enum Route: Hashable {
    /// A sidebar-level screen: overview, activity, settings, terminal, a project, session or tab.
    case destination(SidebarDestination)
    /// A section inside the selected project, consumed by `ProjectCoordinator`.
    case projectSection(ProjectSection)
    /// The Dashboard's full ticket list, pushed over its home screen.
    case dashboardTickets
}
