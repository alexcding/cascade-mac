import Foundation

public enum ShellCommand: String, Sendable, CaseIterable {
    case overview, terminal, activity, settings, sidebar, refresh, tray, biggerFont, smallerFont, resetFont, checkForUpdates
    case newProject, newSession, newTab, newSidebarTab, openFile, saveFile, closePage, findPage, back, forward, nextPage, previousPage, zoomIn, zoomOut, resetZoom
    case reloadPage
    case runProject, stopBuild
    case nextModel, previousModel
    case tab1, tab2, tab3, tab4, tab5, tab6, tab7, tab8, tab9

    static let tabs: [ShellCommand] = [.tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9]
    /// The position a tab command selects, from zero. The ninth is the last tab, as in Safari.
    var tabIndex: Int? { Self.tabs.firstIndex(of: self) }
}
