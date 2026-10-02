import Foundation
import Testing

actor DiffFixture: DiffService {
    var calls = 0
    var fails = false
    /// Marks later replies, so a stale one landing is told apart from the snapshot it would replace.
    var edits = 0
    func fail(_ value: Bool) { fails = value }
    func edit() { edits += 1 }
    func load(worktree: String) async throws -> DiffSnapshot {
        calls += 1
        let edits = edits
        // Deliberately finish even after cancellation to exercise stale responses.
        try? await Task.sleep(for: .milliseconds(60))
        if fails { throw BackendError.operation("Repository unavailable") }
        return .init(diff: "diff for \(worktree)" + (edits > 0 ? " edit \(edits)" : ""), untracked: ["new.swift"], branch: "feature")
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
    await service.fail(false); await service.edit()
    model.refresh()
    // Hidden, the model keeps what it showed and drops the reply still in flight.
    model.hide()
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.snapshot?.diff == "diff for /tmp/diff-test" && !model.loading)
    model.refresh(); await model.waitForRefresh()
    #expect(model.snapshot?.diff == "diff for /tmp/diff-test edit 1" && model.error == nil)
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
        let asset = DiffPageAssets.data(for: URL(string: "cascade-diff://page/\(name)")!)
        // The test bundle carries no app resources, so this reads the source tree: it proves the
        // handler serves each file, not that the app target still bundles it.
        #expect(asset?.0.isEmpty == false, "\(name) is missing from Resources/DiffPage")
    }
    #expect(DiffPageAssets.data(for: URL(string: "cascade-diff://page/DiffPage.js")!)?.1 == "text/javascript")
    #expect(DiffPageAssets.data(for: URL(string: "cascade-diff://page/../Info.plist")!) == nil)
    #expect(DiffPageAssets.data(for: URL(string: "cascade-diff://other/DiffPage.html")!) == nil)
    #expect(DiffPageAssets.data(for: URL(string: "cascade-diff://page/sub/DiffPage.html")!) == nil)
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
    // The page reports what it drew, the diff's files and then the untracked ones, for the list beside it.
    for _ in 0..<40 where model.changedFiles.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
    #expect(model.changedFiles.map(\.path) == ["Sources/App.swift", "fä.png", "Notes.md"])
    #expect(model.changedFiles.first?.status == .modified && model.changedFiles.last?.status == .untracked)
    // Choosing a collapsed file opens it.
    _ = try await view.evaluateJavaScript("document.querySelector('.diff-file').classList.add('collapsed'); 0")
    model.reveal(model.changedFiles[0])
    for _ in 0..<20 where try await count(".diff-file.collapsed") > 0 { try await Task.sleep(for: .milliseconds(50)) }
    #expect(try await count(".diff-file.collapsed") == 0)
    // Native translations travel with the payload; labels remain text even when they contain markup.
    var localized = try #require(model.snapshot)
    localized.language = "fr"
    localized.labels?["discard"] = "Ignorer <b>les modifications</b>"
    let localizedData = try JSONEncoder().encode(localized)
    _ = try await view.evaluateJavaScript("window.nativeDiff.render(\(String(decoding: localizedData, as: UTF8.self)))")
    #expect(try await view.evaluateJavaScript("document.querySelector('.hunk-discard').textContent") as? String == "Ignorer <b>les modifications</b>")
    #expect(try await count(".hunk-discard b") == 0)
    // Hidden, the page and its render stay for the next show; disconnecting lets them go.
    model.hide()
    #expect(model.webView === view && model.isPageReady)
    model.disconnect()
    #expect(model.webView == nil && !model.isPageReady && model.changedFiles.isEmpty)
}

@MainActor @Test func diffContentProcessTerminationWhileHiddenReloadsSilentlyOnNextShow() async throws {
    useSourceTreeDiffPage()
    let model = DiffViewModel(worktree: "/tmp/diff-terminate", baseURL: URL(string: "http://127.0.0.1:3000")!, service: PatchFixture())
    model.show(appearance: .dark)
    await model.waitForRefresh()
    for _ in 0..<100 where !model.isPageReady { try await Task.sleep(for: .milliseconds(50)) }
    #expect(model.isPageReady, "the page never posted ready: \(model.error ?? "no error")")
    let view = try #require(model.webView)
    model.hide()
    model.webViewWebContentProcessDidTerminate(view)
    #expect(model.error == nil && !model.isPageReady)
    model.show(appearance: .dark)
    await model.waitForRefresh()
    for _ in 0..<100 where !model.isPageReady { try await Task.sleep(for: .milliseconds(50)) }
    #expect(model.isPageReady && model.error == nil)
    model.disconnect()
}

@MainActor @Test func diffContentProcessTerminationWhileShownReportsAnError() async throws {
    useSourceTreeDiffPage()
    let model = DiffViewModel(worktree: "/tmp/diff-terminate-shown", baseURL: URL(string: "http://127.0.0.1:3000")!, service: PatchFixture())
    model.show(appearance: .dark)
    await model.waitForRefresh()
    for _ in 0..<100 where !model.isPageReady { try await Task.sleep(for: .milliseconds(50)) }
    #expect(model.isPageReady, "the page never posted ready: \(model.error ?? "no error")")
    let view = try #require(model.webView)
    model.webViewWebContentProcessDidTerminate(view)
    #expect(model.error == "The changes view stopped. Reload to restore it.")
    model.disconnect()
}

@MainActor private final class WatchFixture: ChangeWatching {
    var stopped = false
    let onChange: @MainActor () -> Void
    init(onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
    func stop() { stopped = true }
}

@MainActor private final class WatchingFactory: DocumentFeatureFactory {
    var watchers: [WatchFixture] = []
    func watchChanges(worktree: String, onChange: @escaping @MainActor () -> Void) -> (any ChangeWatching)? {
        let watcher = WatchFixture(onChange: onChange); watchers.append(watcher); return watcher
    }
}

@MainActor @Test func theWorkingDiffRefreshesItselfWhenItsWorktreeChangesAndOnlyWhileShown() async throws {
    let service = DiffFixture(), factory = WatchingFactory()
    let model = DiffViewModel(worktree: "/tmp/diff-test", baseURL: URL(string: "http://127.0.0.1:3000")!, service: service,
                              actionsService: GitActionFixture(), factory: factory)
    model.show(appearance: .system); await model.waitForRefresh()
    #expect(factory.watchers.count == 1 && model.snapshot?.diff == "diff for /tmp/diff-test")
    // A change lands: the diff loads again without being asked.
    await service.edit(); factory.watchers[0].onChange(); await model.waitForRefresh()
    #expect(await service.calls == 2 && model.snapshot?.diff == "diff for /tmp/diff-test edit 1")
    // A change during a load is not lost: another load follows the one in flight.
    await service.edit(); factory.watchers[0].onChange(); factory.watchers[0].onChange()
    await model.waitForRefresh(); await model.waitForRefresh()
    #expect(await service.calls == 4 && model.snapshot?.diff == "diff for /tmp/diff-test edit 2")
    // Hidden, it stops watching; a change reported late does nothing.
    model.hide()
    #expect(factory.watchers[0].stopped)
    factory.watchers[0].onChange()
    #expect(await service.calls == 4)
    model.disconnect()
}

@MainActor @Test func aPatchFromHistoryIsNotWatched() {
    let factory = WatchingFactory()
    let model = factory.patch(worktree: "/tmp/diff-test", baseURL: URL(string: "http://127.0.0.1:3000")!, diff: "")
    model.show(appearance: .system)
    #expect(factory.watchers.isEmpty)
    model.disconnect()
}

@Test func aLinkedWorktreesGitDirectoriesAreReadFromItsGitFiles() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    let worktree = base.appendingPathComponent("one"), own = base.appendingPathComponent("repo/.git/worktrees/one")
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    #expect(WorktreeWatcher.Filter(worktree: worktree.path).gitDirectories.isEmpty)
    try "gitdir: \(own.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    try "../..\n".write(to: own.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
    #expect(WorktreeWatcher.Filter(worktree: worktree.path).gitDirectories == [own.path, base.appendingPathComponent("repo/.git").path])
}

@Test func onlyWhatCanChangeTheDiffWakesIt() {
    let filter = WorktreeWatcher.Filter(worktree: "/nonexistent/wt")
    #expect(filter.matters("/nonexistent/wt/Sources/App.swift"))
    #expect(filter.matters("/nonexistent/wt/.git/index"))
    #expect(filter.matters("/nonexistent/wt/.git/refs/heads/main"))
    #expect(filter.matters("/nonexistent/wt/.git/HEAD"))
    // Build output, dependencies, git's objects and logs, and a write still in progress do not.
    #expect(!filter.matters("/nonexistent/wt/node_modules/left-pad/index.js"))
    #expect(!filter.matters("/nonexistent/wt/.build/debug/App.o"))
    #expect(!filter.matters("/nonexistent/wt/crates/app/target/debug/app"))
    #expect(!filter.matters("/nonexistent/wt/.git/objects/ab/cdef"))
    #expect(!filter.matters("/nonexistent/wt/.git/logs/HEAD"))
    #expect(!filter.matters("/nonexistent/wt/.git/index.lock"))
    #expect(!filter.matters("/elsewhere/file"))
}

@MainActor @Test func aRefreshTheWorktreeAskedForFailsQuietlyOverAShownDiff() async throws {
    let service = DiffFixture(), factory = WatchingFactory()
    let model = DiffViewModel(worktree: "/tmp/diff-test", baseURL: URL(string: "http://127.0.0.1:3000")!, service: service,
                              actionsService: GitActionFixture(), factory: factory)
    model.show(appearance: .system); await model.waitForRefresh()
    await service.fail(true)
    factory.watchers[0].onChange(); await model.waitForRefresh()
    #expect(model.error == nil && model.snapshot?.diff == "diff for /tmp/diff-test")
    // One the user asked for still says why it failed.
    model.refresh(); await model.waitForRefresh()
    #expect(model.error == "Repository unavailable")
    model.disconnect()
}

@MainActor @Test func theWatcherHearsARealFileChangeAndNotBuildOutput() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var heard = 0
    let watcher = try #require(WorktreeWatcher(worktree: root.path, latency: 0.05) { heard += 1 })
    defer { watcher.stop() }
    // The folders made just before the stream started can still be reported once: start counting after.
    try await Task.sleep(for: .milliseconds(500))
    heard = 0
    try "x".write(to: root.appendingPathComponent("node_modules/dep.js"), atomically: true, encoding: .utf8)
    try await Task.sleep(for: .milliseconds(700))
    #expect(heard == 0)
    try "x".write(to: root.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
    for _ in 0..<50 where heard == 0 { try await Task.sleep(for: .milliseconds(100)) }
    #expect(heard > 0)
    #expect(WorktreeWatcher(worktree: root.appendingPathComponent("missing").path) { } == nil)
}

@MainActor @Test func aWorktreeFSEventsCannotSeeIsPolledUntilStopped() async throws {
    var heard = 0
    let watcher = PollingWatcher(every: .milliseconds(30)) { heard += 1 }
    for _ in 0..<50 where heard < 2 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(heard >= 2)
    watcher.stop()
    let stopped = heard
    try await Task.sleep(for: .milliseconds(120))
    #expect(heard == stopped)
    let fallback = NativeDocumentFeatureFactory().watchChanges(worktree: "/nonexistent/worktree") { }
    #expect(fallback is PollingWatcher)
    fallback?.stop()
}
