import Foundation

/// Which session a PR or ticket page belongs to.
///
/// A PR, a ticket and a session are all described by up to three identities: the page URL, the git
/// branch, and the Jira key. A session's own identities come from its record; it also inherits the
/// identities of the open PRs it is tied to — a PR on its branch lends its URL and keys, the PR it
/// was started from lends its branch and keys. A ticket page inherits the branch and URL of every
/// open PR that references it. The page and each session then share some identities, weighted by
/// how specific they are: a URL names one page, a branch names one worktree, a key is shared by
/// every PR for that ticket. The session sharing the most wins; the newest breaks a tie. A PR row and
/// its ticket's row therefore land on the same session — the one whose worktree produced the PR.
enum SessionResolver {
    struct PullRequest: Equatable, Sendable {
        let projectID: String
        let url: String
        let branch: String
        let jiraKeys: [String]
    }

    private struct Identity: Hashable {
        enum Kind: Int { case key = 1, branch = 2, url = 4 }
        let kind: Kind
        let value: String
        static func url(_ value: String) -> Identity? { value.isEmpty ? nil : .init(kind: .url, value: value) }
        static func branch(_ value: String) -> Identity? { value.isEmpty ? nil : .init(kind: .branch, value: value) }
        static func key(_ value: String) -> Identity? { value.isEmpty ? nil : .init(kind: .key, value: value.uppercased()) }
    }

    static func pullRequests(_ projects: [DashboardProject]) -> [PullRequest] {
        projects.flatMap { project in
            project.prs.compactMap { pr -> PullRequest? in
                guard pr.state == nil || pr.state == "OPEN", let url = pr.url, !url.isEmpty else { return nil }
                return .init(projectID: project.id, url: url, branch: pr.headRefName ?? "", jiraKeys: pr.jiraKeys ?? [])
            }
        }
    }

    /// The session for `request`'s page among `sessions` in `projectID`. With no project to scope
    /// them, branches and keys of unrelated projects could collide, so only the page's own session counts.
    static func resolve(_ request: OpenPageRequest, page: SessionPage, projectID: String?,
                        sessions: [WorkspaceSession], pullRequests: [PullRequest]) -> WorkspaceSession? {
        guard let projectID else { return sessions.first { $0.url == page.url } }
        let candidates = sessions.filter { $0.projectId == projectID }
        guard !candidates.isEmpty else { return nil }
        let prs = pullRequests.filter { $0.projectID == projectID }
        let wanted = identities(page: page, request: request, pullRequests: prs)
        var best: (score: Int, createdAt: String, session: WorkspaceSession)?
        for session in candidates {
            let shared = identities(session: session, pullRequests: prs).intersection(wanted)
            var score = 0
            for identity in shared { score += identity.kind.rawValue }
            guard score > 0 else { continue }
            let createdAt = session.createdAt ?? ""
            if let current = best, (current.score, current.createdAt) >= (score, createdAt) { continue }
            best = (score, createdAt, session)
        }
        return best?.session
    }

    private static func identities(page: SessionPage, request: OpenPageRequest, pullRequests: [PullRequest]) -> Set<Identity> {
        var set = Set<Identity>([Identity.url(page.url)].compactMap { $0 })
        if page.kind == "jira" {
            set.formUnion([Identity.key(page.key)].compactMap { $0 })
            // A ticket with a PR is that PR's page too.
            for pr in pullRequests where pr.jiraKeys.contains(where: { $0.uppercased() == page.key }) {
                set.formUnion([Identity.url(pr.url), Identity.branch(pr.branch)].compactMap { $0 })
            }
        } else {
            set.formUnion([Identity.branch(request.branch)].compactMap { $0 })
            set.formUnion(request.jiraKeys.compactMap(Identity.key))
        }
        return set
    }

    private static func identities(session: WorkspaceSession, pullRequests: [PullRequest]) -> Set<Identity> {
        var set = Set<Identity>([Identity.url(session.url), Identity.branch(session.branch), Identity.key(session.jiraKey ?? "")].compactMap { $0 })
        for pr in pullRequests where (!session.branch.isEmpty && pr.branch == session.branch) || pr.url == session.url {
            set.formUnion([Identity.url(pr.url), Identity.branch(pr.branch)].compactMap { $0 })
            set.formUnion(pr.jiraKeys.compactMap(Identity.key))
        }
        return set
    }
}
