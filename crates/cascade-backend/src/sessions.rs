//! Creating a session in one request. The app used to drive four round trips itself: resolve
//! the branch's worktree, free the main checkout when it held the branch, make or reuse the
//! worktree, record the session; and it had to explain a failure halfway. Here the steps are one
//! function, the record is written last, and the reply is the record as `GET /api/tasks` lists it.

use std::path::Path;

use axum::{extract::State, http::StatusCode, Json};
use serde::Deserialize;
use serde_json::json;
use url::Url;
use uuid::Uuid;

use crate::{error::ApiError, local, AppState, Session};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NewSession {
    project_id: String,
    branch: String,
    #[serde(default)]
    create_branch: bool,
    /// Where a new branch forks from, and where the main checkout is parked when it holds the
    /// branch. Empty picks the repository's session base: `develop`, else its default branch.
    #[serde(default)]
    base: String,
    /// The worktree the page resolved to; the session reuses it as long as it is still the one.
    #[serde(default)]
    reuse_worktree: Option<String>,
    #[serde(default)]
    url: String,
    #[serde(default)]
    title: String,
    #[serde(default = "default_kind")]
    kind: String,
    #[serde(default)]
    jira_key: String,
    #[serde(default)]
    cli: String,
    /// A conversation id chosen ahead of the launch, for an agent that names its own; else empty.
    #[serde(default)]
    session_id: String,
}

fn default_kind() -> String {
    "session".into()
}

pub async fn create_session(
    State(app): State<AppState>,
    Json(body): Json<NewSession>,
) -> Result<Json<Session>, ApiError> {
    let project = app
        .db
        .project(&body.project_id).await?
        .ok_or_else(|| ApiError::not_found("Project not found"))?;
    let workspace = project.workspace.clone();
    let branch = body.branch.trim().to_owned();
    if branch.is_empty() || workspace.is_empty() {
        return Err(ApiError::bad_request(
            "Choose a project workspace and branch.",
        ));
    }
    let url = body.url.trim().to_owned();
    if !url.is_empty() && !web_url(&url) {
        return Err(ApiError::bad_request(
            "The page address must use HTTP or HTTPS.",
        ));
    }
    if !crate::agents::Agent::allowed_cli(&body.cli) {
        return Err(ApiError::bad_request("Unsupported agent"));
    }

    let trees = local::list_worktrees(&workspace).await;
    let found = trees.iter().find(|tree| tree.branch == branch);
    let reused = body.reuse_worktree.as_deref().filter(|v| !v.is_empty());
    // An empty base picks the repository's session base, for the checkout parked and the branch
    // forked alike; it is asked for only when one of those happens.
    let parks = reused.is_none() && matches!(found, Some(tree) if tree.main);
    let mut base = body.base.trim().to_owned();
    if base.is_empty() && (parks || body.create_branch) {
        let taken: Vec<String> = trees.iter().map(|tree| tree.branch.clone()).collect();
        base = session_base(&workspace, &taken).await?;
    }
    let worktree = match reused {
        // The page resolved to this worktree; it must still be the one, and still a worktree.
        Some(reused) => match found {
            Some(tree) if !tree.main && same_path(&tree.path, reused) => tree.path.clone(),
            _ => {
                return Err(ApiError::conflict(
                    "The existing worktree changed. Resolve the page again before creating the session.",
                ))
            }
        },
        None => match found {
            // A branch that already has a worktree here is reused: the session is new, the
            // worktree is not.
            Some(tree) if !tree.main => tree.path.clone(),
            // The main checkout holds it. Feature branches live in worktrees and the main
            // checkout belongs on the base, so it is parked there first to make the room.
            Some(_) => {
                let parked = free_main_checkout(&workspace, &branch, &base).await?;
                make_worktree(&app, &workspace, &branch, body.create_branch, &base)
                    .await
                    .map_err(|error| {
                        // The checkout has moved and nothing undoes that, so the failure says so.
                        ApiError::conflict(format!(
                            "The main checkout was moved to {parked}, but the worktree could not be created: {error}"
                        ))
                    })?
            }
            None => make_worktree(&app, &workspace, &branch, body.create_branch, &base)
                .await
                .map_err(|error| ApiError::status(StatusCode::UNPROCESSABLE_ENTITY, error))?,
        },
    };

    let id = Uuid::new_v4().to_string();
    let title = if body.title.is_empty() {
        branch.clone()
    } else {
        body.title.clone()
    };
    let record = Session {
        id: id.clone(),
        project_id: body.project_id.clone(),
        workspace: workspace.clone(),
        worktree: worktree.clone(),
        title,
        branch: branch.clone(),
        url: if url.is_empty() { format!("session:{id}") } else { url },
        created_at: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        pinned: false,
        kind: body.kind.clone(),
        jira_key: body.jira_key.clone(),
        cli: body.cli.clone(),
        session_id: body.session_id.clone(),
        ..Session::default()
    };
    // A record refused or a database that failed both leave a worktree without a session, and
    // the person needs to know it is there either way.
    let saved = app.db.upsert_task(&record).await;
    if !matches!(saved, Ok(true)) {
        let detail = match saved {
            Err(error) => format!(" ({error})"),
            Ok(_) => String::new(),
        };
        return Err(ApiError::internal(format!(
            "Worktree created at {worktree}, but the session could not be saved{detail}. Use this branch again to recover it."
        )));
    }
    app.publish(crate::Event::Tasks);
    let saved = app.db.task(&id).await?.unwrap_or(record);
    Ok(Json(saved))
}

/// `POST /api/worktree`'s work, as a result: a refusal's message, or the worktree's path.
async fn make_worktree(
    app: &AppState,
    workspace: &str,
    branch: &str,
    create: bool,
    base: &str,
) -> Result<String, String> {
    let reply = local::create_worktree_value(
        app,
        &json!({"path":workspace,"branch":branch,"create":create,"base":base}),
    )
    .await
    .map_err(|error| error.to_string())?
    .0;
    reply["path"]
        .as_str()
        .filter(|path| !path.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| "Git did not return a worktree.".to_owned())
}

/// Parks the main checkout on `base`, freeing the branch it holds for a worktree of its own, and
/// answers where it was parked. Git checks a branch out once, so there is nothing to ask.
async fn free_main_checkout(workspace: &str, branch: &str, base: &str) -> Result<String, ApiError> {
    let base = base.to_owned();
    if base == branch {
        return Err(ApiError::conflict(format!(
            "{branch} is the branch this session forks from, so the main checkout cannot be moved off it. Choose a different \u{201C}Branch from\u{201D}."
        )));
    }
    let moved = format!("{branch} is checked out in the main repo, which could not be moved to {base}");
    local::git_switch_value(&json!({"path":workspace,"branch":base}))
        .await
        .map(|_| ())
        .map_err(|error| ApiError::conflict(format!("{moved}: {error}")))?;
    Ok(base)
}

/// The base a new session's branch forks from, and the main checkout is parked on: `develop` when
/// the repository has it locally, else its default branch when that exists locally, else the most
/// recently committed local branch, as the app used to pick. A branch a worktree holds (`taken`)
/// cannot be parked on, so it is never the fallback. Short questions to git, not a listing of
/// every branch and worktree.
async fn session_base(workspace: &str, taken: &[String]) -> Result<String, ApiError> {
    if local::ref_exists(workspace, "refs/heads/develop").await {
        return Ok("develop".into());
    }
    let default = local::default_branch(workspace).await;
    if local::ref_exists(workspace, &format!("refs/heads/{default}")).await {
        return Ok(default);
    }
    Ok(local::most_recent_branch(workspace, taken).await.unwrap_or(default))
}

/// An http(s) address with a host and no credentials: what a session page may be.
fn web_url(value: &str) -> bool {
    Url::parse(value).is_ok_and(|url| {
        ["http", "https"].contains(&url.scheme())
            && url.host().is_some()
            && url.username().is_empty()
            && url.password().is_none()
    })
}

/// The same place as git reports it and as the app remembered it: /var is a link to /private/var.
fn same_path(a: &str, b: &str) -> bool {
    let canonical = |value: &str| {
        Path::new(value)
            .canonicalize()
            .unwrap_or_else(|_| Path::new(value).to_path_buf())
    };
    canonical(a) == canonical(b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_web_addresses_without_credentials_pass() {
        assert!(web_url("https://github.com/o/r/pull/1"));
        assert!(web_url("http://localhost:3000/"));
        assert!(!web_url("file:///etc/passwd"));
        assert!(!web_url("https://user:secret@jira.test/browse/A-1"));
        assert!(!web_url("not a url"));
    }

    #[test]
    fn paths_compare_by_where_they_point() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().canonicalize().unwrap();
        assert!(same_path(dir.path().to_str().unwrap(), real.to_str().unwrap()));
        assert!(!same_path(real.to_str().unwrap(), "/nowhere/else"));
        assert!(same_path("/nowhere/else", "/nowhere/else"));
    }
}
