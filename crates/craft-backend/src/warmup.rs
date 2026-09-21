//! IDE warm-up: the preparation a worktree needs before its IDE can build without stalling.
//!
//! A session's worktree is a path the IDE has never seen, so the first build pays for whatever
//! that IDE resolves per checkout — for Xcode, the whole Swift package graph, with nothing on
//! screen but a silent log. The app asks for a warm-up when a session is selected, and shows it
//! running.
//!
//! This module is IDE-neutral: it owns the state machine, the coalescing and the events. Each
//! IDE contributes a `Plan` from its own module, the way `xcode.rs` owns what Xcode-shaped means.

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime},
};

use axum::{
    extract::{Query, State},
    http::HeaderMap,
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::sync::broadcast;

use crate::{
    cli,
    error::ApiError,
    local::{error_line, foreign_origin, resolve_path},
    xcode, AppState,
};

type ApiResult<T> = Result<Json<T>, ApiError>;

/// A warm-up that finished, or an IDE with nothing to prepare — callers never have to know
/// which IDEs have a plan.
pub const READY: &str = "ready";
pub const RUNNING: &str = "running";
pub const FAILED: &str = "failed";

/// How long a failure stands before the same request is allowed to try again. The app asks on
/// every inventory refresh, so without this a graph that cannot resolve — a private package
/// with no credentials, a dependency that 404s — would respawn `xcodebuild` for as long as the
/// session stayed selected.
const RETRY_AFTER: Duration = Duration::from_secs(300);

/// At most one repeat, for the case below where the checkout moved under a run.
const MAX_ATTEMPTS: u8 = 2;

/// One IDE's preparation for one worktree.
pub(crate) struct Plan {
    /// Shown while it runs. A sentence fragment, not a command line.
    pub label: &'static str,
    pub program: &'static str,
    pub args: Vec<String>,
    pub cwd: PathBuf,
    /// The file that decides whether a finished warm-up still holds — the lockfile the
    /// preparation reads. A worktree whose lockfile has changed is warmed up again.
    pub stamp: PathBuf,
}

#[derive(Clone)]
struct Entry {
    status: String,
    label: String,
    message: String,
    /// The lockfile this state describes. A `ready` or `failed` entry whose stamp no longer
    /// matches the worktree is stale, and the next request runs again.
    stamp: String,
    /// When the entry was written, for the failure cooldown.
    at: Instant,
}

impl Entry {
    fn new(status: &str, label: &str, message: &str, stamp: String) -> Self {
        Self {
            status: status.into(),
            label: label.into(),
            message: message.into(),
            stamp,
            at: Instant::now(),
        }
    }

    fn value(&self, worktree: &str) -> Value {
        json!({
            "worktree": worktree,
            "status": self.status,
            "label": self.label,
            "message": self.message,
        })
    }

    /// The same shape the endpoint returns, tagged — so the app parses one struct whether the
    /// state arrived as a reply or as an event.
    fn event(&self, worktree: &str) -> Value {
        let mut value = self.value(worktree);
        value["type"] = json!("ide-warmup");
        value
    }

    /// Whether this state answers a request on its own, instead of starting another run.
    fn settles(&self, stamp: &str) -> bool {
        match self.status.as_str() {
            RUNNING => true,
            READY => self.stamp == stamp,
            FAILED => self.stamp == stamp && self.at.elapsed() < RETRY_AFTER,
            _ => false,
        }
    }
}

#[derive(Default)]
pub struct Warmup {
    states: Mutex<HashMap<String, Entry>>,
}

/// Size and modification time of the lockfile, which is what a resolve rewrites. Cheaper than
/// hashing it and enough to tell "the same graph as last time" from "this branch moved it".
fn stamp_of(path: &Path) -> String {
    let Ok(meta) = std::fs::metadata(path) else {
        return String::new();
    };
    let modified = meta
        .modified()
        .ok()
        .and_then(|time| time.duration_since(SystemTime::UNIX_EPOCH).ok())
        .map(|d| d.as_millis())
        .unwrap_or(0);
    format!("{}:{modified}", meta.len())
}

fn plan_for(root: &Path, rel: &str, ide: &str) -> Option<Plan> {
    match ide {
        // Every other editor opens a folder and resolves nothing per checkout. One that grows
        // a preparation — a Gradle sync, a package install — adds its arm here and builds its
        // `Plan` in its own module.
        "xcode" => xcode::warmup_plan(root, rel),
        _ => None,
    }
}

impl Warmup {
    fn read(&self, worktree: &str) -> Option<Entry> {
        self.states.lock().unwrap().get(worktree).cloned()
    }

    fn write(&self, worktree: &str, entry: Entry) {
        self.states
            .lock()
            .unwrap()
            .insert(worktree.to_string(), entry);
    }

    /// The state to show for a worktree nobody has warmed up in this process: nothing is
    /// running, so nothing is in the way of a build.
    pub fn state(&self, worktree: &str) -> Value {
        self.read(worktree)
            .unwrap_or_else(|| Entry::new(READY, "", "", String::new()))
            .value(worktree)
    }

    /// Starts a warm-up for `worktree` unless one is already running, a finished one still
    /// matches the lockfile, or a failure is still inside its cooldown. Returns immediately
    /// with the state to show: the work runs detached and reports through `ide-warmup` events.
    ///
    /// The app asks whenever a session is selected and again on every inventory refresh while
    /// it stays selected, so "asking again" has to be free.
    pub fn start(self: &Arc<Self>, app: &AppState, root: PathBuf, rel: &str, ide: &str) -> Value {
        let worktree = root.to_string_lossy().into_owned();
        let Some(plan) = plan_for(&root, rel, ide) else {
            return self.state(&worktree);
        };
        self.launch(app.events.clone(), worktree, plan)
    }

    fn launch(self: &Arc<Self>, events: broadcast::Sender<Value>, worktree: String, plan: Plan) -> Value {
        let stamp = stamp_of(&plan.stamp);
        let running = Entry::new(RUNNING, plan.label, "", stamp);
        {
            // Held across the check and the insert, and there is no await inside, so two
            // requests for one worktree cannot both decide to spawn.
            let mut states = self.states.lock().unwrap();
            if let Some(entry) = states.get(&worktree) {
                if entry.settles(&running.stamp) {
                    return entry.value(&worktree);
                }
            }
            states.insert(worktree.clone(), running.clone());
        }
        let _ = events.send(running.event(&worktree));
        let warmup = Arc::clone(self);
        let key = worktree.clone();
        tokio::spawn(async move {
            let entry = warmup.perform(&plan).await;
            warmup.write(&key, entry.clone());
            let _ = events.send(entry.event(&key));
        });
        running.value(&worktree)
    }

    /// Runs the plan, and repeats it once if the checkout moved underneath. A resolve rewrites
    /// the lockfile, so the file on disk afterwards is normally the graph that was just
    /// resolved — but an agent switching branch mid-run rewrites it too, and recording THAT
    /// graph as ready would skip the work the next build depends on.
    async fn perform(&self, plan: &Plan) -> Entry {
        let mut entry = Entry::new(FAILED, plan.label, "", String::new());
        for _ in 0..MAX_ATTEMPTS {
            let before = stamp_of(&plan.stamp);
            // Long, because a cold package graph is minutes of network. `cli` puts the child in
            // its own process group, so the timeout takes the whole tree with it.
            let outcome = cli::run_in(
                plan.program,
                plan.args.clone(),
                Duration::from_secs(900),
                Some(&plan.cwd),
            )
            .await;
            let after = stamp_of(&plan.stamp);
            match outcome {
                Ok(_) => {
                    entry = Entry::new(READY, plan.label, "", after.clone());
                    if after == before {
                        break;
                    }
                }
                // A failure is stamped with what it READ, not with what is there now: that is
                // the input it failed on, and the cooldown is what releases it otherwise.
                Err(error) => {
                    return Entry::new(FAILED, plan.label, &error_line(&error.to_string()), before);
                }
            }
        }
        entry
    }
}

#[derive(Deserialize)]
pub struct WarmupQuery {
    path: Option<String>,
}

pub async fn get_warmup(
    headers: HeaderMap,
    State(app): State<AppState>,
    Query(query): Query<WarmupQuery>,
) -> ApiResult<Value> {
    if foreign_origin(&headers) {
        return Err(ApiError::forbidden("forbidden"));
    }
    let raw = query
        .path
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let root = resolve_path(&raw);
    Ok(Json(app.warmup.state(&root.to_string_lossy())))
}

pub async fn post_warmup(
    headers: HeaderMap,
    State(app): State<AppState>,
    Json(body): Json<Value>,
) -> ApiResult<Value> {
    if foreign_origin(&headers) {
        return Err(ApiError::forbidden("forbidden"));
    }
    let raw = body["path"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let root = resolve_path(raw);
    let rel = body["rel"].as_str().unwrap_or("");
    let ide = body["ide"].as_str().unwrap_or("");
    Ok(Json(app.warmup.start(&app, root, rel, ide)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn xcode_project(root: &Path, resolved: bool) {
        let project = root.join("App.xcodeproj");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("project.pbxproj"), "// project").unwrap();
        if resolved {
            let swiftpm = project.join("project.xcworkspace/xcshareddata/swiftpm");
            fs::create_dir_all(&swiftpm).unwrap();
            fs::write(swiftpm.join("Package.resolved"), "{}").unwrap();
        }
    }

    /// A plan that records every run by appending to a file, so a test can count spawns.
    fn counting_plan(dir: &Path, program: &'static str) -> Plan {
        let stamp = dir.join("Package.resolved");
        // Never rewritten here: the lockfile's mtime IS the coalescing key, so a helper that
        // touched it would hand every request a new graph and hide the behaviour under test.
        if !stamp.exists() {
            fs::write(&stamp, "{}").unwrap();
        }
        Plan {
            label: "Resolving Swift packages",
            program,
            args: vec![dir.join("runs").to_string_lossy().into_owned()],
            cwd: dir.to_path_buf(),
            stamp,
        }
    }

    fn runs(dir: &Path) -> usize {
        fs::read_to_string(dir.join("runs"))
            .map(|body| body.lines().count())
            .unwrap_or(0)
    }

    /// `touch` appends nothing, so the counter is the file's existence; `tee -a` would need a
    /// stdin. `/usr/bin/true` with an argument is the cheapest "succeeded", and a separate
    /// script gives the count.
    fn script(dir: &Path, body: &str) -> String {
        let path = dir.join("run.sh");
        fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        }
        path.to_string_lossy().into_owned()
    }

    async fn settle() {
        for _ in 0..200 {
            tokio::time::sleep(Duration::from_millis(10)).await;
            tokio::task::yield_now().await;
        }
    }

    #[test]
    fn an_xcode_checkout_with_packages_resolves_them() {
        let dir = tempfile::tempdir().unwrap();
        xcode_project(dir.path(), true);
        let plan = plan_for(dir.path(), "", "xcode").expect("a plan");
        assert_eq!(plan.program, "xcodebuild");
        assert!(plan.args.contains(&"-resolvePackageDependencies".to_string()));
        assert!(plan.args.iter().any(|arg| arg.ends_with("App.xcodeproj")));
        assert!(!stamp_of(&plan.stamp).is_empty());
    }

    /// No packages, nothing to prepare — a project without dependencies must never spawn
    /// `xcodebuild` on every session it opens.
    #[test]
    fn an_xcode_checkout_without_packages_has_no_plan() {
        let dir = tempfile::tempdir().unwrap();
        xcode_project(dir.path(), false);
        assert!(plan_for(dir.path(), "", "xcode").is_none());
    }

    /// Editors that open a folder resolve nothing per checkout.
    #[test]
    fn an_editor_without_a_preparation_has_no_plan() {
        let dir = tempfile::tempdir().unwrap();
        xcode_project(dir.path(), true);
        for ide in ["vscode", "cursor", "zed", ""] {
            assert!(plan_for(dir.path(), "", ide).is_none(), "{ide}");
        }
    }

    /// A worktree nobody prepared is not "pending": it must not hold a build back.
    #[test]
    fn an_unknown_worktree_is_ready() {
        let warmup = Warmup::default();
        assert_eq!(warmup.state("/tmp/nowhere")["status"], READY);
    }

    #[test]
    fn the_stamp_follows_the_lockfile() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("Package.resolved");
        assert_eq!(stamp_of(&file), "");
        fs::write(&file, "{}").unwrap();
        let first = stamp_of(&file);
        assert!(!first.is_empty());
        fs::write(&file, "{\"pins\":[]}").unwrap();
        assert_ne!(first, stamp_of(&file));
    }

    /// The app asks on every selection and every inventory refresh after it. A finished
    /// warm-up must answer those without running anything.
    #[tokio::test]
    async fn a_finished_warm_up_answers_later_requests_without_running_again() {
        let dir = tempfile::tempdir().unwrap();
        let (events, _keep) = broadcast::channel(16);
        let warmup = Arc::new(Warmup::default());
        let program = script(dir.path(), "echo run >> \"$1\"");
        let worktree = dir.path().to_string_lossy().into_owned();
        let state = warmup.launch(events.clone(), worktree.clone(), counting_plan(dir.path(), Box::leak(program.into_boxed_str())));
        assert_eq!(state["status"], RUNNING);
        settle().await;
        assert_eq!(warmup.state(&worktree)["status"], READY);
        assert_eq!(runs(dir.path()), 1);
        for _ in 0..5 {
            warmup.launch(events.clone(), worktree.clone(), counting_plan(dir.path(), "/usr/bin/false"));
        }
        settle().await;
        assert_eq!(runs(dir.path()), 1, "a settled warm-up ran again");
        assert_eq!(warmup.state(&worktree)["status"], READY);
    }

    /// The reason the cooldown exists: a graph that cannot resolve fails in seconds, and the
    /// app keeps asking, so a failure that did not hold would respawn the tool forever.
    #[tokio::test]
    async fn a_failure_holds_instead_of_respawning_on_every_request() {
        let dir = tempfile::tempdir().unwrap();
        let (events, _keep) = broadcast::channel(16);
        let warmup = Arc::new(Warmup::default());
        let program = Box::leak(script(dir.path(), "echo run >> \"$1\"; exit 3").into_boxed_str());
        let worktree = dir.path().to_string_lossy().into_owned();
        warmup.launch(events.clone(), worktree.clone(), counting_plan(dir.path(), program));
        settle().await;
        assert_eq!(warmup.state(&worktree)["status"], FAILED);
        for _ in 0..5 {
            warmup.launch(events.clone(), worktree.clone(), counting_plan(dir.path(), program));
        }
        settle().await;
        assert_eq!(runs(dir.path()), 1, "the failure was retried inside its cooldown");

        // A lockfile that moved is a different graph: that one is tried again at once.
        fs::write(dir.path().join("Package.resolved"), "{\"pins\":[1]}").unwrap();
        warmup.launch(events, worktree.clone(), counting_plan(dir.path(), program));
        settle().await;
        assert_eq!(runs(dir.path()), 2);
    }

    /// A checkout that moves while the resolve runs leaves a graph nobody resolved. Recording
    /// it ready would hand the next build exactly the stall this module exists to remove.
    #[tokio::test]
    async fn a_checkout_that_moved_under_the_run_is_resolved_again() {
        let dir = tempfile::tempdir().unwrap();
        let (events, _keep) = broadcast::channel(16);
        let warmup = Arc::new(Warmup::default());
        // Every run rewrites the lockfile, which is what a branch switch looks like from here.
        let program = Box::leak(
            script(dir.path(), "echo run >> \"$1\"; echo \"$RANDOM$RANDOM\" > \"$(dirname \"$1\")/Package.resolved\"")
                .into_boxed_str(),
        );
        let worktree = dir.path().to_string_lossy().into_owned();
        warmup.launch(events, worktree.clone(), counting_plan(dir.path(), program));
        settle().await;
        assert_eq!(warmup.state(&worktree)["status"], READY);
        assert_eq!(runs(dir.path()), MAX_ATTEMPTS as usize, "the repeat is bounded");
    }
}
