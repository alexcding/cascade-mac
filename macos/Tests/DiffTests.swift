import Foundation
import Testing

actor DiffFixture: DiffService {
    var calls = 0
    var fails = false
    func fail(_ value: Bool) { fails = value }
    func load(worktree: String) async throws -> DiffSnapshot {
        calls += 1
        // Deliberately finish even after cancellation to exercise stale responses.
        try? await Task.sleep(for: .milliseconds(60))
        if fails { throw BackendError.operation("Repository unavailable") }
        return .init(diff: "diff for \(worktree)", untracked: ["new.swift"], branch: "feature")
    }
}

@MainActor @Test func diffRefreshCoalescesRetainsLastSuccessAndRejectsHiddenReplies() async throws {
    let service = DiffFixture()
    let model = DiffViewModel(worktree: "/tmp/diff-test", baseURL: URL(string: "http://127.0.0.1:3000")!, service: service)
    model.refresh(); model.refresh()
    await model.waitForRefresh()
    #expect(await service.calls == 1)
    #expect(model.snapshot?.diff == "diff for /tmp/diff-test")
    await service.fail(true)
    model.refresh(); await model.waitForRefresh()
    #expect(model.error == "Repository unavailable")
    #expect(model.snapshot?.branch == "feature")
    await service.fail(false)
    model.refresh()
    model.hide()
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.snapshot == nil && !model.loading)
    model.refresh(); await model.waitForRefresh()
    #expect(model.snapshot != nil && model.error == nil)
    model.disconnect(); model.refresh()
    #expect(model.error == "Connect to the backend to load changes.")
}

private struct PatchFixture: DiffService {
    func load(worktree: String) async throws -> DiffSnapshot {
        let patch = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111..2222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,3 +1,3 @@
         import Foundation
        -let name = "old"
        +let name = "new"
         print(name)

        """
        // A binary file's path appears only in the `diff --git` header, C-quoted when not ASCII.
        let binary = #"""
        diff --git "a/f\303\244.png" "b/f\303\244.png"
        index 1111111..2222222 100644
        Binary files "a/f\303\244.png" and "b/f\303\244.png" differ

        """#
        return .init(diff: patch + binary, untracked: ["Notes.md"], branch: "feature", revision: "r1")
    }
}

private func useSourceTreeDiffPage(file: String = #filePath) {
    DiffPageAssets.directoryOverride = URL(fileURLWithPath: file).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/DiffPage")
}

@Test func diffPageAssetsServeOnlyTheBundledPage() {
    useSourceTreeDiffPage()
    for name in ["DiffPage.html", "DiffPage.css", "DiffPage.js", "DiffParse.mjs", "DiffHighlight.mjs"] {
        let asset = DiffPageAssets.data(for: URL(string: "craft-diff://page/\(name)")!)
        // The test bundle carries no app resources, so this reads the source tree: it proves the
        // handler serves each file, not that the app target still bundles it.
        #expect(asset?.0.isEmpty == false, "\(name) is missing from Resources/DiffPage")
    }
    #expect(DiffPageAssets.data(for: URL(string: "craft-diff://page/DiffPage.js")!)?.1 == "text/javascript")
    #expect(DiffPageAssets.data(for: URL(string: "craft-diff://page/../Info.plist")!) == nil)
    #expect(DiffPageAssets.data(for: URL(string: "craft-diff://other/DiffPage.html")!) == nil)
    #expect(DiffPageAssets.data(for: URL(string: "craft-diff://page/sub/DiffPage.html")!) == nil)
}

// Loads the real page in a real web view: the scheme handler, the CSP, the module imports
// and the renderer all have to work for a highlighted, discardable row to appear.
@MainActor @Test func diffPageRendersTheSnapshotItIsHanded() async throws {
    useSourceTreeDiffPage()
    let model = DiffViewModel(worktree: "/tmp/diff-test", baseURL: URL(string: "http://127.0.0.1:3000")!, service: PatchFixture())
    model.show(appearance: .dark)
    await model.waitForRefresh()
    for _ in 0..<100 where !model.isPageReady { try await Task.sleep(for: .milliseconds(50)) }
    #expect(model.isPageReady, "the page never posted ready: \(model.error ?? "no error")")
    let view = try #require(model.webView)
    func count(_ selector: String) async throws -> Int {
        try #require(try await view.evaluateJavaScript("document.querySelectorAll('\(selector)').length") as? Int)
    }
    for _ in 0..<40 where try await count(".diff-file") == 0 { try await Task.sleep(for: .milliseconds(50)) }
    #expect(try await count(".diff-line.add") == 1)
    #expect(try await count(".diff-line.del") == 1)
    #expect(try await count(".diff-hunk") == 1)
    #expect(try await count(".hunk-discard") == 1)
    #expect(try await count(".tok-kw") > 0)
    #expect(try await count(".diff-untracked") == 1)
    #expect(try await count(".diff-stub") == 1)
    let paths = try #require(try await view.evaluateJavaScript("[...document.querySelectorAll('.diff-fpath')].map(e => e.textContent).join('|')") as? String)
    #expect(paths == "Sources/App.swift|fä.png")
    #expect(try await view.evaluateJavaScript("document.documentElement.dataset.theme") as? String == "dark")
    #expect(model.error == nil)
    model.hide()
    #expect(model.webView == nil && !model.isPageReady)
}
