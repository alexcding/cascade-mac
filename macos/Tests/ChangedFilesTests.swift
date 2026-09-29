import Foundation
import Testing

@Test func changedFilesDecodeOnlyWhatThePageReports() {
    let files = ChangedFile.decode(files: [
        ["path": "Sources/App/Main.swift", "status": "modified", "adds": 3, "dels": 1],
        ["path": "README.md", "status": "added", "adds": 10, "dels": 0],
    ], untracked: ["notes.md", ""])
    #expect(files?.map(\.path) == ["Sources/App/Main.swift", "README.md", "notes.md"])
    #expect(files?.map(\.index) == [0, 1, 0] && files?.first?.status == .modified && files?.last?.status == .untracked)
    // An entry the list cannot show is left out, and the others keep the places the page gave them.
    // An untracked file is one of the page's untracked list, never a diff file that says so.
    let mixed = ChangedFile.decode(files: [
        ["path": "a", "status": "untracked", "adds": 0, "dels": 0],
        ["path": "", "status": "added", "adds": 0, "dels": 0],
        ["path": "b", "status": "copied", "adds": 0, "dels": 0],
        ["path": "c", "status": "added", "adds": -1, "dels": 0],
        ["path": "d", "status": "deleted", "adds": 0, "dels": 4],
    ], untracked: [])
    #expect(mixed?.map(\.path) == ["d"] && mixed?.first?.index == 4)
    #expect(ChangedFile.decode(files: Array(repeating: ["path": "a", "status": "added", "adds": 0, "dels": 0], count: 1001), untracked: []) == nil)
    #expect(ChangedFile.decode(files: "files", untracked: []) == nil)
    #expect(ChangedFile.decode(files: [], untracked: nil) == nil)
}

@Test func changedFilesTreeFoldersFirstAndJoinsLoneFolders() {
    let files = [
        ChangedFile(path: "Sources/App/Main.swift", status: .modified, adds: 1, dels: 0, index: 0),
        ChangedFile(path: "Sources/App/View.swift", status: .added, adds: 2, dels: 0, index: 1),
        ChangedFile(path: "README.md", status: .modified, adds: 0, dels: 1, index: 2),
        ChangedFile(path: "docs/guide.md", status: .untracked, adds: 0, dels: 0, index: 0),
    ]
    let tree = ChangedFileNode.tree(files)
    #expect(tree.map(\.name) == ["docs", "Sources/App", "README.md"])
    #expect(tree[1].id == "Sources/App/" && tree[1].children?.map(\.name) == ["Main.swift", "View.swift"])
    #expect(tree[1].folders == ["Sources/", "Sources/App/"] && tree[0].folders == ["docs/"])
    #expect(tree[0].children?.first?.file?.id == "u:docs/guide.md" && tree[2].file?.id == "f:README.md")
}
