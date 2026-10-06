//! Ported from Synara `packages/shared/src/subagents.ts`: the parsing of subagent runtime
//! payloads that ingestion uses to find a collab tool call's child threads and name them.
//! The payloads are untyped JSON (each provider says it its own way), read as Synara reads them.

use std::collections::{HashMap, HashSet};

use serde_json::{Map, Value};

/// Synara `ParsedSubagentReceiverAgent`
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ParsedSubagentReceiverAgent {
    pub provider_thread_id: String,
    pub agent_id: Option<String>,
    pub nickname: Option<String>,
    pub role: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub background: Option<bool>,
    pub prompt: Option<String>,
    pub model_is_requested_hint: Option<bool>,
}

/// Synara `ParsedSubagentAgentState`
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ParsedSubagentAgentState {
    pub thread_id: String,
    pub agent_id: Option<String>,
    pub nickname: Option<String>,
    pub role: Option<String>,
    pub model: Option<String>,
    pub prompt: Option<String>,
    pub status: Option<String>,
    pub message: Option<String>,
}

/// Synara `ParsedSubagentIdentityHint`
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ParsedSubagentIdentityHint {
    pub provider_thread_id: Option<String>,
    pub agent_id: Option<String>,
    pub nickname: Option<String>,
    pub role: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub background: Option<bool>,
    pub prompt: Option<String>,
    pub status: Option<String>,
    pub message: Option<String>,
    pub model_is_requested_hint: Option<bool>,
}

/// Synara `ParsedSubagentIdentityDirectory`
#[derive(Clone, Debug, Default)]
pub struct ParsedSubagentIdentityDirectory {
    pub by_provider_thread_id: HashMap<String, ParsedSubagentIdentityHint>,
    pub by_agent_id: HashMap<String, ParsedSubagentIdentityHint>,
}

/// Synara `isWorkerTierSubagentRole`: Synara's own effort-carrying agent definitions, never shown
/// as a role.
pub fn is_worker_tier_subagent_role(role: Option<&str>) -> bool {
    role.map(|r| r.trim().to_ascii_lowercase())
        .is_some_and(|r| matches!(r.as_str(), "worker-low" | "worker-medium" | "worker-high" | "worker-xhigh"))
}

fn sanitize_subagent_role(role: Option<String>) -> Option<String> {
    role.filter(|r| !is_worker_tier_subagent_role(Some(r)))
}

fn as_record(value: Option<&Value>) -> Option<&Map<String, Value>> {
    value.and_then(Value::as_object)
}

fn as_trimmed_string(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).map(str::trim).filter(|v| !v.is_empty()).map(str::to_owned)
}

fn first_string_value(object: Option<&Map<String, Value>>, keys: &[&str]) -> Option<String> {
    let object = object?;
    keys.iter().find_map(|key| as_trimmed_string(object.get(*key)))
}

/// `a ?? b ?? …` over raw values, then trimmed (Synara's `asTrimmedString(item.a ?? item.b …)`).
fn first_present_trimmed(object: &Map<String, Value>, keys: &[&str]) -> Option<String> {
    let value = keys.iter().find_map(|key| object.get(*key).filter(|v| !v.is_null()));
    as_trimmed_string(value)
}

fn extract_subagent_identity_from_source(item: &Map<String, Value>) -> Option<ParsedSubagentIdentityHint> {
    let source = as_record(item.get("source"));
    let subagent = source
        .and_then(|s| as_record(s.get("subAgent")).or_else(|| as_record(s.get("sub_agent"))))
        .or_else(|| as_record(item.get("subAgent")));
    let thread_spawn = subagent.and_then(|s| as_record(s.get("thread_spawn")).or_else(|| as_record(s.get("threadSpawn"))));
    let provider_thread_id = first_present_trimmed(
        item,
        &["threadId", "thread_id", "conversationId", "conversation_id", "receiverThreadId", "receiver_thread_id"],
    )
    .or_else(|| first_string_value(thread_spawn, &["threadId", "thread_id"]));
    let agent_id = first_present_trimmed(item, &["agentId", "agent_id", "id"])
        .or_else(|| first_string_value(thread_spawn, &["agentId", "agent_id", "id"]))
        .or_else(|| first_string_value(subagent, &["agentId", "agent_id", "id"]));
    let nickname = first_string_value(Some(item), &["agentNickname", "agent_nickname", "nickname"])
        .or_else(|| first_string_value(thread_spawn, &["agentNickname", "agent_nickname", "nickname", "name"]))
        .or_else(|| first_string_value(subagent, &["agentNickname", "agent_nickname", "nickname", "name"]));
    let role_keys = ["agentRole", "agent_role", "agentType", "agent_type"];
    let role = sanitize_subagent_role(
        first_string_value(Some(item), &role_keys)
            .or_else(|| first_string_value(thread_spawn, &role_keys))
            .or_else(|| first_string_value(subagent, &role_keys)),
    );
    if provider_thread_id.is_none() && agent_id.is_none() && nickname.is_none() && role.is_none() {
        return None;
    }
    Some(ParsedSubagentIdentityHint { provider_thread_id, agent_id, nickname, role, ..Default::default() })
}

fn push_unique_thread_id(target: &mut Vec<String>, seen: &mut HashSet<String>, thread_id: Option<String>) {
    if let Some(thread_id) = thread_id {
        if seen.insert(thread_id.clone()) {
            target.push(thread_id);
        }
    }
}

/// Synara `decodeSubagentReceiverThreadIds`
pub fn decode_subagent_receiver_thread_ids(item: &Map<String, Value>) -> Vec<String> {
    for key in ["receiverThreadIds", "receiver_thread_ids", "threadIds", "thread_ids"] {
        let Some(values) = item.get(key).and_then(Value::as_array) else { continue };
        let ids: Vec<String> = values.iter().filter_map(|v| as_trimmed_string(Some(v))).collect();
        if !ids.is_empty() {
            return ids;
        }
    }
    first_string_value(
        Some(item),
        &["receiverThreadId", "receiver_thread_id", "threadId", "thread_id", "newThreadId", "new_thread_id"],
    )
    .into_iter()
    .collect()
}

/// Synara `decodeSubagentReceiverAgents`
pub fn decode_subagent_receiver_agents(item: &Map<String, Value>, fallback_thread_ids: &[String]) -> Vec<ParsedSubagentReceiverAgent> {
    let top_level_model = first_string_value(Some(item), &["model", "modelName", "model_name", "requestedModel", "requested_model"]);
    let top_level_effort = first_string_value(Some(item), &["effort", "reasoningEffort", "reasoning_effort"]);
    let top_level_prompt = first_string_value(Some(item), &["prompt", "task", "message"]);
    let item_background = item.get("background").and_then(Value::as_bool) == Some(true);
    let agents_value = ["receiverAgents", "receiver_agents", "agents"].iter().find_map(|key| item.get(*key).and_then(Value::as_array));
    let decoded: Vec<ParsedSubagentReceiverAgent> = agents_value
        .into_iter()
        .flatten()
        .enumerate()
        .filter_map(|(index, entry)| {
            let object = entry.as_object()?;
            let provider_thread_id = first_string_value(
                Some(object),
                &["threadId", "thread_id", "receiverThreadId", "receiver_thread_id", "newThreadId", "new_thread_id"],
            )
            .or_else(|| fallback_thread_ids.get(index).cloned())?;
            let agent_id = first_string_value(
                Some(object),
                &["agentId", "agent_id", "receiverAgentId", "receiver_agent_id", "newAgentId", "new_agent_id", "id"],
            );
            let nickname = first_string_value(
                Some(object),
                &[
                    "agentNickname",
                    "agent_nickname",
                    "receiverAgentNickname",
                    "receiver_agent_nickname",
                    "newAgentNickname",
                    "new_agent_nickname",
                    "nickname",
                    "name",
                ],
            );
            let role = sanitize_subagent_role(first_string_value(
                Some(object),
                &[
                    "agentRole",
                    "agent_role",
                    "receiverAgentRole",
                    "receiver_agent_role",
                    "newAgentRole",
                    "new_agent_role",
                    "agentType",
                    "agent_type",
                ],
            ));
            let direct_model = first_string_value(Some(object), &["model", "modelName", "model_name"]);
            let requested_model = first_string_value(Some(object), &["requestedModel", "requested_model"]);
            let model = direct_model.clone().or(requested_model).or_else(|| top_level_model.clone());
            let effort =
                first_string_value(Some(object), &["effort", "reasoningEffort", "reasoning_effort"]).or_else(|| top_level_effort.clone());
            let background = object.get("background").and_then(Value::as_bool) == Some(true) || item_background;
            let prompt = first_string_value(Some(object), &["prompt", "task", "message"]).or_else(|| top_level_prompt.clone());
            Some(ParsedSubagentReceiverAgent {
                provider_thread_id,
                agent_id,
                nickname,
                role,
                model_is_requested_hint: (model.is_some() && direct_model.is_none()).then_some(true),
                model,
                effort,
                background: background.then_some(true),
                prompt,
            })
        })
        .collect();
    if !decoded.is_empty() {
        return decoded;
    }
    let Some(provider_thread_id) = fallback_thread_ids.first().cloned() else {
        return Vec::new();
    };
    let agent_id = first_string_value(Some(item), &["newAgentId", "new_agent_id", "agentId", "agent_id"]);
    let nickname = first_string_value(
        Some(item),
        &[
            "newAgentNickname",
            "new_agent_nickname",
            "agentNickname",
            "agent_nickname",
            "receiverAgentNickname",
            "receiver_agent_nickname",
        ],
    );
    let role = sanitize_subagent_role(first_string_value(
        Some(item),
        &[
            "receiverAgentRole",
            "receiver_agent_role",
            "newAgentRole",
            "new_agent_role",
            "agentRole",
            "agent_role",
            "agentType",
            "agent_type",
        ],
    ));
    vec![ParsedSubagentReceiverAgent {
        provider_thread_id,
        agent_id,
        nickname,
        role,
        model_is_requested_hint: top_level_model.is_some().then_some(true),
        model: top_level_model,
        effort: top_level_effort,
        background: item_background.then_some(true),
        prompt: top_level_prompt,
    }]
}

fn build_subagent_agent_state(thread_id: String, object: Option<&Map<String, Value>>) -> ParsedSubagentAgentState {
    ParsedSubagentAgentState {
        thread_id,
        agent_id: first_string_value(object, &["agentId", "agent_id"]),
        nickname: first_string_value(object, &["agentNickname", "agent_nickname", "receiverAgentNickname", "receiver_agent_nickname"]),
        role: sanitize_subagent_role(first_string_value(
            object,
            &["agentRole", "agent_role", "receiverAgentRole", "receiver_agent_role", "agentType", "agent_type"],
        )),
        model: first_string_value(object, &["model", "modelName", "model_name", "requestedModel", "requested_model"]),
        prompt: first_string_value(object, &["prompt", "task", "message"]),
        status: first_string_value(object, &["status", "state"]),
        message: first_string_value(object, &["summary", "message", "latestUpdate", "latest_update"]),
    }
}

/// Synara `decodeSubagentAgentStates`, in the payload's order.
pub fn decode_subagent_agent_states(item: &Map<String, Value>) -> Vec<ParsedSubagentAgentState> {
    let candidate = ["statuses", "agentsStates", "agents_states", "agentStates", "agent_states"]
        .iter()
        .find_map(|key| item.get(*key).and_then(Value::as_object));
    if let Some(candidate) = candidate {
        let mut decoded: Vec<ParsedSubagentAgentState> = Vec::new();
        for (raw_thread_id, raw_value) in candidate {
            let object = raw_value.as_object();
            let thread_id = Some(raw_thread_id.trim().to_owned())
                .filter(|id| !id.is_empty())
                .or_else(|| first_string_value(object, &["threadId", "thread_id"]));
            let Some(thread_id) = thread_id else { continue };
            decoded.retain(|state| state.thread_id != thread_id);
            decoded.push(build_subagent_agent_state(thread_id, object));
        }
        return decoded;
    }
    let values = ["agentStatuses", "agent_statuses", "statuses"].iter().find_map(|key| item.get(*key).and_then(Value::as_array));
    let mut decoded: Vec<ParsedSubagentAgentState> = Vec::new();
    for raw_value in values.into_iter().flatten() {
        let object = raw_value.as_object();
        let Some(thread_id) = first_string_value(object, &["threadId", "thread_id"]) else { continue };
        decoded.retain(|state| state.thread_id != thread_id);
        decoded.push(build_subagent_agent_state(thread_id, object));
    }
    decoded
}

/// Synara `collectSubagentProviderThreadIds`: every child thread a collab tool call names.
pub fn collect_subagent_provider_thread_ids(item: &Map<String, Value>) -> Vec<String> {
    let mut ordered = Vec::new();
    let mut seen = HashSet::new();
    for thread_id in decode_subagent_receiver_thread_ids(item) {
        push_unique_thread_id(&mut ordered, &mut seen, Some(thread_id));
    }
    let fallback = ordered.clone();
    for agent in decode_subagent_receiver_agents(item, &fallback) {
        push_unique_thread_id(&mut ordered, &mut seen, Some(agent.provider_thread_id));
    }
    for state in decode_subagent_agent_states(item) {
        push_unique_thread_id(&mut ordered, &mut seen, Some(state.thread_id));
    }
    push_unique_thread_id(&mut ordered, &mut seen, extract_subagent_identity_from_source(item).and_then(|h| h.provider_thread_id));
    push_unique_thread_id(
        &mut ordered,
        &mut seen,
        first_string_value(Some(item), &["newThreadId", "new_thread_id", "receiverThreadId", "receiver_thread_id"]),
    );
    ordered
}

/// Synara `extractSubagentIdentityHints`
pub fn extract_subagent_identity_hints(item: &Map<String, Value>) -> Vec<ParsedSubagentIdentityHint> {
    let mut hints: Vec<ParsedSubagentIdentityHint> = Vec::new();
    let mut push_hint = |hint: Option<ParsedSubagentIdentityHint>| {
        if let Some(hint) = hint {
            if !hints.contains(&hint) {
                hints.push(hint);
            }
        }
    };
    push_hint(extract_subagent_identity_from_source(item));
    push_hint(Some(ParsedSubagentIdentityHint {
        provider_thread_id: first_string_value(
            Some(item),
            &["newThreadId", "new_thread_id", "receiverThreadId", "receiver_thread_id", "threadId", "thread_id"],
        ),
        agent_id: first_string_value(
            Some(item),
            &["newAgentId", "new_agent_id", "receiverAgentId", "receiver_agent_id", "agentId", "agent_id"],
        ),
        nickname: first_string_value(
            Some(item),
            &[
                "newAgentNickname",
                "new_agent_nickname",
                "receiverAgentNickname",
                "receiver_agent_nickname",
                "agentNickname",
                "agent_nickname",
                "nickname",
            ],
        ),
        role: sanitize_subagent_role(first_string_value(
            Some(item),
            &[
                "newAgentRole",
                "new_agent_role",
                "receiverAgentRole",
                "receiver_agent_role",
                "agentRole",
                "agent_role",
                "agentType",
                "agent_type",
            ],
        )),
        ..Default::default()
    }));
    let receiver_thread_ids = decode_subagent_receiver_thread_ids(item);
    for agent in decode_subagent_receiver_agents(item, &receiver_thread_ids) {
        push_hint(Some(ParsedSubagentIdentityHint {
            provider_thread_id: Some(agent.provider_thread_id),
            agent_id: agent.agent_id,
            nickname: agent.nickname,
            role: agent.role,
            model: agent.model,
            effort: agent.effort,
            background: agent.background,
            prompt: agent.prompt,
            status: None,
            message: None,
            model_is_requested_hint: agent.model_is_requested_hint,
        }));
    }
    for state in decode_subagent_agent_states(item) {
        push_hint(Some(ParsedSubagentIdentityHint {
            provider_thread_id: Some(state.thread_id),
            agent_id: state.agent_id,
            nickname: state.nickname,
            role: state.role,
            model: state.model,
            prompt: state.prompt,
            status: state.status,
            message: state.message,
            ..Default::default()
        }));
    }
    hints.retain(|h| h.provider_thread_id.is_some() || h.agent_id.is_some() || h.nickname.is_some() || h.role.is_some());
    hints
}

fn select_merged_model(
    existing: Option<&ParsedSubagentIdentityHint>,
    incoming: &ParsedSubagentIdentityHint,
) -> (Option<String>, Option<bool>) {
    let existing_model = existing.and_then(|e| e.model.clone());
    let Some(incoming_model) = incoming.model.clone() else {
        return (existing_model, existing.and_then(|e| e.model_is_requested_hint));
    };
    if incoming.model_is_requested_hint == Some(true)
        && existing_model.is_some()
        && existing.and_then(|e| e.model_is_requested_hint) != Some(true)
    {
        return (existing_model, existing.and_then(|e| e.model_is_requested_hint));
    }
    (Some(incoming_model), incoming.model_is_requested_hint)
}

fn merge_subagent_identity_hints(
    existing: Option<&ParsedSubagentIdentityHint>,
    incoming: &ParsedSubagentIdentityHint,
) -> ParsedSubagentIdentityHint {
    let (model, model_is_requested_hint) = select_merged_model(existing, incoming);
    let pick = |a: &Option<String>, b: Option<&Option<String>>| a.clone().or_else(|| b.cloned().flatten());
    ParsedSubagentIdentityHint {
        provider_thread_id: pick(&incoming.provider_thread_id, existing.map(|e| &e.provider_thread_id)),
        agent_id: pick(&incoming.agent_id, existing.map(|e| &e.agent_id)),
        nickname: pick(&incoming.nickname, existing.map(|e| &e.nickname)),
        role: pick(&incoming.role, existing.map(|e| &e.role)),
        model,
        effort: pick(&incoming.effort, existing.map(|e| &e.effort)),
        background: incoming.background.or_else(|| existing.and_then(|e| e.background)),
        prompt: pick(&incoming.prompt, existing.map(|e| &e.prompt)),
        status: pick(&incoming.status, existing.map(|e| &e.status)),
        message: pick(&incoming.message, existing.map(|e| &e.message)),
        model_is_requested_hint,
    }
}

fn trimmed(value: Option<&str>) -> Option<String> {
    value.map(str::trim).filter(|v| !v.is_empty()).map(str::to_owned)
}

/// Synara `buildSubagentIdentityDirectory`
pub fn build_subagent_identity_directory(hints: &[ParsedSubagentIdentityHint]) -> ParsedSubagentIdentityDirectory {
    let mut directory = ParsedSubagentIdentityDirectory::default();
    for hint in hints {
        let provider_thread_id = trimmed(hint.provider_thread_id.as_deref());
        let agent_id = trimmed(hint.agent_id.as_deref());
        if provider_thread_id.is_none() && agent_id.is_none() && hint.nickname.is_none() && hint.role.is_none() {
            continue;
        }
        let existing_by_thread = provider_thread_id.as_ref().and_then(|id| directory.by_provider_thread_id.get(id)).cloned();
        let existing_by_agent = agent_id.as_ref().and_then(|id| directory.by_agent_id.get(id)).cloned();
        let existing = match existing_by_agent {
            Some(by_agent) => Some(merge_subagent_identity_hints(existing_by_thread.as_ref(), &by_agent)),
            None => existing_by_thread,
        };
        let mut incoming = hint.clone();
        if provider_thread_id.is_some() {
            incoming.provider_thread_id = provider_thread_id.clone();
        }
        if agent_id.is_some() {
            incoming.agent_id = agent_id.clone();
        }
        let merged = merge_subagent_identity_hints(existing.as_ref(), &incoming);
        if let Some(id) = &provider_thread_id {
            directory.by_provider_thread_id.insert(id.clone(), merged.clone());
        }
        if let Some(id) = &agent_id {
            directory.by_agent_id.insert(id.clone(), merged.clone());
        }
        if let (Some(thread), Some(agent)) = (&merged.provider_thread_id, &merged.agent_id) {
            directory.by_provider_thread_id.insert(thread.clone(), merged.clone());
            directory.by_agent_id.insert(agent.clone(), merged.clone());
        }
    }
    directory
}

/// Synara `resolveSubagentIdentityFromDirectory`
pub fn resolve_subagent_identity_from_directory(
    directory: &ParsedSubagentIdentityDirectory,
    provider_thread_id: Option<&str>,
    agent_id: Option<&str>,
) -> Option<ParsedSubagentIdentityHint> {
    let provider_thread_id = trimmed(provider_thread_id);
    let agent_id = trimmed(agent_id);
    let thread_entry = provider_thread_id.as_ref().and_then(|id| directory.by_provider_thread_id.get(id));
    let agent_entry = agent_id.as_ref().and_then(|id| directory.by_agent_id.get(id));
    if thread_entry.is_none() && agent_entry.is_none() {
        return None;
    }
    let mut incoming = thread_entry.cloned().unwrap_or_default();
    incoming.provider_thread_id = thread_entry
        .and_then(|t| t.provider_thread_id.clone())
        .or_else(|| agent_entry.and_then(|a| a.provider_thread_id.clone()))
        .or(provider_thread_id);
    incoming.agent_id =
        thread_entry.and_then(|t| t.agent_id.clone()).or_else(|| agent_entry.and_then(|a| a.agent_id.clone())).or(agent_id);
    Some(merge_subagent_identity_hints(agent_entry, &incoming))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn a_claude_task_names_its_child_and_identity() {
        let item = json!({
            "toolCallId": "toolu_1",
            "toolName": "Agent",
            "receiverThreadId": "toolu_1",
            "agentType": "general-purpose",
            "nickname": "List files",
            "prompt": "Run ls",
        });
        let item = item.as_object().unwrap();
        assert_eq!(collect_subagent_provider_thread_ids(item), vec!["toolu_1".to_string()]);
        let directory = build_subagent_identity_directory(&extract_subagent_identity_hints(item));
        let identity = resolve_subagent_identity_from_directory(&directory, Some("toolu_1"), None).unwrap();
        assert_eq!(identity.nickname.as_deref(), Some("List files"));
        assert_eq!(identity.role.as_deref(), Some("general-purpose"));
        assert_eq!(identity.prompt.as_deref(), Some("Run ls"));
    }

    #[test]
    fn codex_receiver_lists_and_states_are_read() {
        let item = json!({
            "type": "collabAgentToolCall",
            "receiverThreadIds": ["t-a", "t-b"],
            "agentsStates": { "t-b": { "status": "running", "agentNickname": "Bee" } },
            "model": "gpt-5",
        });
        let item = item.as_object().unwrap();
        assert_eq!(collect_subagent_provider_thread_ids(item), vec!["t-a".to_string(), "t-b".to_string()]);
        let directory = build_subagent_identity_directory(&extract_subagent_identity_hints(item));
        let b = resolve_subagent_identity_from_directory(&directory, Some("t-b"), None).unwrap();
        assert_eq!(b.nickname.as_deref(), Some("Bee"));
        assert_eq!(b.status.as_deref(), Some("running"));
        // A top-level model is only the first receiver's, and only as the model asked for.
        let a = resolve_subagent_identity_from_directory(&directory, Some("t-a"), None).unwrap();
        assert_eq!(a.model.as_deref(), Some("gpt-5"));
        assert_eq!(a.model_is_requested_hint, Some(true));
        assert_eq!(b.model, None);
    }

    #[test]
    fn worker_tier_roles_are_not_roles() {
        let item = json!({ "receiverThreadId": "x", "agentType": "worker-high" });
        let hints = extract_subagent_identity_hints(item.as_object().unwrap());
        assert!(hints.iter().all(|h| h.role.is_none()));
    }
}
