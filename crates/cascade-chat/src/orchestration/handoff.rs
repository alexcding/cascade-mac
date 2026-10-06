//! Synara `apps/server/src/orchestration/handoff.ts`: the transcript recap a provider handoff
//! sends its new provider ahead of the first message (`buildImportedMessagesBootstrapText`).
//! Ported is the text builder alone, which Cascade uses for a chat that starts with what a
//! terminal session's agent knows on another provider (`ThreadKnowledgeSource`); the message
//! filters that pick a thread's imported messages are not, since here the messages come from a
//! terminal transcript and never sit in the thread. Lengths count characters where Synara counts
//! UTF-16 code units.

const RECENT_MESSAGE_COUNT: usize = 6;
const EARLIER_MESSAGE_CHAR_LIMIT: usize = 320;
const RECENT_MESSAGE_CHAR_LIMIT: usize = 2_400;
/// Hard ceiling for any bootstrap transcript: it replays as one uncached user message, so long
/// threads must drop their oldest summaries rather than grow.
pub const BOOTSTRAP_TRANSCRIPT_CHAR_BUDGET: usize = 32_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecapRole {
    User,
    Assistant,
}

/// One settled message of the conversation recapped.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecapMessage {
    pub role: RecapRole,
    pub text: String,
}

/// What the recap says about where the conversation took place.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RecapThread {
    pub title: String,
    pub branch: Option<String>,
    pub worktree_path: Option<String>,
}

/// Synara `normalizeMessageText`: `/\s+\n/g` → "\n" (a whitespace run up to its last line break
/// becomes that one break), `/\n{3,}/g` → "\n\n", trimmed.
fn normalize_message_text(value: &str) -> String {
    let chars: Vec<char> = value.chars().collect();
    let mut out = String::with_capacity(value.len());
    let mut i = 0;
    while i < chars.len() {
        if !chars[i].is_whitespace() {
            out.push(chars[i]);
            i += 1;
            continue;
        }
        let start = i;
        while i < chars.len() && chars[i].is_whitespace() {
            i += 1;
        }
        let run = &chars[start..i];
        match run.iter().rposition(|c| *c == '\n') {
            Some(last) => {
                out.push('\n');
                out.extend(&run[last + 1..]);
            }
            None => out.extend(run),
        }
    }
    let mut collapsed = out;
    while collapsed.contains("\n\n\n") {
        collapsed = collapsed.replace("\n\n\n", "\n\n");
    }
    collapsed.trim().to_owned()
}

/// Synara `truncateText`
fn truncate_text(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        return value.to_owned();
    }
    let end = max_chars.saturating_sub(3);
    let head: String = value.chars().take(end).collect();
    format!("{}...", head.trim_end())
}

fn role_label(role: RecapRole) -> &'static str {
    match role {
        RecapRole::Assistant => "Assistant",
        RecapRole::User => "User",
    }
}

fn earlier_summary_header(omitted_count: usize) -> String {
    if omitted_count > 0 {
        format!(
            "Earlier conversation summary ({omitted_count} older {} omitted to fit the context budget):",
            if omitted_count == 1 { "message" } else { "messages" }
        )
    } else {
        "Earlier conversation summary:".to_owned()
    }
}

/// Synara `buildImportedMessagesBootstrapText`: `intro`, where the conversation took place, a
/// summary line for each earlier message the budget keeps (newest first, the oldest dropped),
/// then the last six messages in full up to a limit each. None for no messages.
pub fn build_imported_messages_bootstrap_text(
    thread: &RecapThread,
    imported_messages: &[RecapMessage],
    intro: &str,
    max_chars: usize,
) -> Option<String> {
    if imported_messages.is_empty() {
        return None;
    }
    let max_chars = max_chars.min(BOOTSTRAP_TRANSCRIPT_CHAR_BUDGET);
    let split = imported_messages.len().saturating_sub(RECENT_MESSAGE_COUNT);
    let (earlier_messages, recent_messages) = imported_messages.split_at(split);
    let mut sections: Vec<String> = vec![intro.to_owned(), format!("Original conversation title: {}", thread.title)];
    if let Some(branch) = thread.branch.as_deref().filter(|b| !b.is_empty()) {
        sections.push(format!("Git branch: {branch}"));
    }
    if let Some(path) = thread.worktree_path.as_deref().filter(|p| !p.is_empty()) {
        sections.push(format!("Worktree path: {path}"));
    }
    let recent_section = format!(
        "Most recent imported messages:\n{}",
        recent_messages
            .iter()
            .map(|message| {
                let normalized = truncate_text(&normalize_message_text(&message.text), RECENT_MESSAGE_CHAR_LIMIT);
                format!("{}:\n{normalized}", role_label(message.role))
            })
            .collect::<Vec<_>>()
            .join("\n\n")
    );
    if !earlier_messages.is_empty() {
        let used: usize = sections.iter().map(|s| s.chars().count() + 2).sum::<usize>() + recent_section.chars().count() + 2;
        let mut remaining = max_chars as isize - used as isize;
        remaining -= earlier_summary_header(earlier_messages.len()).chars().count() as isize + 1;
        let mut summary_lines: Vec<String> = Vec::new();
        for message in earlier_messages.iter().rev() {
            let normalized = truncate_text(&normalize_message_text(&message.text), EARLIER_MESSAGE_CHAR_LIMIT);
            let line = format!("- {}: {normalized}", role_label(message.role));
            let cost = line.chars().count() as isize + 1;
            if remaining < cost {
                break;
            }
            remaining -= cost;
            summary_lines.push(line);
        }
        summary_lines.reverse();
        let header = earlier_summary_header(earlier_messages.len() - summary_lines.len());
        sections.push(match summary_lines.is_empty() {
            true => header,
            false => format!("{header}\n{}", summary_lines.join("\n")),
        });
    }
    sections.push(recent_section);
    let joined = sections.join("\n\n");
    Some(truncate_text(joined.trim(), max_chars))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn message(role: RecapRole, text: &str) -> RecapMessage {
        RecapMessage { role, text: text.to_owned() }
    }

    #[test]
    fn a_short_conversation_is_recapped_whole() {
        let thread = RecapThread { title: "Fix login".into(), branch: Some("fix-login".into()), worktree_path: Some("/w".into()) };
        let text = build_imported_messages_bootstrap_text(
            &thread,
            &[message(RecapRole::User, "Remember  \n\n\n\nPELICAN"), message(RecapRole::Assistant, "Noted.")],
            "Intro.",
            BOOTSTRAP_TRANSCRIPT_CHAR_BUDGET,
        )
        .unwrap();
        assert_eq!(
            text,
            "Intro.\n\nOriginal conversation title: Fix login\n\nGit branch: fix-login\n\nWorktree path: /w\n\n\
             Most recent imported messages:\nUser:\nRemember\nPELICAN\n\nAssistant:\nNoted."
        );
        assert_eq!(build_imported_messages_bootstrap_text(&thread, &[], "Intro.", 100), None);
    }

    #[test]
    fn a_long_conversation_keeps_its_newest_summaries_within_the_budget() {
        let thread = RecapThread { title: "Long".into(), ..RecapThread::default() };
        let messages: Vec<RecapMessage> = (0..400)
            .map(|i| message(if i % 2 == 0 { RecapRole::User } else { RecapRole::Assistant }, &format!("message {i} {}", "x".repeat(500))))
            .collect();
        let text = build_imported_messages_bootstrap_text(&thread, &messages, "Intro.", BOOTSTRAP_TRANSCRIPT_CHAR_BUDGET).unwrap();
        assert!(text.chars().count() <= BOOTSTRAP_TRANSCRIPT_CHAR_BUDGET, "{}", text.len());
        assert!(text.contains("older messages omitted to fit the context budget"));
        assert!(text.contains("message 393 "), "the newest earlier message is summarized");
        assert!(!text.contains("message 0 "), "the oldest is dropped");
        assert!(text.contains(&format!("Assistant:\nmessage 399 {}", "x".repeat(500))));
        // A smaller budget is a hard cap.
        let small = build_imported_messages_bootstrap_text(&thread, &messages, "Intro.", 1_000).unwrap();
        assert!(small.chars().count() <= 1_000);
    }
}
