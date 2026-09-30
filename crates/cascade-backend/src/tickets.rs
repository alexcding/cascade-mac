//! Where a ticket sits in its workflow and how pressing it is, read from Jira's words once, here.
//! Every ticket the backend hands out carries a `stage` and a `level`, so the app draws them and
//! never matches status or priority names itself.

/// The workflow stage: `toDo`, `inProgress`, `pendingRelease` or `blocked`. The status name is
/// read first and Jira's category second: a board names "Ready for Development" as in progress,
/// but nobody has started it yet, and "Reopened" is `new` but is back in someone's hands. The
/// name is read by its words ("Blocking" and "Blockers" are blocked, "Releasing" is a release;
/// "Unblocked", "Abandoned" and "Blockchain" are none of these), and a denial earlier in the same
/// phrase ("Not yet released", "Unable to resolve") takes it back, while one in another phrase
/// does not ("No QA - Blocked" is blocked).
pub fn stage(status: &str, category: &str) -> &'static str {
    let words = words(status);
    if says(&words, BLOCKED) {
        "blocked"
    } else if says(&words, RELEASED) || category == "done" {
        "pendingRelease"
    } else if says(&words, REOPENED) {
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
    says(&words(status), REOPENED)
}

const BLOCKED: &[&str] = &["blocked", "blocking", "blocker", "blockers", "blocks", "block"];
const RELEASED: &[&str] = &["release", "released", "releasing", "prerelease", "done", "resolved", "resolve"];
const REOPENED: &[&str] = &["reopened", "reopen"];
const DENIALS: &[&str] = &["not", "no", "never", "unable", "cannot"];

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

/// Whether one of `said` is among the words of a phrase, with no denial earlier in that phrase.
fn says(phrases: &[Vec<String>], said: &[&str]) -> bool {
    phrases.iter().any(|words| {
        words.iter().enumerate().any(|(index, word)| {
            said.contains(&word.as_str()) && !words[..index].iter().any(|w| DENIALS.contains(&w.as_str()))
        })
    })
}

/// The marks that end a phrase when they stand between words: a dash, a colon, a comma or a bar
/// set off by whitespace. Not a period: "Not in ver. 2 release" is one phrase.
const SEPARATORS: &str = "-\u{2013}\u{2014}:;,|";

/// The status name's phrases, each its lowercased words. A phrase ends at a separator standing
/// between words ("Blocked - Record" is two, so "No QA - Blocked" is blocked); any other mark, or
/// one inside a word, only ends the word ("Not-Blocked", "Not (yet) released", "Not in ver. 2
/// release" and "Unable to reproduce/resolve" are each one phrase, and their denial reaches the
/// end).
fn words(status: &str) -> Vec<Vec<String>> {
    let mut phrases: Vec<Vec<String>> = vec![Vec::new()];
    let mut word = String::new();
    let mut gap = String::new();
    for c in status.to_lowercase().chars() {
        if c.is_alphanumeric() {
            if gap.chars().any(char::is_whitespace) && gap.chars().any(|g| SEPARATORS.contains(g)) {
                phrases.push(Vec::new());
            }
            gap.clear();
            word.push(c);
        } else {
            if !word.is_empty() {
                phrases.last_mut().expect("one phrase from the start").push(std::mem::take(&mut word));
            }
            gap.push(c);
        }
    }
    if !word.is_empty() {
        phrases.last_mut().expect("one phrase from the start").push(word);
    }
    phrases.retain(|phrase| !phrase.is_empty());
    phrases
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
    fn a_word_is_read_whole_and_a_denial_before_it_takes_it_back() {
        for name in ["Blocking Issue", "Blockers", "Blocked", "Blocks", "No QA - Blocked", "No QA \u{2013} Blocked", "Blocked - Record"] {
            assert_eq!(stage(name, "indeterminate"), "blocked", "{name}");
        }
        for name in ["Releasing", "Released", "Resolve", "Done", "Prerelease", "Not a bug - Released", "Not a bug: released"] {
            assert_eq!(stage(name, "indeterminate"), "pendingRelease", "{name}");
        }
        for name in ["Unblocked", "Not Blocked", "Not currently blocked", "Abandoned", "Undone", "Not Done", "Not yet released",
                     "Not ready to be released", "Unable to reproduce/resolve", "Cannot reproduce / resolve",
                     "Not the vendor's release", "Not-Blocked", "Not Pre-Released", "Not in v2.1 release",
                     "Not in ver. 2 release", "Not (yet) released", "(Not) Released",
                     "Blockchain Audit", "Unable to resolve", "Cannot release", "No release"] {
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
