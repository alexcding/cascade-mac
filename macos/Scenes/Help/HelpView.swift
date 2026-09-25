import SwiftUI

/// Offline, read-only help. Keeping the articles native makes them searchable and accessible
/// without introducing another bundled web page or requiring the backend to be running.
struct HelpView: View {
    @State private var query = ""

    private var articles: [HelpArticle] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return HelpArticle.all.filter {
            term.isEmpty || $0.title.localizedStandardContains(term) || $0.body.localizedStandardContains(term)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Cascade Help").font(.largeTitle.bold())
                TextField("Search help", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("help-search")
                if articles.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
                ForEach(articles) { article in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(article.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        Text(article.body).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }
            }
            .padding(28)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 480, minHeight: 400)
        // Match the language used by String(localized:), even when the system's language differs.
        .environment(\.layoutDirection,
                     Locale.Language(identifier: Bundle.main.preferredLocalizations.first ?? "en")
                        .characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
    }
}

struct HelpArticle: Identifiable {
    let id: String
    let title: String
    let body: String

    static let all: [HelpArticle] = [
        .init(id: "start", title: String(localized: "Get started"), body: String(localized: "Add a project and choose its local repository folder. Each project uses one repository. Add GitHub or Jira details if you want pull requests or tickets. Open Settings → Integrations to check your tools or run the setup assistant again. Agents are optional: choose Shell only to use a terminal.")),
        .init(id: "sessions", title: String(localized: "Sessions and worktrees"), body: String(localized: "Choose New Session and enter a branch name, GitHub pull request URL, or Jira ticket URL. Choose a base branch and an agent, or Shell only. A session keeps its terminal and Git worktree together so tasks can run independently. Worktrees created outside Cascade do not appear automatically. Settings → Worktrees controls location, copied files, and optional fetching.")),
        .init(id: "reviews", title: String(localized: "Pull requests and reviews"), body: String(localized: "The dashboard separates your pull requests from your review queue. Reviews you have already submitted can remain in that queue. The menu bar highlights active requests for your review. GitHub and Jira refresh in the background; change the intervals in Settings → Integrations. If a refresh fails, the last available data stays visible.")),
        .init(id: "files", title: String(localized: "Files, changes, and commits"), body: String(localized: "Use Files to edit and Diff to inspect working changes. Save your files before Commit and Push. Untracked files are included only when selected. If a push fails after a commit succeeds, the local commit is kept and you can retry the push. Discard removes the changes shown in its preview. Unsaved editor changes are not recovered after a crash.")),
        .init(id: "automation", title: String(localized: "Automation and workflows"), body: String(localized: "Automation reacts to GitHub and Jira events across projects. Test a pipeline with a dry run before enabling it. Workflows run a saved sequence of agent prompts for one project. Install the agent hooks in Settings → Integrations before running a workflow. Jira board columns and Fix Version features also need a Jira API token.")),
        .init(id: "closing", title: String(localized: "Close, quit, and remove"), body: String(localized: "Closing the main window keeps sessions running. Quitting Cascade or restarting for an update stops its terminals and workflows after checking unsaved files. Removing a session previews the affected work; discarding uncommitted changes requires confirmation. Removing a project keeps its workspace folders and sessions.")),
        .init(id: "troubleshooting", title: String(localized: "Troubleshooting"), body: String(localized: "If GitHub or Jira data is missing, check installation and sign-in status in Settings → Integrations, then click Refresh. Sign in from your terminal with gh auth login or acli jira auth login. Open Settings → Activity for errors and Settings → System for diagnostics. The Simulator preview needs Node.js 20 or later. Review logs for private information before sharing them.")),
        .init(id: "language", title: String(localized: "Language and shortcuts"), body: String(localized: "Cascade follows your preferred app language in macOS System Settings → General → Language & Region. Restart Cascade after changing it. Customize keyboard shortcuts in Settings → Shortcuts. Terminal output, repository content, and text from GitHub or Jira stay in their original language."))
    ]
}
