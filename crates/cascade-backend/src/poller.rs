//! The sync engine: GitHub and Jira synchronization into the `data.db` snapshots, and the
//! lifecycle and merge automation that follows from what a sync sees.
//!
//! The engine is one task (`Engine`) that owns all of its state: which syncs are running, each
//! project's invalidation generation, the last state each pull request was seen in, and the
//! repositories seeded. `Poller` is its handle, and every method is a message. A sync itself is a
//! plain async function (`sync_project`, `sync_pr_scope`, `sync_board`) the engine spawns with the
//! generation it started under; the same sync asked for while it runs is not started again, and
//! GitHub syncs run at most `GH_LANES` at a time.
//!
//! The engine also keeps each upstream's breaker (`Breaker`). A sync reports whether GitHub or
//! Jira answered; after one that did not, nothing in the background asks that service again until
//! a wait has passed, each failure in a row doubling it, and the app hears once that the service
//! is unreachable and once that it is back, rather than an error for every project.
//!
//! And it keeps the projects GitHub said changed (`Poller::changed`, a forwarded webhook event)
//! until their sync: events are gathered for a moment so a burst is one query, a project is not
//! synced again within the poll interval of its last sync however many events arrive, with one
//! sync at the end of that gap for whatever came during it, and nothing is synced on an event's
//! word while GitHub is failing or the hour's rate allowance is nearly spent.

use std::{
    collections::{HashMap, HashSet, VecDeque},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

use chrono::{Duration as ChronoDuration, Utc};
use serde_json::{json, Value};
use tokio::{
    sync::{mpsc, oneshot},
    task::{Id, JoinSet},
};

use crate::{cli, github, AppState};
use crate::{Fault, PrSnapshot, Project};

/// How many projects sync against GitHub at once. `sync_all` asks for every project together,
/// and each runs two or three `gh` calls; GitHub rate-limits such a burst, and a request the
/// user is waiting on (an issue lookup, a search) would otherwise queue behind it. The bound sits
/// here, on the burst, so those requests never wait for it.
const GH_LANES: usize = 4;

/// A service the syncs ask.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Upstream {
    GitHub,
    Jira,
}

impl Upstream {
    const ALL: [Upstream; 2] = [Upstream::GitHub, Upstream::Jira];

    /// Its name in the `upstream` event and `GET /api/upstreams`.
    pub fn name(self) -> &'static str {
        match self {
            Upstream::GitHub => "github",
            Upstream::Jira => "jira",
        }
    }
}

/// Why a sync is asked for, which decides what may turn it away.
enum Ask {
    /// Someone asked for it by name (a refresh): it runs whatever came before.
    Now,
    /// Nobody is waiting on it (an automation's loop, a read that found a board stale): it is
    /// turned away while its upstream is failing.
    Background,
    /// GitHub said these projects changed (`Engine::flush`): as `Background`, and if GitHub
    /// then cannot be reached, the projects go back to waiting for their sync, since the event
    /// that asked for it is not coming again.
    Event,
    /// Someone is looking at these projects' pull requests (a read marked `look`), and wants
    /// them no older than `pace`: as `Background`, and a project whose last sync started less
    /// than `pace` ago is left out. The pace is kept from the start of a sync, which the engine
    /// remembers (`tried`), not from the stamp its snapshot got when it finished: someone who
    /// keeps looking reads once an interval, and must find a sync due each time however long
    /// the last one took, and a failing repository must not be asked again on every look. Only
    /// for a project the engine remembers no sync of, as after a restart, does the snapshot's
    /// own age (`synced`, by project id, as the read saw it) stand in.
    Stale {
        pace: Duration,
        synced: HashMap<String, Duration>,
    },
}

/// The wait after a first failure, and the longest wait failures in a row grow it to.
const FIRST_WAIT: Duration = Duration::from_secs(30);
const LONGEST_WAIT: Duration = Duration::from_secs(15 * 60);

/// One upstream's breaker. While it waits, a background sync of that upstream is not started:
/// the service is known to be failing, and each attempt would only spend a timeout to learn it
/// again.
#[derive(Default)]
struct Breaker {
    /// Failures in a row; none is a service that answers.
    failures: u32,
    retry_at: Option<Instant>,
}

impl Breaker {
    fn waiting(&self, now: Instant) -> bool {
        self.retry_at.is_some_and(|at| now < at)
    }

    /// The service did not answer. The wait doubles with each failure in a row, and `spread`
    /// (0 to 1) lengthens it by up to a fifth, so everything that failed together in one outage
    /// does not come back together. A failure told while it already waits is the same failure
    /// again (two syncs that were running together, a refresh someone asked for meanwhile) and
    /// changes nothing. Answers whether this is the failure that took it down.
    fn failed(&mut self, now: Instant, spread: f64) -> bool {
        if self.waiting(now) {
            return false;
        }
        self.failures += 1;
        let doubled = FIRST_WAIT.saturating_mul(1 << (self.failures - 1).min(10));
        let wait = doubled.min(LONGEST_WAIT);
        self.retry_at = Some(now + wait + wait.mul_f64(spread.clamp(0.0, 1.0) / 5.0));
        self.failures == 1
    }

    /// The service answered. Answers whether it had been down.
    fn reached(&mut self) -> bool {
        let was_down = self.failures > 0;
        *self = Self::default();
        was_down
    }
}

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
        ask: Ask,
        runner: Option<Arc<dyn cli::CommandRunner>>,
        done: oneshot::Sender<()>,
    },
    /// How an upstream answered a sync; answers `Some(reachable)` when that changed whether it
    /// is reachable, which is the caller's to publish.
    Outcome {
        app: AppState,
        upstream: Upstream,
        reached: bool,
        reply: oneshot::Sender<Option<bool>>,
    },
    /// Asks for each upstream that is failing, with the seconds until it may be asked again.
    Health {
        reply: oneshot::Sender<Vec<(Upstream, u64)>>,
    },
    /// GitHub said a project's pull requests changed (a forwarded event): sync it once events
    /// have had `gather` to collect, and no sooner than `pace` after its last sync started.
    Changed {
        app: AppState,
        project: Project,
        gather: Duration,
        pace: Duration,
        runner: Option<Arc<dyn cli::CommandRunner>>,
    },
    /// A wait `Changed` set is over: sync the changed projects that are due.
    Flush(AppState),
    /// A sync an event asked for could not reach GitHub for these projects: they wait again,
    /// each unless it was edited since the sync started under the generation beside it.
    Unanswered { app: AppState, projects: Vec<(Project, u64)> },
    /// What a batched query said is left of the allowance.
    Budget(github::Budget),
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
    /// Projects' open pull requests, with each one's recent closed window for merge detection,
    /// fetched together.
    Projects(Vec<Project>),
    /// A project's pull requests in another state (`merged`, `closed`).
    Scope(Project, String),
    /// A project's sprint board.
    Board(Project),
}

impl Job {
    fn projects(&self) -> &[Project] {
        match self {
            Job::Projects(projects) => projects,
            Job::Scope(project, _) | Job::Board(project) => std::slice::from_ref(project),
        }
    }

    /// Whether it talks to GitHub, and so takes one of the lanes.
    fn github(&self) -> bool {
        !matches!(self, Job::Board(_))
    }

    fn upstream(&self) -> Upstream {
        if self.github() { Upstream::GitHub } else { Upstream::Jira }
    }

    /// What the same sync of `project`, asked for again while this one runs, is coalesced on.
    /// The generation is part of it: an invalidated project's sync is a new sync.
    fn key(&self, project: &Project, generation: u64) -> String {
        match self {
            Job::Projects(_) => format!("pr:{}:{}:{generation}", project.id, project.repo),
            Job::Scope(_, state) => {
                format!("scope:{}:{state}:{}:{generation}", project.id, project.repo)
            }
            Job::Board(_) => format!("board:{}:{generation}", project.id),
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
        // The counter is read after the lookup: an invalidate that lands during it counts.
        app.db.project(id).await.ok().flatten().is_some()
            && self.counter.load(Ordering::SeqCst) == self.started
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
    /// running, or when `ask` lets the engine turn it away. The sync runs under the caller's
    /// command runner, so a scripted test covers it.
    async fn run(&self, app: &AppState, job: Job, ask: Ask) {
        let (done, finished) = oneshot::channel();
        let message = Msg::Run {
            app: app.clone(),
            job,
            ask,
            runner: cli::inherited(),
            done,
        };
        if self.tx.send(message).is_ok() {
            let _ = finished.await;
        }
    }

    /// Syncs every project's pull requests now: what a refresh asks for.
    pub async fn sync_all(&self, app: &AppState) {
        let Ok(projects) = app.db.projects().await else {
            return;
        };
        if !projects.is_empty() {
            self.run(app, Job::Projects(projects), Ask::Now).await;
        }
    }

    /// Syncs `projects` together in the background, leaving out any whose sync is already
    /// running; nothing is asked while GitHub is failing.
    pub async fn sync_projects(&self, app: &AppState, projects: Vec<Project>) {
        if !projects.is_empty() {
            self.run(app, Job::Projects(projects), Ask::Background).await;
        }
    }

    /// Syncs those of `projects` whose last sync started `pace` ago or longer: what a read
    /// asks for behind itself. Each comes with the age of its snapshot as the read saw it, none
    /// for one never synced, which stands in where the engine remembers no sync (`Ask::Stale`).
    pub async fn sync_stale(
        &self,
        app: &AppState,
        projects: Vec<(Project, Option<Duration>)>,
        pace: Duration,
    ) {
        if projects.is_empty() {
            return;
        }
        let synced = projects
            .iter()
            .filter_map(|(project, age)| Some((project.id.clone(), (*age)?)))
            .collect();
        let projects = projects.into_iter().map(|(project, _)| project).collect();
        self.run(app, Job::Projects(projects), Ask::Stale { pace, synced }).await;
    }

    pub async fn sync_project(&self, app: &AppState, project: Project) {
        self.run(app, Job::Projects(vec![project]), Ask::Now).await;
    }

    /// A project's pull requests in another state, for a read that found them stale.
    pub async fn sync_pr_scope(&self, app: &AppState, project: Project, state: &str) {
        self.run(app, Job::Scope(project, state.to_owned()), Ask::Background).await;
    }

    pub async fn sync_all_jira(&self, app: &AppState) {
        if let Ok(projects) = app.db.projects().await {
            for project in projects {
                self.sync_board(app, &project).await;
            }
        }
    }

    /// Syncs a project's board now: what a refresh, or a change just made to it, asks for.
    pub async fn sync_board(&self, app: &AppState, project: &Project) {
        self.run(app, Job::Board(project.clone()), Ask::Now).await;
    }

    /// Syncs a project's board for a read that found it stale; not while Jira is failing.
    pub async fn sync_stale_board(&self, app: &AppState, project: &Project) {
        self.run(app, Job::Board(project.clone()), Ask::Background).await;
    }

    /// GitHub said a project's pull requests changed (a forwarded webhook event): its snapshot
    /// is synced without anybody looking at it, gathered with the other events of the moment
    /// and no more often than the poll interval (see the module's last paragraph).
    pub async fn changed(&self, app: &AppState, project: Project) {
        let pace = Duration::from_secs(poll_interval(app).await);
        self.changed_within(app, project, GATHER, pace);
    }

    fn changed_within(&self, app: &AppState, project: Project, gather: Duration, pace: Duration) {
        let message = Msg::Changed {
            app: app.clone(),
            project,
            gather,
            pace,
            runner: cli::inherited(),
        };
        let _ = self.tx.send(message);
    }

    fn flush(&self, app: &AppState) {
        let _ = self.tx.send(Msg::Flush(app.clone()));
    }

    fn unanswered(&self, app: &AppState, projects: Vec<(Project, u64)>) {
        let _ = self.tx.send(Msg::Unanswered { app: app.clone(), projects });
    }

    fn budget(&self, budget: github::Budget) {
        let _ = self.tx.send(Msg::Budget(budget));
    }

    /// The upstreams that are failing, each with the seconds until it may be asked again.
    pub async fn unreachable(&self) -> Vec<(Upstream, u64)> {
        let (reply, health) = oneshot::channel();
        if self.tx.send(Msg::Health { reply }).is_err() {
            return Vec::new();
        }
        health.await.unwrap_or_default()
    }

    /// Tells the engine how an upstream answered; answers `Some(reachable)` when that changed.
    async fn outcome(&self, app: &AppState, upstream: Upstream, reached: bool) -> Option<bool> {
        let (reply, changed) = oneshot::channel();
        let message = Msg::Outcome { app: app.clone(), upstream, reached, reply };
        if self.tx.send(message).is_err() {
            return None;
        }
        changed.await.ok().flatten()
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
            dispatch_merge(app, project, pr, false).await;
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

/// How long an event waits for others before its sync. GitHub sends several for one action (a
/// push to a pull request is a `synchronize`, often with a review request beside it), and
/// projects that change together are one query.
const GATHER: Duration = Duration::from_secs(2);

/// How soon a project whose sync is still running is looked at again, for an event that came
/// while it ran: the running sync may have read GitHub before the change.
const RUNNING_RECHECK: Duration = Duration::from_secs(5);

/// What is left of GitHub's hourly allowance, as of the last batched query.
#[derive(Clone, Copy)]
struct Budget {
    remaining: u64,
    limit: u64,
    reset_at: Instant,
}

impl Budget {
    /// Under a fifth left before the hour turns. What nobody is waiting on stops there, and
    /// leaves the rest to what a person asks for, in the app and with `gh` outside it.
    fn spent(&self, now: Instant) -> bool {
        now < self.reset_at && self.remaining * 5 < self.limit
    }
}

/// The engine's state, owned by its task. Nothing else sees it.
#[derive(Default)]
struct Engine {
    started: bool,
    generations: HashMap<String, Arc<AtomicU64>>,
    /// The keys of the syncs running or waiting for a lane, one per project a sync covers.
    claimed: HashSet<String>,
    /// GitHub syncs waiting for a lane, in the order asked.
    waiting: VecDeque<Spawn>,
    github_running: usize,
    /// Each running task's keys, and whether it holds a lane.
    running: HashMap<Id, (Vec<String>, bool)>,
    /// The last state each pull request was seen in, by `pr_key`.
    pr_states: HashMap<String, String>,
    /// Repositories seen at least once: their first sight shows no news.
    seeded: HashSet<String>,
    /// When each project's pull requests were last asked for, by project id.
    tried: HashMap<String, Instant>,
    breakers: HashMap<Upstream, Breaker>,
    /// The projects GitHub said changed, waiting for their sync, by id.
    pending: HashMap<String, Project>,
    /// The gap kept between an event's sync and its project's last one, and the runner the
    /// sync runs under: the last event's.
    pending_pace: Duration,
    pending_runner: Option<Arc<dyn cli::CommandRunner>>,
    /// When `pending` is looked at next: every wait that is set and not yet over.
    flushes: Vec<Instant>,
    budget: Option<Budget>,
}

/// A sync the engine has accepted and will spawn.
struct Spawn {
    app: AppState,
    job: Job,
    runner: Option<Arc<dyn cli::CommandRunner>>,
    /// The generation each of the job's projects started under, in the job's order.
    generations: Vec<Generation>,
    keys: Vec<String>,
    /// Someone is looking at what it syncs (`Ask::Stale`): the app hears when each project is
    /// synced, even one whose pull requests did not change, so what is shown takes the new
    /// stamp. The read the app makes on hearing it is not a look, and starts nothing.
    read: bool,
    /// An event asked for it (`Ask::Event`): a project GitHub could not answer for is set to
    /// wait again.
    event: bool,
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
                // An edited project is a new one to a stale read: its last try was of the old.
                self.tried.remove(&id);
                // And an event waiting for its sync named the project as it was.
                self.pending.remove(&id);
                let _ = ack.send(());
            }
            Msg::Run {
                app,
                mut job,
                ask,
                runner,
                done,
            } => {
                let mut generations = Vec::new();
                let mut keys = Vec::new();
                let mut left_out = HashSet::new();
                let now = Instant::now();
                let waiting = self.breakers.get(&job.upstream()).is_some_and(|b| b.waiting(now));
                if waiting && !matches!(ask, Ask::Now) {
                    // Its upstream is failing; `done` drops, and the caller does not wait.
                    return;
                }
                for (index, project) in job.projects().iter().enumerate() {
                    if let (Job::Projects(_), Ask::Stale { pace, synced }) = (&job, &ask) {
                        let since = self
                            .tried
                            .get(&project.id)
                            .map(|at| now.duration_since(*at))
                            .or_else(|| synced.get(&project.id).copied());
                        if since.is_some_and(|since| since < *pace) {
                            left_out.insert(index);
                            continue;
                        }
                    }
                    let counter = self.generation(&project.id);
                    let generation = Generation {
                        started: counter.load(Ordering::SeqCst),
                        counter,
                    };
                    let key = job.key(project, generation.started);
                    if self.claimed.insert(key.clone()) {
                        if matches!(job, Job::Projects(_)) {
                            self.tried.insert(project.id.clone(), now);
                        }
                        generations.push(generation);
                        keys.push(key);
                    } else {
                        left_out.insert(index);
                    }
                }
                if keys.is_empty() {
                    // Running or waiting already; `done` drops, and the caller does not wait.
                    return;
                }
                if let Job::Projects(projects) = &mut job {
                    // A project whose sync is running already is left to that sync.
                    let mut index = 0;
                    projects.retain(|_| {
                        index += 1;
                        !left_out.contains(&(index - 1))
                    });
                }
                let spawn = Spawn {
                    app,
                    job,
                    runner,
                    generations,
                    keys,
                    read: matches!(ask, Ask::Stale { .. }),
                    event: matches!(ask, Ask::Event),
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
            Msg::Outcome { app, upstream, reached, reply } => {
                let breaker = self.breakers.entry(upstream).or_default();
                let changed = if reached {
                    breaker.reached().then_some(true)
                } else {
                    breaker.failed(Instant::now(), spread()).then_some(false)
                };
                let _ = reply.send(changed);
                // GitHub is back sooner than the wait set for it: the projects events named
                // meanwhile are synced now rather than when that wait would have ended.
                if changed == Some(true) && upstream == Upstream::GitHub && !self.pending.is_empty() {
                    self.flush_at(&app, Instant::now());
                }
            }
            Msg::Health { reply } => {
                let now = Instant::now();
                let failing = Upstream::ALL
                    .into_iter()
                    .filter_map(|upstream| {
                        let breaker = self.breakers.get(&upstream).filter(|b| b.failures > 0)?;
                        let wait = breaker.retry_at.map(|at| at.saturating_duration_since(now));
                        Some((upstream, wait.unwrap_or_default().as_secs()))
                    })
                    .collect();
                let _ = reply.send(failing);
            }
            Msg::Merged { key, reply } => {
                let _ = reply.send(self.merged(&key));
            }
            Msg::Changed { app, project, gather, pace, runner } => {
                self.pending.insert(project.id.clone(), project);
                self.pending_pace = pace;
                self.pending_runner = runner;
                let now = Instant::now();
                self.flush_at(&app, self.held_until(now).unwrap_or(now + gather));
            }
            Msg::Unanswered { app, projects } => {
                for (project, started) in projects {
                    // Edited meanwhile: this is the project as it was, and the edit's own
                    // reads sync it as it is.
                    if self.generation(&project.id).load(Ordering::SeqCst) == started {
                        self.pending.insert(project.id.clone(), project);
                    }
                }
                if self.pending.is_empty() {
                    return;
                }
                let now = Instant::now();
                self.flush_at(&app, self.held_until(now).unwrap_or(now + RUNNING_RECHECK));
            }
            Msg::Flush(app) => self.flush(app, tasks),
            Msg::Budget(left) => {
                self.budget = Some(Budget {
                    remaining: left.remaining,
                    limit: left.limit,
                    reset_at: Instant::now() + left.reset_in,
                });
            }
        }
    }

    /// Sets a look at `pending` for `at`, unless one is already set for no later. The wait is a
    /// task of its own that tells the engine when it is over. Every wait set is remembered until
    /// it is over, so a busy repository's events through a long hold are the one wait for the
    /// hold's end, not one more each.
    fn flush_at(&mut self, app: &AppState, at: Instant) {
        let now = Instant::now();
        self.flushes.retain(|set| *set > now);
        if self.flushes.iter().any(|set| *set <= at) {
            return;
        }
        self.flushes.push(at);
        let app = app.clone();
        tokio::spawn(async move {
            tokio::time::sleep_until(at.into()).await;
            app.poller.flush(&app);
        });
    }

    /// Syncs, together, the projects GitHub said changed that are due, and sets the next look
    /// for the rest: none while GitHub is failing or its allowance is nearly spent, and each
    /// project no sooner than the pace after its last sync started, so the events of a busy
    /// repository are one sync an interval, with the last of them never left unsynced.
    fn flush(&mut self, app: AppState, tasks: &mut JoinSet<oneshot::Sender<()>>) {
        let now = Instant::now();
        if self.pending.is_empty() {
            return;
        }
        if let Some(until) = self.held_until(now) {
            self.flush_at(&app, until);
            return;
        }
        let mut due = Vec::new();
        let mut later: Option<Instant> = None;
        for (id, project) in &self.pending {
            let paced = self.tried.get(id).map(|at| *at + self.pending_pace).filter(|at| now < *at);
            let wait = if self.syncing(id) {
                Some(paced.unwrap_or(now).max(now + RUNNING_RECHECK))
            } else {
                paced
            };
            match wait {
                Some(at) => later = Some(later.map_or(at, |sooner| sooner.min(at))),
                None => due.push(project.clone()),
            }
        }
        for project in &due {
            self.pending.remove(&project.id);
        }
        if let Some(at) = later {
            self.flush_at(&app, at);
        }
        if due.is_empty() {
            return;
        }
        // Nobody waits for it: `done` is dropped.
        let (done, _) = oneshot::channel();
        let run = Msg::Run {
            app,
            job: Job::Projects(due),
            ask: Ask::Event,
            runner: self.pending_runner.clone(),
            done,
        };
        self.handle(run, tasks);
    }

    /// Until when nothing is synced on an event's word: while GitHub is failing, and while its
    /// allowance is nearly spent. The allowance holds events only: what an automation waits
    /// for, and what a person asks for, still runs.
    fn held_until(&self, now: Instant) -> Option<Instant> {
        let failing = self.breakers.get(&Upstream::GitHub).and_then(|b| b.retry_at).filter(|at| now < *at);
        let spent = self.budget.filter(|budget| budget.spent(now)).map(|budget| budget.reset_at);
        failing.into_iter().chain(spent).max()
    }

    /// Whether a sync of the project's pull requests is running or waiting for a lane.
    fn syncing(&self, id: &str) -> bool {
        let prefix = format!("pr:{id}:");
        self.claimed.iter().any(|key| key.starts_with(&prefix))
    }

    fn generation(&mut self, id: &str) -> Arc<AtomicU64> {
        self.generations.entry(id.to_owned()).or_default().clone()
    }

    fn spawn(&mut self, spawn: Spawn, tasks: &mut JoinSet<oneshot::Sender<()>>) {
        let Spawn {
            app,
            job,
            runner,
            generations,
            keys,
            read,
            event,
            done,
        } = spawn;
        let github = job.github();
        if github {
            self.github_running += 1;
        }
        let handle = tasks.spawn(async move {
            let work = async move {
                let mut generations = generations.into_iter();
                match job {
                    Job::Projects(projects) => {
                        let told = Told { read, event };
                        sync_projects(&app, projects.into_iter().zip(generations).collect(), told).await
                    }
                    Job::Scope(project, state) => {
                        let generation = generations.next().expect("a generation per project");
                        sync_pr_scope(&app, &generation, project, &state).await
                    }
                    Job::Board(project) => {
                        let generation = generations.next().expect("a generation per project");
                        sync_board(&app, &generation, &project).await
                    }
                }
            };
            match runner {
                Some(runner) => cli::scoped(runner, work).await,
                None => work.await,
            }
            done
        });
        self.running.insert(handle.id(), (keys, github));
    }

    fn finished(&mut self, id: Id, tasks: &mut JoinSet<oneshot::Sender<()>>) {
        let Some((keys, github)) = self.running.remove(&id) else {
            return;
        };
        for key in keys {
            self.claimed.remove(&key);
        }
        if github {
            self.github_running -= 1;
            self.spawn_next(tasks);
        }
    }

    /// Starts the next waiting GitHub sync. One whose projects were all invalidated while it
    /// waited is dropped instead: its fetch would be thrown away, so it takes no lane, and its
    /// caller hears at once.
    fn spawn_next(&mut self, tasks: &mut JoinSet<oneshot::Sender<()>>) {
        while let Some(next) = self.waiting.pop_front() {
            let stale = |generation: &Generation| {
                generation.counter.load(Ordering::SeqCst) != generation.started
            };
            if next.generations.iter().all(stale) {
                for key in &next.keys {
                    self.claimed.remove(key);
                }
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
        // Snapshots are synced when they are read stale (`routes::dashboard`, the board). The
        // loops sync in the background only what an automation that is on waits for: a project an
        // armed pull request pipeline covers, and each armed pipeline's JQL.
        let pr_app = app.clone();
        tokio::spawn(async move {
            loop {
                let projects = pr_app.db.projects().await.unwrap_or_default();
                if !crate::automation::paused(&pr_app).await {
                    let covered = crate::automation::pr_covered(&pr_app, &projects).await;
                    let watched = projects.into_iter().filter(|p| covered.contains(&p.id)).collect();
                    pr_app.poller.sync_projects(&pr_app, watched).await;
                }
                tokio::time::sleep(Duration::from_secs(poll_interval(&pr_app).await)).await;
            }
        });
        // Scheduled automations, on the minute: the times they name are minutes of the clock.
        let schedule_app = app.clone();
        tokio::spawn(async move {
            loop {
                let into = chrono::Utc::now().timestamp() % 60;
                tokio::time::sleep(Duration::from_secs((60 - into) as u64)).await;
                crate::automation::schedule::tick(&schedule_app).await;
            }
        });
        tokio::spawn(async move {
            loop {
                crate::automation::poll_jira(&app).await;
                tokio::time::sleep(Duration::from_secs(jira_poll_interval(&app).await)).await;
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

/// Who a sync of pull requests answers to, beyond the snapshot it writes.
#[derive(Clone, Copy, Default)]
struct Told {
    /// Someone is looking and is shown the old stamps: told of every project synced, changed
    /// or not.
    read: bool,
    /// An event asked for it: a project GitHub could not answer for waits for its sync again.
    event: bool,
}

/// Projects' open pull requests, each with its recent closed window for merge detection: fetched
/// together (`github::fetch_repos`), then written project by project.
async fn sync_projects(app: &AppState, projects: Vec<(Project, Generation)>, told: Told) {
    // A snapshot older than this was not being kept up: what its sync finds happened while
    // nobody was looking, and is caught up on rather than told as it happens. Someone looking
    // syncs it once an interval, twice that when a read just misses, so the line is drawn well
    // past both: three intervals and a minute, four minutes at least.
    let away_after = (3 * poll_interval(app).await as i64 + 60).max(240);
    let mut queries = Vec::new();
    let mut fetched = Vec::new();
    for (project, generation) in projects {
        let id = project.id.clone();
        let previous = app.db.pr_snapshot(&id, "open", None).await.ok().flatten();
        if project.repo.is_empty() {
            let changed = snapshot_changed(previous.as_ref(), &[], None);
            if !generation.current(app, &id).await {
                continue;
            }
            let _ = app.db.set_pr_snapshot(&id, &PrSnapshot::taken(Vec::new(), None)).await;
            if changed {
                app.publish(crate::Event::Sync { scope: Some("prs"), project_id: Some(id.to_string()) });
            }
            continue;
        }
        let since = previous
            .as_ref()
            .and_then(PrSnapshot::synced_at)
            .map(|v| (v - ChronoDuration::seconds(60)).to_rfc3339());
        queries.push(github::RepoQuery {
            repo: project.repo.clone(),
            jira_key: project.jira_project_key.clone(),
            since,
            alone: previous.as_ref().is_some_and(|snapshot| snapshot.error.is_some()),
        });
        fetched.push((project, generation, previous));
    }
    if queries.is_empty() {
        return;
    }
    let (results, budget) = github::fetch_repos(&queries).await;
    if let Some(budget) = budget {
        app.poller.budget(budget);
    }
    // A refusal is an answer too: GitHub is reachable unless a fetch could not get one.
    let reached = !results.iter().any(|result| is_transient(result.as_ref().err()));
    report(app, Upstream::GitHub, reached).await;
    if told.event {
        // After the report: the breaker is open by now, and holds them until GitHub is back.
        let unanswered: Vec<(Project, u64)> = fetched
            .iter()
            .zip(&results)
            .filter(|(_, result)| is_transient(result.as_ref().err()))
            .map(|((project, generation, _), _)| (project.clone(), generation.started))
            .collect();
        if !unanswered.is_empty() {
            app.poller.unanswered(app, unanswered);
        }
    }
    for ((project, generation, previous), result) in fetched.into_iter().zip(results) {
        record_prs(app, &generation, project, previous, result, told.read, away_after).await;
    }
}

fn is_transient(error: Option<&github::SyncError>) -> bool {
    error.is_some_and(|error| error.fault == Fault::Transient)
}

/// Tells the engine how an upstream answered a sync, and the app when that changed whether it
/// is reachable: once when it goes down, once when it is back.
async fn report(app: &AppState, upstream: Upstream, reached: bool) {
    if let Some(reachable) = app.poller.outcome(app, upstream, reached).await {
        if !reachable {
            tracing::warn!(upstream = upstream.name(), "unreachable; background syncs wait");
        }
        app.publish(crate::Event::Upstream { name: upstream.name(), reachable });
    }
}

/// A fraction from 0 to 1 that differs from call to call, for spreading retries out.
fn spread() -> f64 {
    (uuid::Uuid::new_v4().as_u128() % 1000) as f64 / 1000.0
}

/// What one project's fetch brought back, written to its snapshot.
async fn record_prs(
    app: &AppState,
    generation: &Generation,
    project: Project,
    previous: Option<PrSnapshot>,
    result: github::RepoPrs,
    read: bool,
    away_after: i64,
) {
    let id = project.id.clone();
    let repo = project.repo.clone();
    // GitHub could not answer: the snapshot stands as it is, and nothing is said per project.
    // The outage is the upstream's (`report`), told once for all of them.
    if is_transient(result.as_ref().err()) || !generation.current(app, &id).await {
        return;
    }
    let synced = result.is_ok();
    let changed = match result {
        Ok((mut open, closed)) => {
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
            let away = previous
                .as_ref()
                .and_then(PrSnapshot::synced_at)
                .is_some_and(|at| Utc::now().signed_duration_since(at).num_seconds() > away_after);
            record_lifecycle(app, &project, &open, &closed, away).await;
            // After `requestedAt` is merged in: a re-request is a new event by its time.
            crate::automation::observe_prs(app, &project, &open, &closed, me.as_deref()).await;
            let lean: Vec<Value> = open.iter().map(|pr| github::lean(pr, &repo)).collect();
            let _ = app.db.prune_review_state(&repo, &numbers).await;
            let changed = snapshot_changed(previous.as_ref(), &lean, None);
            // Asked once more right before the write: the lifecycle and automation steps above
            // awaited long enough for a project edit or delete to have landed meanwhile.
            if !generation.current(app, &id).await {
                return;
            }
            let _ = app.db.set_pr_snapshot(&id, &PrSnapshot::taken(lean, None)).await;
            changed
        }
        Err(error) => {
            let message = error.message;
            let prs = previous.as_ref().map(|v| v.prs.clone()).unwrap_or_default();
            if previous.as_ref().and_then(|v| v.error.as_deref()) != Some(&message) {
                event(app, "sync_failed", json!({"repo":repo,"error":message})).await;
            }
            let changed = snapshot_changed(previous.as_ref(), &prs, Some(&message));
            if !generation.current(app, &id).await {
                return;
            }
            // The stamp stays at the last success: the next sync's closed-PR window starts there,
            // so a merge during the outage is still seen.
            let snapshot = PrSnapshot {
                prs,
                last_synced: previous.as_ref().and_then(|v| v.last_synced.clone()),
                error: Some(message),
            };
            let _ = app.db.set_pr_snapshot(&id, &snapshot).await;
            changed
        }
    };
    // `lastSynced` moved either way. The app hears about PRs or an error that changed, and a
    // read that is showing the old stamp hears that it moved.
    if changed || (read && synced) {
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
    let fetched = github::fetch_prs(repo, state, Some(30), true, jira).await;
    let transient = fetched.as_ref().is_err_and(|error| github::fault(error) == Fault::Transient);
    report(app, Upstream::GitHub, !transient).await;
    let (prs, error) = match fetched {
        Ok(prs) => (prs.iter().map(|p| github::lean(p, repo)).collect::<Vec<Value>>(), None),
        Err(error) => (
            previous.as_ref().map(|v| v.prs.clone()).unwrap_or_default(),
            Some(error.to_string()),
        ),
    };
    // GitHub could not answer: the snapshot stands as it is.
    if transient || !generation.current(app, id).await {
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
            let transient = crate::jira::fault(&error) == Fault::Transient;
            report(app, Upstream::Jira, !transient).await;
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
        // No active sprint: Jira answered, unless there is no project key and nothing asked it.
        // With a sprint, the search below is what reports, once for the whole sync.
        if !jira_key.is_empty() {
            report(app, Upstream::Jira, true).await;
        }
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
                report(app, Upstream::Jira, true).await;
                json!({"items":items,"jql":jql,"lastSynced":now(),"error":null,"meta":meta})
            }
            Err(error) => {
                let transient = crate::jira::fault(&error) == Fault::Transient;
                report(app, Upstream::Jira, !transient).await;
                let message = error.to_string();
                // The board says what went wrong either way; only a failure that stays until
                // someone fixes it is activity, and a notice.
                if !transient
                    && previous
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
///
/// `away`: the sync follows a gap, so this is catching up on what happened meanwhile rather than
/// hearing it happen. Several changes found that way are logged `quiet`, for Activity and not
/// for a notice each, and told once in a `prs_caught_up` line that counts them; a single one is
/// told as itself. The automations hear of every merge either way.
async fn record_lifecycle(
    app: &AppState,
    project: &Project,
    open: &[Value],
    closed: &[Value],
    away: bool,
) {
    let repo = project.repo.as_str();
    let prs: Vec<&Value> = open.iter().chain(closed).collect();
    let number = |pr: &Value| pr["number"].as_i64().unwrap_or(0);
    let seen = prs
        .iter()
        .map(|pr| (pr_key(repo, number(pr)), pr["state"].as_str().unwrap_or("").to_owned()))
        .collect();
    let transitions = app.poller.observe(repo, seen).await;
    let quiet = away && transitions.len() > 1;
    for (index, transition) in &transitions {
        let kind = match transition {
            Transition::Opened => "pr_opened",
            Transition::Closed => "pr_closed",
            Transition::Merged => continue,
        };
        let pr = prs[*index];
        let mut payload = json!({"repo":repo,"pr":{"number":number(pr),"title":pr["title"],"url":pr["url"]}});
        if quiet {
            payload["quiet"] = json!(true);
        }
        event(app, kind, payload).await;
    }
    for (index, transition) in &transitions {
        if *transition == Transition::Merged {
            dispatch_merge(app, project, prs[*index], quiet).await;
        }
    }
    if quiet {
        let count = |wanted: Transition| transitions.iter().filter(|(_, t)| *t == wanted).count();
        let counts = json!({
            "repo": repo,
            "opened": count(Transition::Opened),
            "closed": count(Transition::Closed),
            "merged": count(Transition::Merged),
        });
        event(app, "prs_caught_up", counts).await;
    }
}

/// A merge: a line of activity, `quiet` when it is one of several being caught up on, and the
/// automations that act on a merge, which run either way.
async fn dispatch_merge(app: &AppState, project: &Project, pr: &Value, quiet: bool) {
    let mut payload = json!({"repo":project.repo,"pr":{"number":pr["number"],"title":pr["title"],"url":pr["url"]}});
    if quiet {
        payload["quiet"] = json!(true);
    }
    event(app, "pr_merged", payload).await;
    crate::automation::merged(app, project, pr).await;
}

/// How old a pull request snapshot may be, in seconds, before a read syncs it again: the
/// `poll_interval` setting.
pub async fn poll_interval(app: &AppState) -> u64 {
    app.db
        .config_value("poll_interval").await
        .ok()
        .flatten()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(60)
        .clamp(15, 86400)
}

/// How old a kept ticket search may be, in seconds, before a look searches again: the
/// `jira_poll_interval` setting, which also paces the automations' Jira queries.
pub async fn jira_poll_interval(app: &AppState) -> u64 {
    app.db
        .config_value("jira_poll_interval").await
        .ok()
        .flatten()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(120)
        .clamp(30, 86400)
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
                Ok(br#"{"data":{"r0":{"open":{"nodes":[],"pageInfo":{"hasNextPage":false}},"closed":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}"#.to_vec())
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

    fn graphql_calls(runner: &cli::ScriptedRunner) -> Vec<String> {
        runner
            .asked
            .lock()
            .unwrap()
            .iter()
            .filter(|asked| asked.args.iter().any(|arg| arg == "graphql"))
            .map(|asked| asked.args.iter().map(|arg| arg.to_string_lossy()).collect::<Vec<_>>().join(" "))
            .collect()
    }

    /// The query of a read someone is looking at: `?look=1`.
    fn look() -> axum::extract::Query<crate::routes::LookQuery> {
        axum::extract::Query(serde_json::from_value(json!({"look":"1"})).unwrap())
    }

    /// Projects as a read hands them to `sync_stale` when it has no stamp to go by.
    fn unsynced(projects: &[Project]) -> Vec<(Project, Option<Duration>)> {
        projects.iter().map(|project| (project.clone(), None)).collect()
    }

    async fn add_projects(app: &AppState, repos: &[&str]) -> Vec<Project> {
        let mut projects = Vec::new();
        for repo in repos {
            let mut fields = serde_json::Map::new();
            fields.insert("name".into(), json!(repo));
            fields.insert("repo".into(), json!(repo));
            fields.insert("workspace".into(), json!("/tmp/none"));
            projects.push(app.db.add_project(&fields).await.unwrap());
        }
        projects
    }

    /// Two projects sync in one GraphQL query, and each gets its own snapshot from it.
    #[tokio::test]
    async fn projects_synced_together_share_one_query() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let projects = add_projects(&app, &["owner/a", "owner/b"]).await;
        let page = |number: u64| json!({"open":{"nodes":[{"number":number,"title":"t","state":"OPEN","author":{"login":"x"}}],"pageInfo":{"hasNextPage":false}},"closed":{"nodes":[],"pageInfo":{"hasNextPage":false}}});
        let answer = json!({"data":{"r0":page(1),"r1":page(2)}}).to_string();
        let runner = Arc::new(cli::ScriptedRunner::new().on("gh", move |args| {
            args.iter().any(|arg| arg == "graphql").then(|| Ok(answer.clone().into_bytes()))
        }));
        cli::scoped(runner.clone(), app.poller.sync_projects(&app, projects.clone())).await;
        let calls = graphql_calls(&runner);
        assert_eq!(calls.len(), 1, "{calls:?}");
        assert!(calls[0].contains("o0=owner") && calls[0].contains("n1=b"), "{}", calls[0]);
        for (project, number) in projects.iter().zip([1, 2]) {
            let snapshot = app.db.pr_snapshot(&project.id, "open", None).await.unwrap().unwrap();
            assert_eq!(snapshot.error, None);
            assert_eq!(snapshot.prs.len(), 1);
            assert_eq!(snapshot.prs[0]["number"], number);
            assert_eq!(snapshot.prs[0]["repo"], project.repo.as_str());
        }
    }

    /// A batched query GitHub refused is asked again repository by repository, so only the one
    /// that cannot be read records an error; and from then on it is asked for by itself, so the
    /// others' query is not refused with it sync after sync.
    #[tokio::test]
    async fn a_refused_batch_is_asked_again_one_by_one_and_the_failing_repository_alone_after() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let projects = add_projects(&app, &["owner/good", "owner/gone"]).await;
        let runner = Arc::new(cli::ScriptedRunner::new().on("gh", |args| {
            let text = args.iter().map(|arg| arg.to_string_lossy()).collect::<Vec<_>>().join(" ");
            if !text.contains("graphql") {
                return None;
            }
            Some(if text.contains("gone") {
                Err("Could not resolve to a Repository".into())
            } else if text.contains("o0=") {
                Ok(br#"{"data":{"r0":{"open":{"nodes":[],"pageInfo":{"hasNextPage":false}},"closed":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}"#.to_vec())
            } else {
                Ok(br#"{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#.to_vec())
            })
        }));
        cli::scoped(runner.clone(), app.poller.sync_projects(&app, projects.clone())).await;
        let good = app.db.pr_snapshot(&projects[0].id, "open", None).await.unwrap().unwrap();
        let gone = app.db.pr_snapshot(&projects[1].id, "open", None).await.unwrap().unwrap();
        assert_eq!(good.error, None);
        assert!(gone.error.is_some());
        assert!(app.poller.unreachable().await.is_empty(), "a refusal is an answer: GitHub is reachable");

        let before = graphql_calls(&runner).len();
        cli::scoped(runner.clone(), app.poller.sync_projects(&app, projects.clone())).await;
        let calls = graphql_calls(&runner);
        let again = &calls[before..];
        assert_eq!(again.len(), 2, "{again:?}");
        assert!(again[0].contains("n0=good") && !again[0].contains("gone"), "{}", again[0]);
        assert!(again[1].contains("name=gone"), "{}", again[1]);
    }

    /// GitHub not answering is one outage, not an error for every project: the snapshots stand,
    /// nothing goes to Activity, the app hears once that GitHub is unreachable, background syncs
    /// wait, a refresh still asks, and the app hears once that GitHub is back.
    #[tokio::test]
    async fn an_outage_is_told_once_and_background_syncs_wait_it_out() {
        use std::sync::atomic::AtomicBool;
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let projects = add_projects(&app, &["owner/a", "owner/b"]).await;
        let mut events = app.events.subscribe();
        let down = Arc::new(AtomicBool::new(true));
        let runner = Arc::new(cli::ScriptedRunner::new().on("gh", {
            let down = down.clone();
            move |args| {
                args.iter().any(|arg| arg == "graphql").then(|| {
                    if down.load(Ordering::SeqCst) {
                        return Err(cli::Failed::timed_out("gh", Duration::from_secs(20)));
                    }
                    let page = json!({"open":{"nodes":[],"pageInfo":{"hasNextPage":false}},"closed":{"nodes":[],"pageInfo":{"hasNextPage":false}}});
                    Ok(json!({"data":{"r0":page,"r1":page}}).to_string().into_bytes())
                })
            }
        }));
        let told = |events: &mut tokio::sync::broadcast::Receiver<Value>| {
            let mut told = Vec::new();
            while let Ok(event) = events.try_recv() {
                told.push(event);
            }
            told
        };

        cli::scoped(runner.clone(), app.poller.sync_projects(&app, projects.clone())).await;
        assert_eq!(graphql_calls(&runner).len(), 1, "an outage is not asked again one by one");
        for project in &projects {
            assert!(app.db.pr_snapshot(&project.id, "open", None).await.unwrap().is_none());
        }
        assert_eq!(told(&mut events), vec![json!({"type":"upstream","name":"github","reachable":false})]);
        let failing = app.poller.unreachable().await;
        assert_eq!(failing.len(), 1);
        assert!(failing[0].0 == Upstream::GitHub && (25..=36).contains(&failing[0].1), "{failing:?}");
        let axum::Json(listed) = crate::routes::upstreams(axum::extract::State(app.clone())).await.unwrap();
        assert_eq!(listed["github"]["retryIn"], failing[0].1);

        // Nothing in the background asks while it waits: not a loop, not a stale read.
        cli::scoped(runner.clone(), app.poller.sync_projects(&app, projects.clone())).await;
        cli::scoped(runner.clone(), app.poller.sync_stale(&app, unsynced(&projects), Duration::ZERO)).await;
        assert_eq!(graphql_calls(&runner).len(), 1);
        assert!(told(&mut events).is_empty());

        // A refresh asks anyway, and a second failure is not news.
        cli::scoped(runner.clone(), app.poller.sync_all(&app)).await;
        assert_eq!(graphql_calls(&runner).len(), 2);
        assert!(told(&mut events).is_empty());

        down.store(false, Ordering::SeqCst);
        cli::scoped(runner.clone(), app.poller.sync_all(&app)).await;
        assert_eq!(graphql_calls(&runner).len(), 3);
        let told = told(&mut events);
        assert_eq!(told[0], json!({"type":"upstream","name":"github","reachable":true}));
        assert_eq!(told.iter().filter(|event| event["type"] == "sync").count(), 2);
        assert!(told.iter().all(|event| event["type"] != "activity"));
        assert!(app.poller.unreachable().await.is_empty());
        assert!(app.db.query_logs(Some("event"), None, 10).await.unwrap().is_empty(), "nothing went to Activity");
    }

    /// Jira not answering is the same outage: the board keeps its tickets and says why it could
    /// not refresh, nothing goes to Activity, and a stale read does not ask again while it waits.
    #[tokio::test]
    async fn a_board_whose_search_times_out_keeps_its_tickets_and_stays_out_of_activity() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let mut fields = serde_json::Map::new();
        fields.insert("name".into(), json!("P"));
        fields.insert("repo".into(), json!(""));
        fields.insert("workspace".into(), json!("/tmp/none"));
        fields.insert("jiraProjectKey".into(), json!("REC"));
        let project = app.db.add_project(&fields).await.unwrap();
        let mut events = app.events.subscribe();
        let runner = Arc::new(cli::ScriptedRunner::new().on("acli", |args| {
            let text = args.iter().map(|arg| arg.to_string_lossy()).collect::<Vec<_>>().join(" ");
            Some(if text.contains("board search") {
                Ok(br#"{"values":[{"type":"scrum","id":7}]}"#.to_vec())
            } else if text.contains("list-sprints") {
                Ok(br#"{"sprints":[{"id":11,"name":"Sprint 11"}]}"#.to_vec())
            } else {
                Err(cli::Failed::timed_out("acli", Duration::from_secs(30)))
            })
        }));
        cli::scoped(runner.clone(), app.poller.sync_board(&app, &project)).await;
        let snapshot = app.db.jira_snapshot(&format!("board:{}", project.id)).await.unwrap().unwrap();
        assert_eq!(snapshot["error"], "acli timed out after 30s");
        let mut told = Vec::new();
        while let Ok(event) = events.try_recv() {
            told.push(event);
        }
        assert!(told.contains(&json!({"type":"upstream","name":"jira","reachable":false})), "{told:?}");
        assert!(told.iter().all(|event| event["type"] != "activity"), "{told:?}");
        assert_eq!(app.poller.unreachable().await[0].0, Upstream::Jira);

        let asked = runner.asked.lock().unwrap().len();
        cli::scoped(runner.clone(), app.poller.sync_stale_board(&app, &project)).await;
        assert_eq!(runner.asked.lock().unwrap().len(), asked, "a stale read waits the outage out");

        // A refresh asks again. Its sprint answers and its search does not, which is one
        // failure, not Jira coming back and going down again.
        cli::scoped(runner.clone(), app.poller.sync_board(&app, &project)).await;
        assert!(runner.asked.lock().unwrap().len() > asked);
        // A board with no Jira project asks Jira nothing, so it says nothing about Jira.
        fields.insert("jiraProjectKey".into(), json!(""));
        let keyless = app.db.add_project(&fields).await.unwrap();
        cli::scoped(runner.clone(), app.poller.sync_board(&app, &keyless)).await;
        while let Ok(event) = events.try_recv() {
            assert_ne!(event["type"], "upstream", "{event}");
        }
        assert_eq!(app.poller.unreachable().await[0].0, Upstream::Jira);
    }

    /// GitHub giving up on a query of several repositories is asked again one by one before it
    /// is called an outage: all of them together may only have been too much for one query.
    #[tokio::test]
    async fn a_batch_github_gave_up_on_is_asked_again_one_by_one() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let projects = add_projects(&app, &["owner/a", "owner/b"]).await;
        let runner = Arc::new(cli::ScriptedRunner::new().on("gh", |args| {
            let text = args.iter().map(|arg| arg.to_string_lossy()).collect::<Vec<_>>().join(" ");
            if !text.contains("graphql") {
                return None;
            }
            Some(if text.contains("o0=") {
                Err("gh: Something went wrong while executing your query. This may be the result of a timeout".into())
            } else {
                Ok(br#"{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#.to_vec())
            })
        }));
        cli::scoped(runner.clone(), app.poller.sync_projects(&app, projects.clone())).await;
        assert_eq!(graphql_calls(&runner).len(), 5, "the batch, then two lists for each");
        for project in &projects {
            let snapshot = app.db.pr_snapshot(&project.id, "open", None).await.unwrap().unwrap();
            assert_eq!(snapshot.error, None);
        }
        assert!(app.poller.unreachable().await.is_empty());
    }

    /// An outage met while one repository's longer list is fetched does not throw away what
    /// the batch had already answered in full for the others.
    #[tokio::test]
    async fn an_outage_keeps_what_the_batch_already_answered_in_full() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let projects = add_projects(&app, &["owner/long", "owner/short"]).await;
        let runner = Arc::new(cli::ScriptedRunner::new().on("gh", |args| {
            let text = args.iter().map(|arg| arg.to_string_lossy()).collect::<Vec<_>>().join(" ");
            if !text.contains("graphql") {
                return None;
            }
            Some(if text.contains("o0=") {
                // `long` has more open pull requests than the page holds; `short` is whole.
                Ok(br#"{"data":{"r0":{"open":{"nodes":[],"pageInfo":{"hasNextPage":true}},"closed":{"nodes":[],"pageInfo":{"hasNextPage":false}}},"r1":{"open":{"nodes":[],"pageInfo":{"hasNextPage":false}},"closed":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}"#.to_vec())
            } else {
                Err(cli::Failed::timed_out("gh", Duration::from_secs(20)))
            })
        }));
        cli::scoped(runner.clone(), app.poller.sync_projects(&app, projects.clone())).await;
        assert_eq!(graphql_calls(&runner).len(), 2, "the batch, and the one longer list");
        assert!(app.db.pr_snapshot(&projects[0].id, "open", None).await.unwrap().is_none());
        let short = app.db.pr_snapshot(&projects[1].id, "open", None).await.unwrap().unwrap();
        assert!(short.error.is_none() && short.last_synced.is_some());
        assert_eq!(app.poller.unreachable().await[0].0, Upstream::GitHub);
    }

    /// An outage that starts while a refused batch is being asked again one by one stops the
    /// asking: the repositories not reached yet fail with it rather than each waiting it out.
    #[tokio::test]
    async fn an_outage_met_while_asking_one_by_one_stops_the_asking() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let projects = add_projects(&app, &["owner/a", "owner/b", "owner/c"]).await;
        let runner = Arc::new(cli::ScriptedRunner::new().on("gh", |args| {
            let text = args.iter().map(|arg| arg.to_string_lossy()).collect::<Vec<_>>().join(" ");
            if !text.contains("graphql") {
                return None;
            }
            Some(if text.contains("o0=") {
                Err("Could not resolve to a Repository with the name 'owner/b'.".into())
            } else if text.contains("name=a") {
                Ok(br#"{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#.to_vec())
            } else {
                Err(cli::Failed::timed_out("gh", Duration::from_secs(20)))
            })
        }));
        cli::scoped(runner.clone(), app.poller.sync_projects(&app, projects.clone())).await;
        let calls = graphql_calls(&runner);
        assert_eq!(calls.len(), 4, "the batch, a's two lists, and b's timeout: {calls:?}");
        assert!(calls.iter().all(|call| !call.contains("name=c")), "c is not asked into the outage");
        let snapshot = |index: usize| app.db.pr_snapshot(&projects[index].id, "open", None);
        assert_eq!(snapshot(0).await.unwrap().unwrap().error, None);
        assert!(snapshot(1).await.unwrap().is_none() && snapshot(2).await.unwrap().is_none());
        assert_eq!(app.poller.unreachable().await[0].0, Upstream::GitHub);
    }

    #[test]
    fn a_breaker_doubles_its_wait_up_to_a_limit_and_resets_when_the_service_answers() {
        let start = Instant::now();
        let seconds = Duration::from_secs;
        let mut breaker = Breaker::default();
        assert!(!breaker.waiting(start));
        assert!(breaker.failed(start, 0.0), "the failure that took it down");
        assert!(breaker.waiting(start + seconds(29)) && !breaker.waiting(start + seconds(30)));
        // Told again while it waits: the same outage, from a sync that ran beside the first.
        assert!(!breaker.failed(start + seconds(10), 0.0));
        assert!(!breaker.waiting(start + seconds(30)), "the wait did not move");
        // Failing again once the wait is over doubles it.
        let mut now = start + seconds(30);
        assert!(!breaker.failed(now, 0.0), "already down");
        assert!(breaker.waiting(now + seconds(59)) && !breaker.waiting(now + seconds(60)));
        for _ in 0..40 {
            now += seconds(900);
            breaker.failed(now, 0.0);
        }
        assert!(breaker.waiting(now + seconds(899)) && !breaker.waiting(now + seconds(900)));
        assert!(breaker.reached(), "it had been down");
        assert!(!breaker.reached() && !breaker.waiting(now));
        // The spread lengthens a wait by up to a fifth.
        breaker.failed(now, 1.0);
        assert!(breaker.waiting(now + seconds(35)) && !breaker.waiting(now + seconds(36)));
    }

    /// What happened while nobody was looking is caught up on, not told as it happens: several
    /// changes found after a gap go to Activity quietly with one line that counts them, a
    /// single change is told as itself, and changes found while the snapshot is kept up are
    /// told one by one as before.
    #[tokio::test]
    async fn changes_found_after_a_gap_are_counted_in_one_line() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let project = add_projects(&app, &["owner/repo"]).await.remove(0);
        let lists = Arc::new(std::sync::Mutex::new((json!([]), json!([]))));
        let runner = Arc::new(cli::ScriptedRunner::new().on("gh", {
            let lists = lists.clone();
            move |args| {
                args.iter().any(|arg| arg == "graphql").then(|| {
                    let (open, closed) = lists.lock().unwrap().clone();
                    let page = |nodes: Value| json!({"nodes":nodes,"pageInfo":{"hasNextPage":false}});
                    Ok(json!({"data":{"r0":{"open":page(open),"closed":page(closed)}}}).to_string().into_bytes())
                })
            }
        }));
        let now = now();
        let pr = |number: u64, state: &str| json!({"number":number,"title":format!("PR {number}"),"state":state,"url":format!("https://github.com/owner/repo/pull/{number}"),"updatedAt":now,"author":{"login":"x"}});
        let sync = || cli::scoped(runner.clone(), app.poller.sync_project(&app, project.clone()));
        // The stamp of a snapshot nobody kept up for an hour.
        let leave = || async {
            let mut snapshot = app.db.pr_snapshot(&project.id, "open", None).await.unwrap().unwrap();
            snapshot.last_synced = Some((Utc::now() - ChronoDuration::hours(1)).to_rfc3339());
            app.db.set_pr_snapshot(&project.id, &snapshot).await.unwrap();
        };
        // The activity logged since the last ask, oldest first, as (type, quiet).
        let seen = std::cell::Cell::new(0usize);
        let logged = || async {
            let mut rows = app.db.query_logs(Some("event"), None, 100).await.unwrap();
            rows.reverse();
            let new: Vec<(String, bool)> = rows[seen.get()..]
                .iter()
                .map(|row| {
                    let payload: Value = serde_json::from_str(row["payload"].as_str().unwrap_or("{}")).unwrap();
                    (row["type"].as_str().unwrap().to_owned(), payload["quiet"] == true)
                })
                .collect();
            seen.set(rows.len());
            new
        };

        sync().await;
        assert!(logged().await.is_empty(), "the first sight of a repository is not news");

        // An hour away, and three things happened.
        leave().await;
        *lists.lock().unwrap() = (json!([pr(1, "OPEN")]), json!([pr(2, "MERGED"), pr(3, "CLOSED")]));
        sync().await;
        let caught_up = logged().await;
        assert_eq!(caught_up.len(), 4, "{caught_up:?}");
        assert!(caught_up[..3].iter().all(|(kind, quiet)| *quiet && kind != "prs_caught_up"), "{caught_up:?}");
        assert_eq!(caught_up[3], ("prs_caught_up".to_owned(), false));
        let rows = app.db.query_logs(Some("event"), None, 1).await.unwrap();
        let counts: Value = serde_json::from_str(rows[0]["payload"].as_str().unwrap()).unwrap();
        assert_eq!((&counts["opened"], &counts["closed"], &counts["merged"]), (&json!(1), &json!(1), &json!(1)));

        // Kept up: what happens now is told as it happens.
        *lists.lock().unwrap() = (json!([pr(1, "OPEN"), pr(4, "OPEN"), pr(5, "OPEN")]), json!([pr(2, "MERGED"), pr(3, "CLOSED")]));
        sync().await;
        assert_eq!(logged().await, vec![("pr_opened".to_owned(), false), ("pr_opened".to_owned(), false)]);

        // Away again, and one thing happened: it is told as itself.
        leave().await;
        *lists.lock().unwrap() = (json!([pr(1, "OPEN"), pr(4, "OPEN"), pr(5, "OPEN"), pr(6, "OPEN")]), json!([pr(2, "MERGED"), pr(3, "CLOSED")]));
        sync().await;
        assert_eq!(logged().await, vec![("pr_opened".to_owned(), false)]);
    }

    /// A read that found a snapshot stale is showing its old stamp: it hears when the sync it
    /// set off is done even if no pull request changed, so the age it shows is the new one. A
    /// sync nobody is reading for stays silent when nothing changed.
    #[tokio::test]
    async fn a_stale_read_hears_of_its_sync_even_when_nothing_changed() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let projects = add_projects(&app, &["owner/quiet"]).await;
        let old = PrSnapshot { prs: Vec::new(), last_synced: Some("2026-01-01T00:00:00.000Z".into()), error: None };
        app.db.set_pr_snapshot(&projects[0].id, &old).await.unwrap();
        let mut events = app.events.subscribe();
        let runner = Arc::new(cli::ScriptedRunner::new().on("gh", |args| {
            args.iter().any(|arg| arg == "graphql").then(|| {
                Ok(br#"{"data":{"r0":{"open":{"nodes":[],"pageInfo":{"hasNextPage":false}},"closed":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}"#.to_vec())
            })
        }));
        cli::scoped(runner.clone(), app.poller.sync_stale(&app, unsynced(&projects), Duration::from_secs(60))).await;
        let told = events.try_recv().expect("the read is told");
        assert_eq!((&told["type"], &told["projectId"]), (&json!("sync"), &json!(projects[0].id)));
        let stamp = app.db.pr_snapshot(&projects[0].id, "open", None).await.unwrap().unwrap().last_synced;
        assert_ne!(stamp, old.last_synced);

        cli::scoped(runner, app.poller.sync_project(&app, projects[0].clone())).await;
        assert!(events.try_recv().is_err(), "nothing changed and nobody is reading");
    }

    /// After a restart the engine remembers no sync, and a read goes by the snapshot's own
    /// stamp: one synced within the interval is left alone, an older one is synced.
    #[tokio::test]
    async fn after_a_restart_a_read_goes_by_the_snapshots_own_stamp() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let projects = add_projects(&app, &["owner/recent", "owner/older"]).await;
        for (project, age) in projects.iter().zip([20, 75]) {
            let stamp = (Utc::now() - ChronoDuration::seconds(age)).to_rfc3339();
            let snapshot = PrSnapshot { prs: Vec::new(), last_synced: Some(stamp), error: None };
            app.db.set_pr_snapshot(&project.id, &snapshot).await.unwrap();
        }
        let mut events = app.events.subscribe();
        let runner = Arc::new(cli::ScriptedRunner::new().on("gh", |args| {
            args.iter().any(|arg| arg == "graphql").then(|| {
                Ok(br#"{"data":{"r0":{"open":{"nodes":[],"pageInfo":{"hasNextPage":false}},"closed":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}"#.to_vec())
            })
        }));
        cli::scoped(runner.clone(), async {
            let _ = crate::routes::dashboard(axum::extract::State(app.clone()), look()).await.unwrap();
            let event = tokio::time::timeout(Duration::from_secs(5), events.recv()).await.unwrap().unwrap();
            assert_eq!((&event["type"], &event["projectId"]), (&json!("sync"), &json!(projects[1].id)));
        })
        .await;
        let calls = graphql_calls(&runner);
        assert_eq!(calls.len(), 1, "{calls:?}");
        assert!(calls[0].contains("n0=older") && !calls[0].contains("recent"), "{}", calls[0]);
    }

    /// The pace of looks is kept from when the last sync started, which the engine remembers,
    /// and not from the stamp the snapshot got when it finished: that is what lets someone who
    /// keeps looking, reading once an interval, find a sync due every time.
    #[tokio::test]
    async fn looks_are_paced_from_when_the_last_sync_started() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let projects = add_projects(&app, &["owner/repo"]).await;
        let runner = Arc::new(cli::ScriptedRunner::new().on("gh", |args| {
            args.iter().any(|arg| arg == "graphql").then(|| {
                Ok(br#"{"data":{"r0":{"open":{"nodes":[],"pageInfo":{"hasNextPage":false}},"closed":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}"#.to_vec())
            })
        }));
        // A look that saw the snapshot stamped this long ago.
        let look = |pace: Duration, stamped: Duration| {
            let seen = vec![(projects[0].clone(), Some(stamped))];
            cli::scoped(runner.clone(), app.poller.sync_stale(&app, seen, pace))
        };
        let (minute, moment) = (Duration::from_secs(60), Duration::from_millis(10));
        cli::scoped(runner.clone(), app.poller.sync_stale(&app, unsynced(&projects), minute)).await;
        assert_eq!(graphql_calls(&runner).len(), 1);
        look(minute, Duration::from_secs(100)).await;
        assert_eq!(graphql_calls(&runner).len(), 1, "started inside the pace, whatever the stamp says");
        tokio::time::sleep(moment * 2).await;
        look(moment, Duration::from_millis(1)).await;
        assert_eq!(graphql_calls(&runner).len(), 2, "past the pace, though the snapshot is a moment old");
    }

    /// Only a look syncs. The read the app makes because a sync just finished is its echo, and
    /// starts nothing however stale everything is: an echo that could start a sync is a loop.
    #[tokio::test]
    async fn a_read_that_is_not_a_look_starts_no_sync() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        add_projects(&app, &["owner/a", "owner/b"]).await;
        let mut events = app.events.subscribe();
        let runner = Arc::new(cli::ScriptedRunner::new().on("gh", |args| {
            args.iter().any(|arg| arg == "graphql").then(|| {
                let page = json!({"open":{"nodes":[],"pageInfo":{"hasNextPage":false}},"closed":{"nodes":[],"pageInfo":{"hasNextPage":false}}});
                Ok(json!({"data":{"r0":page,"r1":page}}).to_string().into_bytes())
            })
        }));
        let plain = || axum::extract::Query(crate::routes::LookQuery::default());
        cli::scoped(runner.clone(), async {
            let _ = crate::routes::dashboard(axum::extract::State(app.clone()), plain()).await.unwrap();
            let _ = crate::routes::prs_tray(axum::extract::State(app.clone()), plain()).await.unwrap();
            tokio::time::sleep(Duration::from_millis(100)).await;
            assert!(runner.asked.lock().unwrap().is_empty() && events.try_recv().is_err());
            // The same snapshots, looked at: one sync, of both projects.
            let _ = crate::routes::prs_tray(axum::extract::State(app.clone()), look()).await.unwrap();
            for _ in 0..2 {
                let event = tokio::time::timeout(Duration::from_secs(5), events.recv()).await.unwrap().unwrap();
                assert_eq!(event["type"], "sync");
            }
        })
        .await;
        assert_eq!(graphql_calls(&runner).len(), 1);
    }

    /// A scripted `gh` that answers a batched query with an empty page for each repository it
    /// names.
    fn empty_pages() -> Arc<cli::ScriptedRunner> {
        Arc::new(cli::ScriptedRunner::new().on("gh", |args| {
            let text = args.iter().map(|arg| arg.to_string_lossy()).collect::<Vec<_>>().join(" ");
            text.contains("graphql").then(|| {
                let page = json!({"open":{"nodes":[],"pageInfo":{"hasNextPage":false}},"closed":{"nodes":[],"pageInfo":{"hasNextPage":false}}});
                let mut data = serde_json::Map::new();
                for index in 0..5 {
                    if text.contains(&format!("o{index}=")) {
                        data.insert(format!("r{index}"), page.clone());
                    }
                }
                Ok(json!({"data":data}).to_string().into_bytes())
            })
        }))
    }

    async fn until_async<F: std::future::Future<Output = bool>>(condition: impl Fn() -> F) {
        for _ in 0..500 {
            if condition().await {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    async fn until(condition: impl Fn() -> bool) {
        for _ in 0..500 {
            if condition() {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    /// The events of a moment are one sync, of every project they named together; and a project
    /// is not synced again within the pace of its last sync however many events arrive, with
    /// one sync at the end of the gap for what came during it.
    #[tokio::test]
    async fn events_are_gathered_into_one_sync_and_paced_per_project() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let projects = add_projects(&app, &["owner/a", "owner/b"]).await;
        let runner = empty_pages();
        let (gather, pace) = (Duration::from_millis(50), Duration::from_millis(1500));
        let event = |project: &Project| {
            let project = project.clone();
            cli::scoped(runner.clone(), async { app.poller.changed_within(&app, project, gather, pace) })
        };
        event(&projects[0]).await;
        event(&projects[0]).await;
        event(&projects[1]).await;
        until(|| !graphql_calls(&runner).is_empty()).await;
        tokio::time::sleep(Duration::from_millis(100)).await;
        let calls = graphql_calls(&runner);
        assert_eq!(calls.len(), 1, "{calls:?}");
        assert!(calls[0].contains("n0=") && calls[0].contains("n1="), "both projects, together: {}", calls[0]);

        // More events for one of them, inside the pace: nothing yet, then one sync for all of them.
        event(&projects[0]).await;
        event(&projects[0]).await;
        tokio::time::sleep(Duration::from_millis(250)).await;
        assert_eq!(graphql_calls(&runner).len(), 1, "inside the pace");
        until(|| graphql_calls(&runner).len() > 1).await;
        tokio::time::sleep(Duration::from_millis(200)).await;
        let calls = graphql_calls(&runner);
        assert_eq!(calls.len(), 2, "{calls:?}");
        assert!(calls[1].contains("n0=a") && !calls[1].contains("n1="), "only the project that changed: {}", calls[1]);
    }

    /// A project edited while its event's sync was failing is not set to wait again as it was:
    /// what would be synced is the project before the edit.
    #[tokio::test]
    async fn a_project_edited_during_its_events_sync_does_not_wait_again_as_it_was() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let projects = add_projects(&app, &["owner/kept", "owner/edited"]).await;
        let mut engine = Engine::default();
        let mut tasks = JoinSet::new();
        let (ack, acked) = oneshot::channel();
        engine.handle(Msg::Invalidate(projects[1].id.clone(), ack), &mut tasks);
        acked.await.unwrap();
        // Both syncs started under generation 0; the second project has moved on since.
        let unanswered = projects.iter().cloned().map(|project| (project, 0)).collect();
        engine.handle(Msg::Unanswered { app: app.clone(), projects: unanswered }, &mut tasks);
        assert_eq!(engine.pending.keys().collect::<Vec<_>>(), vec![&projects[0].id]);
    }

    /// The sync an event asked for meets an outage: the event is not lost. Its project waits
    /// out the breaker and is synced when GitHub is back, with nobody looking and no new event.
    #[tokio::test]
    async fn an_event_whose_sync_meets_an_outage_is_synced_when_github_is_back() {
        use std::sync::atomic::AtomicBool;
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let projects = add_projects(&app, &["owner/a"]).await;
        let down = Arc::new(AtomicBool::new(true));
        let runner = Arc::new(cli::ScriptedRunner::new().on("gh", {
            let down = down.clone();
            move |args| {
                args.iter().any(|arg| arg == "graphql").then(|| {
                    if down.load(Ordering::SeqCst) {
                        return Err(cli::Failed::timed_out("gh", Duration::from_secs(20)));
                    }
                    Ok(br#"{"data":{"r0":{"open":{"nodes":[],"pageInfo":{"hasNextPage":false}},"closed":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}"#.to_vec())
                })
            }
        }));
        let changed = projects[0].clone();
        cli::scoped(runner.clone(), async {
            app.poller.changed_within(&app, changed, Duration::from_millis(20), Duration::ZERO)
        })
        .await;
        until(|| graphql_calls(&runner).len() == 1).await;
        until_async(|| async { !app.poller.unreachable().await.is_empty() }).await;
        assert_eq!(app.poller.unreachable().await[0].0, Upstream::GitHub);
        // GitHub answers again, and the wait is cut short as a refresh someone asked for would
        // cut it: a sync of another project reaches GitHub and closes the breaker.
        down.store(false, Ordering::SeqCst);
        let other = add_projects(&app, &["owner/other"]).await.remove(0);
        cli::scoped(runner.clone(), app.poller.sync_project(&app, other)).await;
        until(|| graphql_calls(&runner).iter().filter(|call| call.contains("n0=a")).count() == 2).await;
        // The sync is written a moment after GitHub answers.
        let synced = || async {
            let snapshot = app.db.pr_snapshot(&projects[0].id, "open", None).await.unwrap();
            snapshot.is_some_and(|snapshot| snapshot.last_synced.is_some())
        };
        until_async(synced).await;
        assert!(synced().await, "the event's project was synced: {:?}", graphql_calls(&runner));
    }

    /// With GitHub's allowance nearly spent, an event's sync waits for the hour to turn, while
    /// a sync someone is looking for still runs.
    #[tokio::test]
    async fn events_wait_while_the_rate_allowance_is_nearly_spent() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let projects = add_projects(&app, &["owner/a", "owner/b"]).await;
        let runner = empty_pages();
        app.poller.budget(github::Budget { remaining: 100, limit: 5000, reset_in: Duration::from_millis(1200) });
        let changed = projects[0].clone();
        cli::scoped(runner.clone(), async {
            app.poller.changed_within(&app, changed, Duration::from_millis(20), Duration::ZERO)
        })
        .await;
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert!(graphql_calls(&runner).is_empty(), "nobody is waiting on it");
        cli::scoped(runner.clone(), app.poller.sync_stale(&app, unsynced(&projects[1..]), Duration::from_secs(60))).await;
        let calls = graphql_calls(&runner);
        assert_eq!(calls.len(), 1, "someone is looking: {calls:?}");
        assert!(calls[0].contains("n0=b"), "{}", calls[0]);
        // The hour turns: the event's sync runs.
        until(|| graphql_calls(&runner).len() > 1).await;
        let calls = graphql_calls(&runner);
        assert_eq!(calls.len(), 2, "{calls:?}");
        assert!(calls[1].contains("n0=a"), "{}", calls[1]);
    }

    /// A forwarded pull request event of any kind refreshes its project's snapshot, whoever is
    /// or is not looking; one for a repository no project tracks does nothing.
    #[tokio::test]
    async fn a_forwarded_pull_request_event_refreshes_its_project() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let projects = add_projects(&app, &["owner/repo"]).await;
        let mut events = app.events.subscribe();
        let runner = empty_pages();
        let forwarded = |repo: &'static str| {
            let mut headers = axum::http::HeaderMap::new();
            headers.insert("x-github-event", "pull_request".parse().unwrap());
            let body = json!({"action":"review_requested","repository":{"full_name":repo},"pull_request":{"number":7}});
            crate::integrations::github_webhook(axum::extract::State(app.clone()), headers, axum::Json(body))
        };
        cli::scoped(runner.clone(), async {
            forwarded("someone/else").await;
            forwarded("Owner/Repo").await;
        })
        .await;
        let event = tokio::time::timeout(GATHER + Duration::from_secs(5), events.recv()).await.unwrap().unwrap();
        assert_eq!((&event["type"], &event["projectId"]), (&json!("sync"), &json!(projects[0].id)));
        let calls = graphql_calls(&runner);
        assert_eq!(calls.len(), 1, "{calls:?}");
        assert!(calls[0].contains("n0=repo"), "{}", calls[0]);
    }

    /// Opening the tray is a read of the same snapshots, and syncs the stale ones behind it too:
    /// it does not depend on the dashboard having been opened.
    #[tokio::test]
    async fn a_tray_read_syncs_stale_snapshots() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let projects = add_projects(&app, &["owner/fresh", "owner/stale"]).await;
        app.db.set_pr_snapshot(&projects[0].id, &PrSnapshot::taken(Vec::new(), None)).await.unwrap();
        let mut events = app.events.subscribe();
        let runner = Arc::new(cli::ScriptedRunner::new().on("gh", |args| {
            args.iter().any(|arg| arg == "graphql").then(|| {
                Ok(br#"{"data":{"r0":{"open":{"nodes":[],"pageInfo":{"hasNextPage":false}},"closed":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}"#.to_vec())
            })
        }));
        cli::scoped(runner.clone(), async {
            let _ = crate::routes::prs_tray(axum::extract::State(app.clone()), look()).await.unwrap();
            let event = tokio::time::timeout(Duration::from_secs(5), events.recv()).await.unwrap().unwrap();
            assert_eq!((&event["type"], &event["projectId"]), (&json!("sync"), &json!(projects[1].id)));
        })
        .await;
        let calls = graphql_calls(&runner);
        assert_eq!(calls.len(), 1, "{calls:?}");
        assert!(calls[0].contains("n0=stale") && !calls[0].contains("fresh"), "{}", calls[0]);
    }

    /// A dashboard read answers from the snapshots at once and syncs the stale ones behind it.
    #[tokio::test]
    async fn a_dashboard_read_syncs_only_stale_snapshots() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let projects = add_projects(&app, &["owner/fresh", "owner/stale"]).await;
        app.db.set_pr_snapshot(&projects[0].id, &PrSnapshot::taken(Vec::new(), None)).await.unwrap();
        let mut events = app.events.subscribe();
        let runner = Arc::new(cli::ScriptedRunner::new().on("gh", |args| {
            args.iter().any(|arg| arg == "graphql").then(|| {
                Ok(br#"{"data":{"r0":{"open":{"nodes":[],"pageInfo":{"hasNextPage":false}},"closed":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}"#.to_vec())
            })
        }));
        cli::scoped(runner.clone(), async {
            let _ = crate::routes::dashboard(axum::extract::State(app.clone()), look()).await.unwrap();
            let event = tokio::time::timeout(Duration::from_secs(5), events.recv()).await.unwrap().unwrap();
            assert_eq!(event["type"], "sync");
            assert_eq!(event["projectId"], projects[1].id);
        })
        .await;
        let calls = graphql_calls(&runner);
        assert_eq!(calls.len(), 1, "{calls:?}");
        assert!(calls[0].contains("n0=stale") && !calls[0].contains("fresh"), "{}", calls[0]);
    }

    /// A project whose sync failed stays stale, but a second read within the poll interval does
    /// not ask GitHub for it again.
    #[tokio::test]
    async fn a_failing_project_is_not_asked_again_on_every_read() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let projects = add_projects(&app, &["owner/gone"]).await;
        let runner = Arc::new(cli::ScriptedRunner::new().on("gh", |args| {
            args.iter().any(|arg| arg == "graphql").then(|| Err("Could not resolve to a Repository".into()))
        }));
        let max_age = Duration::from_secs(60);
        cli::scoped(runner.clone(), app.poller.sync_stale(&app, unsynced(&projects), max_age)).await;
        assert_eq!(graphql_calls(&runner).len(), 1);
        let snapshot = app.db.pr_snapshot(&projects[0].id, "open", None).await.unwrap().unwrap();
        assert!(snapshot.is_stale(60) && snapshot.error.is_some());
        cli::scoped(runner.clone(), app.poller.sync_stale(&app, unsynced(&projects), max_age)).await;
        assert_eq!(graphql_calls(&runner).len(), 1, "tried within the interval");
        cli::scoped(runner.clone(), app.poller.sync_project(&app, projects[0].clone())).await;
        assert_eq!(graphql_calls(&runner).len(), 2, "an explicit sync still runs");
        app.poller.invalidate(&projects[0].id).await;
        cli::scoped(runner.clone(), app.poller.sync_stale(&app, unsynced(&projects), max_age)).await;
        assert_eq!(graphql_calls(&runner).len(), 3, "an edited project is read afresh");
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
                Ok(br#"{"data":{"r0":{"open":{"nodes":[],"pageInfo":{"hasNextPage":false}},"closed":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}"#.to_vec())
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
            let run = Msg::Run { app: app.clone(), job: Job::Projects(vec![project]), ask: Ask::Now, runner: Some(runner.clone()), done };
            engine.handle(run, &mut tasks);
        }
        assert_eq!((engine.github_running, engine.waiting.len(), engine.claimed.len()), (4, 2, 6));
        let board = app.db.projects().await.unwrap().remove(0);
        let (done, board_heard) = oneshot::channel();
        let run = Msg::Run { app: app.clone(), job: Job::Board(board), ask: Ask::Now, runner: Some(runner.clone()), done };
        engine.handle(run, &mut tasks);
        assert_eq!((engine.github_running, engine.waiting.len()), (4, 2), "a board takes no lane");
        let fifth = engine.waiting[0].job.projects()[0].id.clone();
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
                Ok(br#"{"data":{"r0":{"open":{"nodes":[],"pageInfo":{"hasNextPage":false}},"closed":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}"#.to_vec())
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

