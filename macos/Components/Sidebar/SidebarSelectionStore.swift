import Foundation

@MainActor protocol SidebarSelectionPersisting {
    func load() -> SidebarDestination?
    func save(_ destination: SidebarDestination)
}

@MainActor final class TransientSidebarSelectionStore: SidebarSelectionPersisting {
    private var value: SidebarDestination?
    init(_ value: SidebarDestination? = nil) { self.value = value }
    func load() -> SidebarDestination? { value }
    func save(_ destination: SidebarDestination) { value = destination }
}

@MainActor struct UserDefaultsSidebarSelectionStore: SidebarSelectionPersisting {
    let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    func load() -> SidebarDestination? {
        guard let data = preferences.data(forKey: "sidebar.selection") else { return nil }
        return try? JSONDecoder().decode(SidebarDestination.self, from: data)
    }
    func save(_ destination: SidebarDestination) {
        if let data = try? JSONEncoder().encode(destination) { preferences.set(data, forKey: "sidebar.selection") }
    }
}

/// The order the user dragged the sidebar's projects and sessions into. It is how this window
/// is arranged, not a fact about the projects, so it lives with the app and the backend never
/// hears of it. Ids the lists do not know yet — a new project, a new session — come last.
struct SidebarOrder: Equatable {
    var projects: [String] = []
    var sessions: [String] = []
    /// The Pinned section's own order. Pinning appends and unpinning forgets, so a session
    /// that is unpinned and pinned again comes back last, not where it used to be.
    var pinned: [String] = []

    /// The Pinned order after `id` was pinned or unpinned, given the ids Pinned showed before.
    func pinning(_ id: String, pinned isPinned: Bool, shown: [String]) -> Self {
        var next = self
        next.pinned = shown.filter { $0 != id } + (isPinned ? [id] : [])
        return next
    }
}

@MainActor protocol SidebarOrderPersisting {
    func load() -> SidebarOrder
    func save(_ order: SidebarOrder)
}

@MainActor final class TransientSidebarOrderStore: SidebarOrderPersisting {
    private var value: SidebarOrder
    init(_ value: SidebarOrder = .init()) { self.value = value }
    func load() -> SidebarOrder { value }
    func save(_ order: SidebarOrder) { value = order }
}

@MainActor struct UserDefaultsSidebarOrderStore: SidebarOrderPersisting {
    let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    func load() -> SidebarOrder {
        .init(projects: preferences.stringArray(forKey: "sidebar.projectOrder") ?? [],
              sessions: preferences.stringArray(forKey: "sidebar.sessionOrder") ?? [],
              pinned: preferences.stringArray(forKey: "sidebar.pinnedOrder") ?? [])
    }
    func save(_ order: SidebarOrder) {
        preferences.set(order.projects, forKey: "sidebar.projectOrder")
        preferences.set(order.sessions, forKey: "sidebar.sessionOrder")
        preferences.set(order.pinned, forKey: "sidebar.pinnedOrder")
    }
}
