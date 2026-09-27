import Foundation

/// How the Start page names what it creates: a task's branch and title, and the checks a typed
/// branch name must pass.
enum ProjectSessionStart {
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

    /// The server's validBranchName, so a bad name is caught before the worktree call.
    static func branchNameError(_ branch: String) -> String? {
        if branch.isEmpty { return String(localized: "Enter a branch name") }
        if branch.hasPrefix("-") || branch.hasSuffix("/") || branch.hasSuffix(".") || branch.hasSuffix(".lock") {
            return String(localized: "Branch name can’t start with “-” or end with “/”, “.” or “.lock”")
        }
        if branch.range(of: #"[\x00-\x20\x7f~^:?*\[\\]|\.\.|@\{|//|^@$"#, options: .regularExpression) != nil {
            return String(localized: "Branch name can’t contain spaces, “..” or ~ ^ : ? * [ \\")
        }
        if !branch.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) {
            return String(localized: "No branch segment may start with “.”")
        }
        return nil
    }
}
