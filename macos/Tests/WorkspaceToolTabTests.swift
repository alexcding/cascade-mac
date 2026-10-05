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
        #expect(context.tabs.map(\.id) == [page.id, other.id, file.id], "a file among the pages")
        context.select(.page(page))
        context.openTool(.changes)
        context.openTool(.simulator)
        #expect(context.tabs.map(\.id) == [page.id, WorkspaceTool.changes.id, WorkspaceTool.simulator.id, other.id, file.id],
                "Diff and the Simulator are tabs of the strip, each opened beside the tab it was opened from")
        context.select(.page(page))
        context.cycle(1)
        #expect(context.activeTool == .changes && context.pane == .diff, "cycling walks Diff")
        context.cycle(1)
        #expect(context.activeTool == .simulator, "and the Simulator")
        context.cycle(1)
        #expect(context.activePage === other)
        context.cycle(1)
        #expect(context.activeDocument === file, "and the pages and files")
        context.cycle(1)
        #expect(context.activePage === page)
    }

    @Test func leavingDiffReturnsToTheLastPageOrFileOrOpensABlankPage() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        context.showPages()
        #expect(context.activeID == nil && context.pane == .term, "no tab open: the pages, where the bar opens a blank page")
        let page = try #require(context.open("https://example.com/home", title: "Home"))
        _ = try #require(context.open("https://example.com/other", title: "Other"))
        context.select(.page(page))
        context.openTool(.changes)
        context.showPages()
        #expect(context.activePage === page, "the page last selected, not the last opened")
        let file = try #require(context.openFile("/tmp/sections.swift"))
        context.openTool(.changes)
        context.showPages()
        #expect(context.activeDocument === file, "or the file")
    }

    @Test func leavingDiffWithOnlyTheSimulatorShowsItNotANewTab() {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        context.openTool(.simulator)
        context.openTool(.changes)
        context.showPages()
        #expect(context.activeTool == .simulator && context.pages.isEmpty)
    }

    @Test func closingATabSelectsItsNearestNeighbour() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        let page = try #require(context.open("https://example.com/home", title: "Home"))
        context.openTool(.simulator)
        context.openTool(.changes)
        context.select(.tool(.simulator))
        #expect(context.pane == .simulator)
        context.close(.tool(.simulator))
        #expect(context.activeTool == .changes && context.pane == .diff, "the tab that took its place")
        context.close(.tool(.changes))
        #expect(context.activePage === page && context.pane == .term, "else the one before it")
    }

    // The pane's own blank page is a New Tab in the strip; what is typed or picked in it takes its
    // place. The Files explorer stays a tab of its own, and each file picked in it opens beside it.
    @Test func aBlankTabOrTheExplorerIsTheNewTabUntilFilled() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        let filler = context.openBlankPage()
        context.fillerPageID = filler.id
        #expect(context.tabs.map(\.id) == [filler.id], "a New Tab")
        let page = context.openBlankPage()
        #expect(page === filler && context.pages.count == 1, "New Tab takes the blank page, not a second one")
        context.openTool(.files, replacingBlank: true)
        #expect(context.tabs.map(\.id) == [WorkspaceTool.files.id], "Files took its place")
        context.openFromTree("/tmp/tools/picked.swift")
        let picked = try #require(context.activeDocument)
        #expect(context.tabs.map(\.id) == [WorkspaceTool.files.id, picked.id], "the explorer stays")
    }

    // Files has as many tabs as are opened, as web pages do; the other tools one each. Each is saved.
    @Test func filesOpensAnotherTabEachTimeAndTheyAreSaved() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        context.openTool(.files, another: true)
        context.openTool(.files, another: true)
        context.openTool(.changes, another: true)
        context.openTool(.changes, another: true)
        let second = WorkspaceToolTab(.files, number: 2)
        #expect(context.tools == [.files, second, .changes], "two Files tabs, one Diff")
        context.select(.tool(second))
        #expect(context.activeTool == .files)
        context.openTool(.files)
        #expect(context.activeID == second.id, "without `another`, the Files tab shown is kept")
        context.close(.tool(.files))
        context.openTool(.files, another: true)
        #expect(context.tools.contains(.files), "the first number freed is taken again")
        let restored = WorkspaceContext(id: context.id, sourceURL: "session:tools", title: "", snapshot: context.snapshot)
        #expect(Set(restored.tools) == Set(context.tools) && restored.tabs.map(\.id) == context.tabs.map(\.id))
    }

    // Terminal has as many tabs as are opened, as Files does; each is saved, and closing one tells
    // the app, which ends its shell.
    @Test func terminalOpensAnotherTabEachTimeAndClosingOneIsTold() throws {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        var closed: [WorkspaceToolTab] = []
        context.toolClosed = { closed.append($0) }
        context.openTool(.terminal, another: true)
        context.openTool(.terminal, another: true)
        let second = WorkspaceToolTab(.terminal, number: 2)
        #expect(context.tools == [.terminal, second] && context.activeTool == .terminal && context.pane == .term)
        #expect(WorkspaceToolTab(rawValue: "terminal:2") == second)
        let restored = WorkspaceContext(id: context.id, sourceURL: "session:tools", title: "", snapshot: context.snapshot)
        #expect(restored.tools == context.tools && restored.tabs.map(\.id) == context.tabs.map(\.id))
        context.close(.tool(second))
        #expect(closed == [second] && context.tools == [.terminal])
        context.openTool(.terminal, another: true)
        #expect(context.tools.contains(second), "the freed number is taken again")
    }

    // Each later Files tab filters its own tree; the first shares the file tabs' tree, and a
    // closed tab's tree goes with it.
    @Test func eachFilesTabKeepsItsOwnTree() {
        let context = WorkspaceContext(id: "task:tools", sourceURL: "session:tools", title: "")
        context.openTool(.files, another: true)
        context.openTool(.files, another: true)
        let second = WorkspaceToolTab(.files, number: 2)
        context.worktreeFiles(for: .files).query = "first"
        context.worktreeFiles(for: second).query = "second"
        #expect(context.worktreeFiles.query == "first" && context.worktreeFiles(for: second).query == "second")
        let tree = context.worktreeFiles(for: second)
        context.close(.tool(second))
        #expect(tree.retired && context.worktreeFiles(for: second) !== tree, "closed, its tree is retired")
        context.close(.tool(.files))
        #expect(context.worktreeFiles.query.isEmpty, "the last Files tab gone, the next opens on the whole tree")
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

    // Every file picked from the tree opens in a tab of its own; picking one already open selects
    // its tab rather than opening it twice.
    @Test func eachFilePickedFromTheTreeOpensItsOwnTab() throws {
        let context = WorkspaceContext(id: "task:tree", sourceURL: "session:tree", title: "")
        let page = try #require(context.open("https://example.com/home", title: "Home"))
        context.openTool(.files)
        context.openFromTree("/tmp/tree/first.swift")
        let first = try #require(context.activeDocument)
        context.select(.tool(.files))
        context.openFromTree("/tmp/tree/second.swift")
        let second = try #require(context.activeDocument)
        context.openFromTree("/tmp/tree/third.swift")
        #expect(context.documents.map(\.record.path) == ["/tmp/tree/first.swift", "/tmp/tree/second.swift", "/tmp/tree/third.swift"])
        #expect(context.tools == [.files] && context.tabs.first?.id == page.id, "the explorer and the page stay")
        context.openFromTree("/tmp/tree/first.swift")
        #expect(context.activeDocument === first && context.documents.count == 3 && second !== first)
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
        restored.showPages()
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
