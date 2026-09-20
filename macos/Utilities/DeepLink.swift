import Foundation

struct DeepLink: Equatable {
    let routes: [Route]
    init(_ routes: [Route]) { self.routes = routes }
    init(_ route: Route) { routes = [route] }
    var first: Route? { routes.first }
    func droppingFirst() -> Self { Self(Array(routes.dropFirst())) }

    /// Validate the whole chain before changing any visible navigation state.
    var destination: SidebarDestination? {
        guard case .destination(let destination) = first else { return nil }
        if routes.count == 1 { return destination }
        guard routes.count == 2, case .project = destination,
              case .projectSection = routes[1] else { return nil }
        return destination
    }
}

protocol DeepLinkRouting {
    func deepLink(for url: URL) -> DeepLink?
    func url(for deepLink: DeepLink) -> URL?
}

protocol DeepLinkRouteHandling {
    func parse(_ components: [String]) -> DeepLink?
    func print(_ deepLink: DeepLink) -> [String]?
}

/// One origin and one path grammar, with injected handlers tried in order.
struct CraftRouter: DeepLinkRouting {
    let handlers: [any DeepLinkRouteHandling]
    init(handlers: [any DeepLinkRouteHandling] = [RootRouteHandler(), ProjectRouteHandler(), SessionRouteHandler()]) {
        self.handlers = handlers
    }

    func deepLink(for url: URL) -> DeepLink? {
        guard url.absoluteString.utf8.count <= 2048,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "craft", components.host?.lowercased() == "app",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil else { return nil }
        // The contract uses ASCII route names and opaque IDs. Reject escaped separators,
        // double escaping and empty segments instead of normalizing ambiguous paths.
        let path = components.percentEncodedPath
        guard path.hasPrefix("/") else { return nil }
        let segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.allSatisfy(Self.validComponent) else { return nil }
        return handlers.lazy.compactMap { $0.parse(segments) }.first
    }

    func url(for deepLink: DeepLink) -> URL? {
        guard deepLink.destination != nil,
              let segments = handlers.lazy.compactMap({ $0.print(deepLink) }).first,
              segments.allSatisfy(Self.validComponent) else { return nil }
        return URL(string: "craft://app/" + segments.joined(separator: "/"))
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value != "." && value != ".."
            && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || [45, 46, 95, 126].contains($0) }
    }
}

struct RootRouteHandler: DeepLinkRouteHandling {
    private let routes: [String: SidebarDestination] = ["overview": .overview, "terminal": .terminal]
    func parse(_ components: [String]) -> DeepLink? {
        guard components.count == 1, let destination = routes[components[0]] else { return nil }
        return DeepLink(.destination(destination))
    }
    func print(_ deepLink: DeepLink) -> [String]? {
        guard deepLink.routes.count == 1, let destination = deepLink.destination,
              let name = routes.first(where: { $0.value == destination })?.key else { return nil }
        return [name]
    }
}

struct ProjectRouteHandler: DeepLinkRouteHandling {
    private let sections: [String: ProjectSection] = ["prs": .prs, "tickets": .tickets, "board": .board,
                                                     "workflows": .workflows, "automation": .automation, "settings": .settings]
    func parse(_ components: [String]) -> DeepLink? {
        guard (2...3).contains(components.count), components[0] == "projects" else { return nil }
        let root = Route.destination(.project(components[1]))
        if components.count == 2 { return DeepLink(root) }
        guard let section = sections[components[2]] else { return nil }
        return DeepLink([root, .projectSection(section)])
    }
    func print(_ deepLink: DeepLink) -> [String]? {
        guard case .project(let id) = deepLink.destination else { return nil }
        if deepLink.routes.count == 1 { return ["projects", id] }
        guard case .projectSection(let section) = deepLink.routes[1],
              let name = sections.first(where: { $0.value == section })?.key else { return nil }
        return ["projects", id, name]
    }
}

struct SessionRouteHandler: DeepLinkRouteHandling {
    func parse(_ components: [String]) -> DeepLink? {
        guard components.count == 2, components[0] == "sessions" else { return nil }
        return DeepLink(.destination(.session(components[1])))
    }
    func print(_ deepLink: DeepLink) -> [String]? {
        guard deepLink.routes.count == 1, case .session(let id) = deepLink.destination else { return nil }
        return ["sessions", id]
    }
}
