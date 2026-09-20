import Foundation
import Testing

actor JiraFixture: JiraService {
    var fails = false
    var rejectMove = false
    var reads = 0
    var searches: [String] = []
    var moves: [String] = []
    var saved: [String] = []
    var status = "To Do"
    func fail(_ value: Bool) { fails = value }
    func reject(_ value: Bool) { rejectMove = value }
    func confirm(_ value: String) { status = value }
    func snapshot(projectID: String) async throws -> JiraSnapshot {
        reads += 1
        try await Task.sleep(for: .milliseconds(20))
        if fails { throw BackendError.operation("Jira snapshot offline") }
        return JiraSnapshot(items: [
            JiraTicket(key: "REC-1", summary: "Login crash", status: status, type: "Bug", priority: "High", assignee: "Alice"),
            JiraTicket(key: "REC-2", summary: "Completed task", status: "Done", type: "Task", priority: "Low"),
            JiraTicket(key: "OTHER-3", summary: "Other project", status: "Blocked", type: "Task", priority: "High")
        ], jql: "project = REC")
    }
    func site() async throws -> JiraSite {
        try await Task.sleep(for: .milliseconds(100))
        return JiraSite(baseUrl: "https://jira.example.test")
    }
    func search(jql: String) async throws -> JiraSnapshot {
        searches.append(jql)
        if jql.contains("slow") { try await Task.sleep(for: .milliseconds(100)) }
        if fails { throw BackendError.operation("Jira search offline") }
        return JiraSnapshot(items: [JiraTicket(key: "REC-1", summary: jql, status: status)], jql: jql)
    }
    func transition(key: String, status: String) async throws {
        moves.append(status)
        try await Task.sleep(for: .milliseconds(20))
        if rejectMove { throw BackendError.operation("Transition rejected") }
        // Deliberately keep the snapshot stale until confirm() to exercise the overlay.
    }
    func settings() async throws -> [String: String] {
        try await Task.sleep(for: .milliseconds(60))
        return ["ticket_filter_p": #"{"project":"OTHER"}"#]
    }
    func syncAfterMutation() {}
    func saveFilters(_ filters: String, projectID: String) async throws {
        try await Task.sleep(for: .milliseconds(20))
        if fails { throw BackendError.operation("Preferences offline") }
        saved.append(filters)
    }
}

@MainActor private struct JiraFixturePageActions: PageActionServing {
    let open: (OpenPageRequest) async throws -> Void
    func openPage(_ request: OpenPageRequest) async throws { try await open(request) }
    func openBrowser(_ url: URL) -> Bool { true }
    func copyLink(_ value: String) {}
}

@MainActor private func jiraModel(_ service: JiraFixture, now: @escaping () -> Date = Date.init,
                                 open: @escaping (OpenPageRequest) async throws -> Void = { _ in }) -> JiraTicketsViewModel {
    JiraTicketsViewModel(project: Project(id: "p", name: "Native", repo: "", color: nil, workspace: "/tmp", jiraProjectKey: "REC"),
                         service: service, pageActions: JiraFixturePageActions(open: open), now: now)
}

@MainActor private func waitForJira(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

@MainActor @Test func jiraSnapshotFacetsRetainDataAndSerializeChangedPreferences() async throws {
    let service = JiraFixture()
    let model = jiraModel(service)
    model.refresh()
    try await waitForJira { !model.loading }
    #expect(model.items.count == 3 && model.baseURL == nil) // account discovery does not block rows
    model.setFilter(.project, "REC") // newer than the delayed saved-filter read
    model.setFilter(.status, "To Do")
    model.setFilter(.status, "Done")
    try await waitForJira { model.baseURL != nil }
    #expect(model.filters["project"] == "REC" && model.rows.map(\.key) == ["REC-2"])
    #expect(model.options(.status) == ["Done", "To Do"])
    let saved = await service.saved
    #expect(JiraTicketsViewModel.parseFilters(try #require(saved.last)) == ["project": "REC", "status": "Done"])
    await service.fail(true)
    model.refresh()
    try await waitForJira { !model.loading }
    #expect(model.rows.count == 1 && model.snapshotError == "Jira snapshot offline")
    await service.fail(false)
    model.refresh()
    try await waitForJira { !model.loading }
    #expect(model.snapshotError == nil)
    await model.stop()
}

@MainActor @Test func jiraSearchRejectsLateResultsAndDoesNotRepeatOnSnapshotSync() async throws {
    let service = JiraFixture()
    let model = jiraModel(service)
    model.query = "slow"
    let old = Task { await model.search() }
    try await Task.sleep(for: .milliseconds(10))
    model.query = "rec-42"
    await model.search(); await old.value
    #expect(model.source?.jql == "key = REC-42" && model.searchedQuery == "rec-42")
    model.refresh()
    try await waitForJira { !model.loading }
    #expect(await service.searches.count == 2 && model.source?.jql == "key = REC-42")
    await service.fail(true)
    model.query = "another"
    await model.search()
    #expect(model.searchedQuery == "rec-42" && model.error == "Jira search offline")
    await service.fail(false)
    model.query = "slow"
    let cleared = Task { await model.search() }
    try await Task.sleep(for: .milliseconds(10))
    model.clearSearch(); await cleared.value
    #expect(model.searchResult == nil && !model.searching && model.searchedQuery == nil)
    await model.stop()
}

@MainActor @Test func jiraExplicitAllFilterWinsOverDelayedStoredPreference() async throws {
    let model = jiraModel(JiraFixture())
    model.refresh()
    // Choosing All while settings are loading is still an explicit intent, even
    // though the provisional selection also looks empty.
    model.setFilter(.project, "")
    try await waitForJira { model.baseURL != nil }
    #expect(model.filters["project"] == nil && model.rows.count == 3)
    await model.stop()
}

@MainActor @Test func jiraMovesRejectFailuresCoalesceAndSurviveStaleSnapshotsUntilExpiry() async throws {
    let service = JiraFixture()
    var date = Date()
    var opened: OpenPageRequest?
    let model = jiraModel(service, now: { date }, open: { opened = $0 })
    model.refresh()
    try await waitForJira { !model.loading }
    let ticket = try #require(model.items.first)
    await service.reject(true)
    await model.transition(ticket, to: "Blocked")
    #expect(model.items.first?.status == "To Do" && model.error == "Transition rejected")
    await service.reject(false)
    let first = Task { await model.transition(ticket, to: "Done") }
    try await Task.sleep(for: .milliseconds(5))
    await model.transition(ticket, to: "Done"); await first.value
    try await waitForJira { !model.loading }
    #expect(await service.moves == ["Blocked", "Done"])
    #expect(model.items.first?.status == "Done" && model.snapshot?.items.first?.status == "To Do")
    date = date.addingTimeInterval(301)
    model.refresh()
    try await waitForJira { !model.loading && model.baseURL != nil }
    #expect(model.items.first?.status == "To Do")
    model.setFilter(.project, "")
    model.onAction = { [weak model] in model?.perform($0) }
    model.open(ticket); await model.navigation.waitForOpen()
    #expect(opened?.url == "https://jira.example.test/browse/REC-1")
    #expect(model.ticketURL(JiraTicket(key: "../secret")) == nil)
    await model.stop()
}

@Test func jiraQueryMatchesSharedKeywordKeyAndJQLRules() {
    let cases = [
        ("login crash", "project = REC AND text ~ \"login crash\" ORDER BY updated DESC"),
        ("say \"hi\"", "project = REC AND text ~ \"say hi\" ORDER BY updated DESC"),
        ("rec-42", "key = REC-42"), ("", "")
    ]
    for (input, expected) in cases { #expect(JiraQuery.make(input, projectKey: "REC") == expected) }
    #expect(JiraQuery.make("  order   status ", projectKey: "") == "text ~ \"order status\" ORDER BY updated DESC")
    for text in ["not working", "log in crash", "cannot log in", "video is black", "ios or android", "sign in and out"] {
        #expect(!JiraQuery.looksLikeJQL(text))
        #expect(JiraQuery.make(text, projectKey: "REC") == "project = REC AND text ~ \"\(text)\" ORDER BY updated DESC")
    }
    for text in ["status in (Open, Done)", "assignee is EMPTY", "status was \"In Progress\"", "status not in (Done)",
                 "labels is not empty", "order by created", "assignee = currentUser() AND status != Done", "summary ~ login order by created"] {
        #expect(JiraQuery.looksLikeJQL(text))
        #expect(JiraQuery.make(text, projectKey: "REC") == text)
    }
}
