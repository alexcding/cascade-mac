import Foundation
import Testing

actor GitActionFixture: GitChangesService, DiffService {
    var commits: [(String, Bool)] = []
    var pushes = 0, discards = 0
    var discardFails = true
    var commitFails = false, pushFails = true, loadFails = false
    var dirty = true, ahead = 0
    func previewDiscard(worktree: String, revision: String, selection: [Int]) async throws -> DiscardProposal {
        try await Task.sleep(for: .milliseconds(40))
        return .init(path: "test.swift", patch: "patch", revision: revision, selection: selection)
    }
    func discard(worktree: String, proposal: DiscardProposal) async throws {
        discards += 1
        try await Task.sleep(for: .milliseconds(40))
        if discardFails { throw BackendError.operation("File changed on disk") }
        dirty = false
    }
    func setDiscardFailure(_ value: Bool) { discardFails = value }
    func setCommitFailure(_ value: Bool) { commitFails = value }
    func setPushFailure(_ value: Bool) { pushFails = value }
    func setLoadFailure(_ value: Bool) { loadFails = value }
    func load(worktree: String) async throws -> DiffSnapshot {
        if loadFails { throw BackendError.operation("Repository unavailable") }
        return .init(diff: dirty ? "tracked changes" : "", untracked: dirty ? ["new.swift"] : [], branch: "feature", ahead: ahead, behind: 0)
    }
    func commit(worktree: String, message: String, includeUntracked: Bool) async throws -> String {
        commits.append((message, includeUntracked))
        try await Task.sleep(for: .milliseconds(50))
        if commitFails { throw BackendError.operation("Signing failed") }
        dirty = false; ahead += 1
        return "abc1234"
    }
    func push(worktree: String) async throws {
        pushes += 1
        try await Task.sleep(for: .milliseconds(30))
        if pushFails { throw BackendError.operation("Push rejected") }
        ahead = 0
    }
}

@MainActor @Test func nativeCommitCoalescesAndPushFailureCannotRepeatCommit() async throws {
    let service = GitActionFixture()
    var refreshes = 0
    let model = GitChangesActions(worktree: "/fixture", service: service, didChange: { refreshes += 1 })
    await model.load()
    model.message = " Preserve this message "
    model.includeUntracked = false
    let operation = Task { await model.perform(.commitAndPush) }
    for _ in 0..<50 { if model.busy { break }; await Task.yield() }
    await model.perform(.commitAndPush)
    await operation.value
    #expect(await service.commits.count == 1)
    #expect(await service.commits.first?.0 == "Preserve this message")
    #expect(await service.commits.first?.1 == false)
    #expect(await service.pushes == 1)
    #expect(model.committedHash == "abc1234" && !model.canCommit && model.canPush)
    #expect(model.error == "Commit abc1234 is saved locally. Push rejected")
    #expect(model.snapshot?.diff == "" && refreshes == 1)
    await model.perform(.commitAndPush)
    #expect(await service.commits.count == 1)
    await service.setPushFailure(false)
    await model.perform(.push)
    #expect(await service.commits.count == 1)
    #expect(await service.pushes == 2)
    #expect(!model.canPush)
    #expect(model.status == "Committed abc1234 and pushed." && model.error == nil)
}

@MainActor @Test func nativeCommitFailureRetainsDraftAndRefreshFailureDisablesMutations() async {
    let service = GitActionFixture()
    let model = GitChangesActions(worktree: "/fixture", service: service)
    await model.load()
    model.message = "My draft"; model.includeUntracked = false
    await service.setCommitFailure(true)
    await model.perform(.commit)
    #expect(model.message == "My draft" && model.committedHash == nil && model.canCommit)
    #expect(model.error == "Signing failed")
    await service.setLoadFailure(true)
    await model.perform(.commit)
    #expect(!model.canCommit && !model.canPush && model.message == "My draft")
    #expect(model.error?.contains("Could not refresh changes") == true)
    await service.setLoadFailure(false)
    await model.load()
    #expect(model.canCommit)
    await service.setCommitFailure(false)
    await model.perform(.commit)
    #expect(model.committedHash == "abc1234" && !model.canCommit)
    model.beginNextCommit()
    #expect(model.committedHash == nil && !model.canCommit) // The fresh snapshot is clean.
}


@MainActor @Test func shutdownWaitsForGitMutationAndPreventsNewOperations() async throws {
    let service = GitActionFixture()
    let model = GitChangesActions(worktree: "/fixture", service: service)
    await model.load()
    let operation = Task { await model.perform(.commitAndPush) }
    for _ in 0..<100 { if model.busy { break }; await Task.yield() }
    #expect(model.busy)
    await model.suspendAndWait()
    #expect(!model.busy && !model.canPush && model.committedHash == "abc1234")
    await operation.value
    await model.perform(.push)
    #expect(await service.pushes == 1)
    model.resume()
    #expect(model.canPush)
}


@MainActor @Test func discardRequiresPreviewAndConfirmationAndPreservesFailedProposal() async throws {
    let service = GitActionFixture()
    var refreshes = 0
    let model = GitChangesActions(worktree: "/fixture", service: service, didChange: { refreshes += 1 })
    await model.load()
    await model.confirmDiscard()
    #expect(await service.discards == 0)
    await model.prepareDiscard(revision: "reviewed", selection: [0, 1, 2])
    #expect(model.discardProposal?.selection == [0, 1, 2] && !model.canCommit && !model.canPush)
    model.cancelDiscard()
    #expect(model.discardProposal == nil)
    #expect(await service.discards == 0)
    await model.prepareDiscard(revision: "reviewed", selection: [0, 1, 2])
    let operation = Task { await model.confirmDiscard() }
    for _ in 0..<100 { if model.busy { break }; await Task.yield() }
    await model.confirmDiscard()
    await operation.value
    #expect(await service.discards == 1)
    #expect(model.error == "File changed on disk" && model.discardProposal != nil && refreshes == 1)
    await service.setDiscardFailure(false)
    await model.confirmDiscard()
    #expect(model.discardProposal == nil && model.error == nil && refreshes == 2)
    #expect(!model.canCommit && !model.canPush) // Commit must reload the changed disk state.
}

@MainActor @Test func hiddenDiffRejectsLateDiscardPreview() async {
    let service = GitActionFixture()
    let model = GitChangesActions(worktree: "/fixture", service: service)
    let preview = Task { await model.prepareDiscard(revision: "reviewed", selection: [0, 0, 0]) }
    for _ in 0..<100 { if model.busy { break }; await Task.yield() }
    model.cancelDiscard()
    await preview.value
    #expect(model.discardProposal == nil && !model.busy)
    #expect(await service.discards == 0)
}


@Test func discardMessagesRequireExactRenderedRevisionAndIntegerIndices() {
    let valid: [String: Any] = ["type": "discard", "selection": [0, 1, 2], "revision": "current"]
    #expect(DiscardSelectionMessage.decode(valid, revision: "current")?.selection == [0, 1, 2])
    #expect(DiscardSelectionMessage.decode(valid, revision: "newer") == nil)
    for selection: [Any] in [[true, 0, 0], [0.5, 0, 0], [-1, 0, 0], [0, 0], [0, 0, 0, 0]] {
        #expect(DiscardSelectionMessage.decode(["type": "discard", "selection": selection, "revision": "current"], revision: "current") == nil)
    }
}

/// A popover closes on a click outside it, even mid-commit. The commit runs on, and the
/// presentation must end with it rather than stay open behind a popover no longer shown.
@MainActor @Test func commitPopoverClosedMidCommitEndsThePresentation() async throws {
    let service = GitActionFixture()
    let model = DiffViewModel(worktree: "/fixture", baseURL: URL(string: "http://127.0.0.1:3000")!, service: service, actionsService: service)
    var ended = 0
    model.coordinator.presentationEnded = { ended += 1 }
    model.show(appearance: .light)
    let actions = try #require(model.actions)
    await actions.load()
    model.requestActions()
    #expect(model.coordinator.showsActions)
    let commit = Task { await actions.perform(.commit) }
    for _ in 0..<50 where !actions.busy { await Task.yield() }
    #expect(actions.busy)
    model.coordinator.dismissActions()
    #expect(model.coordinator.showsActions)
    model.coordinator.actionsClosed()
    #expect(!model.coordinator.showsActions && !model.coordinator.isPresenting && ended == 1)
    await commit.value
    #expect(actions.committedHash == "abc1234" && !model.coordinator.showsActions && ended == 1)
    // Opening it again shows how the last operation went: a rejected push still stands, and only
    // Refresh clears it.
    await actions.perform(.push)
    #expect(actions.error?.contains("Push rejected") == true)
    await actions.load(keepingOutcome: true)
    #expect(actions.error?.contains("Push rejected") == true)
    await actions.load()
    #expect(actions.error == nil)
    // Leaving the changes — another section, another session — closes it, whatever anchored it.
    model.requestActions()
    #expect(model.coordinator.showsActions)
    model.hide()
    #expect(!model.coordinator.showsActions)
    model.disconnect()
}

/// Commit sits in the review's bar over History too, where the diff itself is hidden: it still opens
/// its popover there, and only while that bar is on screen.
@MainActor @Test func commitOpensOverHistoryWhileTheReviewIsShown() async throws {
    let service = GitActionFixture()
    let model = DiffViewModel(worktree: "/fixture", baseURL: URL(string: "http://127.0.0.1:3000")!, service: service, actionsService: service)
    #expect(model.actions != nil && !model.isActive)
    model.requestActions()
    #expect(!model.coordinator.showsActions, "nothing on screen to anchor it")
    model.reviewing = true
    model.requestActions()
    #expect(model.coordinator.showsActions, "the bar over History")
    model.reviewing = false
    #expect(!model.coordinator.showsActions && !model.coordinator.isPresenting, "the bar leaving takes it with it")
    model.requestActions()
    #expect(!model.coordinator.showsActions)
    model.disconnect()
}
