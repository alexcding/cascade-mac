//! A session's name: what the sidebar calls it. Without one the sidebar falls back to the
//! worktree's folder, the branch slug cut from the first prompt (`fix-the-login-crash-on-ios`).
//!
//! - A session started from a page takes the page's own title at once: a pull request's number
//!   and title (`#482 Fix login crash`), an issue's or a Jira ticket's title as the app already
//!   wrote it (`#12 …`, `PROJ-123 …`). No model is asked.
//! - A session started from a typed prompt is named by a model in the background, a few seconds
//!   after it starts (Synara's first-turn thread title, `ProviderCommandReactor.ts`, with a prompt
//!   of its own: one title for the whole task, never a list of steps).
//!
//! Either way the name is written only while the session has none, so a rename made meanwhile
//! wins, and a session removed meanwhile is not brought back.

use cascade_chat::text_generation::{
    is_usable_generated_thread_title, limit_section, sanitize_generated_thread_title,
};

use crate::{chat::titles, cli, AppState, Event};

/// The prompt a typed task is named with. Synara's thread-title prompt asks for a summary of the
/// request, which for a task of several steps reads as a list of them ("Redesign cancel button,
/// move recording time"); a session is one piece of work, and is named as one.
pub(crate) fn session_name_prompt(message: &str) -> String {
    [
        "You name coding sessions. Each session is one task a developer asked an AI agent to do.",
        "Return a JSON object with key: title.",
        "Respond with only the JSON object, no prose and no code fences.",
        "Rules:",
        "- Write a real title for the whole task, as a good pull request or issue title would be: 3-6 words naming its main goal.",
        "- Never list several steps or tasks. No commas, semicolons, slashes, ampersands or dashes; do not join two tasks with \"and\".",
        "- When the message asks for several things, name the goal they share, not the first step.",
        "- Be specific: keep distinguishing identifiers from the message (PR/issue numbers, branch, file, feature or product names, error codes).",
        "- Fix spelling mistakes from the message, but never add details the message does not say.",
        "- Sentence case: capitalize the first word and proper nouns only. No quotes, markdown, emoji or trailing punctuation.",
        "- Never a generic title such as Session, Task, Chat or Update.",
        "",
        "User message:",
        &limit_section(message.trim(), 8_000),
    ]
    .join("\n")
}

/// Words a title does not end on.
const DANGLING: [&str; 12] = ["and", "or", "for", "with", "to", "of", "the", "a", "an", "in", "on", "from"];

/// What the model answered, as a name: one title, not a list. A clause after a comma or a
/// semicolon is dropped (the model was told not to write one), list marks become spaces, and the
/// rest is held to six words and sixty characters. None when nothing usable is left.
pub(crate) fn tidy_session_name(raw: &str) -> Option<String> {
    let unlisted: String = first_clause(raw.trim())
        .chars()
        .map(|c| if matches!(c, '/' | '&' | '|' | '—' | '–') { ' ' } else { c })
        .collect();
    let unlisted = unlisted.replace(" - ", " ");
    let name = sanitize_generated_thread_title(&unlisted);
    let mut words: Vec<&str> = name.split_whitespace().collect();
    // Past sixty characters the title was cut mid-word and marked "...": the cut word goes.
    if name.ends_with("...") && words.len() > 1 {
        words.pop();
    }
    let name = words.join(" ");
    let mut words: Vec<&str> = name.trim_end_matches(['.', '!', '?', ':', '-']).split_whitespace().collect();
    // Six words cut from seven can end on a joint ("… incomplete work and").
    while words.len() > 1 && DANGLING.contains(&words[words.len() - 1].to_lowercase().as_str()) {
        words.pop();
    }
    let name = words.join(" ");
    (is_usable_generated_thread_title(&name) && !matches!(name.to_lowercase().as_str(), "task" | "update" | "new task"))
        .then_some(name)
}

/// The text before the first semicolon, or the first comma that is not inside a number
/// (`10,000`).
fn first_clause(text: &str) -> &str {
    let chars: Vec<(usize, char)> = text.char_indices().collect();
    for (index, &(at, c)) in chars.iter().enumerate() {
        let in_number = c == ','
            && index > 0
            && chars[index - 1].1.is_ascii_digit()
            && chars.get(index + 1).is_some_and(|(_, next)| next.is_ascii_digit());
        if c == ';' || (c == ',' && !in_number) {
            return &text[..at];
        }
    }
    text
}

/// A page session's name from what the page was resolved to: a pull request's number and title,
/// an issue's or a ticket's title as the app wrote it. None for a session from a typed prompt.
pub(crate) fn page_name(kind: &str, url: &str, title: &str) -> Option<String> {
    let title = title.trim();
    match kind {
        "github" => {
            let number = pull_request_number(url)?;
            Some(if title.is_empty() { format!("#{number}") } else { format!("#{number} {title}") })
        }
        "issue" | "jira" => (!title.is_empty()).then(|| title.to_owned()),
        _ => None,
    }
}

/// `482` in `https://github.com/owner/repo/pull/482` (and `/pull/482/files`).
fn pull_request_number(url: &str) -> Option<u64> {
    let mut segments = url.split(['/', '?', '#']);
    segments.by_ref().find(|segment| *segment == "pull")?;
    segments.next()?.parse().ok()
}

/// Names the session from its typed prompt in the background, and tells the app when it did.
/// A test's scripted runner goes with the task.
pub(crate) fn name_in_background(app: AppState, id: String, prompt: String, agent: String) {
    let runner = cli::inherited();
    tokio::spawn(async move {
        let work = name_from_prompt(app, id, prompt, agent);
        match runner {
            Some(runner) => cli::scoped(runner, work).await,
            None => work.await,
        }
    });
}

async fn name_from_prompt(app: AppState, id: String, prompt: String, agent: String) {
    let raw = match titles::title_by(titles::TitleCli::of_session(&agent), &session_name_prompt(&prompt)).await {
        Ok(raw) => raw,
        Err(error) => {
            tracing::info!(session = %id, "session left on its branch name: {error}");
            return;
        }
    };
    let Some(name) = tidy_session_name(&raw) else {
        tracing::info!(session = %id, "session left on its branch name: no usable title in {raw:?}");
        return;
    };
    match app.db.name_task_if_unnamed(&id, &name).await {
        Ok(true) => app.publish(Event::Tasks),
        Ok(false) => {}
        Err(error) => tracing::warn!(session = %id, "could not save the session's name: {error}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_name_is_one_title_not_a_list() {
        assert_eq!(tidy_session_name("Redesign cancel button, move recording time").as_deref(), Some("Redesign cancel button"));
        assert_eq!(tidy_session_name("Fix login; add tests").as_deref(), Some("Fix login"));
        assert_eq!(tidy_session_name("Pull main & Synara release").as_deref(), Some("Pull main Synara release"));
        assert_eq!(tidy_session_name("Audit features - find flaws").as_deref(), Some("Audit features find flaws"));
        assert_eq!(tidy_session_name("\"Protect app from decoding.\"").as_deref(), Some("Protect app from decoding"));
        // A number keeps its thousands separator.
        assert_eq!(tidy_session_name("Raise 10,000 row export limit").as_deref(), Some("Raise 10,000 row export limit"));
        // Cut at sixty characters: the word the cut went through goes, with no stray "...".
        assert_eq!(
            tidy_session_name("Internationalization infrastructure reorganization documentation implementation verification").as_deref(),
            Some("Internationalization infrastructure reorganization")
        );
        // Seven words are cut to six, and the joint the cut leaves goes too.
        assert_eq!(tidy_session_name("Review features for incomplete work and flaws").as_deref(), Some("Review features for incomplete work"));
    }

    #[test]
    fn nothing_usable_is_no_name() {
        for raw in ["", "   ", "Session", "new thread", "Task", ", leading comma"] {
            assert_eq!(tidy_session_name(raw), None, "{raw:?}");
        }
    }

    #[test]
    fn a_page_names_its_session() {
        assert_eq!(page_name("github", "https://github.com/o/r/pull/482", "Fix login crash").as_deref(), Some("#482 Fix login crash"));
        assert_eq!(page_name("github", "https://github.com/o/r/pull/7/files", "").as_deref(), Some("#7"));
        assert_eq!(page_name("github", "https://github.com/o/r/issues/7", "Odd"), None);
        assert_eq!(page_name("issue", "https://github.com/o/r/issues/12", "#12 Sidebar scroll").as_deref(), Some("#12 Sidebar scroll"));
        assert_eq!(page_name("jira", "https://x.atlassian.net/browse/P-1", "P-1 Export CSV").as_deref(), Some("P-1 Export CSV"));
        assert_eq!(page_name("session", "session:abc", "fix the thing"), None);
    }

    #[test]
    fn the_prompt_asks_for_one_title_and_carries_the_message() {
        let prompt = session_name_prompt("  pull latest mian  ");
        assert!(prompt.starts_with("You name coding sessions."));
        assert!(prompt.contains("Never list several steps"));
        assert!(prompt.ends_with("User message:\npull latest mian"));
    }
}
