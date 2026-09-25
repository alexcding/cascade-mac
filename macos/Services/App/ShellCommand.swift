import Foundation

public enum ShellCommand: String, Sendable, CaseIterable {
    case overview, terminal, activity, settings, sidebar, refresh, tray, biggerFont, smallerFont, resetFont, checkForUpdates
    case newProject, newSession, newTab, newSidebarTab, openFile, saveFile, closePage, findPage, back, forward, nextPage, previousPage, zoomIn, zoomOut, resetZoom
    case reloadPage
    case runProject, stopBuild
    case nextModel, previousModel
    case nextSession, previousSession
    case session1, session2, session3, session4, session5, session6, session7, session8, session9, session10

    static let sessions: [ShellCommand] = [.session1, .session2, .session3, .session4, .session5, .session6, .session7, .session8, .session9, .session10]
    /// The position in the sidebar's sessions a command selects, from zero: ⌘1–⌘9, then ⌘0.
    var sessionIndex: Int? { Self.sessions.firstIndex(of: self) }
}
