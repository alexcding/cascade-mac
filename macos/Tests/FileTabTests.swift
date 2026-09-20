import Foundation
import Testing

private struct FileSearchFixture: FileSearchService {
    let files: [String]
    func files(in root: String, matching query: String) async throws -> [String] {
        files.filter { $0.localizedCaseInsensitiveContains(query) }
    }
}

@MainActor @Test func blankFileTabGivesItsSlotToTheFileItOpensAndIsNeverSaved() {
    let context = WorkspaceContext(id: "task:files", sourceURL: "", title: "Files")
    context.newFileTab()
    #expect(context.blankFileActive && context.pane == .files && context.activeDocument == nil)
    #expect(context.snapshot.documents?.isEmpty == true && context.fileTabs.isEmpty)
    context.openFile("/tmp/one.swift")
    #expect(!context.hasBlankFileTab && context.activeDocument?.record.path == "/tmp/one.swift")
    // A second blank beside an open file closes back onto that file.
    context.newFileTab()
    #expect(context.blankFileActive && context.documents.count == 1)
    context.closeBlankFileTab()
    #expect(!context.hasBlankFileTab && context.activeDocument?.record.path == "/tmp/one.swift")
}

@MainActor @Test func closingTheLastFileSelectsTheBlankTabBesideIt() {
    let context = WorkspaceContext(id: "task:last", sourceURL: "", title: "Last")
    let file = context.openFile("/tmp/last.swift")!
    context.newFileTab()
    context.select(.file(file))
    context.remove(file)
    #expect(context.blankFileActive && context.documents.isEmpty)
}

@MainActor @Test func blankFileTabSurvivesAPanelSwitch() {
    let context = WorkspaceContext(id: "task:panels", sourceURL: "", title: "Panels")
    context.newFileTab()
    context.setPane(.term)
    context.setPane(.files)
    #expect(context.blankFileActive)
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
