import Foundation
import Testing
@testable import Cascade

/// The Live tab reads the agent's transcript into lanes, counts, a log and packets, by the kinds
/// every CLI shares, and is a tab of the strip like the Files explorer.
@MainActor struct LivePanelTests {
    private func tool(_ id: String, kind: String, label: String, output: String? = "done", error: Bool = false) -> TranscriptBlock {
        TranscriptBlock(type: .tool, text: nil, id: id, name: "Tool", summary: label, command: nil, path: nil,
                        old: nil, new: nil, output: output, isError: error, kind: kind)
    }
    private func user(_ id: String) -> TranscriptTurn {
        TranscriptTurn(id: id, role: .user, timestamp: nil, ended: nil, model: nil,
                       blocks: [TranscriptBlock(type: .text, text: id, id: nil, name: nil, summary: nil, command: nil,
                                                path: nil, old: nil, new: nil, output: nil, isError: nil)])
    }
    private func agent(_ id: String, _ blocks: [TranscriptBlock], model: String? = "opus") -> TranscriptTurn {
        TranscriptTurn(id: id, role: .assistant, timestamp: nil, ended: nil, model: model, blocks: blocks)
    }

    @Test func theTranscriptFoldsIntoLanesCountsAndALog() {
        let turns = [
            user("u1"),
            agent("a1", [tool("t1", kind: "read", label: "README.md"), tool("t2", kind: "create", label: "new.swift"),
                         tool("t3", kind: "run", label: "ls\nmore", error: true), tool("t4", kind: "plan", label: "plan")]),
            user("u2"),
            agent("a2", [tool("t5", kind: "edit", label: "a.swift"), tool("t6", kind: "delegate", label: "explore", output: nil),
                         tool("t7", kind: "fetch", label: "https://example.com", output: nil)], model: "sonnet"),
        ]
        let activity = LiveActivity.of(turns, busy: true)
        #expect(activity.calls == 7 && activity.prompts == 2 && activity.failures == 1)
        #expect(activity.counts == [.read: 1, .edit: 2, .run: 1, .delegate: 1, .web: 1], "create is an edit, fetch the web, plan no lane")
        #expect(activity.running == [.delegate, .web], "calls with no output in the turn under way")
        #expect(activity.subagents.map(\.id) == ["t6"])
        #expect(activity.model == "sonnet")
        #expect(activity.log.map(\.id) == ["t2", "t3", "t4", "t5", "t6", "t7"], "the latest six, oldest first")
        #expect(activity.log.first { $0.id == "t3" }?.label == "ls", "a label is its first line")
    }

    @Test func theFilesBoxHoldsTheLastFilesChangedEachOnce() {
        func failed(_ id: String, _ path: String) -> TranscriptBlock {
            TranscriptBlock(type: .tool, text: nil, id: id, name: "Tool", summary: path, command: nil, path: path,
                            old: nil, new: nil, output: "no match", isError: true, kind: "edit")
        }
        func change(_ id: String, _ kind: String, _ path: String) -> TranscriptBlock {
            TranscriptBlock(type: .tool, text: nil, id: id, name: "Tool", summary: path, command: nil, path: path,
                            old: nil, new: nil, output: "done", isError: false, kind: kind)
        }
        let turns = [user("u1"), agent("a1", [change("t1", "edit", "/w/a.swift"), change("t2", "create", "/w/b.swift"),
                                              change("t3", "read", "/w/c.swift"), change("t4", "edit", "/w/a.swift"),
                                              change("t5", "edit", "/w/d.swift"), change("t6", "edit", "/w/e.swift"),
                                              failed("t7", "/w/f.swift")])]
        let files = LiveActivity.of(turns, busy: false).files
        #expect(files.map(\.path) == ["/w/e.swift", "/w/d.swift", "/w/a.swift"], "newest first, each once, reads and failed edits left out, three at most")
        #expect(files.last?.kind == "edit" && files.map(\.kind).allSatisfy { $0 == "edit" })
    }

    @Test func nothingRunsOnceTheAgentStopsOrAPromptFollows() {
        let open = agent("a1", [tool("t1", kind: "run", label: "make", output: nil)])
        #expect(LiveActivity.of([user("u1"), open], busy: false).running.isEmpty, "an interrupted call is not running")
        #expect(LiveActivity.of([user("u1"), open, user("u2")], busy: true).running.isEmpty, "only the turn under way runs")
    }

    @Test func eachReadAsksFromTheRevisionLastSeen() async {
        var transcript = AgentTranscript(revision: "r1", turns: [user("u1"), agent("a1", [tool("t1", kind: "read", label: "a")])], hooks: nil)
        var since: [String?] = []
        let model = LivePanelModel(load: { revision in since.append(revision); return transcript }, busy: { true })
        await model.refresh()
        transcript = AgentTranscript(revision: "r2", turns: [user("u1"), agent("a1", [tool("t1", kind: "read", label: "a"),
                                                                                   tool("t2", kind: "search", label: "b", output: nil)])], hooks: nil)
        await model.refresh()
        #expect(model.activity.running == [.search] && model.activity.latest[.search]?.id == "t2")
        #expect(since == [nil, "r1"])
    }

    private func hook(_ phase: String, _ id: String, kind: String? = nil, label: String? = nil, agent: String? = nil) -> ServerEvent {
        ServerEvent(type: "agent-tool", projectId: nil, id: nil, runId: "pty9", cli: "claude", label: label,
                    phase: phase, toolUseId: id, tool: "Tool", kind: kind, agentId: agent)
    }

    @Test func theFeedKeepsTheAgentsOwnCallsAsTheyStartAndEnd() {
        let feed = AgentToolFeed()
        let start = Date(timeIntervalSince1970: 100), end = Date(timeIntervalSince1970: 103)
        feed.receive(hook("start", "t1", kind: "run", label: "cargo test"), at: start)
        feed.receive(hook("start", "t1", kind: "run", label: "again"), at: end)
        feed.receive(hook("start", "s1", kind: "read", agent: "a1"), at: start)
        #expect(feed.calls.map(\.id) == ["t1"] && feed.calls[0].label == "cargo test", "once each, a subagent's own calls left out")
        feed.receive(hook("failed", "t1"), at: end)
        #expect(feed.calls[0].ended == end && feed.calls[0].failed)
        feed.receive(hook("done", "unknown"), at: end)
        #expect(feed.calls.count == 1, "an end with no start is nothing to draw")
        feed.receive(ServerEvent(type: "agent-tool", projectId: nil, id: nil, runId: "pty9", cli: "claude", sessionId: "c2",
                                 phase: "start", toolUseId: "t2", kind: "read"), at: end)
        #expect(feed.calls(in: "c2").map(\.id) == ["t1", "t2"] && feed.calls(in: "c1").map(\.id) == ["t1"],
                "a call names its conversation; one that named none is every conversation's")
        feed.reset()
        #expect(feed.calls.isEmpty)
    }

    @Test func theHooksDrawACallBeforeTheTranscriptHasIt() {
        let turns = [user("u1"), agent("a1", [tool("t1", kind: "read", label: "a.swift", output: nil)])]
        let started = Date(timeIntervalSince1970: 200)
        var early = AgentToolFeed.Call(id: "t1", kind: "read", label: "a.swift", started: started)
        early.ended = started
        let fresh = AgentToolFeed.Call(id: "t2", kind: "run", label: "make", started: started)
        let activity = LiveActivity.of(turns, busy: true).merging([early, fresh], busy: true)
        #expect(activity.calls == 2 && activity.counts[.run] == 1 && activity.latest[.run]?.label == "make")
        #expect(activity.log.map(\.id) == ["t1", "t2"] && activity.log.allSatisfy { $0.time == started }, "the time each really started")
        #expect(activity.log[0].running == false && activity.log[1].running, "t1's hook says it ended; t2 runs")
        #expect(activity.running == [.run], "read's call ended by its hook: its lane runs no more")
        var failed = early; failed.failed = true
        #expect(LiveActivity.of(turns, busy: true).merging([failed], busy: true).failures == 1, "failed by its hook before the transcript says so")
        #expect(LiveActivity.of(turns, busy: true).merging([], busy: true) == LiveActivity.of(turns, busy: true))
    }

    @Test func theModelDrawsTheFeedAsItArrives() async {
        var calls: [AgentToolFeed.Call] = []
        let model = LivePanelModel(load: { _ in AgentTranscript(revision: "r", turns: [], hooks: nil) }, busy: { true }, feed: { calls })
        await model.refresh()
        calls = [AgentToolFeed.Call(id: "t1", kind: "search", label: "grep", started: Date())]
        #expect(model.activity.latest[.search]?.label == "grep", "no read of the transcript needed")
    }

    @Test func theThemeIsAPreferenceKeptAcrossModels() throws {
        let defaults = try #require(UserDefaults(suiteName: "live-theme-\(UUID().uuidString)"))
        let load: (String?) async throws -> AgentTranscript = { _ in AgentTranscript(revision: "r", turns: [], hooks: nil) }
        let first = LivePanelModel(load: load, busy: { false }, defaults: defaults)
        #expect(first.theme == .terminal, "the reference's look until one is picked")
        first.setTheme(.blueprint)
        #expect(LivePanelModel(load: load, busy: { false }, defaults: defaults).theme == .blueprint)
        first.retire()
        first.setTheme(.pastel)
        #expect(first.theme == .blueprint, "a retired model changes nothing")
    }

    @Test func aTabOutOfSightReadsNothingAndAFailedReadStillStopsWhatRan() async {
        var shown = false, busy = true, fail = false, reads = 0
        let turns = [user("u1"), agent("a1", [tool("t1", kind: "run", label: "make", output: nil)])]
        let model = LivePanelModel(load: { _ in
            reads += 1
            if fail { throw BackendError.operation("gone") }
            return AgentTranscript(revision: "r", turns: turns, hooks: nil)
        }, busy: { busy }, visible: { shown })
        model.appear()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(reads == 0 && !model.isVisible, "a hidden tab reads nothing")
        shown = true
        await model.refresh()
        #expect(model.activity.running == [.run])
        fail = true; busy = false
        await model.refresh()
        #expect(model.error != nil && model.activity.running.isEmpty, "the agent stopping ends what ran, read or not")
        model.retire()
    }

    @Test func aRetiredModelStopsReading() async {
        var reads = 0
        let model = LivePanelModel(load: { _ in reads += 1; return AgentTranscript(revision: "r", turns: [], hooks: nil) }, busy: { false })
        model.retire()
        await model.refresh()
        model.appear()
        #expect(reads == 0 && !model.loaded)
    }

    @Test func liveIsATabOfTheStrip() throws {
        let context = WorkspaceContext(id: "task:live", sourceURL: "session:live", title: "")
        let page = try #require(context.open("https://example.com/home", title: "Home"))
        context.openTool(.live)
        #expect(context.pane == .term)
        #expect(context.tabs.map(\.id) == [page.id, WorkspaceTool.live.id])
        context.select(.page(page))
        context.openTool(.live)
        #expect(context.activeTool == .live && context.tools == [.live], "opening it again selects the one tab")
        context.close(.tool(.live))
        #expect(context.activePage === page, "closing it selects its neighbour")
    }

    @Test func liveIsSavedWithTheTabs() throws {
        let context = WorkspaceContext(id: "task:live", sourceURL: "session:live", title: "")
        _ = try #require(context.open("https://example.com/home", title: "Home"))
        context.openTool(.live)
        let snapshot = context.snapshot
        #expect(snapshot.tools == ["live"] && snapshot.activeID == WorkspaceTool.live.id)
    }
}
