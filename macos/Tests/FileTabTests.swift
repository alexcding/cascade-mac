import Foundation
import Testing

@MainActor @Test func aFileOpenedFromABlankPageTakesItsPlace() throws {
    let context = WorkspaceContext(id: "task:files", sourceURL: "", title: "Files")
    let home = try #require(context.open("https://example.com/home", title: "Home"))
    let blank = context.openBlankPage()
    #expect(context.activePage === blank && context.tabs.count == 2)
    let file = try #require(context.openFile("/tmp/one.swift"))
    #expect(context.activeDocument === file && context.pane == .term)
    #expect(context.tabs.map(\.id) == [home.id, file.id], "the blank page gives its slot to the file")
    // Opened again from a blank page, an open file is selected and the blank page still goes.
    context.openBlankPage()
    context.openFile("/tmp/one.swift")
    #expect(context.activeDocument === file && context.tabs.map(\.id) == [home.id, file.id])
}

@MainActor @Test func aSnapshotSavedOnTheFilesPaneRestoresToTheBrowser() {
    var snapshot = ContextSnapshot()
    snapshot.pane = "files"
    snapshot.documents = [.init(path: "/tmp/saved.swift")]
    let context = WorkspaceContext(id: "task:legacy", sourceURL: "", title: "", snapshot: snapshot)
    #expect(context.pane == .term && context.lastPane == .term && context.activeDocument?.record.path == "/tmp/saved.swift")
}

@Test func compactTabsFallBackToIconsThenLeaveOutTheLeftmost() {
    let ids = ["a", "b", "c", "d", "e"]
    // Room for titles: everything, titled. Unmeasured counts as room.
    #expect(CompactTabLayout(ids: ids, activeID: "c", available: 700) == CompactTabLayout(ids: ids, activeID: "c", available: 0))
    #expect(!CompactTabLayout(ids: ids, activeID: "c", available: 700).iconOnly)
    // 180 + 4 * 38 + 4 = 336 fits in 400 as icons, but not titled (576).
    let icons = CompactTabLayout(ids: ids, activeID: "c", available: 400)
    #expect(icons.iconOnly && icons.visible == ids)
    // 260 holds the selected tab and two icons: the leftmost go, the selected one never does.
    let cut = CompactTabLayout(ids: ids, activeID: "a", available: 260)
    #expect(cut.iconOnly && cut.visible == ["a", "d", "e"])
    #expect(CompactTabLayout(ids: ids, activeID: "a", available: 50).visible == ["a"])
    // A flat strip's titles fade rather than cut, so they hold on far longer: 180 + 4 * 74 + 4 = 480.
    #expect(!CompactTabLayout(ids: ids, activeID: "c", available: 500, minTitled: CompactTabMetrics.minFlatTitledTabWidth).iconOnly)
    #expect(CompactTabLayout(ids: ids, activeID: "c", available: 470, minTitled: CompactTabMetrics.minFlatTitledTabWidth).iconOnly)
}
