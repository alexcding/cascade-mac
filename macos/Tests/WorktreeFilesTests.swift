import Foundation
import Testing
@testable import Cascade

private struct ListingFixture: FileSearchService {
    let files: [String]
    func files(in root: String, matching query: String) async throws -> [String] { [] }
    func allFiles(in root: String) async throws -> (files: [String], truncated: Bool) { (files, false) }
}

@MainActor struct WorktreeFilesTests {
    @Test func aTreeNestsEveryFolderAndPutsFoldersFirst() {
        let nodes = WorktreeFileNode.tree(["README.md", "Sources/App/main.swift", "Sources/App/View.swift", "a.txt"])
        #expect(nodes.map(\.name) == ["Sources", "a.txt", "README.md"])
        #expect(nodes.first?.id == "Sources/")
        #expect(nodes.first?.children?.map(\.id) == ["Sources/App/"])
        #expect(nodes.first?.children?.first?.children?.map(\.id) == ["Sources/App/main.swift", "Sources/App/View.swift"])
    }

    @Test func theListNarrowsToMatchesAndAChosenFileOpensAbsolute() async throws {
        let model = WorktreeFilesViewModel()
        model.service = { ListingFixture(files: ["a/One.swift", "b/two.md"]) }
        var opened: [String] = []
        model.onAction = { if case .open(let path) = $0 { opened.append(path) } }
        model.show(root: "/tmp/tree")
        for _ in 0..<100 where model.phase != .loaded { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.phase == .loaded && model.nodes.map(\.name) == ["a", "b"])
        model.query = "one"
        for _ in 0..<100 where model.nodes.count != 1 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.nodes.map(\.name) == ["a"] && model.nodes.first?.children?.map(\.id) == ["a/One.swift"])
        model.open("a/One.swift")
        #expect(opened == ["/tmp/tree/a/One.swift"])
    }

    @Test func aFileChosenInTheFilesTabTakesItsPlace() throws {
        let context = WorkspaceContext(id: "task:files", sourceURL: "session:files", title: "")
        let page = try #require(context.open("https://example.com/home", title: "Home"))
        context.openTool(.files)
        context.worktreeFiles.query = "x"
        context.openFromTree("/tmp/picked.swift")
        let file = try #require(context.activeDocument)
        #expect(context.tabs.map(\.id) == [page.id, file.id])
        #expect(context.activeDocument === file && context.tools.isEmpty && context.pane == .term)
        #expect(context.worktreeFiles.query.isEmpty)
        let restored = WorkspaceContext(id: context.id, sourceURL: "session:files", title: "", snapshot: context.snapshot)
        #expect(restored.tools.isEmpty, "the picker is not saved once a file took its place")
    }

    @Test func aFileOpenedAnotherWayLeavesTheFilesTabOpen() throws {
        let context = WorkspaceContext(id: "task:files", sourceURL: "session:files", title: "")
        context.openTool(.files)
        context.worktreeFiles.query = "x"
        _ = try #require(context.openFile("/tmp/linked.swift"))
        #expect(context.tools == [.files] && context.worktreeFiles.query == "x", "only a pick in the tree takes its place")
    }

    @Test func aFileChosenInTheTreeBesideAFileTakesItsTab() throws {
        let context = WorkspaceContext(id: "task:files", sourceURL: "session:files", title: "")
        let page = try #require(context.open("https://example.com/home", title: "Home"))
        let first = try #require(context.openFile("/tmp/first.swift"))
        context.openFromTree("/tmp/second.swift")
        let second = try #require(context.activeDocument)
        #expect(second.record.path == "/tmp/second.swift" && context.tabs.map(\.id) == [page.id, second.id])
        #expect(!context.documents.contains { $0 === first }, "the file shown before gives way")
    }

    @Test func aQueryKeepsAPlusInAPath() {
        let query = APIClient.query("/api/files/content", ["path": "/tmp/View+Extensions.swift"])
        #expect(query.contains("View%2BExtensions.swift") && !query.contains("+"))
    }

    @Test func aRetiredListingRefusesToList() {
        let model = WorktreeFilesViewModel()
        var asked = 0
        model.service = { asked += 1; return ListingFixture(files: ["a.swift"]) }
        model.retire()
        model.show(root: "/tmp/tree")
        model.query = "a"
        #expect(asked == 0 && model.phase == .idle && model.nodes.isEmpty)
    }

    @Test func tryAgainReloadsTheWorktreeAListingWithNoServiceFailed() async throws {
        let model = WorktreeFilesViewModel()
        var service: (any FileSearchService)? = nil
        model.service = { service }
        model.show(root: "/tmp/tree")
        #expect(model.phase == .failed)
        service = ListingFixture(files: ["a.swift"])
        model.reload()
        for _ in 0..<100 where model.phase != .loaded { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.phase == .loaded && model.files == ["a.swift"])
    }
}
