import Foundation

/// A session started from the project composer. A pull request or Jira link starts on that page, as
/// a page's own New Session does (`PageSessionStart`). Anything else is a task: its branch is named
/// from the text and forks from the session base, and the text is the agent's first prompt. With
/// Shell only there is no agent to prompt, so the text is the branch name, as in the sheet.
@MainActor enum ProjectSessionStart {
    struct Plan: Equatable, Sendable {
        var draft: SessionDraft
        /// What the agent is asked first, on its first launch only.
        var prompt: String?
    }

    enum Outcome: Sendable {
        case planned(Plan)
        /// A link to a pull request whose branch nothing could look up: the sheet asks for it.
        case needsBranch(url: String)
    }

    static func plan(_ request: ProjectSessionRequest, project: Project, operations: any SessionCreating) async throws -> Outcome {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var draft = SessionDraft(); draft.agent = request.agent
        if text.range(of: "^https?://", options: .regularExpression) != nil {
            guard SessionPage.parse(text) != nil else {
                throw BackendError.operation(String(localized: "Paste a GitHub pull request or Jira issue link, or describe a task."))
            }
            do { draft = try await operations.resolvePage(text, project: project, draft: draft) }
            catch is PullRequestBranchUnknown { return .needsBranch(url: text) }
            if draft.createBranch && draft.reuseWorktree == nil { draft.base = try await operations.references(project).sessionBase }
            return .planned(Plan(draft: draft))
        }
        let references = try await operations.references(project)
        let existing = Set(references.branches.map(\.name))
        draft.base = references.sessionBase
        if request.agent == .shell {
            let branch = text.replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
            if let problem = NewSessionViewModel.branchNameError(branch) { throw BackendError.operation(problem) }
            draft.branch = branch; draft.createBranch = !existing.contains(branch)
            return .planned(Plan(draft: draft))
        }
        draft.branch = uniqueBranch(branchName(for: text), taken: existing)
        draft.createBranch = true
        draft.title = title(for: text)
        return .planned(Plan(draft: draft, prompt: text))
    }

    /// A few words of the task, as a branch: lowercase, hyphenated, at most 40 characters and cut
    /// at a word. A task with no letters or digits in it is a plain "session".
    static func branchName(for text: String) -> String {
        let words = text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .split(separator: " ")
        var name = ""
        for word in words {
            let next = name.isEmpty ? String(word) : "\(name)-\(word)"
            if next.count > 40 { break }
            name = next
        }
        if name.isEmpty, let first = words.first { name = String(first.prefix(40)) }
        return name.isEmpty ? "session" : name
    }

    /// `name`, or `name-2`, `name-3`… when the repository already has it: a task is always new work.
    static func uniqueBranch(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        var suffix = 2
        while taken.contains("\(name)-\(suffix)") { suffix += 1 }
        return "\(name)-\(suffix)"
    }

    /// The session's title: the task's first line, shortened for the sidebar.
    static func title(for text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }
}
