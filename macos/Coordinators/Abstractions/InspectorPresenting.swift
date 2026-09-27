import Foundation

/// A screen with a pane in the window's inspector column (`MainSplitViewController`): a session's
/// context pane, or a project's settings. The column follows `showsInspector` while the screen is on
/// show, and a pane the user opens or collapses from the divider or a menu is told back through
/// `setInspectorPresented`, so the column and the screen never disagree.
@MainActor protocol InspectorPresenting: AnyObject {
    var showsInspector: Bool { get }
    /// Whether the screen has anything to put in the column right now.
    var canToggleInspector: Bool { get }
    func setInspectorPresented(_ presented: Bool)
}

extension SessionWorkspaceViewModel: InspectorPresenting {
    var canToggleInspector: Bool { canToggleContext }
    func setInspectorPresented(_ presented: Bool) { setContextPresented(presented) }
}
