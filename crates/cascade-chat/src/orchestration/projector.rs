//! Ported from Synara `apps/server/src/orchestration/projector.ts` (the thread events), with the
//! helpers it uses from `turnLifecycle.ts`, `turnStartSession.ts`, `@synara/shared/pinnedMessages`
//! and `@synara/shared/asyncUserInput`: folds one event into one thread's read model.
//!
//! Synara's in-memory projector leaves a few thread fields to its SQL projection
//! (`Layers/ProjectionPipeline.ts`); since this crate keeps only this read model, two of them are
//! kept here and marked: `latestUserMessageAt`, and the latest turn's `assistantMessageId`.
//! Pending interactions, the shell's pending counts and the project kind (Studio threads) are not
//! projected.

use crate::contracts::base::{IsoDateTime, MessageId, TurnId};
use crate::contracts::orchestration::*;

use super::decider::{model_selection_instance_id, model_selection_provider, resolve_stable_message_turn_id};

const MAX_THREAD_MESSAGES: usize = 2_000;
const MAX_THREAD_ACTIVITIES: usize = 500;
const MAX_THREAD_CHECKPOINTS: usize = 500;
const MAX_THREAD_PROPOSED_PLANS: usize = 200;

fn checkpoint_status_to_latest_turn_state(status: OrchestrationCheckpointStatus) -> OrchestrationLatestTurnState {
    match status {
        OrchestrationCheckpointStatus::Error => OrchestrationLatestTurnState::Error,
        OrchestrationCheckpointStatus::Missing => OrchestrationLatestTurnState::Interrupted,
        OrchestrationCheckpointStatus::Ready => OrchestrationLatestTurnState::Completed,
    }
}

fn is_terminal_latest_turn(latest_turn: Option<&OrchestrationLatestTurn>) -> bool {
    latest_turn.is_some_and(|turn| {
        turn.completed_at.is_some()
            && matches!(turn.state, OrchestrationLatestTurnState::Completed | OrchestrationLatestTurnState::Error)
    })
}

/// Synara `settleTurnStateFromSession` (turnLifecycle.ts): the terminal turn state a session
/// update implies, or `None` while the provider can still deliver the terminal event.
pub fn settle_turn_state_from_session(
    session: &OrchestrationSession,
    existing_state: OrchestrationLatestTurnState,
) -> Option<OrchestrationLatestTurnState> {
    use OrchestrationLatestTurnState as Turn;
    use OrchestrationSessionStatus as Session;
    if session.active_turn_id.is_some() && session.status != Session::Error {
        return None;
    }
    match session.status {
        Session::Error => Some(Turn::Error),
        Session::Interrupted | Session::Stopped => Some(Turn::Interrupted),
        Session::Ready => Some(match existing_state {
            Turn::Error => Turn::Error,
            Turn::Interrupted => Turn::Interrupted,
            _ => Turn::Completed,
        }),
        Session::Idle | Session::Starting | Session::Running => None,
    }
}

/// Synara `maxIso` (turnLifecycle.ts): thread timestamps only move forward.
pub fn max_iso(left: Option<&IsoDateTime>, right: &IsoDateTime) -> IsoDateTime {
    match left {
        Some(left) if right.as_str() <= left.as_str() => left.clone(),
        _ => right.clone(),
    }
}

/// Turn lifecycle settles with the session: once a session leaves "running", a running latest
/// turn is settled here (Synara `settleLatestTurnForSessionStatus`).
fn settle_latest_turn_for_session_status(
    latest_turn: Option<OrchestrationLatestTurn>,
    session: &OrchestrationSession,
) -> Option<OrchestrationLatestTurn> {
    let turn = latest_turn?;
    if turn.state != OrchestrationLatestTurnState::Running {
        return Some(turn);
    }
    match settle_turn_state_from_session(session, turn.state) {
        None => Some(turn),
        Some(state) => Some(OrchestrationLatestTurn {
            state,
            completed_at: turn.completed_at.clone().or_else(|| Some(session.updated_at.clone())),
            ..turn
        }),
    }
}

/// Synara `canProjectTurnModelSelectionForSession`
pub fn can_project_turn_model_selection_for_session(
    session: Option<&OrchestrationSession>,
    requested_instance_id: &str,
) -> bool {
    let Some(session) = session else { return true };
    if matches!(session.status, OrchestrationSessionStatus::Stopped | OrchestrationSessionStatus::Error) {
        return true;
    }
    let bound = session
        .provider_instance_id
        .as_ref()
        .map(|id| id.as_str().to_string())
        .or_else(|| session.provider_name.clone());
    bound.is_none_or(|bound| bound.is_empty() || bound == requested_instance_id)
}

/// Synara `resolveModelSelectionInstanceId` (providerInstances.ts)
fn resolve_model_selection_instance_id(selection: &ModelSelection) -> String {
    model_selection_instance_id(selection)
        .map(|id| id.as_str().to_string())
        .unwrap_or_else(|| model_selection_provider(selection).as_str().to_string())
}

/// Synara `canAdoptFirstTurnProvider` (turnStartSession.ts): imported history does not freeze the
/// first-turn provider.
fn can_adopt_first_turn_provider(thread: &OrchestrationThread) -> bool {
    let native = thread
        .messages
        .iter()
        .filter(|m| {
            !matches!(m.source, OrchestrationMessageSource::ForkImport | OrchestrationMessageSource::HandoffImport)
        })
        .count();
    thread.latest_turn.is_none() && thread.session.is_none() && native <= 1
}

/// Synara `deriveTurnStartSession` (turnStartSession.ts)
fn derive_turn_start_session(
    thread: &OrchestrationThread,
    provider_name: &str,
    provider_instance_id: Option<crate::contracts::base::ProviderInstanceId>,
    requested_runtime_mode: RuntimeMode,
    requested_at: &IsoDateTime,
) -> Option<OrchestrationSession> {
    let current = thread.session.as_ref();
    if current.is_some_and(|s| {
        matches!(s.status, OrchestrationSessionStatus::Starting | OrchestrationSessionStatus::Running)
    }) {
        return None;
    }
    Some(OrchestrationSession {
        thread_id: thread.id.clone(),
        status: OrchestrationSessionStatus::Starting,
        provider_name: Some(
            current
                .and_then(|s| s.provider_name.clone())
                .unwrap_or_else(|| provider_name.to_string()),
        ),
        provider_instance_id: current.and_then(|s| s.provider_instance_id.clone()).or(provider_instance_id),
        runtime_mode: current.map(|s| s.runtime_mode).unwrap_or(requested_runtime_mode),
        active_turn_id: None,
        last_error: None,
        last_activity_at: None,
        last_progress_at: None,
        updated_at: requested_at.clone(),
    })
}

/// Synara `retainThreadMessagesAfterRevert`
fn retain_thread_messages_after_revert(
    messages: &[OrchestrationMessage],
    retained_turn_ids: &[TurnId],
    turn_count: u64,
) -> Vec<OrchestrationMessage> {
    let in_retained = |turn: &Option<TurnId>| turn.as_ref().is_some_and(|t| retained_turn_ids.contains(t));
    let mut retained: Vec<&MessageId> = messages
        .iter()
        .filter(|m| m.role == OrchestrationMessageRole::System || in_retained(&m.turn_id))
        .map(|m| &m.id)
        .collect();
    for role in [OrchestrationMessageRole::User, OrchestrationMessageRole::Assistant] {
        let retained_count = messages.iter().filter(|m| m.role == role && retained.contains(&&m.id)).count() as u64;
        let missing = turn_count.saturating_sub(retained_count) as usize;
        if missing > 0 {
            let fallback: Vec<&MessageId> = messages
                .iter()
                .filter(|m| {
                    m.role == role
                        && !retained.contains(&&m.id)
                        && (m.turn_id.is_none() || in_retained(&m.turn_id))
                })
                .take(missing)
                .map(|m| &m.id)
                .collect();
            retained.extend(fallback);
        }
    }
    messages.iter().filter(|m| retained.contains(&&m.id)).cloned().collect()
}

/// Synara `clearRemovedAsyncUserInputResponses` (asyncUserInput.ts)
fn clear_removed_async_user_input_responses(messages: Vec<OrchestrationMessage>, sequence: u64) -> Vec<OrchestrationMessage> {
    let retained: Vec<MessageId> = messages.iter().map(|m| m.id.clone()).collect();
    messages
        .into_iter()
        .map(|mut message| {
            if let Some(input) = &message.async_user_input {
                if let Some(response) = &input.response {
                    if !retained.contains(&response.message_id) {
                        message.async_user_input = Some(AsyncUserInput {
                            questions: input.questions.clone(),
                            response: None,
                            response_sequence: Some(sequence),
                        });
                    }
                }
            }
            message
        })
        .collect()
}

fn compare_thread_activities(
    left: &OrchestrationThreadActivity,
    right: &OrchestrationThreadActivity,
) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    match (left.sequence, right.sequence) {
        (Some(l), Some(r)) if l != r => return l.cmp(&r),
        (Some(_), None) => return Ordering::Greater,
        (None, Some(_)) => return Ordering::Less,
        _ => {}
    }
    left.created_at
        .as_str()
        .cmp(right.created_at.as_str())
        .then_with(|| left.id.as_str().cmp(right.id.as_str()))
}

/// Synara `upsertThreadActivity`: replace in place when the order key is unchanged, else move it
/// to its sorted position.
fn upsert_thread_activity(activities: &mut Vec<OrchestrationThreadActivity>, activity: OrchestrationThreadActivity) {
    use std::cmp::Ordering;
    if let Some(index) = activities.iter().position(|entry| entry.id == activity.id) {
        if compare_thread_activities(&activities[index], &activity) == Ordering::Equal {
            activities[index] = activity;
            cap_front(activities, MAX_THREAD_ACTIVITIES);
            return;
        }
        activities.remove(index);
    }
    let position = activities.partition_point(|entry| compare_thread_activities(entry, &activity) != Ordering::Greater);
    activities.insert(position, activity);
    cap_front(activities, MAX_THREAD_ACTIVITIES);
}

fn cap_front<T>(items: &mut Vec<T>, cap: usize) {
    if items.len() > cap {
        items.drain(..items.len() - cap);
    }
}

/// Synara `deriveNextMessageTextSegments`: streamed deltas accumulate into the current segment,
/// a row-making event between deltas starts a new one, and completion keeps the boundaries when
/// the segments still add up to the final text.
fn derive_next_message_text_segments(
    previous: Option<&Vec<OrchestrationMessageTextSegment>>,
    text: &str,
    streaming: bool,
    segment_started_at: Option<&IsoDateTime>,
    sequence: u64,
    created_at: &IsoDateTime,
    updated_at: &IsoDateTime,
) -> Option<Vec<OrchestrationMessageTextSegment>> {
    if streaming {
        if let Some(started_at) = segment_started_at {
            let mut next = previous.cloned().unwrap_or_default();
            next.push(OrchestrationMessageTextSegment {
                sequence,
                started_at: started_at.clone(),
                ended_at: updated_at.clone(),
                text: text.to_string(),
            });
            return Some(next);
        }
        if let Some(previous) = previous.filter(|p| !p.is_empty()) {
            let mut next = previous.clone();
            let tail = next.last_mut().expect("non-empty");
            tail.text.push_str(text);
            tail.ended_at = updated_at.clone();
            return Some(next);
        }
        return Some(vec![OrchestrationMessageTextSegment {
            sequence,
            started_at: created_at.clone(),
            ended_at: updated_at.clone(),
            text: text.to_string(),
        }]);
    }
    if let Some(previous) = previous.filter(|p| p.len() > 1) {
        let collated: String = previous.iter().map(|s| s.text.as_str()).collect();
        if collated == text || text.is_empty() {
            let mut next = previous.clone();
            next.last_mut().expect("non-empty").ended_at = updated_at.clone();
            return Some(next);
        }
    }
    None
}

/// Synara `normalizePinLabel` (pinnedMessages.ts)
fn normalize_pin_label(label: Option<&str>) -> Option<String> {
    let trimmed = label.unwrap_or("").trim();
    if trimmed.is_empty() {
        return None;
    }
    Some(trimmed.chars().take(PINNED_MESSAGE_LABEL_MAX_CHARS).collect())
}

/// Synara `projectEvent` for one thread: the thread after `event`, or `None` while it does not
/// exist. Events for a thread that is absent leave it absent; `thread.created` replaces it.
pub fn project(thread: Option<OrchestrationThread>, event: &OrchestrationEvent) -> Option<OrchestrationThread> {
    use OrchestrationEventBody as E;
    if let E::ThreadCreated(payload) = &event.body {
        return Some(thread_from_created(payload));
    }
    let mut thread = thread?;
    let occurred_at = &event.occurred_at;
    match &event.body {
        E::ThreadCreated(_) => unreachable!(),

        E::ThreadDeleted(payload) => {
            thread.deleted_at = Some(payload.deleted_at.clone());
            thread.snoozed_until = None;
            thread.snooze_reminder_at = None;
            thread.updated_at = payload.deleted_at.clone();
        }

        E::ThreadArchived(payload) => {
            let archived_at = payload
                .archived_at
                .clone()
                .or_else(|| payload.updated_at.clone())
                .unwrap_or_else(|| occurred_at.clone());
            thread.updated_at = payload.updated_at.clone().unwrap_or_else(|| archived_at.clone());
            thread.archived_at = Some(archived_at);
            thread.snoozed_until = None;
            thread.snooze_reminder_at = None;
        }

        E::ThreadUnarchived(payload) => {
            thread.archived_at = None;
            thread.updated_at = payload
                .updated_at
                .clone()
                .or_else(|| payload.unarchived_at.clone())
                .unwrap_or_else(|| occurred_at.clone());
        }

        E::ThreadMetaUpdated(payload) => {
            let next_create_branch_flow_completed = payload.create_branch_flow_completed.or_else(|| {
                payload
                    .branch
                    .as_ref()
                    .filter(|branch| **branch != thread.branch)
                    .map(|_| false)
            });
            if let Some(title) = &payload.title {
                thread.title = title.clone();
            }
            if let Some(selection) = &payload.model_selection {
                thread.model_selection = selection.clone();
            }
            if let Some(env_mode) = payload.env_mode {
                thread.env_mode = env_mode;
            }
            if let Some(branch) = &payload.branch {
                thread.branch = branch.clone();
            }
            if let Some(path) = &payload.worktree_path {
                thread.worktree_path = path.clone();
            }
            if let Some(dir) = &payload.working_directory {
                thread.working_directory = dir.clone();
            }
            if let Some(path) = &payload.associated_worktree_path {
                thread.associated_worktree_path = path.clone();
            }
            if let Some(branch) = &payload.associated_worktree_branch {
                thread.associated_worktree_branch = branch.clone();
            }
            if let Some(reference) = &payload.associated_worktree_ref {
                thread.associated_worktree_ref = reference.clone();
            }
            if let Some(completed) = next_create_branch_flow_completed {
                thread.create_branch_flow_completed = completed;
            }
            if let Some(pinned) = payload.is_pinned {
                thread.is_pinned = pinned;
            }
            if let Some(settled_at) = &payload.settled_at {
                thread.settled_at = settled_at.clone();
            }
            if let Some(snoozed_until) = &payload.snoozed_until {
                thread.snoozed_until = snoozed_until.clone();
            }
            if let Some(reminder) = &payload.snooze_reminder_at {
                thread.snooze_reminder_at = reminder.clone();
            }
            if let Some(parent) = &payload.parent_thread_id {
                thread.parent_thread_id = parent.clone();
            }
            if let Some(agent_id) = &payload.subagent_agent_id {
                thread.subagent_agent_id = agent_id.clone();
            }
            if let Some(nickname) = &payload.subagent_nickname {
                thread.subagent_nickname = nickname.clone();
            }
            if let Some(role) = &payload.subagent_role {
                thread.subagent_role = role.clone();
            }
            if let Some(pins) = &payload.pinned_messages {
                thread.pinned_messages = Some(pins.clone());
            }
            if let Some(notes) = &payload.notes {
                thread.notes = Some(notes.clone());
            }
            thread.updated_at = payload.updated_at.clone();
        }

        E::ThreadPinnedMessageAdded(payload) => {
            let mut pins = thread.pinned_messages.take().unwrap_or_default();
            if !pins.iter().any(|pin| pin.message_id == payload.pin.message_id) {
                pins.push(payload.pin.clone());
            }
            thread.pinned_messages = Some(pins);
            thread.updated_at = payload.updated_at.clone();
        }

        E::ThreadPinnedMessageRemoved(payload) => {
            let mut pins = thread.pinned_messages.take().unwrap_or_default();
            pins.retain(|pin| pin.message_id != payload.message_id);
            thread.pinned_messages = Some(pins);
            thread.updated_at = payload.updated_at.clone();
        }

        E::ThreadPinnedMessageDoneSet(payload) => {
            let mut pins = thread.pinned_messages.take().unwrap_or_default();
            for pin in pins.iter_mut().filter(|pin| pin.message_id == payload.message_id) {
                pin.done = payload.done;
            }
            thread.pinned_messages = Some(pins);
            thread.updated_at = payload.updated_at.clone();
        }

        E::ThreadPinnedMessageLabelSet(payload) => {
            let label = normalize_pin_label(payload.label.as_deref());
            let mut pins = thread.pinned_messages.take().unwrap_or_default();
            for pin in pins.iter_mut().filter(|pin| pin.message_id == payload.message_id) {
                pin.label = label.clone();
            }
            thread.pinned_messages = Some(pins);
            thread.updated_at = payload.updated_at.clone();
        }

        E::ThreadRuntimeModeSet(payload) => {
            thread.runtime_mode = payload.runtime_mode;
            thread.updated_at = payload.updated_at.clone();
        }

        E::ThreadInteractionModeSet(payload) => {
            thread.interaction_mode = payload.interaction_mode;
            thread.updated_at = payload.updated_at.clone();
        }

        E::ThreadTurnStartRequested(payload) => {
            let requested = payload.model_selection.as_ref().filter(|selection| {
                can_project_turn_model_selection_for_session(
                    thread.session.as_ref(),
                    &resolve_model_selection_instance_id(selection),
                )
            });
            let can_adopt = can_adopt_first_turn_provider(&thread);
            let projected = match requested {
                Some(requested)
                    if model_selection_provider(requested) == model_selection_provider(&thread.model_selection)
                        || can_adopt =>
                {
                    requested.clone()
                }
                _ => thread.model_selection.clone(),
            };
            let provider = model_selection_provider(&projected).as_str();
            let instance_id = model_selection_instance_id(&projected)
                .cloned()
                .or_else(|| thread.session.as_ref().and_then(|s| s.provider_instance_id.clone()))
                .or_else(|| Some(crate::contracts::base::ProviderInstanceId::new(provider)));
            if let Some(session) =
                derive_turn_start_session(&thread, provider, instance_id, payload.runtime_mode, &payload.created_at)
            {
                thread.session = Some(session);
            }
            thread.model_selection = projected;
            thread.runtime_mode = payload.runtime_mode;
            thread.interaction_mode = payload.interaction_mode;
            thread.updated_at = payload.created_at.clone();
        }

        E::ThreadAsyncUserInputAnswered(payload) => {
            for message in thread.messages.iter_mut().filter(|m| m.id == payload.message_id) {
                if let Some(input) = &mut message.async_user_input {
                    input.response = Some(payload.response.clone());
                    input.response_sequence = Some(event.sequence);
                }
            }
        }

        E::ThreadMessageSent(payload) => project_message_sent(&mut thread, event, payload),

        E::ThreadSessionSet(payload) => {
            let session = payload.session.clone();
            let latest = thread.latest_turn.take();
            thread.latest_turn = match (&session.active_turn_id, session.status) {
                (Some(active), OrchestrationSessionStatus::Running) => {
                    let same = latest.as_ref().filter(|turn| &turn.turn_id == active);
                    if same.is_some() && is_terminal_latest_turn(same) {
                        latest
                    } else {
                        Some(OrchestrationLatestTurn {
                            turn_id: active.clone(),
                            state: OrchestrationLatestTurnState::Running,
                            requested_at: same
                                .map(|t| t.requested_at.clone())
                                .unwrap_or_else(|| session.updated_at.clone()),
                            started_at: Some(
                                same.and_then(|t| t.started_at.clone())
                                    .unwrap_or_else(|| session.updated_at.clone()),
                            ),
                            completed_at: None,
                            assistant_message_id: same.and_then(|t| t.assistant_message_id.clone()),
                            source_proposed_plan: None,
                        })
                    }
                }
                _ => settle_latest_turn_for_session_status(latest, &session),
            };
            thread.session = Some(session);
            thread.updated_at = max_iso(Some(&thread.updated_at), occurred_at);
        }

        E::ThreadProposedPlanUpserted(payload) => {
            thread.proposed_plans.retain(|plan| plan.id != payload.proposed_plan.id);
            thread.proposed_plans.push(payload.proposed_plan.clone());
            thread.proposed_plans.sort_by(|l, r| {
                l.created_at.as_str().cmp(r.created_at.as_str()).then_with(|| l.id.cmp(&r.id))
            });
            cap_front(&mut thread.proposed_plans, MAX_THREAD_PROPOSED_PLANS);
            thread.updated_at = occurred_at.clone();
        }

        E::ThreadTurnDiffCompleted(payload) => {
            let checkpoint = OrchestrationCheckpointSummary {
                turn_id: payload.turn_id.clone(),
                checkpoint_turn_count: payload.checkpoint_turn_count,
                checkpoint_ref: payload.checkpoint_ref.clone(),
                status: payload.status,
                files: payload.files.clone(),
                assistant_message_id: payload.assistant_message_id.clone(),
                completed_at: payload.completed_at.clone(),
            };
            // A placeholder ("missing") never overwrites a captured checkpoint.
            let existing = thread.checkpoints.iter().find(|c| c.turn_id == checkpoint.turn_id);
            if existing.is_some_and(|c| c.status != OrchestrationCheckpointStatus::Missing)
                && checkpoint.status == OrchestrationCheckpointStatus::Missing
            {
                return Some(thread);
            }
            let preserved_assistant_message_id = payload.assistant_message_id.clone().or_else(|| {
                thread
                    .latest_turn
                    .as_ref()
                    .filter(|t| t.turn_id == payload.turn_id)
                    .and_then(|t| t.assistant_message_id.clone())
            });
            let previous_latest_checkpoint_turn_count = thread.latest_turn.as_ref().and_then(|latest| {
                thread
                    .checkpoints
                    .iter()
                    .find(|c| c.turn_id == latest.turn_id)
                    .map(|c| c.checkpoint_turn_count)
            });
            let preserves_newer_latest_turn = payload.preserve_latest_turn == Some(true)
                || previous_latest_checkpoint_turn_count.is_some_and(|count| count > payload.checkpoint_turn_count);
            thread.checkpoints.retain(|c| c.turn_id != checkpoint.turn_id);
            thread.checkpoints.push(checkpoint);
            thread.checkpoints.sort_by_key(|c| c.checkpoint_turn_count);
            cap_front(&mut thread.checkpoints, MAX_THREAD_CHECKPOINTS);
            if !preserves_newer_latest_turn {
                thread.latest_turn = match thread.latest_turn.take().filter(|t| t.turn_id == payload.turn_id) {
                    // Checkpoints describe the filesystem; the session decides the lifecycle.
                    Some(matching) => Some(OrchestrationLatestTurn {
                        assistant_message_id: preserved_assistant_message_id,
                        ..matching
                    }),
                    None => Some(OrchestrationLatestTurn {
                        turn_id: payload.turn_id.clone(),
                        state: checkpoint_status_to_latest_turn_state(payload.status),
                        requested_at: payload.completed_at.clone(),
                        started_at: Some(payload.completed_at.clone()),
                        completed_at: Some(payload.completed_at.clone()),
                        assistant_message_id: preserved_assistant_message_id,
                        source_proposed_plan: None,
                    }),
                };
            }
            thread.updated_at = max_iso(Some(&thread.updated_at), occurred_at);
        }

        E::ThreadReverted(payload) => {
            thread.checkpoints.retain(|c| c.checkpoint_turn_count <= payload.turn_count);
            thread.checkpoints.sort_by_key(|c| c.checkpoint_turn_count);
            cap_front(&mut thread.checkpoints, MAX_THREAD_CHECKPOINTS);
            let retained_turn_ids: Vec<TurnId> = thread.checkpoints.iter().map(|c| c.turn_id.clone()).collect();
            let retained = retain_thread_messages_after_revert(&thread.messages, &retained_turn_ids, payload.turn_count);
            let mut messages = clear_removed_async_user_input_responses(retained, event.sequence);
            cap_front(&mut messages, MAX_THREAD_MESSAGES);
            thread.messages = messages;
            let keeps = |turn: &Option<TurnId>| turn.as_ref().is_none_or(|t| retained_turn_ids.contains(t));
            thread.proposed_plans.retain(|plan| keeps(&plan.turn_id));
            cap_front(&mut thread.proposed_plans, MAX_THREAD_PROPOSED_PLANS);
            thread.activities.retain(|activity| keeps(&activity.turn_id));
            thread.latest_turn = latest_turn_from_checkpoint(thread.checkpoints.last());
            thread.updated_at = occurred_at.clone();
        }

        E::ThreadConversationRolledBack(payload) => {
            if payload.num_turns == 0 {
                return Some(thread);
            }
            let Some(target_index) = thread.messages.iter().position(|m| m.id == payload.message_id) else {
                return Some(thread);
            };
            let removed: Vec<OrchestrationMessage> = thread.messages.split_off(target_index);
            let removed_turn_ids: Vec<TurnId> = removed.iter().filter_map(|m| m.turn_id.clone()).collect();
            thread.checkpoints.retain(|c| !removed_turn_ids.contains(&c.turn_id));
            thread.checkpoints.sort_by_key(|c| c.checkpoint_turn_count);
            cap_front(&mut thread.checkpoints, MAX_THREAD_CHECKPOINTS);
            let keeps = |turn: &Option<TurnId>| turn.as_ref().is_none_or(|t| !removed_turn_ids.contains(t));
            thread.proposed_plans.retain(|plan| keeps(&plan.turn_id));
            cap_front(&mut thread.proposed_plans, MAX_THREAD_PROPOSED_PLANS);
            thread.activities.retain(|activity| keeps(&activity.turn_id));
            let mut messages = clear_removed_async_user_input_responses(std::mem::take(&mut thread.messages), event.sequence);
            cap_front(&mut messages, MAX_THREAD_MESSAGES);
            thread.messages = messages;
            thread.latest_turn = latest_turn_from_checkpoint(thread.checkpoints.last());
            thread.updated_at = occurred_at.clone();
        }

        E::ThreadActivityAppended(payload) => {
            let mut activity = payload.activity.clone();
            activity.sequence = activity.sequence.or(Some(event.sequence));
            upsert_thread_activity(&mut thread.activities, activity);
            thread.updated_at = occurred_at.clone();
        }

        // Requests for the provider: they change nothing in the read model.
        E::ThreadTurnQueued(_)
        | E::ThreadTurnInterruptRequested(_)
        | E::ThreadTaskStopRequested(_)
        | E::ThreadTaskBackgroundRequested(_)
        | E::ThreadApprovalResponseRequested(_)
        | E::ThreadUserInputResponseRequested(_)
        | E::ThreadCheckpointRevertRequested(_)
        | E::ThreadConversationRollbackRequested(_)
        | E::ThreadMessageEditResendRequested(_)
        | E::ThreadSessionStopRequested(_) => {}
    }
    Some(thread)
}

fn latest_turn_from_checkpoint(checkpoint: Option<&OrchestrationCheckpointSummary>) -> Option<OrchestrationLatestTurn> {
    checkpoint.map(|c| OrchestrationLatestTurn {
        turn_id: c.turn_id.clone(),
        state: checkpoint_status_to_latest_turn_state(c.status),
        requested_at: c.completed_at.clone(),
        started_at: Some(c.completed_at.clone()),
        completed_at: Some(c.completed_at.clone()),
        assistant_message_id: c.assistant_message_id.clone(),
        source_proposed_plan: None,
    })
}

fn thread_from_created(payload: &ThreadCreatedPayload) -> OrchestrationThread {
    OrchestrationThread {
        is_project_import: None,
        id: payload.thread_id.clone(),
        project_id: payload.project_id.clone(),
        title: payload.title.clone(),
        model_selection: payload.model_selection.clone(),
        runtime_mode: payload.runtime_mode,
        interaction_mode: payload.interaction_mode,
        env_mode: payload.env_mode,
        branch: payload.branch.clone(),
        worktree_path: payload.worktree_path.clone(),
        working_directory: payload.working_directory.clone(),
        associated_worktree_path: payload.associated_worktree_path.clone(),
        associated_worktree_branch: payload.associated_worktree_branch.clone(),
        associated_worktree_ref: payload.associated_worktree_ref.clone(),
        create_branch_flow_completed: payload.create_branch_flow_completed,
        is_pinned: payload.is_pinned,
        parent_thread_id: payload.parent_thread_id.clone(),
        creation_source: payload.creation_source.flatten(),
        source_thread_id: payload.source_thread_id.clone().flatten(),
        source_turn_id: payload.source_turn_id.clone().flatten(),
        gateway_operation_id: payload.gateway_operation_id.clone().flatten(),
        gateway_operation_index: payload.gateway_operation_index.flatten(),
        subagent_agent_id: payload.subagent_agent_id.clone(),
        subagent_nickname: payload.subagent_nickname.clone(),
        subagent_role: payload.subagent_role.clone(),
        fork_source_thread_id: payload.fork_source_thread_id.clone(),
        latest_turn: None,
        latest_user_message_at: None,
        latest_human_message_at: None,
        has_pending_approvals: None,
        has_pending_user_input: None,
        has_actionable_proposed_plan: None,
        created_at: payload.created_at.clone(),
        updated_at: payload.updated_at.clone(),
        archived_at: None,
        settled_at: None,
        snoozed_until: None,
        snooze_reminder_at: None,
        deleted_at: None,
        pinned_messages: None,
        notes: None,
        messages: vec![],
        proposed_plans: vec![],
        activities: vec![],
        pending_interactions: None,
        checkpoints: vec![],
        session: None,
    }
}

fn project_message_sent(thread: &mut OrchestrationThread, event: &OrchestrationEvent, payload: &ThreadMessageSentPayload) {
    let segment_sequence = payload.segment_sequence.unwrap_or(event.sequence);
    let is_assistant = payload.role == OrchestrationMessageRole::Assistant;
    if let Some(index) = thread.messages.iter().rposition(|m| m.id == payload.message_id) {
        let entry = &mut thread.messages[index];
        let resolved_text = if payload.streaming {
            format!("{}{}", entry.text, payload.text)
        } else if !payload.text.is_empty() {
            payload.text.clone()
        } else {
            entry.text.clone()
        };
        let next_segments = if is_assistant {
            derive_next_message_text_segments(
                entry.text_segments.as_ref(),
                if payload.streaming { &payload.text } else { &resolved_text },
                payload.streaming,
                payload.segment_started_at.as_ref(),
                segment_sequence,
                &payload.created_at,
                &payload.updated_at,
            )
        } else {
            None
        };
        if payload.async_user_input.is_some() {
            entry.async_user_input = payload.async_user_input.clone();
        }
        entry.text = resolved_text;
        entry.text_segments = next_segments;
        entry.streaming = payload.streaming;
        entry.source = payload.source;
        entry.updated_at = payload.updated_at.clone();
        entry.turn_id = resolve_stable_message_turn_id(entry.turn_id.as_ref(), payload.turn_id.as_ref());
        if payload.attachments.is_some() {
            entry.attachments = payload.attachments.clone();
        }
        if payload.skills.is_some() {
            entry.skills = payload.skills.clone();
        }
        if payload.mentions.is_some() {
            entry.mentions = payload.mentions.clone();
        }
        if payload.dispatch_mode.is_some() {
            entry.dispatch_mode = payload.dispatch_mode;
        }
        if payload.dispatch_origin.is_some() {
            entry.dispatch_origin = payload.dispatch_origin;
        }
        if payload.starts_new_turn.is_some() {
            entry.starts_new_turn = payload.starts_new_turn;
        }
    } else {
        let text_segments = if is_assistant {
            derive_next_message_text_segments(
                None,
                &payload.text,
                payload.streaming,
                payload.segment_started_at.as_ref(),
                segment_sequence,
                &payload.created_at,
                &payload.updated_at,
            )
        } else {
            None
        };
        thread.messages.push(OrchestrationMessage {
            id: payload.message_id.clone(),
            role: payload.role,
            text: payload.text.clone(),
            text_segments,
            async_user_input: payload.async_user_input.clone(),
            attachments: payload.attachments.clone(),
            skills: payload.skills.clone(),
            mentions: payload.mentions.clone(),
            dispatch_mode: payload.dispatch_mode,
            dispatch_origin: payload.dispatch_origin,
            starts_new_turn: payload.starts_new_turn,
            turn_id: payload.turn_id.clone(),
            streaming: payload.streaming,
            source: payload.source,
            created_at: payload.created_at.clone(),
            updated_at: payload.updated_at.clone(),
        });
        cap_front(&mut thread.messages, MAX_THREAD_MESSAGES);
    }
    // From Synara `ProjectionPipeline.ts` (applyThreadShellSummariesProjection and the turn
    // projection's `thread.message-sent` case), which this crate has no SQL counterpart for.
    if payload.role == OrchestrationMessageRole::User {
        let latest = thread.latest_user_message_at.clone().flatten();
        thread.latest_user_message_at = Some(Some(max_iso(latest.as_ref(), &payload.created_at)));
    }
    if is_assistant {
        if let (Some(turn_id), Some(latest)) = (&payload.turn_id, thread.latest_turn.as_mut()) {
            if &latest.turn_id == turn_id {
                latest.assistant_message_id = Some(payload.message_id.clone());
            }
        }
    }
    thread.updated_at = event.occurred_at.clone();
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn make_event(sequence: u64, occurred_at: &str, kind: &str, payload: serde_json::Value) -> OrchestrationEvent {
        serde_json::from_value(json!({
            "sequence": sequence,
            "eventId": format!("evt-{sequence}"),
            "aggregateKind": "thread",
            "aggregateId": "thread-1",
            "occurredAt": occurred_at,
            "commandId": format!("cmd-{sequence}"),
            "causationEventId": null,
            "correlationId": null,
            "metadata": {},
            "type": kind,
            "payload": payload,
        }))
        .unwrap()
    }

    fn created(created_at: &str) -> OrchestrationThread {
        project(
            None,
            &make_event(
                1,
                created_at,
                "thread.created",
                json!({
                    "threadId": "thread-1",
                    "projectId": "project-1",
                    "title": "demo",
                    "modelSelection": { "provider": "codex", "model": "gpt-5.3-codex" },
                    "runtimeMode": "full-access",
                    "branch": null,
                    "worktreePath": null,
                    "createdAt": created_at,
                    "updatedAt": created_at,
                }),
            ),
        )
        .unwrap()
    }

    fn session_set(sequence: u64, at: &str, status: &str, active_turn_id: Option<&str>, last_error: Option<&str>) -> OrchestrationEvent {
        make_event(
            sequence,
            at,
            "thread.session-set",
            json!({
                "threadId": "thread-1",
                "session": {
                    "threadId": "thread-1",
                    "status": status,
                    "providerName": "codex",
                    "runtimeMode": "approval-required",
                    "activeTurnId": active_turn_id,
                    "lastError": last_error,
                    "updatedAt": at,
                }
            }),
        )
    }

    // projector.test.ts "applies thread.created events"
    #[test]
    fn applies_thread_created_events() {
        let thread = created("2026-02-23T08:00:00.000Z");
        assert_eq!(thread.id.as_str(), "thread-1");
        assert_eq!(thread.title, "demo");
        assert!(thread.messages.is_empty());
        assert_eq!(thread.session, None);
        assert_eq!(thread.latest_turn, None);
        assert_eq!(thread.deleted_at, None);
    }

    // projector.test.ts "tracks latest turn id from session lifecycle events"
    #[test]
    fn tracks_latest_turn_id_from_session_lifecycle_events() {
        let thread = created("2026-02-23T08:00:00.000Z");
        let thread = project(Some(thread), &session_set(2, "2026-02-23T08:00:05.000Z", "running", Some("turn-1"), None)).unwrap();
        assert_eq!(thread.latest_turn.as_ref().unwrap().turn_id.as_str(), "turn-1");
        assert_eq!(thread.session.unwrap().status, OrchestrationSessionStatus::Running);
    }

    // projector.test.ts "does not settle while an interrupted session still retains the active turn"
    #[test]
    fn does_not_settle_while_an_interrupted_session_retains_the_turn() {
        let thread = created("2026-02-23T08:00:00.000Z");
        let thread = project(Some(thread), &session_set(2, "2026-02-23T08:00:05.000Z", "running", Some("turn-1"), None)).unwrap();
        let thread = project(Some(thread), &session_set(3, "2026-02-23T08:00:10.000Z", "interrupted", Some("turn-1"), None)).unwrap();
        let latest = thread.latest_turn.clone().unwrap();
        assert_eq!(latest.state, OrchestrationLatestTurnState::Running);
        assert_eq!(latest.completed_at, None);
        let thread = project(Some(thread), &session_set(4, "2026-02-23T08:00:15.000Z", "ready", None, None)).unwrap();
        let latest = thread.latest_turn.unwrap();
        assert_eq!(latest.state, OrchestrationLatestTurnState::Completed);
        assert_eq!(latest.completed_at.unwrap().as_str(), "2026-02-23T08:00:15.000Z");
    }

    // projector.test.ts "settles an errored turn even when the session still retains the active turn"
    #[test]
    fn settles_an_errored_turn_with_a_retained_active_turn() {
        let thread = created("2026-02-23T08:00:00.000Z");
        let thread = project(Some(thread), &session_set(2, "2026-02-23T08:00:05.000Z", "running", Some("turn-1"), None)).unwrap();
        let thread = project(Some(thread), &session_set(3, "2026-02-23T08:00:10.000Z", "error", Some("turn-1"), Some("provider crashed"))).unwrap();
        let latest = thread.latest_turn.unwrap();
        assert_eq!(latest.state, OrchestrationLatestTurnState::Error);
        assert_eq!(latest.completed_at.unwrap().as_str(), "2026-02-23T08:00:10.000Z");
    }

    fn message_sent(sequence: u64, at: &str, id: &str, text: &str, streaming: bool, segment_started_at: Option<&str>) -> OrchestrationEvent {
        let mut payload = json!({
            "threadId": "thread-1",
            "messageId": id,
            "role": "assistant",
            "text": text,
            "turnId": "turn-1",
            "streaming": streaming,
            "createdAt": at,
            "updatedAt": at,
        });
        if let Some(started) = segment_started_at {
            payload["segmentStartedAt"] = json!(started);
        }
        make_event(sequence, at, "thread.message-sent", payload)
    }

    // projector.test.ts "marks assistant messages completed with non-streaming updates"
    #[test]
    fn marks_assistant_messages_completed_with_non_streaming_updates() {
        let thread = created("2026-02-23T09:00:00.000Z");
        let thread = project(Some(thread), &message_sent(2, "2026-02-23T09:00:01.000Z", "assistant:msg-1", "hello", true, None)).unwrap();
        let thread = project(Some(thread), &message_sent(3, "2026-02-23T09:00:03.500Z", "assistant:msg-1", "", false, None)).unwrap();
        let message = &thread.messages[0];
        assert_eq!(message.id.as_str(), "assistant:msg-1");
        assert_eq!(message.text, "hello");
        assert!(!message.streaming);
        assert_eq!(message.updated_at.as_str(), "2026-02-23T09:00:03.500Z");
    }

    // projector.test.ts "accumulates streaming deltas in place without reordering the transcript"
    #[test]
    fn accumulates_streaming_deltas_into_segments() {
        let thread = created("2026-02-23T09:00:00.000Z");
        let thread = project(Some(thread), &message_sent(2, "2026-02-23T09:00:01.000Z", "a", "Hel", true, Some("2026-02-23T09:00:01.000Z"))).unwrap();
        let thread = project(Some(thread), &message_sent(3, "2026-02-23T09:00:02.000Z", "a", "lo", true, None)).unwrap();
        let thread = project(Some(thread), &message_sent(4, "2026-02-23T09:00:03.000Z", "a", " world", true, Some("2026-02-23T09:00:03.000Z"))).unwrap();
        let thread = project(Some(thread), &message_sent(5, "2026-02-23T09:00:04.000Z", "a", "", false, None)).unwrap();
        let message = &thread.messages[0];
        assert_eq!(message.text, "Hello world");
        let segments = message.text_segments.as_ref().unwrap();
        assert_eq!(segments.len(), 2);
        assert_eq!(segments[0].text, "Hello");
        assert_eq!(segments[0].sequence, 2);
        assert_eq!(segments[1].text, " world");
        assert_eq!(segments[1].ended_at.as_str(), "2026-02-23T09:00:04.000Z");
    }

    // projector.test.ts "updates canonical thread runtime mode from thread.runtime-mode-set"
    #[test]
    fn updates_runtime_mode() {
        let thread = created("2026-02-23T08:00:00.000Z");
        let thread = project(
            Some(thread),
            &make_event(2, "2026-02-23T08:00:01.000Z", "thread.runtime-mode-set", json!({ "threadId": "thread-1", "runtimeMode": "approval-required", "updatedAt": "2026-02-23T08:00:01.000Z" })),
        )
        .unwrap();
        assert_eq!(thread.runtime_mode, RuntimeMode::ApprovalRequired);
    }

    // projector.test.ts "keeps activity order while appending and replacing without a full sort"
    #[test]
    fn keeps_activity_order_while_appending_and_replacing() {
        let mut thread = created("2026-02-23T08:00:00.000Z");
        let activity = |id: &str, sequence: u64, summary: &str| {
            make_event(
                10 + sequence,
                "2026-02-23T08:00:01.000Z",
                "thread.activity-appended",
                json!({ "threadId": "thread-1", "activity": { "id": id, "tone": "tool", "kind": "tool.updated", "summary": summary, "payload": {}, "turnId": null, "sequence": sequence, "createdAt": "2026-02-23T08:00:01.000Z" } }),
            )
        };
        for (id, sequence) in [("a", 1), ("c", 3), ("b", 2)] {
            thread = project(Some(thread), &activity(id, sequence, id)).unwrap();
        }
        thread = project(Some(thread), &activity("b", 2, "b replaced")).unwrap();
        let order: Vec<_> = thread.activities.iter().map(|a| a.id.as_str().to_string()).collect();
        assert_eq!(order, ["a", "b", "c"]);
        assert_eq!(thread.activities[1].summary, "b replaced");
        thread = project(Some(thread), &activity("a", 5, "a moved")).unwrap();
        let order: Vec<_> = thread.activities.iter().map(|a| a.id.as_str().to_string()).collect();
        assert_eq!(order, ["b", "c", "a"]);
    }

    // projector.test.ts "prunes reverted turn messages from in-memory thread snapshot"
    #[test]
    fn prunes_reverted_turn_messages() {
        let mut thread = created("2026-02-23T08:00:00.000Z");
        let mut sequence = 1;
        for turn in 1..=2 {
            for (role, id) in [("user", format!("user-{turn}")), ("assistant", format!("assistant-{turn}"))] {
                sequence += 1;
                thread = project(
                    Some(thread),
                    &make_event(sequence, "2026-02-23T08:00:01.000Z", "thread.message-sent", json!({
                        "threadId": "thread-1", "messageId": id, "role": role, "text": id,
                        "turnId": format!("turn-{turn}"), "streaming": false,
                        "createdAt": "2026-02-23T08:00:01.000Z", "updatedAt": "2026-02-23T08:00:01.000Z",
                    })),
                )
                .unwrap();
            }
            sequence += 1;
            thread = project(
                Some(thread),
                &make_event(sequence, "2026-02-23T08:00:02.000Z", "thread.turn-diff-completed", json!({
                    "threadId": "thread-1", "turnId": format!("turn-{turn}"), "checkpointTurnCount": turn,
                    "checkpointRef": format!("ref-{turn}"), "status": "ready", "files": [],
                    "assistantMessageId": format!("assistant-{turn}"), "completedAt": "2026-02-23T08:00:02.000Z",
                })),
            )
            .unwrap();
        }
        assert_eq!(thread.messages.len(), 4);
        thread = project(
            Some(thread),
            &make_event(sequence + 1, "2026-02-23T08:00:03.000Z", "thread.reverted", json!({ "threadId": "thread-1", "turnCount": 1 })),
        )
        .unwrap();
        let ids: Vec<_> = thread.messages.iter().map(|m| m.id.as_str().to_string()).collect();
        assert_eq!(ids, ["user-1", "assistant-1"]);
        assert_eq!(thread.checkpoints.len(), 1);
        assert_eq!(thread.latest_turn.unwrap().turn_id.as_str(), "turn-1");
    }

    #[test]
    fn a_missing_placeholder_never_overwrites_a_captured_checkpoint() {
        let thread = created("2026-02-23T08:00:00.000Z");
        let diff = |sequence: u64, status: &str, reference: &str| {
            make_event(sequence, "2026-02-23T08:00:02.000Z", "thread.turn-diff-completed", json!({
                "threadId": "thread-1", "turnId": "turn-1", "checkpointTurnCount": 1,
                "checkpointRef": reference, "status": status, "files": [],
                "assistantMessageId": null, "completedAt": "2026-02-23T08:00:02.000Z",
            }))
        };
        let thread = project(Some(thread), &diff(2, "ready", "git-ref")).unwrap();
        let thread = project(Some(thread), &diff(3, "missing", "provider-diff:x")).unwrap();
        assert_eq!(thread.checkpoints[0].checkpoint_ref.as_str(), "git-ref");
    }

    #[test]
    fn turn_start_requested_projects_a_starting_session() {
        let thread = created("2026-02-23T08:00:00.000Z");
        let thread = project(
            Some(thread),
            &make_event(2, "2026-02-23T08:00:01.000Z", "thread.turn-start-requested", json!({
                "threadId": "thread-1", "messageId": "msg-1",
                "modelSelection": { "provider": "claudeAgent", "model": "claude-x" },
                "runtimeMode": "approval-required", "interactionMode": "plan",
                "createdAt": "2026-02-23T08:00:01.000Z",
            })),
        )
        .unwrap();
        // An empty thread adopts the first turn's provider.
        assert!(matches!(thread.model_selection, ModelSelection::ClaudeAgent(_)));
        let session = thread.session.unwrap();
        assert_eq!(session.status, OrchestrationSessionStatus::Starting);
        assert_eq!(session.provider_name.as_deref(), Some("claudeAgent"));
        assert_eq!(thread.interaction_mode, ProviderInteractionMode::Plan);
    }

    #[test]
    fn events_for_an_absent_thread_leave_it_absent() {
        let event = session_set(2, "2026-02-23T08:00:05.000Z", "running", Some("turn-1"), None);
        assert!(project(None, &event).is_none());
    }
}
