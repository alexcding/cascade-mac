import Foundation
import Testing
@testable import Craft

// A project only shows the sections it can serve: GitHub ones need a repo, Jira
// ones a project key or JQL.
@MainActor struct ProjectSectionAvailabilityTests {
    private func model(_ project: Project) throws -> ProjectPageViewModel {
        let api = try APIClient(baseURL: URL(string: "http://127.0.0.1:1")!)
        let service = APIProjectService(api: api)
        let editor = NativeCreationFlowFactory(chooseFolder: { nil }).projectEditor(project: project, service: service)
        return ProjectPageViewModel(project: project, service: service, editor: editor)
    }

    @Test func sectionsFollowTheProjectsIntegrations() {
        let bare = Project(id: "p", name: "P", repo: "", color: nil, workspace: "/tmp")
        #expect(ProjectSection.available(for: bare) == [.workflows, .settings])
        let github = Project(id: "p", name: "P", repo: "o/r", color: nil, workspace: "/tmp")
        #expect(ProjectSection.available(for: github) == [.prs, .workflows, .automation, .settings])
        let jiraKey = Project(id: "p", name: "P", repo: "", color: nil, workspace: "/tmp", jiraProjectKey: "APP")
        #expect(ProjectSection.available(for: jiraKey) == [.tickets, .board, .workflows, .settings])
        let jql = Project(id: "p", name: "P", repo: "", color: nil, workspace: "/tmp", jql: "project = APP")
        #expect(ProjectSection.available(for: jql) == [.tickets, .board, .workflows, .settings])
        let both = Project(id: "p", name: "P", repo: "o/r", color: nil, workspace: "/tmp", jiraProjectKey: "APP")
        #expect(ProjectSection.available(for: both) == ProjectSection.allCases)
    }

    @Test func selectionNeverRestsOnAHiddenSection() throws {
        let page = try model(Project(id: "p", name: "P", repo: "", color: nil, workspace: "/tmp", jiraProjectKey: "APP"))
        #expect(page.section == .tickets)  // the default Pull Requests tab is hidden without a repo
        page.setSection(.prs)
        #expect(page.section == .tickets)
        page.setSection(.board)
        #expect(page.section == .board)
        // Removing Jira in Settings moves the selection off the now-hidden board.
        page.update(Project(id: "p", name: "P", repo: "o/r", color: nil, workspace: "/tmp"))
        #expect(page.availableSections == [.prs, .workflows, .automation, .settings])
        #expect(page.section == .prs)
        page.setSection(.settings)
        page.update(Project(id: "p", name: "P", repo: "", color: nil, workspace: "/tmp"))
        #expect(page.section == .settings)
    }
}
