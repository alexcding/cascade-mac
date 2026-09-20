import Foundation

extension AppCoordinator {
    @discardableResult func handle(url: URL) -> Bool {
        guard let link = router.deepLink(for: url), link.destination != nil else { return false }
        enqueue(link)
        return true
    }

    func enqueue(_ link: DeepLink) {
        guard link.destination != nil else { return }
        pendingDeepLink = link // Latest valid external intent wins while navigation is deferred.
        routingError = nil
        processPendingDeepLink()
    }

    func setRoutingReady(_ ready: Bool) {
        routingReady = ready
        if ready { processPendingDeepLink() }
    }

    func discardQueuedDeepLink() { pendingDeepLink = nil; routingError = nil }

    func processPendingDeepLink() {
        guard routingReady, canRoute, canOpenExternalRoute(), let runtime = rootRuntime,
              let link = pendingDeepLink, let destination = link.destination else { return }
        pendingDeepLink = nil // Clear before callbacks; reentrant delivery cannot replay this link.
        let state = runtime.rootState()
        switch destination {
        case .project(let id) where !state.projects.contains(where: { $0.id == id }):
            routingError = "The linked project is no longer available."
            return
        case .session(let id) where !state.sessions.contains(where: { $0.id == id }):
            routingError = "The linked session is no longer available."
            return
        case .tab(let id) where !state.tabs.contains(where: { $0.id == id }):
            routingError = "The linked page is no longer available."
            return
        default: break
        }
        navigate(to: destination)
        let remainder = link.droppingFirst()
        guard !remainder.routes.isEmpty else { return }
        guard case .project(let id) = destination, let model = runtime.rootState().projectModels[id] else {
            routingError = "The linked project section is not available yet."
            return
        }
        let child = installProject(model, runtime: runtime as? any ProjectCoordinating)
        _ = child.navigate(to: remainder)
    }

    /// Finish the originating operation's callbacks before applying a queued link.
    /// AppKit sheet-end delivery also retries, after the actual window detaches.
    func schedulePendingDeepLink() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.processPendingDeepLink()
        }
    }
}
