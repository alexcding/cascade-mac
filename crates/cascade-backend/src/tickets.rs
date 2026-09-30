//! Where a ticket sits in its workflow and how pressing it is, read from Jira's words once, here.
//! Every ticket the backend hands out carries a `stage` and a `level`, so the app draws them and
//! never matches status or priority names itself.

/// The workflow stage: `toDo`, `inProgress`, `pendingRelease` or `blocked`. The status name is
/// read first and Jira's category second: a board names "Ready for Development" as in progress,
/// but nobody has started it yet, and "Reopened" is `new` but is back in someone's hands. The
/// name is read by its words' stems ("Blocking" and "Blockers" are blocked, "Releasing" is a
/// release), a word is not its negation ("Unblocked" is not blocked, "Abandoned" is not done),
/// and a "not" anywhere before a word denies it ("Not yet released").
pub fn stage(status: &str, category: &str) -> &'static str {
    let words = words(status);
    if says(&words, &["block"]) {
        "blocked"
    } else if says(&words, &["releas", "done", "resolv"]) || category == "done" {
        "pendingRelease"
    } else if says(&words, &["reopen"]) {
        "inProgress"
    } else if category == "new"
        || status.to_lowercase().starts_with("ready for")
        || matches!(
            status.to_lowercase().as_str(),
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
    says(&words(status), &["reopen"])
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

/// Whether a word starting with one of `stems` is said, and not denied by a "not" before it.
fn says(words: &[String], stems: &[&str]) -> bool {
    words.iter().enumerate().any(|(index, word)| {
        stems.iter().any(|stem| word.starts_with(stem)) && !words[..index].iter().any(|w| w == "not")
    })
}

/// The status name's words, lowercased: split on anything that is not a letter or a digit.
fn words(status: &str) -> Vec<String> {
    status
        .to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(str::to_owned)
        .collect()
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
    fn a_word_is_read_by_its_stem_and_a_not_before_it_denies_it() {
        for name in ["Blocking Issue", "Blockers", "Blocked"] {
            assert_eq!(stage(name, "indeterminate"), "blocked", "{name}");
        }
        for name in ["Releasing", "Released", "Resolve", "Done"] {
            assert_eq!(stage(name, "indeterminate"), "pendingRelease", "{name}");
        }
        for name in ["Unblocked", "Not Blocked", "Not currently blocked", "Abandoned", "Undone", "Not Done", "Not yet released"] {
            assert_eq!(stage(name, "indeterminate"), "inProgress", "{name}");
        }
        // Jira's own category still decides a name that says nothing.
        assert_eq!(stage("Not Done", "done"), "pendingRelease");
        // The same reading answers whether a ticket was reopened.
        assert!(reopened("Reopened") && reopened("Reopen for QA"));
        assert!(!reopened("Not Reopened"));
        assert_eq!(stage("Not Reopened", "new"), "toDo");
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
