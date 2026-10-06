//! A chat that starts with what a terminal session's agent knows (Cascade, not Synara): the
//! `knowledgeSource` a `thread.create` may carry, which names the session's agent (`provider`) and
//! its conversation. Here it is made whole before the engine takes it: the conversation must be
//! the one named, held for the session's worktree exactly (`agents::conversation_in`: Claude's in
//! the worktree's own project folder, Codex's a session file whose `session_meta` names that id
//! and that worktree), and not a conversation a chat holds (`ChatEngine::chat_conversations`), so
//! a pane chat is never taken for the terminal's agent. No other conversation stands in for it.
//! Its transcript is read for the model it last ran and for the recap a chat on another provider
//! is sent (`cascade_chat::orchestration::handoff`). The engine forks the conversation itself when
//! the chat runs the same provider. Nothing of the session is changed.

use std::{collections::HashSet, path::Path};

use cascade_chat::{
    contracts::orchestration::ThreadKnowledgeSource,
    orchestration::handoff::{build_imported_messages_bootstrap_text, RecapMessage, RecapRole, RecapThread, BOOTSTRAP_TRANSCRIPT_CHAR_BUDGET},
};
use serde_json::{json, Value};

use crate::agents::{self, transcript, Agent};

/// What a session's agent holds that a chat can start from: its conversation's id, the model it
/// last ran, and its transcript as a recap. None when it has no conversation on disk yet.
pub(crate) struct Found {
    pub conversation_id: String,
    pub model: Option<String>,
    pub recap: Option<String>,
}

/// `provider`'s conversation `conversation`, held for `worktree` and by no chat (`held_by_chats`),
/// read. The error says why a chat cannot start with it.
pub(crate) fn find(
    home: &Path,
    provider: &str,
    worktree: &str,
    conversation: &str,
    held_by_chats: &HashSet<String>,
) -> Result<Found, String> {
    let agent = Agent::of_chat_provider(provider).ok_or_else(|| format!("'{provider}' is not a session's agent."))?;
    if conversation.trim().is_empty() {
        return Err("The session's agent has no conversation to start from yet.".to_owned());
    }
    if held_by_chats.contains(conversation) {
        return Err("That conversation is a chat's, not the session's agent's.".to_owned());
    }
    let path = agents::conversation_in(home, agent, worktree, conversation)
        .ok_or_else(|| "The session's agent's conversation is not on disk in this worktree.".to_owned())?;
    let read = transcript::read_file(&path, agent, worktree, None, false);
    let turns = read["turns"].as_array().map(Vec::as_slice).unwrap_or_default();
    let model = turns
        .iter()
        .rev()
        .filter(|turn| turn["role"] == "assistant")
        .find_map(|turn| turn["model"].as_str().filter(|m| !m.trim().is_empty()))
        .map(str::to_owned);
    Ok(Found { conversation_id: conversation.to_owned(), model, recap: recap(agent, worktree, turns) })
}

/// Synara's handoff recap of a transcript's turns: what the person wrote and what the agent
/// answered, its thinking and tool calls left out; bounded by Synara's bootstrap budget.
pub(crate) fn recap(agent: Agent, worktree: &str, turns: &[Value]) -> Option<String> {
    let messages: Vec<RecapMessage> = turns
        .iter()
        .filter_map(|turn| {
            let role = match turn["role"].as_str()? {
                "user" => RecapRole::User,
                "assistant" => RecapRole::Assistant,
                _ => return None,
            };
            let text = turn["blocks"]
                .as_array()?
                .iter()
                .filter(|block| block["type"] == "text")
                .filter_map(|block| block["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n\n");
            (!text.trim().is_empty()).then_some(RecapMessage { role, text })
        })
        .collect();
    let thread = RecapThread {
        title: "Terminal session".to_owned(),
        branch: None,
        worktree_path: Some(worktree.to_owned()),
    };
    let intro = format!(
        "This chat starts with what the {} agent of a terminal session in the same worktree knew. \
         That session goes on by itself; this is its conversation so far.",
        agent.profile().display_name
    );
    build_imported_messages_bootstrap_text(&thread, &messages, &intro, BOOTSTRAP_TRANSCRIPT_CHAR_BUDGET)
}

/// The `knowledgeSource` of a `thread.create`, made whole for the engine: the conversation it
/// names, found in the chat's worktree ([`find`]), the model it ran and the recap. An error when
/// there is none to start from.
pub(crate) fn resolve(
    home: &Path,
    source: ThreadKnowledgeSource,
    worktree: &str,
    held_by_chats: &HashSet<String>,
) -> Result<ThreadKnowledgeSource, String> {
    let found = find(home, source.provider.as_str(), worktree, &source.conversation_id, held_by_chats)?;
    Ok(ThreadKnowledgeSource {
        provider: source.provider,
        conversation_id: found.conversation_id,
        model: found.model,
        recap: found.recap,
    })
}

/// `chat.sessionKnowledge {provider, worktree, conversationId}`: whether a chat can start with
/// what that session's agent knows, by the same rule as [`resolve`], as `{conversationId}`, or
/// null when it cannot.
pub(crate) fn describe(home: &Path, provider: &str, worktree: &str, conversation: Option<&str>, held_by_chats: &HashSet<String>) -> Value {
    let Some(conversation) = conversation.filter(|id| !id.trim().is_empty()) else { return Value::Null };
    let usable = Agent::of_chat_provider(provider)
        .filter(|_| !held_by_chats.contains(conversation))
        .and_then(|agent| agents::conversation_in(home, agent, worktree, conversation))
        .is_some();
    match usable {
        true => json!({ "conversationId": conversation }),
        false => Value::Null,
    }
}
