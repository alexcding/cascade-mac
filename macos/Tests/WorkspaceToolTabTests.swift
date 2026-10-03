import Foundation
import Testing
@testable import Cascade

/// Changes, Simulator and the Files picker are tabs beside the pages and files: the active tab
/// decides what the pane shows and which section's tabs the strip holds, and they are saved
/// with the rest.
@MainActor struct WorkspaceToolTabTests {
    @Test func aToolOpensAsATabAndItsTabDecidesThePane() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        let page = try #require(context.open("https://example.com/home", title: "Home"))
        context.openTool(.changes)
        #expect(context.tabs.map(\.id) == [page.id, WorkspaceTool.changes.id])
        #expect(context.activeTool == .changes && context.pane == .diff)
        context.openTool(.files)
        #expect(context.activeTool == .files && context.pane == .term)
        context.openTool(.changes)
        #expect(context.tools == [.changes, .files], "a tool already open is selected, not opened again")
        context.select(.page(page))
        #expect(context.pane == .term && context.activeTool == nil)
        context.setPane(.simulator)
        #expect(context.activeTool == .simulator && context.pane == .simulator, "asking for a pane opens its tab")
    }

    @Test func theStripShowsThePagesAndFilesTogether() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        let page = try #require(context.open("https://example.com/home", title: "Home"))
        let other = try #require(context.open("https://example.com/other", title: "Other"))
        let file = try #require(context.openFile("/tmp/sections.swift"))
        #expect(context.section == .browser && context.stripTabs.map(\.id) == [page.id, other.id, file.id], "a file among the pages")
        context.select(.page(page))
        #expect(context.section == .browser && context.stripTabs.map(\.id) == [page.id, other.id, file.id])
        context.openTool(.changes)
        #expect(context.section == .diff && context.stripTabs.isEmpty)
        context.openTool(.simulator)
        #expect(context.section == .browser && context.stripTabs.map(\.id) == [page.id, WorkspaceTool.simulator.id, other.id, file.id],
                "the Simulator is a tab of the strip, opened beside the tab it was opened from")
        context.select(.page(page))
        context.cycle(1)
        #expect(context.activeTool == .simulator, "cycling walks the Simulator")
        context.cycle(1)
        #expect(context.activePage === other)
        context.cycle(1)
        #expect(context.activeDocument === file, "and the pages and files")
        context.cycle(1)
        #expect(context.activePage === page)
    }

    @Test func theTabsReturnToTheirLastTabOrOpenABlankPage() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        context.showSection(.browser)
        #expect(context.activePage?.controls.isBlank == true, "no tab open: a blank page")
        let page = try #require(context.open("https://example.com/home", title: "Home"))
        _ = try #require(context.open("https://example.com/other", title: "Other"))
        context.select(.page(page))
        context.openTool(.changes)
        context.showSection(.browser)
        #expect(context.activePage === page, "the page last selected, not the last opened")
        let file = try #require(context.openFile("/tmp/sections.swift"))
        context.openTool(.changes)
        context.showSection(.browser)
        #expect(context.activeDocument === file, "or the file")
    }

    @Test func leavingDiffWithOnlyTheSimulatorShowsItNotANewTab() {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        context.openTool(.simulator)
        context.openTool(.changes)
        context.showSection(.browser)
        #expect(context.activeTool == .simulator && context.pages.isEmpty, "the picker's Tabs")
        context.openTool(.changes)
        context.showPages()
        #expect(context.activeTool == .simulator && context.pages.isEmpty, "Diff's toggle")
    }

    @Test func closingTheSimulatorFallsBackToTheStripNotToDiff() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        let page = try #require(context.open("https://example.com/home", title: "Home"))
        context.openTool(.changes)
        context.openTool(.simulator)
        #expect(context.section == .browser && context.pane == .simulator)
        context.close(.tool(.simulator))
        #expect(context.activePage === page && context.section == .browser, "the nearest tab of the strip")
    }

    // The pane's own blank page is a New Tab in the strip; what is typed or picked in it takes its
    // place. The Files explorer is such a tab too, until a file picked in it takes its place.
    @Test func aBlankTabOrTheExplorerIsTheNewTabUntilFilled() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        let filler = context.openBlankPage()
        context.fillerPageID = filler.id
        #expect(context.stripTabs.map(\.id) == [filler.id], "a New Tab")
        let page = context.openBlankPage()
        #expect(page === filler && context.pages.count == 1, "New Tab takes the blank page, not a second one")
        context.openTool(.files, replacingBlank: true)
        #expect(context.stripTabs.map(\.id) == [WorkspaceTool.files.id], "Files took its place")
        context.openFromTree("/tmp/tools/picked.swift")
        #expect(context.stripTabs.count == 1 && context.activeDocument != nil, "the file took the explorer's place")
    }

    @Test func cyclingFromATabTheStripHidesStartsAtTheEnds() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        let first = try #require(context.openFile("/tmp/a.swift"))
        _ = try #require(context.openFile("/tmp/b.swift"))
        let last = try #require(context.openFile("/tmp/c.swift"))
        context.openTool(.files)
        context.cycle(1)
        #expect(context.activeDocument === first, "next from the picker is the first file, not the second")
        context.openTool(.files)
        context.cycle(-1)
        #expect(context.activeDocument === last)
    }

    @Test func aWorkspaceSavedOnTheSimulatorReopensOnItsPageNotAnotherTool() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        context.openTool(.changes)
        let page = try #require(context.open("https://example.com/home", title: "Home"))
        context.openTool(.simulator)
        #expect(context.snapshot.activeID == page.id)
    }

    // A file picked from the tree goes on in the explorer's place, as a link does in a browser tab:
    // Back returns to the explorer and Forward to the file, in the one tab, and a new pick drops
    // what was ahead.
    @Test func aFileTabGoesBackAndForwardThroughWhatItShowed() throws {
        let context = WorkspaceContext(id: "task:trail", sourceURL: "session:trail", title: "")
        let page = try #require(context.open("https://example.com/home", title: "Home"))
        context.openTool(.files)
        #expect(!context.canGoBackInFiles && !context.canGoForwardInFiles)
        context.openFromTree("/tmp/trail/first.swift")
        #expect(context.activeDocument?.record.path == "/tmp/trail/first.swift" && !context.tools.contains(.files))
        #expect(context.canGoBackInFiles && !context.canGoForwardInFiles)
        context.openFromTree("/tmp/trail/second.swift")
        #expect(context.documents.map(\.record.path) == ["/tmp/trail/second.swift"], "the tab went on, not a second one")
        context.goBackInFiles()
        #expect(context.activeDocument?.record.path == "/tmp/trail/first.swift" && context.canGoForwardInFiles)
        context.goBackInFiles()
        #expect(context.activeTool == .files && context.documents.isEmpty && !context.canGoBackInFiles)
        #expect(context.tabs.map(\.id) == [page.id, WorkspaceTool.files.id], "in the same place")
        context.goForwardInFiles()
        #expect(context.activeDocument?.record.path == "/tmp/trail/first.swift")
        context.openFromTree("/tmp/trail/third.swift")
        #expect(!context.canGoForwardInFiles, "a new pick drops what was ahead")
        context.goBackInFiles()
        #expect(context.activeDocument?.record.path == "/tmp/trail/first.swift")
        context.select(.page(page))
        #expect(!context.canGoBackInFiles, "a page has no file trail")
    }

    // A pick already open in another tab selects that tab, its own trail kept, and leaves this one.
    @Test func aPickOpenInAnotherTabSelectsItAndKeepsBothTrails() throws {
        let context = WorkspaceContext(id: "task:trail", sourceURL: "session:trail", title: "")
        context.openTool(.files)
        context.openFromTree("/tmp/trail/b.swift")
        let b = try #require(context.activeDocument)
        #expect(context.canGoBackInFiles)
        let a = try #require(context.openFile("/tmp/trail/a.swift"))
        context.openFromTree("/tmp/trail/b.swift")
        #expect(context.activeDocument === b && context.canGoBackInFiles, "B's own way back is kept")
        #expect(context.documents.contains { $0 === a }, "the tab left is not closed")
    }

    // Closing the explorer's tab falls back to the tabs, never to Diff beside it.
    @Test func closingTheExplorerStaysInTheTabs() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        let blank = context.openBlankPage()
        context.setPane(.diff)
        context.select(.page(blank))
        context.openTool(.files, replacingBlank: true)
        #expect(context.tabs.map(\.id) == [WorkspaceTool.files.id, WorkspaceTool.changes.id])
        context.close(.tool(.files))
        #expect(context.activeTool != .changes && context.pane == .term, "not the Changes tab beside it")
    }

    @Test func closingATabSelectsTheNearestPageOrFile() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        let page = try #require(context.open("https://example.com/home", title: "Home"))
        let first = try #require(context.openFile("/tmp/first.swift"))
        let second = try #require(context.openFile("/tmp/second.swift"))
        context.remove(second)
        #expect(context.activeDocument === first, "the file beside it")
        context.remove(first)
        #expect(context.activePage === page, "the last file gone: the page before it")
        context.close(page)
        #expect(context.activeID == nil && context.pane == .term, "the last page gone: the bar opens a blank one")
    }

    @Test func closingAToolSelectsItsNeighbourAndTheLastTabLeavesThePagesPane() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        let page = try #require(context.open("https://example.com/home", title: "Home"))
        context.openTool(.changes)
        context.close(.tool(.changes))
        #expect(context.tools.isEmpty && context.activePage === page && context.pane == .term)
        context.close(page)
        context.openTool(.simulator)
        context.close(.tool(.simulator))
        #expect(context.tabs.isEmpty && context.activeID == nil && context.pane == .term)
    }

    @Test func leavingAToolForThePagesReturnsToTheLastPageOrFile() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        let file = try #require(context.openFile("/tmp/tools.swift"))
        context.openTool(.changes)
        context.setPane(.term)
        #expect(context.activeDocument === file && context.pane == .term)
        #expect(context.tools == [.changes], "the tool's tab stays open")
    }

    @Test func leavingTheOnlyToolOpensANewTab() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        context.openTool(.changes)
        context.showPages()
        #expect(context.activePage?.controls.isBlank == true && context.activeTool == nil && context.pane == .term)
        #expect(context.tools == [.changes], "the tool's tab stays")
    }

    @Test func aNewTabFromOnlyAToolIsOneTab() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        context.openTool(.changes)
        context.openBlankPage()
        #expect(context.pages.count == 1 && context.pane == .term, "Cmd-T's own page, and no second one")
    }

    @Test func leavingAToolSelectsThePageAsAClickWould() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        let page = try #require(context.open("https://example.com/home", title: "Home"))
        var activated: [String] = []
        context.activatePage = { activated.append($0.id) }
        context.openTool(.changes)
        context.setPane(.term)
        #expect(context.activePage === page && activated == [page.id], "a suspended page is loaded again")
    }

    @Test func toolTabsAreSavedAndRestoredInTheirPlaces() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        let page = try #require(context.open("https://example.com/home", title: "Home"))
        context.openTool(.simulator)
        context.select(.page(page))
        context.openTool(.changes)
        let encoded = try JSONEncoder().encode(context.snapshot)
        let restored = WorkspaceContext(id: context.id, sourceURL: "session:tools", title: "",
                                        snapshot: try JSONDecoder().decode(ContextSnapshot.self, from: encoded))
        #expect(restored.tabs.map(\.id) == [page.id, WorkspaceTool.changes.id], "the Simulator's stream was this launch's")
        #expect(restored.activeTool == .changes && restored.pane == .diff)
        context.openTool(.simulator)
        let onSimulator = WorkspaceContext(id: context.id, sourceURL: "session:tools", title: "", snapshot: context.snapshot)
        #expect(onSimulator.activeTool == nil && onSimulator.pane == .term && onSimulator.activeID == page.id)
    }

    @Test func aToolLeavesABlankTabAlone() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        let typing = context.openBlankPage()
        context.openTool(.files)
        #expect(context.pages.contains { $0 === typing } && context.activeTool == .files)
    }

    @Test func theRailGoesBackToTheTabShownBeforeARestore() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        let first = try #require(context.open("https://example.com/a", title: "A"))
        _ = try #require(context.open("https://example.com/b", title: "B"))
        context.select(.page(first))
        let restored = WorkspaceContext(id: context.id, sourceURL: "session:tools", title: "", snapshot: context.snapshot)
        restored.openTool(.changes)
        restored.showSection(.browser)
        #expect(restored.activePage?.id == first.id, "the page that was shown, not the last in the order")
    }

    @Test func aSaveOnTheSimulatorKeepsTheFileShownLast() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        _ = try #require(context.open("https://example.com/a", title: "A"))
        let file = try #require(context.openFile("/tmp/last.swift"))
        context.openTool(.simulator)
        #expect(context.snapshot.activeID == file.id)
    }

    @Test func aSnapshotFromBeforeToolTabsShowingDiffGetsAChangesTab() throws {
        var snapshot = ContextSnapshot()
        snapshot.pane = "diff"
        let context = WorkspaceContext(id: "task:old", sourceURL: "session:old", title: "", snapshot: snapshot)
        #expect(context.tools == [.changes] && context.activeTool == .changes && context.pane == .diff)
        snapshot.pane = "off"
        let hidden = WorkspaceContext(id: "task:old", sourceURL: "session:old", title: "", snapshot: snapshot)
        #expect(hidden.tools.isEmpty && hidden.pane == .off)
    }
}
