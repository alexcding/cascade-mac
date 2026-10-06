//! A chat's generated title: ported from Synara `apps/server/src/git/Services/TextGeneration.ts`
//! (`generateThreadTitle` and its input), `apps/server/src/git/textGenerationShared.ts`
//! (`buildThreadTitlePrompt`, `limitSection`, `attachmentMetadataLines`) and
//! `packages/shared/src/chatThreads.ts` (`sanitizeGeneratedThreadTitle`,
//! `isUsableGeneratedThreadTitle`).
//!
//! The engine decides when a title is generated and applies it (`reactor.rs`,
//! `maybeGenerateAndRenameThreadTitleForFirstTurn`); running a CLI for it is the host's, which
//! hands the engine a [`TextGeneration`] (Synara's `ClaudeTextGeneration` / `CodexTextGeneration`
//! layers). With none, a chat keeps its first-message fallback title.

use std::{future::Future, path::PathBuf, pin::Pin};

use crate::contracts::orchestration::{ChatAttachment, ModelSelection};

/// Synara `MAX_CHAT_THREAD_TITLE_WORDS` (chatThreads.ts:25)
pub const MAX_CHAT_THREAD_TITLE_WORDS: usize = 6;
/// Synara `MAX_CHAT_THREAD_TITLE_LENGTH` (chatThreads.ts:7)
pub const MAX_CHAT_THREAD_TITLE_LENGTH: usize = 60;
/// Synara `GENERIC_CHAT_THREAD_TITLE` (chatThreads.ts:6)
pub const GENERIC_CHAT_THREAD_TITLE: &str = "New thread";

/// Synara `GENERIC_GENERATED_THREAD_TITLES` (chatThreads.ts:11)
const GENERIC_GENERATED_THREAD_TITLES: [&str; 9] =
    ["chat", "conversation", "new chat", "new conversation", "new session", "new thread", "session", "thread", "untitled"];

/// Synara `ThreadTitleGenerationInput` (TextGeneration.ts:110), for the first-turn title alone
/// (no `context: "conversation"` regeneration).
#[derive(Clone, Debug, PartialEq)]
pub struct ThreadTitleGenerationInput {
    /// The chat's folder; a generator runs its CLI elsewhere (Synara uses an isolated temp dir).
    pub cwd: Option<PathBuf>,
    pub message: String,
    pub attachments: Vec<ChatAttachment>,
    /// The chat's own model selection: whose CLI the host asks.
    pub model_selection: ModelSelection,
}

pub type TextGenerationFuture = Pin<Box<dyn Future<Output = Result<String, String>> + Send>>;

/// Synara `TextGenerationShape.generateThreadTitle`: a title for the first message as the model
/// gave it (the engine sanitizes it, `sanitize_generated_thread_title`), or why there is none.
pub trait TextGeneration: Send + Sync {
    fn generate_thread_title(&self, input: ThreadTitleGenerationInput) -> TextGenerationFuture;
}

/// Synara `limitSection` (textGenerationShared.ts:24)
pub fn limit_section(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        return value.to_owned();
    }
    format!("{}\n\n[truncated]", value.chars().take(max_chars).collect::<String>())
}

/// Synara `attachmentMetadataLines` (textGenerationShared.ts:224)
fn attachment_metadata_lines(attachments: &[ChatAttachment]) -> Vec<String> {
    attachments
        .iter()
        .filter_map(|attachment| match attachment {
            ChatAttachment::Image(image) => Some(format!("- {} ({}, {} bytes)", image.name, image.mime_type, image.size_bytes)),
            _ => None,
        })
        .collect()
}

/// Synara `buildThreadTitlePrompt` (textGenerationShared.ts:656), first-message form. The JSON
/// schema the CLI is held to is [`THREAD_TITLE_OUTPUT_SCHEMA`].
pub fn build_thread_title_prompt(message: &str, attachments: &[ChatAttachment]) -> String {
    let attachment_lines = attachment_metadata_lines(attachments);
    let mut sections = vec![
        "You generate concise chat thread titles.".to_owned(),
        "Return a JSON object with key: title.".to_owned(),
        "Respond with only the JSON object, no prose and no code fences.".to_owned(),
        "Rules:".to_owned(),
        format!("- Summarize the user's request in 3-{MAX_CHAT_THREAD_TITLE_WORDS} words."),
        format!("- Never exceed {MAX_CHAT_THREAD_TITLE_WORDS} words."),
        "- Be specific: include distinguishing identifiers from the message when present (PR/issue numbers, branch names, file or feature names, error codes).".to_owned(),
        "- Two different requests should never produce the same title if the message contains anything that tells them apart.".to_owned(),
        "- Use a short noun or verb phrase, not a full sentence.".to_owned(),
        "- Avoid quotes, markdown, emoji, and trailing punctuation.".to_owned(),
        "- If images are attached, use them as primary context for the title.".to_owned(),
        String::new(),
        "User message:".to_owned(),
        limit_section(message, 8_000),
    ];
    if !attachment_lines.is_empty() {
        sections.push(String::new());
        sections.push("Attachment metadata:".to_owned());
        sections.push(limit_section(&attachment_lines.join("\n"), 4_000));
    }
    sections.join("\n")
}

/// The `{title: string}` schema of `buildThreadTitlePrompt`'s `outputSchemaJson`, as JSON Schema.
pub const THREAD_TITLE_OUTPUT_SCHEMA: &str =
    r#"{"type":"object","properties":{"title":{"type":"string"}},"required":["title"],"additionalProperties":false}"#;

/// Synara `normalizeTitleWhitespace` (chatThreads.ts:27)
pub(crate) fn normalize_title_whitespace(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Synara `titleWords` (chatThreads.ts:35)
pub(crate) fn title_words(value: &str) -> Vec<String> {
    normalize_title_whitespace(value)
        .split(' ')
        .map(|token| {
            token
                .trim_start_matches(|c: char| c.is_whitespace() || "\"'`([{".contains(c))
                .trim_end_matches(|c: char| c.is_whitespace() || "\"'`)]}:;,.!?".contains(c))
                .to_owned()
        })
        .filter(|token| !token.is_empty())
        .collect()
}

/// Synara `truncateChatThreadTitle` (chatThreads.ts:141)
pub(crate) fn truncate_chat_thread_title(text: &str) -> String {
    let trimmed = normalize_title_whitespace(text);
    if trimmed.chars().count() <= MAX_CHAT_THREAD_TITLE_LENGTH {
        return trimmed;
    }
    format!("{}...", trimmed.chars().take(MAX_CHAT_THREAD_TITLE_LENGTH).collect::<String>())
}

/// Synara `removeReasoningWrappers` (chatThreads.ts:42): drops `<analysis|reasoning|think>`
/// blocks, and an unclosed one to the end.
fn remove_reasoning_wrappers(value: &str) -> String {
    let mut out = String::new();
    let mut rest = value;
    loop {
        let lower = rest.to_ascii_lowercase();
        let open = ["<analysis>", "<reasoning>", "<think>"].iter().filter_map(|tag| lower.find(tag).map(|at| (at, *tag))).min();
        let Some((at, tag)) = open else {
            out.push_str(rest);
            return out;
        };
        out.push_str(&rest[..at]);
        let close = format!("</{}", &tag[1..]);
        match lower[at..].find(&close) {
            Some(end) => rest = &rest[at + end + close.len()..],
            None => return out,
        }
    }
}

/// Synara `firstGeneratedTitleLine` (chatThreads.ts:50)
fn first_generated_title_line(value: &str) -> String {
    remove_reasoning_wrappers(value)
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty() && !line.starts_with("```"))
        .unwrap_or_default()
        .to_owned()
}

/// Synara `sanitizeGeneratedThreadTitle` (chatThreads.ts:162)
pub fn sanitize_generated_thread_title(raw: &str) -> String {
    let line = first_generated_title_line(raw);
    let unquoted = line.trim_matches(|c| c == '\'' || c == '"' || c == '`');
    let words: Vec<String> = title_words(unquoted).into_iter().take(MAX_CHAT_THREAD_TITLE_WORDS).collect();
    if words.is_empty() {
        return GENERIC_CHAT_THREAD_TITLE.to_owned();
    }
    truncate_chat_thread_title(&words.join(" "))
}

/// Synara `isUsableGeneratedThreadTitle` (chatThreads.ts:171)
pub fn is_usable_generated_thread_title(title: &str) -> bool {
    let normalized = normalize_title_whitespace(title).to_lowercase();
    !normalized.is_empty() && !GENERIC_GENERATED_THREAD_TITLES.contains(&normalized.as_str())
}

/// Synara `isGenericChatThreadTitle` (chatThreads.ts:176)
pub fn is_generic_chat_thread_title(title: &str) -> bool {
    normalize_title_whitespace(title) == GENERIC_CHAT_THREAD_TITLE
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_generated_title_is_cut_to_its_first_line_and_six_words() {
        assert_eq!(sanitize_generated_thread_title("\"Fix the flaky login test on CI today please\""), "Fix the flaky login test on");
        assert_eq!(sanitize_generated_thread_title("<think>hmm\nlong</think>\n```\nBasic arithmetic question.\n"), "Basic arithmetic question");
        assert_eq!(sanitize_generated_thread_title("<reasoning>never closed"), GENERIC_CHAT_THREAD_TITLE);
        assert_eq!(sanitize_generated_thread_title("   "), GENERIC_CHAT_THREAD_TITLE);
    }

    #[test]
    fn generic_titles_are_not_usable() {
        assert!(!is_usable_generated_thread_title("New  Chat"));
        assert!(!is_usable_generated_thread_title("Untitled"));
        assert!(!is_usable_generated_thread_title(""));
        assert!(is_usable_generated_thread_title("Basic arithmetic question"));
        assert!(is_generic_chat_thread_title(" New   thread "));
    }

    #[test]
    fn the_prompt_carries_the_rules_and_the_message() {
        let prompt = build_thread_title_prompt("hi, what's 2+2", &[]);
        assert!(prompt.starts_with("You generate concise chat thread titles.\nReturn a JSON object with key: title."));
        assert!(prompt.contains("- Summarize the user's request in 3-6 words.\n- Never exceed 6 words."));
        assert!(prompt.ends_with("User message:\nhi, what's 2+2"));
        assert!(!prompt.contains("Attachment metadata"));
        assert_eq!(limit_section("abcdef", 3), "abc\n\n[truncated]");
    }
}
