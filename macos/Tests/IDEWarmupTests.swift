import Foundation
import Testing

private actor WarmupFixture: IDEWarmupServing {
    private(set) var starts: [String] = []
    private(set) var reads: [String] = []
    var reply = IDEWarmupState(worktree: "", status: "running", label: "Resolving Swift packages")

    func start(worktree: String, ide: String, target: String) async -> IDEWarmupState {
        starts.append("\(worktree)|\(ide)|\(target)")
        var state = reply; state.worktree = worktree; return state
    }
    func state(worktree: String) async -> IDEWarmupState {
        reads.append(worktree)
        var state = reply; state.worktree = worktree; return state
    }
}

@MainActor @Test func warmingAWorktreeRunsOnceWhileTheFirstRunIsStillGoing() async {
    let service = WarmupFixture(), store = IDEWarmupStore()
    store.connect(service)
    // Two calls before the first reply lands — what an inventory refresh does — send one POST.
    store.warm(worktree: "/w/one", ide: "xcode", target: "App.xcodeproj")
    store.warm(worktree: "/w/one", ide: "xcode", target: "App.xcodeproj")
    while !store.state(for: "/w/one").running { await Task.yield() }
    #expect(store.state(for: "/w/one").label == "Resolving Swift packages")
    // Resuming the same session, and every reconnect after it, must not spawn a second resolve.
    store.warm(worktree: "/w/one", ide: "xcode", target: "App.xcodeproj")
    await Task.yield()
    await #expect(service.starts == ["/w/one|xcode|App.xcodeproj"])
}

@MainActor @Test func aSessionWithoutAnIDEOrABackendNeverAsksForAWarmUp() async {
    let service = WarmupFixture(), store = IDEWarmupStore()
    store.warm(worktree: "/w/two", ide: "xcode", target: "")   // no backend connected yet
    store.connect(service)
    store.warm(worktree: "/w/two", ide: "", target: "")        // a project with no IDE
    store.warm(worktree: "", ide: "xcode", target: "")         // a session with no worktree
    await Task.yield()
    await #expect(service.starts.isEmpty)
    #expect(!store.state(for: "/w/two").running)
}

@MainActor @Test func theBackendsEventIsWhatMovesAWarmUpOn() {
    let store = IDEWarmupStore()
    store.receive(ServerEvent(type: "ide-warmup", projectId: nil, id: nil, worktree: "/w/three",
                              status: "running", label: "Resolving Swift packages", message: ""))
    #expect(store.state(for: "/w/three").running)
    store.receive(ServerEvent(type: "ide-warmup", projectId: nil, id: nil, worktree: "/w/three",
                              status: "failed", label: "Resolving Swift packages", message: "no network"))
    #expect(store.state(for: "/w/three").failed && store.state(for: "/w/three").message == "no network")
    // Any other event, and any event without a worktree, leaves it alone.
    store.receive(ServerEvent(type: "sync", projectId: "p", id: nil))
    store.receive(ServerEvent(type: "ide-warmup", projectId: nil, id: nil, worktree: ""))
    #expect(store.state(for: "/w/three").failed)
}

/// A backend that restarted has no warm-up running, so a state left from the old one would
/// claim work nobody is doing.
@MainActor @Test func reconnectingDropsWhatTheOldBackendReported() async {
    let service = WarmupFixture(), store = IDEWarmupStore()
    store.connect(service)
    store.receive(ServerEvent(type: "ide-warmup", projectId: nil, id: nil, worktree: "/w/four",
                              status: "running", label: "Resolving Swift packages", message: ""))
    #expect(store.state(for: "/w/four").running)
    store.connect(nil)
    #expect(!store.state(for: "/w/four").running)
    #expect(store.state(for: "/w/four").status == "ready")
}

@MainActor @Test func resyncAsksTheBackendForEveryOpenSession() async {
    let service = WarmupFixture(), store = IDEWarmupStore()
    store.connect(service)
    store.resync(worktrees: ["/w/five", ""])
    while !store.state(for: "/w/five").running { await Task.yield() }
    await #expect(service.reads == ["/w/five"])
}
