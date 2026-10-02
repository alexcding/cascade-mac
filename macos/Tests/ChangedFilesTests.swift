import Foundation
import Testing

@Test func changedFilesDecodeOnlyWhatThePageReports() {
    let files = ChangedFile.decode(files: [
        ["path": "Sources/App/Main.swift", "status": "modified"],
        ["path": "README.md", "status": "added"],
    ], untracked: ["notes.md", ""])
    #expect(files?.map(\.path) == ["Sources/App/Main.swift", "README.md", "notes.md"])
    #expect(files?.map(\.index) == [0, 1, 0] && files?.first?.status == .modified && files?.last?.status == .untracked)
    // An entry the list cannot show is left out, and the others keep the places the page gave them.
    // An untracked file is one of the page's untracked list, never a diff file that says so.
    let mixed = ChangedFile.decode(files: [
        ["path": "a", "status": "untracked"],
        ["path": "", "status": "added"],
        ["path": "b", "status": "copied"],
        ["path": "d", "status": "deleted"],
    ], untracked: [])
    #expect(mixed?.map(\.path) == ["d"] && mixed?.first?.index == 3)
    #expect(ChangedFile.decode(files: Array(repeating: ["path": "a", "status": "added"], count: 1001), untracked: []) == nil)
    #expect(ChangedFile.decode(files: "files", untracked: []) == nil)
    #expect(ChangedFile.decode(files: [], untracked: nil) == nil)
}

@Test func changedFilesTreeFoldersFirstAndJoinsLoneFolders() {
    let files = [
        ChangedFile(path: "Sources/App/Main.swift", status: .modified, index: 0),
        ChangedFile(path: "Sources/App/View.swift", status: .added, index: 1),
        ChangedFile(path: "README.md", status: .modified, index: 2),
        ChangedFile(path: "docs/guide.md", status: .untracked, index: 0),
    ]
    let tree = ChangedFileNode.tree(files)
    #expect(tree.map(\.name) == ["docs", "Sources/App", "README.md"])
    #expect(tree[1].id == "Sources/App/" && tree[1].children?.map(\.name) == ["Main.swift", "View.swift"])
    #expect(tree[1].folders == ["Sources/", "Sources/App/"] && tree[0].folders == ["docs/"])
    #expect(tree[0].children?.first?.file?.id == "u:docs/guide.md" && tree[2].file?.id == "f:README.md")
}

@Test func fileTreeExpansionStartsOpenOrClosedAndFollowsTheFilter() {
    var diff = FileTreeExpansion(startsOpen: true)
    #expect(diff.isOpen(["Sources/", "Sources/App/"], filtering: false))
    diff.set(["Sources/", "Sources/App/"], open: false, filtering: false)
    #expect(!diff.isOpen(["Sources/"], filtering: false))
    #expect(diff.isOpen(["Sources/"], filtering: true), "a filter opens every folder of its matches")

    var files = FileTreeExpansion(startsOpen: false)
    #expect(!files.isOpen(["Scenes/"], filtering: false))
    files.reveal("Scenes/Workspace/Pane.swift")
    #expect(files.isOpen(["Scenes/"], filtering: false) && files.isOpen(["Scenes/Workspace/"], filtering: false))
    files.set(["Scenes/"], open: false, filtering: true)
    #expect(!files.isOpen(["Scenes/"], filtering: true))
    files.filterChanged()
    #expect(files.isOpen(["Scenes/"], filtering: true), "a new filter starts open again")
}
