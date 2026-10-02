import AppKit
import SwiftUI
import Foundation
import Testing

private func historyCommit(_ digit: String) -> GitCommit {
    .init(sha: String(repeating: digit, count: 40), short: String(repeating: digit, count: 7), parents: [],
          author: "History Author", email: "history@example.invalid", date: "2026-01-01T00:00:00Z", subject: "Commit \(digit)", refs: [])
}
actor HistoryFixture: GitHistoryService {
    var failList = false, failDetail = false
    var revision = "original"
    var ahead = ["a", "b", "c"]
    var older = true
    /// From this call on, the history is another one, as after a commit lands.
    var changesAtCall: Int?
    var calls: [(GitHistoryQuery, Int)] = []
    func failList(_ value: Bool) { failList = value }
    func failDetail(_ value: Bool) { failDetail = value }
    func changeRevision() { revision = "changed" }
    func setAhead(_ value: [String]) { ahead = value }
    func setOlder(_ value: Bool) { older = value }
    func changeRevision(atCall call: Int) { changesAtCall = call }
    func log(worktree: String, query: GitHistoryQuery, skip: Int, limit: Int) async throws -> GitHistoryPage {
        calls.append((query, skip))
        if let changesAtCall, calls.count >= changesAtCall { revision = "changed" }
        try? await Task.sleep(for: .milliseconds(query.aheadOnly ? 50 : 10))
        if failList { throw BackendError.operation("History unavailable") }
        // The whole history repeats the branch's own commits ahead of the older ones.
        let commits = (query.aheadOnly ? ahead : ahead + ["d", "e"]).map(historyCommit)
        // The two lists are different revisions, as the backend's are.
        return .init(commits: Array(commits.dropFirst(skip).prefix(limit)), branch: "feature", viewing: "feature",
                     base: query.aheadOnly ? query.base : nil, historyRevision: revision + (query.aheadOnly ? "-branch" : "-all"),
                     older: query.aheadOnly ? older : nil)
    }
    func detail(worktree: String, sha: String) async throws -> GitCommitDetail {
        try? await Task.sleep(for: .milliseconds(sha.hasPrefix("a") ? 80 : 10))
        if failDetail { throw BackendError.operation("Commit unavailable") }
        return .init(meta: .init(sha: sha, short: String(sha.prefix(7)), parents: [], author: "Author", authorEmail: "a@b",
                                authorDate: "", committer: "Committer", committerEmail: "c@d", commitDate: "", message: "Detail \(sha.first!)"),
                     diff: "immutable patch")
    }
}
@MainActor @Test func nativeHistoryPaginatesPreservesSelectionAndRejectsChangedHistory() async {
    let service = HistoryFixture()
    let model = GitHistoryViewModel(worktree: "/fixture", baseURL: URL(string: "http://127.0.0.1:3000")!, base: "release/next", service: service, pageSize: 2)
    model.show(); await model.waitForList()
    #expect(model.commits.map(\.subject) == ["Commit a", "Commit b"] && model.hasMore)
    #expect(await service.calls.first?.0.base == "release/next")
    model.select(historyCommit("b").sha); await model.waitForDetail()
    #expect(model.detail?.meta.message == "Detail b")
    model.loadMore(); model.loadMore(); await model.waitForList()
    // The branch's commits are all here, and older history is still there to load.
    #expect(model.commits.count == 3 && model.hasMore)
    #expect(model.selectedSHA == historyCommit("b").sha)
    #expect(await service.calls.map(\.1) == [0, 2])
    model.select(historyCommit("c").sha); model.search = "Commit c"
    model.hide(); model.show(); await model.waitForList(); await model.waitForDetail()
    #expect(model.commits.count == 3 && model.selectedSHA == historyCommit("c").sha && model.rows.count == 1)
    model.search = ""
    model.refresh(); await model.waitForList()
    await service.changeRevision()
    model.loadMore(); await model.waitForList()
    #expect(model.commits.count == 2 && model.error?.contains("History changed") == true)
    #expect(!model.hasMore)
    model.hide()
}
@MainActor @Test func historyRejectsLateDetailRepliesAndRecoversFromFailures() async {
    let service = HistoryFixture()
    let model = GitHistoryViewModel(worktree: "/fixture", baseURL: URL(string: "http://127.0.0.1:3000")!, service: service, pageSize: 2)
    model.show(); await model.waitForList()
    model.select(historyCommit("a").sha)
    model.select(historyCommit("b").sha)
    await model.waitForDetail()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(model.detail?.meta.sha == historyCommit("b").sha && model.patch?.actions == nil)
    let patch = try? await HistoricalPatchService(diff: "patch").load(worktree: "/fixture")
    #expect(patch?.fileLinks == false && patch?.revision == nil)
    await service.failList(true)
    model.refresh(); await model.waitForList()
    #expect(model.commits.count == 2 && model.error == "History unavailable")
    await service.failList(false)
    model.refresh(); await model.waitForList()
    try? await Task.sleep(for: .milliseconds(70))
    #expect(model.commits.map(\.subject) == ["Commit a", "Commit b"] && model.error == nil)
    await service.failDetail(true)
    model.select(historyCommit("b").sha); await model.waitForDetail()
    #expect(model.detailError == "Commit unavailable")
    await service.failDetail(false)
    model.retryDetail(); await model.waitForDetail()
    #expect(model.detail?.meta.message == "Detail b")
    model.select(historyCommit("a").sha); model.hide()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(model.detail == nil && model.patch == nil && !model.loadingDetail)
}
@MainActor @Test func reviewHistoryChoiceRestoresIndependentlyPerContext() throws {
    var snapshot = ContextSnapshot(); snapshot.reviewSection = .history
    let context = WorkspaceContext(id: "review", sourceURL: "https://example.com", title: "", snapshot: snapshot)
    #expect(context.reviewSection == .history)
    context.setPane(.diff)
    let encoded = try JSONEncoder().encode(context.snapshot)
    let restored = WorkspaceContext(id: "review", sourceURL: "https://example.com", title: "", snapshot: try JSONDecoder().decode(ContextSnapshot.self, from: encoded))
    #expect(restored.reviewSection == .history && restored.pane == .diff)
    let other = WorkspaceContext(id: "other", sourceURL: "", title: "")
    #expect(other.reviewSection == .changes)
}

@MainActor @Test func historyPropertyChangesOwnRefreshAndSelectionWithoutAView() async {
    let service = HistoryFixture()
    let model = GitHistoryViewModel(worktree: "/fixture", baseURL: URL(string: "http://127.0.0.1:3000")!, service: service, pageSize: 2)
    model.show(); await model.waitForList(); await model.waitForDetail()
    #expect(await service.calls.count == 1)

    model.search = "Commit b"
    await model.waitForDetail()
    #expect(model.selectedSHA == historyCommit("b").sha && model.detail?.meta.message == "Detail b")
    model.search = "missing"
    #expect(model.selectedSHA == nil && model.detail == nil && model.patch == nil)
    #expect(await service.calls.count == 1)

    model.hide()
    model.search = ""
    #expect(!model.loading)
    #expect(await service.calls.count == 1)
    model.show(); await model.waitForList(); await model.waitForDetail()
    #expect(model.commits.map(\.subject) == ["Commit a", "Commit b"])
    #expect(await service.calls.count == 2)
    // Only this branch's own commits are ever asked for.
    #expect(await service.calls.allSatisfy { $0.0.aheadOnly })
    model.hide()
}

/// Selecting another commit must not tear the detail pane down: the commit on screen stays until
/// the next one arrives, and the one diff page is reused instead of a web view per commit.
@MainActor @Test func historyKeepsTheCommitOnScreenAndReusesItsDiffPageAcrossSelections() async throws {
    let model = GitHistoryViewModel(worktree: "/fixture", baseURL: URL(string: "http://127.0.0.1:3000")!, service: HistoryFixture(), pageSize: 3)
    model.show(); await model.waitForList(); await model.waitForDetail()
    let first = try #require(model.patch)
    #expect(model.detail?.meta.sha == historyCommit("a").sha)
    model.select(historyCommit("b").sha)
    #expect(model.loadingDetail && model.detail?.meta.sha == historyCommit("a").sha && model.patch === first)
    await model.waitForDetail()
    #expect(!model.loadingDetail && model.detail?.meta.sha == historyCommit("b").sha && model.patch === first)
    model.hide()
    #expect(model.patch == nil && model.detail == nil)
}

/// A first load lists only what the branch added, even when that is nothing; asking for more
/// carries on into the history it grew from, without repeating the branch's own commits.
@MainActor @Test func historyListsTheBranchFirstAndOlderCommitsOnRequest() async {
    let service = HistoryFixture()
    await service.setAhead([])
    let model = GitHistoryViewModel(worktree: "/fixture", baseURL: URL(string: "http://127.0.0.1:3000")!, base: "main", service: service, pageSize: 2)
    model.show(); await model.waitForList()
    #expect(model.rows.isEmpty && model.hasMore && model.emptyLabel == "No commits ahead of main.")

    await service.setAhead(["a"])
    model.refresh(); await model.waitForList()
    #expect(model.commits.map(\.subject) == ["Commit a"] && model.hasMore && model.contextLabel == "Commits ahead of main")
    model.loadMore(); await model.waitForList()
    #expect(model.commits.map(\.subject) == ["Commit a", "Commit d"] && model.hasMore && model.contextLabel == "History of feature")
    model.loadMore(); await model.waitForList()
    #expect(model.commits.map(\.subject) == ["Commit a", "Commit d", "Commit e"] && !model.hasMore && model.error == nil)
    #expect(await service.calls.map { "\($0.0.aheadOnly ? "branch" : "all")@\($0.1)" } == ["branch@0", "branch@0", "all@0", "all@2"])
    model.hide()
}

/// Leaving History and coming back keeps the older commits loaded; a page of older history that only
/// repeats the branch's commits is passed over.
@MainActor @Test func historyKeepsOlderCommitsAcrossShowsAndSkipsRepeatedPages() async {
    let service = HistoryFixture()
    await service.setAhead(["a", "b"])
    let model = GitHistoryViewModel(worktree: "/fixture", baseURL: URL(string: "http://127.0.0.1:3000")!, base: "main", service: service, pageSize: 2)
    model.show(); await model.waitForList()
    model.loadMore(); await model.waitForList()
    #expect(model.commits.count == 2 && model.hasMore)
    model.loadMore(); await model.waitForList()
    #expect(model.commits.map(\.subject) == ["Commit a", "Commit b", "Commit d", "Commit e"] && model.hasMore)
    #expect(await service.calls.map { "\($0.0.aheadOnly ? "branch" : "all")@\($0.1)" } == ["branch@0", "branch@2", "all@0", "all@2"])
    model.select(historyCommit("d").sha); await model.waitForDetail()
    model.hide(); model.show(); await model.waitForList(); await model.waitForDetail()
    #expect(model.commits.count == 4 && model.selectedSHA == historyCommit("d").sha && model.contextLabel == "History of feature")
    model.loadMore(); await model.waitForList()
    #expect(!model.hasMore && model.error == nil && model.commits.count == 4)
    model.hide()
}

/// Passing over older pages that only repeat the branch's commits still notices the history moving.
@MainActor @Test func historyNoticesAChangeWhilePassingOverRepeatedPages() async {
    let service = HistoryFixture()
    await service.setAhead(["a", "b"])
    let model = GitHistoryViewModel(worktree: "/fixture", baseURL: URL(string: "http://127.0.0.1:3000")!, base: "main", service: service, pageSize: 2)
    model.show(); await model.waitForList()
    model.loadMore(); await model.waitForList()
    await service.changeRevision(atCall: 4)
    model.loadMore(); await model.waitForList()
    #expect(await service.calls.map { "\($0.0.aheadOnly ? "branch" : "all")@\($0.1)" } == ["branch@0", "branch@2", "all@0", "all@2"])
    #expect(model.commits.count == 2 && !model.hasMore && model.error?.contains("History changed") == true)
    model.hide()
}

/// A branch that shares nothing with its base has no older history, so nothing offers to load it.
@MainActor @Test func historyOffersNoOlderCommitsWhereThereAreNone() async {
    let service = HistoryFixture()
    await service.setAhead(["a"])
    await service.setOlder(false)
    let model = GitHistoryViewModel(worktree: "/fixture", baseURL: URL(string: "http://127.0.0.1:3000")!, base: "main", service: service, pageSize: 2)
    model.show(); await model.waitForList()
    #expect(model.commits.map(\.subject) == ["Commit a"] && !model.hasMore)
    model.loadMore(); await model.waitForList()
    #expect(await service.calls.count == 1)
    model.hide()
}
