//! What a paired Mac asks this Mac to do with its sessions, from its sidebar's menu: rename one
//! (done here), or start, remove, fork or create one, which this Mac's app does as its own menu
//! does (`Event::RemoteCommand`). The app's answer is told as `session-command-done`, which the
//! paired Macs hear on their stream: a create or a remove can take longer than a request waits.

use axum::{http::StatusCode, response::{IntoResponse, Response}, Json};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{error::ApiError, AppState};

/// What this Mac's app does when a paired Mac asks: start a stopped session's agent (off screen),
/// say what removing one would lose (`removal`), remove it, fork it, create one in a project.
pub(crate) const APP_OPS: &[&str] = &["start", "removal", "remove", "fork", "create"];
const NAME: usize = 200;

#[derive(Deserialize)]
pub struct Command {
    op: String,
    #[serde(default)]
    task: Option<String>,
    #[serde(default)]
    project: Option<String>,
    /// The op's own fields (a name, a branch, an agent, a prompt), for the app to read.
    #[serde(default)]
    args: Value,
}

pub async fn run(state: &AppState, client: &str, command: Command) -> Response {
    let known = match (&command.task, &command.project) {
        (Some(task), _) => state.db.task(task).await.map(|found| found.is_some()),
        (None, Some(project)) if command.op == "create" => state.db.project(project).await.map(|found| found.is_some()),
        _ => Ok(false),
    };
    match known {
        Ok(true) => {}
        Ok(false) => return ApiError::not_found("No such session or project").into_response(),
        Err(error) => return ApiError::from(error).into_response(),
    }
    super::log(state, "info", "client_command", json!({ "client": client, "op": command.op }));
    if command.op == "rename" {
        let Some(task) = command.task else { return ApiError::bad_request("A session to rename").into_response() };
        let Some(name) = command.args["name"].as_str().map(str::trim).filter(|name| name.chars().count() <= NAME) else {
            return ApiError::bad_request("A name of at most 200 characters").into_response();
        };
        let patch = json!({ "name": name });
        return match state.db.patch_task(&task, patch.as_object().unwrap()).await {
            Ok(true) => {
                state.publish(crate::Event::Tasks);
                Json(json!({ "done": true })).into_response()
            }
            Ok(false) => ApiError::not_found("No such session").into_response(),
            Err(error) => ApiError::from(error).into_response(),
        };
    }
    if !APP_OPS.contains(&command.op.as_str()) {
        return ApiError::status(StatusCode::FORBIDDEN, "Not something a paired Mac may ask").into_response();
    }
    let key = uuid::Uuid::new_v4().simple().to_string();
    state.publish(crate::Event::RemoteCommand {
        key: key.clone(),
        op: command.op,
        task: command.task,
        project: command.project,
        args: command.args,
    });
    (StatusCode::ACCEPTED, Json(json!({ "key": key }))).into_response()
}

/// This Mac's app's answer to a command (`POST /api/remote/command-result`), told to the paired
/// Macs, the one that asked waiting on its key.
#[derive(Deserialize)]
pub struct Done {
    key: String,
    ok: bool,
    #[serde(default)]
    error: Option<String>,
    #[serde(default)]
    data: Value,
}

pub fn done(state: &AppState, done: Done) {
    state.publish(crate::Event::SessionCommandDone { key: done.key, ok: done.ok, error: done.error, data: done.data });
}
