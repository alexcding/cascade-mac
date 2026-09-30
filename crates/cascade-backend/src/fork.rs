//! Forking a session: a new session whose agent carries the source's conversation on under a
//! conversation of its own, in a worktree of its own that starts as the source's code stands,
//! uncommitted work included. The fork is named after the source with a number: `Fix login`
//! forks to `Fix login (2)`, and forking either again gives `Fix login (3)`. Its branch and
//! folder carry the same number, `fix-login-2`.

use axum::{
    extract::{Path, State},
    Json,
};
use serde_json::{json, Map, Value};
use uuid::Uuid;

use crate::{agents, domain::folder, error::ApiError, local, AppState, Session};

type ApiResult<T> = Result<Json<T>, ApiError>;

/// Forks are made one at a time, so two at once never pick the same number from the same list.
static FORKING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// `{"task", "warning"}`: the new session's record, and what of the source's uncommitted work did
/// not come across. The record's `forkFrom` is what its agent starts from, in the form its CLI
/// takes; empty when the source has no conversation on disk, and the fork starts a new one. The
/// app clears it once the fork's own conversation exists.
pub async fn fork_task(State(app): State<AppState>, Path(id): Path<String>) -> ApiResult<Value> {
    let _turn = FORKING.lock().await;
    let tasks = app.db.tasks().await?;
    let source = tasks
        .iter()
        .find(|task| task.id == id)
        .ok_or_else(|| ApiError::not_found("Session not found"))?;
    let (cli, workspace, worktree) = (source.cli.clone(), source.workspace.clone(), source.worktree.clone());
    if agents::Agent::of(&cli).is_none() {
        return Err(ApiError::bad_request("Only a session running an agent can be forked"));
    }
    let shown = source.label();
    let (base, own) = numbered(&shown);
    let labels: Vec<String> = tasks
        .iter()
        .filter(|task| task.project_id == source.project_id)
        .map(Session::label)
        .collect();
    let first = next_number(base, labels.iter().map(String::as_str));
    let branch = Some(source.branch.clone())
        .filter(|branch| !branch.is_empty())
        .unwrap_or_else(|| folder(&worktree).to_owned());
    let stem = branch_stem(&branch, own).to_owned();

    let conversation = source.session_id.clone();
    let (fork_cli, fork_worktree) = (cli.clone(), worktree.clone());
    let from = tokio::task::spawn_blocking(move || agents::fork_source(&fork_cli, &fork_worktree, &conversation))
        .await
        .ok()
        .flatten()
        // A fork not yet talked to has no conversation of its own: forking it forks what it would.
        .or_else(|| Some(source.fork_from.clone()).filter(|source| !source.is_empty()));

    let forked = local::fork_worktree(&app, &workspace, &worktree, first, |number| format!("{stem}-{number}"))
        .await
        .map_err(ApiError::bad_request)?;
    let path = forked.path.to_string_lossy().into_owned();
    let new_id = Uuid::new_v4().to_string();
    // A session started from no page is its own context, which names it.
    let url = Some(source.url.clone())
        .filter(|url| !url.starts_with("session:"))
        .unwrap_or_else(|| format!("session:{new_id}"));
    let record = Session {
        id: new_id.clone(),
        project_id: source.project_id.clone(),
        workspace: workspace.clone(),
        worktree: path,
        branch: forked.branch.clone(),
        title: source.title.clone(),
        kind: source.kind.clone(),
        url,
        jira_key: source.jira_key.clone(),
        cli,
        ..Session::default()
    };
    // The fork's own fields are patch-only, so an upsert of the record never clears them.
    let mut extra = Map::new();
    extra.insert("name".into(), json!(format!("{base} ({})", forked.number)));
    extra.insert("runScheme".into(), json!(source.run_scheme));
    extra.insert("runSim".into(), json!(source.run_sim));
    extra.insert("forkFrom".into(), json!(from.unwrap_or_default()));
    extra.insert("forkedFrom".into(), json!(id));
    let saved = match app.db.upsert_task(&record).await {
        Ok(_) => app.db.patch_task(&new_id, &extra).await,
        Err(error) => Err(error),
    };
    if let Err(error) = saved {
        let _ = app.db.delete_task(&new_id).await;
        local::discard_fork(&workspace, &forked).await;
        return Err(ApiError::internal(format!("The fork could not be saved: {error}")));
    }
    app.publish(crate::Event::Tasks);
    let task = app
        .db
        .task(&new_id).await?
        .ok_or_else(|| ApiError::internal("The forked session was not saved"))?;
    Ok(Json(json!({ "task": task, "warning": forked.warning })))
}

/// A label as its family's name and its number in it: `Fix login (3)` is `("Fix login", 3)`, and
/// anything without a trailing ` (N)`, N at least 2, is itself and 1. A label that is only the
/// number keeps it as its name.
fn numbered(label: &str) -> (&str, u32) {
    let label = label.trim();
    let parsed = label.strip_suffix(')').and_then(|rest| {
        let open = rest.rfind(" (")?;
        let digits = &rest[open + 2..];
        let base = rest[..open].trim_end();
        let valid = !base.is_empty() && !digits.starts_with('0') && digits.bytes().all(|b| b.is_ascii_digit());
        let number = digits.parse::<u32>().ok().filter(|n| valid && *n >= 2)?;
        Some((base, number))
    });
    parsed.unwrap_or((label, 1))
}

/// One past the highest number `base`'s family has among `labels`, so the newest fork always
/// carries the highest and a number once removed is never handed to another session. Names are
/// compared without regard to case.
fn next_number<'a>(base: &str, labels: impl IntoIterator<Item = &'a str>) -> u32 {
    let base = base.to_lowercase();
    labels
        .into_iter()
        .map(numbered)
        .filter(|(name, _)| name.to_lowercase() == base)
        .map(|(_, number)| number)
        .max()
        .unwrap_or(1)
        .saturating_add(1)
}

/// The branch a fork's number goes after: a fork's own `-N` comes off, so a fork of
/// `fix-login-2` is `fix-login-3`, not `fix-login-2-3`. Only the number its label carries.
fn branch_stem(branch: &str, number: u32) -> &str {
    if number < 2 {
        return branch;
    }
    branch
        .strip_suffix(&format!("-{number}"))
        .filter(|stem| !stem.is_empty() && !stem.ends_with('/'))
        .unwrap_or(branch)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_label_splits_into_its_family_and_number() {
        assert_eq!(numbered("Fix login"), ("Fix login", 1));
        assert_eq!(numbered("Fix login (2)"), ("Fix login", 2));
        assert_eq!(numbered("  Fix login (12)  "), ("Fix login", 12));
        assert_eq!(numbered("Fix (login)"), ("Fix (login)", 1));
        assert_eq!(numbered("Fix login (1)"), ("Fix login (1)", 1));
        assert_eq!(numbered("Fix login (02)"), ("Fix login (02)", 1));
        assert_eq!(numbered("(2)"), ("(2)", 1));
        assert_eq!(numbered("Fix login(2)"), ("Fix login(2)", 1));
    }

    #[test]
    fn the_next_number_is_one_past_the_family_highest() {
        assert_eq!(next_number("Fix login", ["Fix login"]), 2);
        assert_eq!(next_number("Fix login", ["Fix login", "fix LOGIN (4)", "Other (9)"]), 5);
        // A fork whose source is gone still counts.
        assert_eq!(next_number("Fix login", ["Fix login (3)"]), 4);
        assert_eq!(next_number("Fix login", ["Fix login (2) (2)"]), 2);
    }

    #[test]
    fn a_forks_branch_drops_only_the_number_its_label_carries() {
        assert_eq!(branch_stem("fix-login", 1), "fix-login");
        assert_eq!(branch_stem("fix-login-2", 2), "fix-login");
        assert_eq!(branch_stem("fix-login-2", 3), "fix-login-2");
        assert_eq!(branch_stem("feature/ABC-2", 1), "feature/ABC-2");
        assert_eq!(branch_stem("feature/-2", 2), "feature/-2");
    }
}
