import Foundation
import Testing

private struct FileSearchFixture: FileSearchService {
    let files: [String]
    func files(in root: String, matching query: String) async throws -> [String] {
        files.filter { $0.localizedCaseInsensitiveContains(query) }
    }
}

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
    #expect(context.pane == .term && context.lastMode == .browser && context.activeDocument?.record.path == "/tmp/saved.swift")
}

@MainActor @Test func aFileSuggestionOpensAsItsOwnTab() throws {
    let context = WorkspaceContext(id: "task:suggest", sourceURL: "", title: "")
    let page = context.openBlankPage()
    let item = AddressSuggestion(id: "file:/repo/README.md", title: "README.md", detail: "", url: "/repo/README.md", kind: .file)
    #expect(item.heading == String(localized: "Files") && !item.isSearch)
    #expect(BrowserAddressSuggestions.open(item, in: page.controls, context: context))
    #expect(context.activeDocument?.record.path == "/repo/README.md" && context.pages.isEmpty)
}

@MainActor @Test func fileSearchListsOnlyTypedQueriesAndOpensAbsolutePaths() async throws {
    let model = FileSearchViewModel()
    var opened: [String] = []
    model.service = { FileSearchFixture(files: ["macos/App/AppDelegate.swift", "README.md"]) }
    model.onAction = { if case .open(let path) = $0 { opened.append(path) } }
    model.search(in: "/repo")
    #expect(model.results.isEmpty && !model.submit())
    model.query = "deleg"
    model.search(in: "/repo")
    // The suite runs in parallel on one main actor: wait for the result, not for a fixed time.
    for _ in 0..<100 where model.results.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
    #expect(model.results.map(\.path) == ["/repo/macos/App/AppDelegate.swift"])
    #expect(model.results.first?.name == "AppDelegate.swift" && model.results.first?.folder == "macos/App")
    #expect(model.submit() && opened == ["/repo/macos/App/AppDelegate.swift"] && model.query.isEmpty && model.results.isEmpty)
    model.query = "/tmp/typed.swift"
    #expect(model.submit() && opened.last == "/tmp/typed.swift")
    model.retire()
    model.query = "readme"; model.search(in: "/repo")
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.results.isEmpty && !model.submit())
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
}

@MainActor @Test func aSidebarTabKeepsItsBlankPageBesideAnOpenedFile() throws {
    let context = WorkspaceContext(id: "tab:draft", sourceURL: "", title: "")
    let page = context.openBlankPage()
    let file = try #require(context.openFile("/tmp/sidebar.swift"))
    #expect(context.tabs.map(\.id) == [page.id, file.id], "its one page is its only address field")
}
