//! The sync engine: GitHub and Jira synchronization into the `data.db` snapshots, and the
//! lifecycle and merge automation that follows from what a sync sees.
//!
//! The engine is one task (`Engine`) that owns all of its state: which syncs are running, each
//! project's invalidation generation, the last state each pull request was seen in, and the
//! repositories seeded. `Poller` is its handle, and every method is a message. A sync itself is a
//! plain async function (`sync_project`, `sync_pr_scope`, `sync_board`) the engine spawns with the
//! generation it started under; the same sync asked for while it runs is not started again, and
//! GitHub syncs run at most `GH_LANES` at a time.

use std::{
    collections::{HashMap, HashSet, VecDeque},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::Duration,
};

use chrono::{Duration as ChronoDuration, Utc};
use serde_json::{json, Value};
use tokio::{
    sync::{mpsc, oneshot},
    task::{Id, JoinSet},
};

use crate::{cli, github, AppState};
use crate::{PrSnapshot, Project};

/// How many projects sync against GitHub at once. `sync_all` asks for every project together,
/// and each runs two or three `gh` calls; GitHub rate-limits such a burst, and a request the
/// user is waiting on (an issue lookup, a search) would otherwise queue behind it. The bound sits
/// here, on the burst, so those requests never wait for it.
const GH_LANES: usize = 4;

/// The sync engine's handle. Cloning it shares the one engine, and the engine ends when the last
/// clone is dropped. It is made inside a Tokio runtime, because the engine is a task.
#[derive(Clone)]
pub struct Poller {
    tx: mpsc::UnboundedSender<Msg>,
}

/// What the engine is told.
enum Msg {
    /// Run the poll loops. Once: a second start is nothing.
    Start(AppState),
    /// A project changed: what its running syncs fetched no longer applies. Answered once the
    /// generation has moved, so the caller's next sync is a new one.
    Invalidate(String, oneshot::Sender<()>),
    /// Run a sync, unless the same one is already running or waiting for a lane. `done` hears
    /// when it has finished, and is dropped at once when it was not started.
    Run {
        app: AppState,
        job: Job,
        runner: Option<Arc<dyn cli::CommandRunner>>,
        done: oneshot::Sender<()>,
    },
    /// What a sync saw of a repository's pull requests, as (key, state) pairs; answers what
    /// moved since the repository was last seen, by index.
    Observe {
        repo: String,
        seen: Vec<(String, String)>,
        reply: oneshot::Sender<Vec<(usize, Transition)>>,
    },
    /// A merge a webhook told of; answers whether it was news.
    Merged {
        key: String,
        reply: oneshot::Sender<bool>,
    },
}

/// One sync.
enum Job {
    /// A project's open pull requests, with the recent closed window for merge detection.
    Project(Project),
    /// A project's pull requests in another state (`merged`, `closed`).
    Scope(Project, String),
    /// A project's sprint board.
    Board(Project),
}

impl Job {
    fn project(&self) -> &Project {
        match self {
            Job::Project(project) | Job::Scope(project, _) | Job::Board(project) => project,
        }
    }

    /// Whether it talks to GitHub, and so takes one of the lanes.
    fn github(&self) -> bool {
        !matches!(self, Job::Board(_))
    }

    /// What the same sync, asked for again while this one runs, is coalesced on. The generation
    /// is part of it: an invalidated project's sync is a new sync.
    fn key(&self, generation: u64) -> String {
        match self {
            Job::Project(project) => format!("pr:{}:{}:{generation}", project.id, project.repo),
            Job::Scope(project, state) => {
                format!("scope:{}:{state}:{}:{generation}", project.id, project.repo)
            }
            Job::Board(project) => format!("board:{}:{generation}", project.id),
        }
    }
}

/// How a pull request moved since its repository was last seen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Transition {
    Opened,
    Closed,
    Merged,
}

/// The generation a sync started under. A project edit bumps the project's counter
/// (`Poller::invalidate`), and a sync whose fetch outlived the edit finds itself stale and
/// writes nothing.
#[derive(Clone)]
struct Generation {
    counter: Arc<AtomicU64>,
    started: u64,
}

impl Generation {
    /// Whether the sync's results still apply: nothing invalidated the project, and it exists.
    async fn current(&self, app: &AppState, id: &str) -> bool {
        self.counter.load(Ordering::SeqCst) == self.started
            && app.db.project(id).await.ok().flatten().is_some()
    }
}

impl Default for Poller {
    fn default() -> Self {
        Self::new()
    }
}

impl Poller {
    pub fn new() -> Self {
        let (tx, rx) = mpsc::unbounded_channel();
        tokio::spawn(Engine::default().run(rx));
        Self { tx }
    }

    /// A project changed: its running syncs write nothing, and its next sync is a new one.
    /// Returns once the engine has moved the generation.
    pub async fn invalidate(&self, id: &str) {
        let (ack, acked) = oneshot::channel();
        if self.tx.send(Msg::Invalidate(id.to_owned(), ack)).is_ok() {
            let _ = acked.await;
        }
    }

    pub fn start(&self, app: AppState) {
        let _ = self.tx.send(Msg::Start(app));
    }

    /// Runs a sync and waits for it to finish; returns at once when the same sync is already
    /// running. The sync runs under the caller's command runner, so a scripted test covers it.
    async fn run(&self, app: &AppState, job: Job) {
        let (done, finished) = oneshot::channel();
        let message = Msg::Run {
            app: app.clone(),
            job,
            runner: cli::inherited(),
            done,
        };
        if self.tx.send(message).is_ok() {
            let _ = finished.await;
        }
    }

    pub async fn sync_all(&self, app: &AppState) {
        let Ok(projects) = app.db.projects().await else {
            return;
        };
        let syncs = projects
            .into_iter()
            .map(|project| self.run(app, Job::Project(project)));
        futures_util::future::join_all(syncs).await;
    }

    pub async fn sync_project(&self, app: &AppState, project: Project) {
        self.run(app, Job::Project(project)).await;
    }

    pub async fn sync_pr_scope(&self, app: &AppState, project: Project, state: &str) {
        self.run(app, Job::Scope(project, state.to_owned())).await;
    }

    pub async fn sync_all_jira(&self, app: &AppState) {
        if let Ok(projects) = app.db.projects().await {
            for project in projects {
                self.sync_board(app, &project).await;
            }
        }
    }

    pub async fn sync_board(&self, app: &AppState, project: &Project) {
        self.run(app, Job::Board(project.clone())).await;
    }

    /// A merge a webhook told of. It is news unless a poll, or an earlier webhook, saw it first.
    pub async fn handle_merge(&self, app: &AppState, project: &Project, pr: &Value) {
        let Some(number) = pr["number"].as_i64().filter(|n| *n > 0) else {
            return;
        };
        let (reply, news) = oneshot::channel();
        let message = Msg::Merged {
            key: pr_key(&project.repo, number),
            reply,
        };
        if self.tx.send(message).is_ok() && news.await.unwrap_or(false) {
            dispatch_merge(app, project, pr).await;
        }
    }

    /// Tells the engine what a sync saw of a repository; answers what moved, by index into `seen`.
    async fn observe(&self, repo: &str, seen: Vec<(String, String)>) -> Vec<(usize, Transition)> {
        let (reply, transitions) = oneshot::channel();
        let message = Msg::Observe {
            repo: repo.to_owned(),
            seen,
            reply,
        };
        if self.tx.send(message).is_err() {
            return Vec::new();
        }
        transitions.await.unwrap_or_default()
    }
}

/// `owner/repo#7`: the key a pull request's last seen state is kept under.
fn pr_key(repo: &str, number: i64) -> String {
    format!("{}#{number}", repo.to_ascii_lowercase())
}

/// The engine's state, owned by its task. Nothing else sees it.
#[derive(Default)]
struct Engine {
    started: bool,
    generations: HashMap<String, Arc<AtomicU64>>,
    /// The keys of the syncs running or waiting for a lane.
    claimed: HashSet<String>,
    /// GitHub syncs waiting for a lane, in the order asked.
    waiting: VecDeque<Spawn>,
    github_running: usize,
    /// Each running task's key, and whether it holds a lane.
    running: HashMap<Id, (String, bool)>,
    /// The last state each pull request was seen in, by `pr_key`.
    pr_states: HashMap<String, String>,
    /// Repositories seen at least once: their first sight shows no news.
    seeded: HashSet<String>,
}

/// A sync the engine has accepted and will spawn.
struct Spawn {
    app: AppState,
    job: Job,
    runner: Option<Arc<dyn cli::CommandRunner>>,
    generation: Generation,
    key: String,
    done: oneshot::Sender<()>,
}

impl Engine {
    async fn run(mut self, mut rx: mpsc::UnboundedReceiver<Msg>) {
        let mut tasks: JoinSet<oneshot::Sender<()>> = JoinSet::new();
        loop {
            tokio::select! {
                message = rx.recv() => {
                    let Some(message) = message else { break };
                    self.handle(message, &mut tasks);
                }
                Some(finished) = tasks.join_next_with_id(), if !tasks.is_empty() => {
                    // The key is released before the caller hears, so a sync asked for right
                    // after is a new sync, never coalesced onto the one just finished.
                    match finished {
                        Ok((id, done)) => {
                            self.finished(id, &mut tasks);
                            let _ = done.send(());
                        }
                        Err(error) => self.finished(error.id(), &mut tasks),
                    }
                }
            }
        }
        // The last handle is gone. Every sync running or waiting held one through its `AppState`,
        // so none is left: `tasks` is empty here.
    }

    fn handle(&mut self, message: Msg, tasks: &mut JoinSet<oneshot::Sender<()>>) {
        match message {
            Msg::Start(app) => self.start(app),
            Msg::Invalidate(id, ack) => {
                self.generation(&id).fetch_add(1, Ordering::SeqCst);
                let _ = ack.send(());
            }
            Msg::Run {
                app,
                job,
                runner,
                done,
            } => {
                let counter = self.generation(&job.project().id);
                let generation = Generation {
                    started: counter.load(Ordering::SeqCst),
                    counter,
                };
                let key = job.key(generation.started);
                if !self.claimed.insert(key.clone()) {
                    // Running or waiting already; `done` drops, and the caller does not wait.
                    return;
                }
                let spawn = Spawn {
                    app,
                    job,
                    runner,
                    generation,
                    key,
                    done,
                };
                if spawn.job.github() && self.github_running >= GH_LANES {
                    self.waiting.push_back(spawn);
                } else {
                    self.spawn(spawn, tasks);
                }
            }
            Msg::Observe { repo, seen, reply } => {
                let _ = reply.send(self.observe(&repo, &seen));
            }
            Msg::Merged { key, reply } => {
                let _ = reply.send(self.merged(&key));
            }
        }
    }

    fn generation(&mut self, id: &str) -> Arc<AtomicU64> {
        self.generations.entry(id.to_owned()).or_default().clone()
    }

    fn spawn(&mut self, spawn: Spawn, tasks: &mut JoinSet<oneshot::Sender<()>>) {
        let Spawn {
            app,
            job,
            runner,
            generation,
            key,
            done,
        } = spawn;
        let github = job.github();
        if github {
            self.github_running += 1;
        }
        let handle = tasks.spawn(async move {
            let work = async move {
                match job {
                    Job::Project(project) => sync_project(&app, &generation, project).await,
                    Job::Scope(project, state) => {
                        sync_pr_scope(&app, &generation, project, &state).await
                    }
                    Job::Board(project) => sync_board(&app, &generation, &project).await,
                }
            };
            match runner {
                Some(runner) => cli::scoped(runner, work).await,
                None => work.await,
            }
            done
        });
        self.running.insert(handle.id(), (key, github));
    }

    fn finished(&mut self, id: Id, tasks: &mut JoinSet<oneshot::Sender<()>>) {
        let Some((key, github)) = self.running.remove(&id) else {
            return;
        };
        self.claimed.remove(&key);
        if github {
            self.github_running -= 1;
            self.spawn_next(tasks);
        }
    }

    /// Starts the next waiting GitHub sync. One whose project was invalidated while it waited is
    /// dropped instead: its fetch would be thrown away, so it takes no lane, and its caller hears
    /// at once.
    fn spawn_next(&mut self, tasks: &mut JoinSet<oneshot::Sender<()>>) {
        while let Some(next) = self.waiting.pop_front() {
            let generation = &next.generation;
            if generation.counter.load(Ordering::SeqCst) != generation.started {
                self.claimed.remove(&next.key);
                continue;
            }
            self.spawn(next, tasks);
            return;
        }
    }

    fn start(&mut self, app: AppState) {
        if self.started {
            return;
        }
        self.started = true;
        crate::agents::warm();
        let pr_app = app.clone();
        tokio::spawn(async move {
            loop {
                pr_app.poller.sync_all(&pr_app).await;
                let seconds = pr_app
                    .db
                    .config_value("poll_interval").await
                    .ok()
                    .flatten()
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(60)
                    .clamp(15, 86400);
                tokio::time::sleep(Duration::from_secs(seconds)).await;
            }
        });
        tokio::spawn(async move {
            loop {
                app.poller.sync_all_jira(&app).await;
                crate::automation::poll_jira(&app).await;
                let seconds = app
                    .db
                    .config_value("jira_poll_interval").await
                    .ok()
                    .flatten()
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(120)
                    .clamp(30, 86400);
                tokio::time::sleep(Duration::from_secs(seconds)).await;
            }
        });
    }

    /// What moved for a repository's pull requests since it was last seen, remembering what was
    /// seen. The first sight of a repository seeds it: nothing it shows is news. A pull request
    /// already recorded as merged (by a webhook, during the poll) is left as it is.
    fn observe(&mut self, repo: &str, seen: &[(String, String)]) -> Vec<(usize, Transition)> {
        let first = !self.seeded.contains(repo);
        let mut transitions = Vec::new();
        for (index, (key, state)) in seen.iter().enumerate() {
            let previous = self.pr_states.get(key).map(String::as_str);
            if previous == Some("MERGED") {
                continue;
            }
            if !first {
                let transition = match state.as_str() {
                    "MERGED" => Some(Transition::Merged),
                    "OPEN" if previous.is_none() => Some(Transition::Opened),
                    "CLOSED" if previous != Some("CLOSED") => Some(Transition::Closed),
                    _ => None,
                };
                transitions.extend(transition.map(|transition| (index, transition)));
            }
            self.pr_states.insert(key.clone(), state.clone());
        }
        self.seeded.insert(repo.to_owned());
        transitions
    }

    /// Records a merge; `true` when it was not already recorded.
    fn merged(&mut self, key: &str) -> bool {
        self.pr_states
            .insert(key.to_owned(), "MERGED".into())
            .as_deref()
            != Some("MERGED")
    }
}

/// A project's open pull requests, with the recent closed window for merge detection.
async fn sync_project(app: &AppState, generation: &Generation, project: Project) {
    let id = project.id.clone();
    let repo = project.repo.clone();
    let previous = app.db.pr_snapshot(&id, "open", None).await.ok().flatten();
    if repo.is_empty() {
        let changed = snapshot_changed(previous.as_ref(), &[], None);
        let _ = app.db.set_pr_snapshot(&id, &PrSnapshot::taken(Vec::new(), None)).await;
        if changed {
            app.publish(crate::Event::Sync { scope: Some("prs"), project_id: Some(id.to_string()) });
        }
        return;
    }
    let jira_key = project.jira_project_key.as_str();
    let since = previous
        .as_ref()
        .and_then(PrSnapshot::synced_at)
        .map(|v| (v - ChronoDuration::seconds(60)).to_rfc3339());
    let result = tokio::join!(
        github::fetch_prs(&repo, "open", None, true, jira_key),
        github::fetch_recent_closed(&repo, since.as_deref())
    );
    if !generation.current(app, &id).await {
        return;
    }
    let changed = match result {
        (Ok(mut open), Ok(closed)) => {
            let me = github::cached_login().await;
            let timeline = if open
                .iter()
                .any(|pr| pr.get("category").and_then(Value::as_str) == Some("review"))
            {
                if let Some(me) = me.as_deref() {
                    github::review_requested_at(&repo, me)
                        .await
                        .unwrap_or_default()
                } else {
                    HashMap::new()
                }
            } else {
                HashMap::new()
            };
            if !generation.current(app, &id).await {
                return;
            }
            let mut numbers = Vec::new();
            for pr in &mut open {
                let number = pr.get("number").and_then(Value::as_i64).unwrap_or(0);
                numbers.push(number);
                if let Some(timestamp) = timeline.get(&number) {
                    pr.as_object_mut()
                        .unwrap()
                        .insert("requestedAt".into(), json!(timestamp));
                    let _ = app
                        .db
                        .mark_review_requested(&format!("{repo}#{number}"), timestamp).await;
                }
            }
            record_lifecycle(app, &project, &open, &closed).await;
            // After `requestedAt` is merged in: a re-request is a new event by its time.
            crate::automation::observe_prs(app, &project, &open, &closed, me.as_deref()).await;
            let lean: Vec<Value> = open.iter().map(|pr| github::lean(pr, &repo)).collect();
            let _ = app.db.prune_review_state(&repo, &numbers).await;
            let changed = snapshot_changed(previous.as_ref(), &lean, None);
            let _ = app.db.set_pr_snapshot(&id, &PrSnapshot::taken(lean, None)).await;
            changed
        }
        (Err(error), _) | (_, Err(error)) => {
            let message = error.to_string();
            let prs = previous.as_ref().map(|v| v.prs.clone()).unwrap_or_default();
            if previous.as_ref().and_then(|v| v.error.as_deref()) != Some(&message) {
                event(app, "sync_failed", json!({"repo":repo,"error":message})).await;
            }
            let changed = snapshot_changed(previous.as_ref(), &prs, Some(&message));
            let _ = app.db.set_pr_snapshot(&id, &PrSnapshot::taken(prs, Some(message))).await;
            changed
        }
    };
    // `lastSynced` moved either way; the app hears only about PRs or an error that changed.
    if changed {
        app.publish(crate::Event::Sync { scope: Some("prs"), project_id: Some(id.to_string()) });
    }
}

/// A project's pull requests in one other state, as a recent window.
async fn sync_pr_scope(app: &AppState, generation: &Generation, project: Project, state: &str) {
    let id = project.id.as_str();
    let repo = project.repo.as_str();
    let previous = app
        .db
        .pr_snapshot(id, state, Some(&crate::db::project_identity(&project))).await
        .ok()
        .flatten();
    let jira = project.jira_project_key.as_str();
    let (prs, error) = match github::fetch_prs(repo, state, Some(30), true, jira).await {
        Ok(prs) => (prs.iter().map(|p| github::lean(p, repo)).collect::<Vec<Value>>(), None),
        Err(error) => (
            previous.as_ref().map(|v| v.prs.clone()).unwrap_or_default(),
            Some(error.to_string()),
        ),
    };
    if !generation.current(app, id).await {
        return;
    }
    let changed = snapshot_changed(previous.as_ref(), &prs, error.as_deref());
    let _ = app.db.set_pr_scope_snapshot(&project, state, &PrSnapshot::taken(prs, error)).await;
    if changed {
        app.publish(crate::Event::Sync { scope: Some("prs"), project_id: Some(id.to_string()) });
    }
}

/// A project's sprint board: the active sprint's items under the project's board query.
async fn sync_board(app: &AppState, generation: &Generation, project: &Project) {
    let project_id = project.id.as_str();
    let id = format!("board:{project_id}");
    let jira_key = project.jira_project_key.as_str();
    let clause = app
        .db
        .config_value(&format!("board_query_{project_id}")).await
        .ok()
        .flatten()
        .unwrap_or_default();
    let sprint = match crate::jira::active_sprint(jira_key).await {
        Ok(sprint) => sprint,
        Err(error) => {
            if !generation.current(app, project_id).await {
                return;
            }
            let previous = app.db.jira_snapshot(&id).await.ok().flatten();
            let mut snapshot = previous
                .clone()
                .unwrap_or_else(|| json!({"items":[],"jql":"","meta":null}));
            snapshot["meta"] = json!({"sprint":snapshot["sprint"],"query":snapshot["query"],"columns":snapshot["columns"]});
            snapshot["error"] = json!(error.to_string());
            snapshot["lastSynced"] = json!(now());
            let changed = jira_snapshot_changed(previous.as_ref(), &snapshot);
            let _ = app.db.set_jira_snapshot(&id, &snapshot).await;
            if changed {
                app.publish(crate::Event::JiraSync { id: id.to_string() });
            }
            return;
        }
    };
    if !generation.current(app, project_id).await {
        return;
    }
    let Some(sprint_id) = sprint.get("id").and_then(Value::as_i64) else {
        let previous = app.db.jira_snapshot(&id).await.ok().flatten();
        let snapshot = json!({"items":[],"jql":"","lastSynced":now(),"error":null,"meta":{"sprint":null,"query":clause,"columns":null}});
        let changed = jira_snapshot_changed(previous.as_ref(), &snapshot);
        let _ = app.db.set_jira_snapshot(&id, &snapshot).await;
        if changed {
            app.publish(crate::Event::JiraSync { id: id.to_string() });
        }
        return;
    };
    let columns = if let Some(board) = sprint["boardId"].as_i64() {
        crate::jira::board_columns(app, board)
            .await
            .unwrap_or(Value::Null)
    } else {
        Value::Null
    };
    let jql = format!(
        "sprint = {sprint_id}{} ORDER BY priority DESC, key ASC",
        if clause.is_empty() {
            String::new()
        } else {
            format!(" AND ({clause})")
        }
    );
    write_jira(
        app,
        generation,
        &id,
        &jql,
        jira_limit(app, "board_limit", 200).await,
        Some(json!({"sprint":sprint,"query":clause,"columns":columns})),
    )
    .await;
}

/// Runs a Jira search and stores it as the snapshot `id`, with `meta` beside the items.
async fn write_jira(
    app: &AppState,
    generation: &Generation,
    id: &str,
    jql: &str,
    limit: usize,
    meta: Option<Value>,
) {
    let project_id = id.strip_prefix("board:").unwrap_or(id);
    if !generation.current(app, project_id).await {
        return;
    }
    let previous = app.db.jira_snapshot(id).await.ok().flatten();
    let snapshot = if jql.is_empty() {
        json!({"items":[],"jql":"","lastSynced":now(),"error":null,"meta":meta})
    } else {
        match crate::jira::search_jira(jql, limit).await {
            Ok(items) => {
                json!({"items":items,"jql":jql,"lastSynced":now(),"error":null,"meta":meta})
            }
            Err(error) => {
                let message = error.to_string();
                if previous
                    .as_ref()
                    .and_then(|v| v.get("error"))
                    .and_then(Value::as_str)
                    != Some(&message)
                {
                    event(
                        app,
                        "jira_sync_failed",
                        json!({"id":id,"jql":jql,"error":message}),
                    ).await;
                }
                json!({"items":previous.as_ref().and_then(|v|v.get("items").cloned()).unwrap_or_else(||json!([])),"jql":jql,"lastSynced":now(),"error":message,"meta":meta})
            }
        }
    };
    if !generation.current(app, project_id).await {
        return;
    }
    let changed = jira_snapshot_changed(previous.as_ref(), &snapshot);
    let _ = app.db.set_jira_snapshot(id, &snapshot).await;
    if changed {
        app.publish(crate::Event::JiraSync { id: id.to_string() });
    }
}

/// Tells the engine what a sync saw of a repository, then the activity log and the automations
/// what moved: openings and closings first, then merges, each in the order fetched.
async fn record_lifecycle(app: &AppState, project: &Project, open: &[Value], closed: &[Value]) {
    let repo = project.repo.as_str();
    let prs: Vec<&Value> = open.iter().chain(closed).collect();
    let number = |pr: &Value| pr["number"].as_i64().unwrap_or(0);
    let seen = prs
        .iter()
        .map(|pr| (pr_key(repo, number(pr)), pr["state"].as_str().unwrap_or("").to_owned()))
        .collect();
    let transitions = app.poller.observe(repo, seen).await;
    for (index, transition) in &transitions {
        let kind = match transition {
            Transition::Opened => "pr_opened",
            Transition::Closed => "pr_closed",
            Transition::Merged => continue,
        };
        let pr = prs[*index];
        event(app, kind, json!({"repo":repo,"pr":{"number":number(pr),"title":pr["title"],"url":pr["url"]}})).await;
    }
    for (index, transition) in &transitions {
        if *transition == Transition::Merged {
            dispatch_merge(app, project, prs[*index]).await;
        }
    }
}

async fn dispatch_merge(app: &AppState, project: &Project, pr: &Value) {
    event(app, "pr_merged", json!({"repo":project.repo,"pr":{"number":pr["number"],"title":pr["title"],"url":pr["url"]}})).await;
    crate::automation::merged(app, project, pr).await;
}

/// A line of activity, logged and told.
async fn event(app: &AppState, kind: &str, payload: Value) {
    if let Ok(event) = app.db.add_event(kind, &payload).await {
        app.publish(crate::Event::Activity { event });
    }
}

/// Whether a fetched PR list, or the error that stood in for one, differs from the stored
/// snapshot (`PrSnapshot::differs`); no stored snapshot is a change.
fn snapshot_changed(previous: Option<&PrSnapshot>, prs: &[Value], error: Option<&str>) -> bool {
    previous.is_none_or(|stored| stored.differs(prs, error))
}

/// Whether a board's fetched items, query, error or sprint details differ from the stored
/// snapshot, which is read back flattened: its `meta` keys sit beside `items`. `lastSynced` alone
/// is not a change the app needs to hear about.
fn jira_snapshot_changed(previous: Option<&Value>, next: &Value) -> bool {
    let Some(previous) = previous else {
        return true;
    };
    let text = |value: &Value, key: &str| value.get(key).and_then(Value::as_str).map(str::to_owned);
    if previous.get("items") != next.get("items")
        || text(previous, "jql").unwrap_or_default() != text(next, "jql").unwrap_or_default()
        || text(previous, "error") != text(next, "error")
    {
        return true;
    }
    match next.get("meta") {
        Some(Value::Object(meta)) => meta
            .iter()
            .any(|(key, value)| previous.get(key).unwrap_or(&Value::Null) != value),
        _ => false,
    }
}

#[cfg(test)]
mod snapshot_tests {
    use super::*;

    /// The sync engine end to end, with `gh` scripted: a repository with no open pull requests,
    /// synced twice. The first sync is news; the second changes nothing and says nothing.
    #[tokio::test]
    async fn a_sync_publishes_once_for_the_same_pull_requests() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let mut fields = serde_json::Map::new();
        fields.insert("name".into(), json!("P"));
        fields.insert("repo".into(), json!("owner/repo"));
        fields.insert("workspace".into(), json!("/tmp/none"));
        let project = app.db.add_project(&fields).await.unwrap();
        let mut events = app.events.subscribe();
        let runner = Arc::new(cli::ScriptedRunner::new().on("gh", |args| {
            args.iter().any(|arg| arg == "graphql").then(|| {
                Ok(br#"{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#.to_vec())
            })
        }));
        cli::scoped(runner.clone(), app.poller.sync_project(&app, project.clone())).await;
        let mut syncs = 0;
        while let Ok(event) = events.try_recv() {
            if event["type"] == "sync" {
                syncs += 1;
                assert_eq!(event["projectId"], project.id);
            }
        }
        assert_eq!(syncs, 1, "the first sync is news");
        assert!(runner.asked.lock().unwrap().iter().all(|asked| asked.program == "gh"));
        cli::scoped(runner, app.poller.sync_project(&app, project)).await;
        while let Ok(event) = events.try_recv() {
            assert_ne!(event["type"], "sync", "nothing changed, so nothing to say");
        }
    }

    #[test]
    fn a_jira_snapshot_changes_with_its_items_error_or_sprint_details() {
        let stored = json!({"items":[{"key":"A-1"}],"jql":"sprint = 1","lastSynced":"t","error":null,"sprint":{"id":1},"query":"","columns":null});
        let same = json!({"items":[{"key":"A-1"}],"jql":"sprint = 1","lastSynced":"t2","error":null,"meta":{"sprint":{"id":1},"query":"","columns":null}});
        assert!(!jira_snapshot_changed(Some(&stored), &same));
        assert!(jira_snapshot_changed(None, &same));
        let moved = json!({"items":[{"key":"A-2"}],"jql":"sprint = 1","lastSynced":"t2","error":null,"meta":{"sprint":{"id":1},"query":"","columns":null}});
        assert!(jira_snapshot_changed(Some(&stored), &moved));
        let failed = json!({"items":[{"key":"A-1"}],"jql":"sprint = 1","lastSynced":"t2","error":"acli: offline","meta":{"sprint":{"id":1},"query":"","columns":null}});
        assert!(jira_snapshot_changed(Some(&stored), &failed));
        let new_sprint = json!({"items":[{"key":"A-1"}],"jql":"sprint = 1","lastSynced":"t2","error":null,"meta":{"sprint":{"id":2},"query":"","columns":null}});
        assert!(jira_snapshot_changed(Some(&stored), &new_sprint));
    }

    #[test]
    fn first_snapshot_is_a_change_and_a_stored_one_is_asked() {
        assert!(snapshot_changed(None, &[], None));
        let prs = vec![json!({"number":1,"title":"a"})];
        let stored = PrSnapshot::taken(prs.clone(), None);
        assert!(!snapshot_changed(Some(&stored), &prs, None));
        assert!(snapshot_changed(Some(&stored), &prs, Some("gh: offline")));
        assert!(snapshot_changed(Some(&stored), &[], None));
    }

    #[test]
    fn the_first_sight_of_a_repository_seeds_it_and_later_moves_are_news() {
        let mut engine = Engine::default();
        let seen = |pairs: &[(&str, &str)]| -> Vec<(String, String)> {
            pairs.iter().map(|(key, state)| (key.to_string(), state.to_string())).collect()
        };
        assert!(engine.observe("o/r", &seen(&[("o/r#1", "OPEN"), ("o/r#2", "CLOSED")])).is_empty());
        let moved = engine.observe("o/r", &seen(&[("o/r#1", "MERGED"), ("o/r#2", "CLOSED"), ("o/r#3", "OPEN")]));
        assert_eq!(moved, vec![(0, Transition::Merged), (2, Transition::Opened)]);
        // A recorded merge stays merged, and a closing is told once.
        let again = engine.observe("o/r", &seen(&[("o/r#1", "MERGED"), ("o/r#3", "CLOSED")]));
        assert_eq!(again, vec![(1, Transition::Closed)]);
        assert!(engine.observe("o/r", &seen(&[("o/r#3", "CLOSED")])).is_empty());
        // Another repository starts unseeded.
        assert!(engine.observe("o/other", &seen(&[("o/other#1", "MERGED")])).is_empty());
    }

    #[test]
    fn a_merge_is_news_once_whoever_tells_it() {
        let mut engine = Engine::default();
        let open = vec![("o/r#1".to_string(), "OPEN".to_string())];
        assert!(engine.observe("o/r", &open).is_empty(), "seeded");
        assert!(engine.merged("o/r#1"), "the webhook is first");
        assert!(!engine.merged("o/r#1"), "a second webhook is not");
        let merged = vec![("o/r#1".to_string(), "MERGED".to_string())];
        assert!(engine.observe("o/r", &merged).is_empty(), "the poll that follows has nothing to add");
    }

    /// GitHub syncs past the fourth wait for a lane, a board takes none, a waiting sync whose
    /// project was invalidated is dropped when its turn comes, and every key is released. Driven
    /// message by message on a single thread, so the counts are exact.
    #[tokio::test]
    async fn github_syncs_take_four_lanes_and_the_rest_wait_their_turn() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let runner: Arc<dyn cli::CommandRunner> = Arc::new(cli::ScriptedRunner::new().on("gh", |args| {
            args.iter().any(|arg| arg == "graphql").then(|| {
                Ok(br#"{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#.to_vec())
            })
        }));
        let mut engine = Engine::default();
        let mut tasks = JoinSet::new();
        let mut hears = Vec::new();
        for n in 0..6 {
            let mut fields = serde_json::Map::new();
            fields.insert("name".into(), json!(format!("P{n}")));
            fields.insert("repo".into(), json!(format!("owner/repo{n}")));
            fields.insert("workspace".into(), json!("/tmp/none"));
            let project = app.db.add_project(&fields).await.unwrap();
            let (done, heard) = oneshot::channel();
            hears.push(heard);
            let run = Msg::Run { app: app.clone(), job: Job::Project(project), runner: Some(runner.clone()), done };
            engine.handle(run, &mut tasks);
        }
        assert_eq!((engine.github_running, engine.waiting.len(), engine.claimed.len()), (4, 2, 6));
        let board = app.db.projects().await.unwrap().remove(0);
        let (done, board_heard) = oneshot::channel();
        let run = Msg::Run { app: app.clone(), job: Job::Board(board), runner: Some(runner.clone()), done };
        engine.handle(run, &mut tasks);
        assert_eq!((engine.github_running, engine.waiting.len()), (4, 2), "a board takes no lane");
        let fifth = engine.waiting[0].job.project().id.clone();
        let (ack, acked) = oneshot::channel();
        engine.handle(Msg::Invalidate(fifth, ack), &mut tasks);
        acked.await.unwrap();
        let mut joined = 0;
        while let Some(result) = tasks.join_next_with_id().await {
            let (id, done) = result.expect("a sync does not panic");
            engine.finished(id, &mut tasks);
            let _ = done.send(());
            joined += 1;
            assert!(engine.github_running <= GH_LANES);
        }
        assert_eq!(joined, 6, "four, then the sixth, and the board; the stale fifth never ran");
        assert_eq!((engine.github_running, engine.waiting.len(), engine.claimed.len()), (0, 0, 0));
        for (n, heard) in hears.into_iter().enumerate() {
            assert_eq!(heard.await.is_ok(), n != 4, "request {n}");
        }
        board_heard.await.unwrap();
    }

    /// Two requests for the same sync at once run it once; a request after it finishes runs it
    /// again. Measured in the GraphQL calls the scripted `gh` answered: one sync's worth first.
    #[tokio::test]
    async fn the_same_sync_asked_for_twice_at_once_runs_once() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let mut fields = serde_json::Map::new();
        fields.insert("name".into(), json!("P"));
        fields.insert("repo".into(), json!("owner/repo"));
        fields.insert("workspace".into(), json!("/tmp/none"));
        let project = app.db.add_project(&fields).await.unwrap();
        let runner = Arc::new(cli::ScriptedRunner::new().on("gh", |args| {
            args.iter().any(|arg| arg == "graphql").then(|| {
                Ok(br#"{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#.to_vec())
            })
        }));
        let queries = |runner: &cli::ScriptedRunner| {
            runner.asked.lock().unwrap().iter().filter(|asked| asked.args.iter().any(|arg| arg == "graphql")).count()
        };
        cli::scoped(runner.clone(), app.poller.sync_project(&app, project.clone())).await;
        let one_sync = queries(&runner);
        assert!(one_sync > 0, "a sync asks GitHub");
        cli::scoped(
            runner.clone(),
            futures_util::future::join(
                app.poller.sync_project(&app, project.clone()),
                app.poller.sync_project(&app, project.clone()),
            ),
        )
        .await;
        assert_eq!(queries(&runner), 2 * one_sync, "the second request found the first running");
        cli::scoped(runner.clone(), app.poller.sync_project(&app, project)).await;
        assert_eq!(queries(&runner), 3 * one_sync, "a request after the first finished is a new sync");
    }
}

async fn jira_limit(app: &AppState, key: &str, default: usize) -> usize {
    app.db
        .config_value(key).await
        .ok()
        .flatten()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
        .max(1)
}
fn now() -> String {
    Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

