//! Where a ticket sits in its workflow and how pressing it is, read from Jira's words once, here.
//! Every ticket the backend hands out carries a `stage` and a `level`, so the app draws them and
//! never matches status or priority names itself.

/// The workflow stage: `toDo`, `inProgress`, `pendingRelease` or `blocked`. The status name is
/// read first and Jira's category second: a board names "Ready for Development" as in progress,
/// but nobody has started it yet, and "Reopened" is `new` but is back in someone's hands.
pub fn stage(status: &str, category: &str) -> &'static str {
    let status = status.to_lowercase();
    if status.contains("block") {
        "blocked"
    } else if status.contains("release")
        || status.contains("done")
        || status.contains("resolved")
        || category == "done"
    {
        "pendingRelease"
    } else if status.contains("reopen") {
        "inProgress"
    } else if category == "new"
        || status.starts_with("ready for")
        || matches!(
            status.as_str(),
            "open" | "to do" | "backlog" | "selected for development"
        )
    {
        "toDo"
    } else {
        "inProgress"
    }
}

/// Whether the status says the ticket came back after being closed. The home screen ranks such
/// a ticket ahead of other work in progress.
pub fn reopened(status: &str) -> bool {
    status.to_lowercase().contains("reopen")
}

/// Jira's priority names folded onto four levels, most pressing first: `urgent`, `high`,
/// `medium`, `low`. Anything unrecognised, or no priority at all, is Medium, Jira's own default.
pub fn level(priority: &str) -> &'static str {
    match priority.to_lowercase().as_str() {
        "urgent" | "highest" | "blocker" | "critical" => "urgent",
        "high" | "major" => "high",
        "low" | "lowest" | "minor" | "trivial" => "low",
        _ => "medium",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_names_win_over_jira_categories() {
        assert_eq!(stage("Ready for Development", "indeterminate"), "toDo");
        assert_eq!(stage("Open", "new"), "toDo");
        assert_eq!(stage("Selected for Development", "new"), "toDo");
        assert_eq!(stage("In PR Review", "indeterminate"), "inProgress");
        assert_eq!(stage("Reopened", "new"), "inProgress");
        assert_eq!(stage("Pending Release", "indeterminate"), "pendingRelease");
        assert_eq!(stage("Resolved", "indeterminate"), "pendingRelease");
        assert_eq!(stage("Blocked - Record", "indeterminate"), "blocked");
    }

    #[test]
    fn a_done_category_is_pending_release_whatever_the_name() {
        assert_eq!(stage("Shipped", "done"), "pendingRelease");
        assert_eq!(stage("Closed", "done"), "pendingRelease");
    }

    #[test]
    fn github_issue_statuses_map_like_jira() {
        assert_eq!(stage("Open", "new"), "toDo");
        assert_eq!(stage("Closed", "done"), "pendingRelease");
        assert_eq!(stage("Not planned", "done"), "pendingRelease");
    }

    #[test]
    fn unknown_status_in_an_open_category_is_in_progress() {
        assert_eq!(stage("Doing Things", "indeterminate"), "inProgress");
        assert_eq!(stage("", ""), "inProgress");
    }

    #[test]
    fn reopened_reads_the_status_name() {
        assert!(reopened("Reopened"));
        assert!(reopened("Re-opened for QA") == false, "only the word itself counts");
        assert!(!reopened("Open"));
    }

    #[test]
    fn priorities_fold_onto_four_levels() {
        for name in ["Urgent", "Highest", "Blocker", "critical"] {
            assert_eq!(level(name), "urgent", "{name}");
        }
        for name in ["High", "Major"] {
            assert_eq!(level(name), "high", "{name}");
        }
        for name in ["Low", "Lowest", "Minor", "Trivial"] {
            assert_eq!(level(name), "low", "{name}");
        }
        for name in ["Medium", "Normal", ""] {
            assert_eq!(level(name), "medium", "{name:?}");
        }
    }
}
