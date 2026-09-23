import AppKit
import SwiftUI
import Testing

/// Stands in for the deck: an AppKit view under SwiftUI, like `SessionWorkspaceDeck`'s.
private struct DeckProbe: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor private final class OverlayRuntimeFixture: WorkspaceServing {
    func workspaceState(in context: WorkspaceContext) -> SessionWorkspaceState { SessionWorkspaceState() }
}

// A session's toolbar rides on `SessionWorkspaceCoordinatorView`, stacked over the deck in the detail
// column: what it draws there must let clicks through to the page beneath, as it would not if it drew
// the workspace itself again. (`Color.clear` takes no clicks even without `allowsHitTesting(false)`;
// that modifier states the intent.)
@MainActor @Test func theWorkspaceCoordinatorViewLetsClicksThroughToTheDeck() throws {
    let runtime = OverlayRuntimeFixture()
    let context = WorkspaceContext(id: "task:overlay", sourceURL: "", title: "Overlay")
    let coordinator = SessionWorkspaceCoordinator(model: SessionWorkspaceViewModel(context: context, service: runtime), context: context)
    let deck = NSView()
    let host = NSHostingView(rootView: ZStack {
        DeckProbe(view: deck)
        SessionWorkspaceCoordinatorView(coordinator: coordinator)
    })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    for point in [NSPoint(x: 200, y: 150), NSPoint(x: 10, y: 10), NSPoint(x: 390, y: 290)] {
        let hit = try #require(host.hitTest(point))
        #expect(hit === deck || hit.isDescendant(of: deck), "clicks at \(point) stopped at \(hit)")
    }
    window.close()
    _ = runtime
}
