//! Ported from Synara `apps/server/src/checkpointing/Layers/CheckpointDiffQuery.ts`: the diff of a
//! range of a thread's turns, or of the whole thread so far, between its checkpoint refs.
//!
//! Synara reads the thread's checkpoint rows and workspace from its projection tables; here they
//! are the thread's own `checkpoints` and working folder (`resolve_cwd`).

use std::path::Path;

use crate::{
    contracts::{
        base::{CheckpointRef, ThreadId, TurnId},
        orchestration::{
            OrchestrationCheckpointStatus, OrchestrationGetFullThreadDiffInput, OrchestrationGetTurnDiffInput,
            OrchestrationThread, ThreadTurnDiff,
        },
    },
    orchestration::engine::resolve_cwd,
};

use super::store::{
    checkpoint_ref_for_thread_turn, checkpoint_ref_for_thread_turn_in_managed_family,
    checkpoint_ref_for_turn_start, checkpoint_ref_for_turn_start_in_managed_family, CheckpointStore,
};

/// Why a diff could not be had: Synara's `CheckpointInvariantError` (the request or the thread is
/// wrong) and `CheckpointUnavailableError` (the checkpoint is not there, or not yet).
#[derive(Debug, PartialEq, Eq)]
pub enum CheckpointDiffError {
    Invariant(String),
    Unavailable { turn_count: u64, detail: String },
    /// The diff could not be computed (git, or the engine, failed).
    Failed(String),
}

impl std::fmt::Display for CheckpointDiffError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Invariant(detail) | Self::Unavailable { detail, .. } | Self::Failed(detail) => f.write_str(detail),
        }
    }
}

impl std::error::Error for CheckpointDiffError {}

fn empty(thread_id: &ThreadId, from_turn_count: u64, to_turn_count: u64) -> ThreadTurnDiff {
    ThreadTurnDiff { thread_id: thread_id.clone(), from_turn_count, to_turn_count, diff: String::new() }
}

fn unavailable(turn_count: u64, detail: String) -> CheckpointDiffError {
    CheckpointDiffError::Unavailable { turn_count, detail }
}

/// Synara `getTurnDiff` (CheckpointDiffQuery.ts:43). `thread` is the thread the input names, or
/// `None` for one that does not exist.
///
/// `live_turn_patch` hands back the cumulative provider patch a running turn's `provider-diff:`
/// placeholder names (Synara reads it from its runtime event journal), or `None`.
pub async fn get_turn_diff(
    store: &CheckpointStore,
    thread: Option<&OrchestrationThread>,
    input: &OrchestrationGetTurnDiffInput,
    live_turn_patch: impl Fn(&TurnId, &CheckpointRef) -> Option<String>,
) -> Result<ThreadTurnDiff, CheckpointDiffError> {
    let ignore_whitespace = input.ignore_whitespace.unwrap_or(true);
    if input.from_turn_count > input.to_turn_count {
        return Err(CheckpointDiffError::Invariant("fromTurnCount must be less than or equal to toTurnCount".into()));
    }
    if input.from_turn_count == input.to_turn_count {
        return Ok(empty(&input.thread_id, input.from_turn_count, input.to_turn_count));
    }
    let Some(thread) = thread else {
        return Err(CheckpointDiffError::Invariant(format!("Thread '{}' not found.", input.thread_id)));
    };
    let max_turn_count = thread.checkpoints.iter().map(|c| c.checkpoint_turn_count).max().unwrap_or(0);
    if input.to_turn_count > max_turn_count {
        return Err(unavailable(
            input.to_turn_count,
            format!(
                "Turn diff range exceeds current turn count: requested {}, current {max_turn_count}.",
                input.to_turn_count
            ),
        ));
    }
    let Ok(cwd) = resolve_cwd(thread) else {
        return Err(CheckpointDiffError::Invariant(format!(
            "Workspace path missing for thread '{}' when computing turn diff.",
            input.thread_id
        )));
    };
    let Some(to_checkpoint) = thread.checkpoints.iter().find(|c| c.checkpoint_turn_count == input.to_turn_count) else {
        return Err(unavailable(
            input.to_turn_count,
            format!("Checkpoint ref is unavailable for turn {}.", input.to_turn_count),
        ));
    };
    let from_checkpoint = match input.from_turn_count {
        0 => None,
        from => thread.checkpoints.iter().find(|c| c.checkpoint_turn_count == from),
    };
    let is_missing = to_checkpoint.status == OrchestrationCheckpointStatus::Missing;
    let single_turn = input.to_turn_count == input.from_turn_count + 1;
    let is_live_snapshot = is_missing && to_checkpoint.checkpoint_ref.as_str().starts_with("provider-diff:") && single_turn;
    // An interrupted turn may have a captured canonical ref while retaining status missing. Its
    // exact start/ref pair remains a readable single turn.
    let is_captured_interrupted_snapshot = is_missing
        && single_turn
        && checkpoint_ref_for_thread_turn_in_managed_family(
            to_checkpoint.checkpoint_ref.as_str(),
            &input.thread_id,
            input.to_turn_count,
        )
        .as_ref()
            == Some(&to_checkpoint.checkpoint_ref);
    if from_checkpoint.is_some_and(|c| c.status == OrchestrationCheckpointStatus::Missing)
        && !is_live_snapshot
        && !is_captured_interrupted_snapshot
    {
        return Err(unavailable(
            input.from_turn_count,
            format!("Checkpoint diff is not available yet for turn {}.", input.from_turn_count),
        ));
    }
    let mut ordered: Vec<_> = thread.checkpoints.iter().collect();
    ordered.sort_by_key(|c| c.checkpoint_turn_count);
    let earliest_managed_baseline_ref = ordered
        .iter()
        .find_map(|c| checkpoint_ref_for_thread_turn_in_managed_family(c.checkpoint_ref.as_str(), &input.thread_id, 0));
    let mut from_ref = if is_live_snapshot || is_captured_interrupted_snapshot {
        Some(checkpoint_ref_for_turn_start(&input.thread_id, &to_checkpoint.turn_id))
    } else {
        match input.from_turn_count {
            0 => Some(earliest_managed_baseline_ref.unwrap_or_else(|| checkpoint_ref_for_thread_turn(&input.thread_id, 0))),
            _ => from_checkpoint.map(|c| c.checkpoint_ref.clone()),
        }
    };
    let Some(mut from) = from_ref.take() else {
        return Err(unavailable(
            input.from_turn_count,
            format!("Checkpoint ref is unavailable for turn {}.", input.from_turn_count),
        ));
    };
    // Synara reads a live revision's captured ref (`checkpointRefForThreadTurnLive`), which only
    // its git-derived live preview writes; that preview is not ported, so a live placeholder is
    // read from its provider patch alone.
    let to = to_checkpoint.checkpoint_ref.clone();
    let cwd = Path::new(&cwd);
    let turn_start = checkpoint_ref_for_turn_start_in_managed_family(to.as_str(), &input.thread_id, &to_checkpoint.turn_id)
        .unwrap_or_else(|| checkpoint_ref_for_turn_start(&input.thread_id, &to_checkpoint.turn_id));
    let turn_start_exists = single_turn && store.has_checkpoint_ref(cwd, &turn_start).await.unwrap_or(false);
    // Missing metadata alone never proves a patch: both an exact turn baseline and its immutable
    // captured ref (or provider patch) must exist. Never read today's tree.
    let missing_snapshot_exists =
        is_captured_interrupted_snapshot && store.has_checkpoint_ref(cwd, &to).await.unwrap_or(false);
    let provider_patch = (is_live_snapshot && turn_start_exists && !missing_snapshot_exists)
        .then(|| live_turn_patch(&to_checkpoint.turn_id, &to))
        .flatten();
    if is_missing && (!turn_start_exists || (!missing_snapshot_exists && provider_patch.is_none())) {
        return Err(unavailable(
            input.to_turn_count,
            format!("Checkpoint diff is not available yet for turn {}.", input.to_turn_count),
        ));
    }
    if turn_start_exists {
        from = turn_start;
    }
    let diff = match &provider_patch {
        Some(patch) => store.diff_provider_patch(cwd, &from, patch, ignore_whitespace).await,
        None => store.diff_checkpoints_with(cwd, &from, &to, ignore_whitespace).await,
    }
    .map_err(|error| CheckpointDiffError::Failed(format!("{error:#}")))?;
    Ok(ThreadTurnDiff {
        thread_id: input.thread_id.clone(),
        from_turn_count: input.from_turn_count,
        to_turn_count: input.to_turn_count,
        diff,
    })
}

/// Synara `getFullThreadDiff` (CheckpointDiffQuery.ts:199): from the thread's baseline to turn
/// `to_turn_count`.
pub async fn get_full_thread_diff(
    store: &CheckpointStore,
    thread: Option<&OrchestrationThread>,
    input: &OrchestrationGetFullThreadDiffInput,
) -> Result<ThreadTurnDiff, CheckpointDiffError> {
    let ignore_whitespace = input.ignore_whitespace.unwrap_or(true);
    if input.to_turn_count == 0 {
        return Ok(empty(&input.thread_id, 0, 0));
    }
    let Some(thread) = thread else {
        return Err(CheckpointDiffError::Invariant(format!("Thread '{}' not found.", input.thread_id)));
    };
    // Synara's context query: the latest checkpointed turn, the earliest checkpoint's ref (the
    // baseline's family) and the ref of the turn asked for.
    let latest_checkpoint_turn_count = thread.checkpoints.iter().map(|c| c.checkpoint_turn_count).max().unwrap_or(0);
    let baseline_checkpoint_ref =
        thread.checkpoints.iter().min_by_key(|c| c.checkpoint_turn_count).map(|c| c.checkpoint_ref.clone());
    let to_checkpoint_ref = thread
        .checkpoints
        .iter()
        .find(|c| c.checkpoint_turn_count == input.to_turn_count)
        .map(|c| c.checkpoint_ref.clone());
    if input.to_turn_count > latest_checkpoint_turn_count {
        return Err(unavailable(
            input.to_turn_count,
            format!(
                "Turn diff range exceeds current turn count: requested {}, current {latest_checkpoint_turn_count}.",
                input.to_turn_count
            ),
        ));
    }
    let Ok(cwd) = resolve_cwd(thread) else {
        return Err(CheckpointDiffError::Invariant(format!(
            "Workspace path missing for thread '{}' when computing full thread diff.",
            input.thread_id
        )));
    };
    let Some(to) = to_checkpoint_ref else {
        return Err(unavailable(
            input.to_turn_count,
            format!("Checkpoint ref is unavailable for turn {}.", input.to_turn_count),
        ));
    };
    let from = baseline_checkpoint_ref
        .and_then(|baseline| checkpoint_ref_for_thread_turn_in_managed_family(baseline.as_str(), &input.thread_id, 0))
        .unwrap_or_else(|| checkpoint_ref_for_thread_turn(&input.thread_id, 0));
    let diff = store
        .diff_checkpoints_with(Path::new(&cwd), &from, &to, ignore_whitespace)
        .await
        .map_err(|error| CheckpointDiffError::Failed(format!("{error:#}")))?;
    Ok(ThreadTurnDiff { thread_id: input.thread_id.clone(), from_turn_count: 0, to_turn_count: input.to_turn_count, diff })
}
