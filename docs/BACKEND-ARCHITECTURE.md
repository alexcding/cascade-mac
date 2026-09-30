# Backend architecture: the shape `crates/cascade-backend` should take

Chosen for, in this order: **reliable** (one subsystem cannot wedge or race another), **testable**
(every rule runs in a unit test without `gh`, `git`, `acli` or a file on disk), **fast** (each
expensive thing lives in one place, where it can be bounded, cached and measured).

These are the common Rust patterns for a tokio + axum + rusqlite service, applied where each
fits. Nothing here is a framework; it is four idioms and a rule about where each one goes.

| Idiom | Applied to | Why it is the standard answer |
|---|---|---|
| **Actor: a task owns its state, callers send messages** | the database, the sync engine, forwarders, warm-up, usage, agent permissions | Replaces every `Mutex<HashMap>` and every static with one owner; the way tokio recommends holding state that outlives a request, and the way `tokio-rusqlite` holds a `Connection` |
| **Layered request path: handler → service function → adapter** | git, files, worktrees, diff, Xcode, Jira reads | What every production axum app does; a handler parses and replies, a plain `async fn` does the work |
| **Typed models, `thiserror` errors, newtype IDs** | everything that crosses a module boundary | Rust's type system is the review tool; `serde_json::Value` turns it off |
| **Traits only at the seams a test must replace** | the process runner, the clock | `Arc<dyn Trait>` where a fake is needed, concrete types everywhere else; generic-everything is not idiomatic and slows compiles |

## Where the code was, and where it is

Read from the source on 2026-09-29, before the migration below; every point had a file behind
it. Each is answered in the step list at the end, and the paragraph after this list says what
stands on 2026-09-30.

- **Shared state under std mutexes on the runtime.** `Poller` has four (`in_flight`,
  `pr_states`, `seeded`, `generations`); `ForwarderManager` one (`children`); `Warmup` two
  (`states`, `gates`); `Usage` one; `transcript.rs`, `claude.rs`, `permission.rs`, `runner.rs`
  keep caches and flags in `static Mutex`es. Coordination is by hand: `enter`/`leave` keys,
  generation counters checked twice per sync.
- **Three `Mutex<Connection>`s, every call synchronous on a tokio worker.** Fine at
  sub-millisecond, but the rule is written nowhere, so `get_file` reads and hashes 5 MB inline
  and `observe_prs` commits one row per open PR per tick.
- **`serde_json::Value` is the model.** A PR, project, tab, task and snapshot are `Value` at
  every layer. `project["repo"].as_str().unwrap_or("")` recurs in the poller, the automation
  triggers and the routes; `pr.as_object_mut().unwrap()` would panic on a non-object.
- **Handlers hold logic** (`rename_tab`, `issues_search`, `prs_tray`, `project_board`) and
  reach `state.db`, `github`, `poller`, `local` directly; handler code sits in ten modules.
- **`Database` is 1,100 lines** of storage plus rules that are not storage: review-state
  pruning, tab positioning, 30-day hook retention, 5,000-row log retention, a cross-database
  cascade. It leaks raw connection guards to `automation/store`.
- **Errors are `anyhow` inside and `ApiError` at the edge**, so every failure is a 500 unless
  a handler hand-maps it. Worktree and switch failures answer `200 {"error"}`, and the Swift
  client throws on any body with `error`, so it decodes every success body twice.
- **Cycles**: `agents` ↔ `usage`, `agents` ↔ `integrations`, `integrations` ↔ `automation`.
- **One seam exists already**: `cli::run` owns process groups, timeouts, kill-on-drop. It has no
  concurrency bound and no test double. `AgentProbe` is a well-shaped adapter trait; keep it.

**On 2026-09-30**, after steps 1 to 7: the sync engine, the forwarders and the tool approvals
are tasks with `Clone` handles on `AppState`, and the only locks left on the runtime are short
tables (`Usage`, `Warmup`, `automation::Limits`) and the adapters' own caches. SQLite runs on
three store threads behind `db::Store`. `Project`, `Session` and `PrSnapshot` are typed at the
store boundary; the pull request itself is still a `Value` (step 5 says why). The backend tells
the app what changed through `Event`, only when something did. Every process goes through
`cli::CommandRunner`, and a test scripts it. `local` is five modules and answers statuses. The
module cycles are gone. Handlers still hold logic and `Database` is still one file: those were
not in scope and are listed under "What is left".

## The target

```
 Swift ──▶ ffi.rs / axum router ──▶ handlers (parse · call · reply)
                                        │
                        ┌───────────────┼──────────────────────┐
                        ▼               ▼                      ▼
                   service fns      actor handles          actor handles
                   git · files      Db (3 threads)         Sync · Forwarders
                   worktrees        Events (broadcast)     Warmup · Usage
                   diff · xcode                            Permissions
                        │               ▲                      │
                        ▼               │ messages             ▼
                   CommandRunner ◀──────┴──────────────── CommandRunner
                   (gh · git · acli · xcodebuild · curl; one Semaphore)

 domain/ : PullRequest · Project · Snapshot<T> · Tab · Task · Event · lean() · stale()
           depends on serde and chrono only
```

### Actors: who owns what

An actor is a `tokio::spawn`ed loop over an `mpsc::Receiver<Msg>`; its handle is a `Clone`
struct wrapping the `Sender`, with one `async fn` per message that awaits a `oneshot` reply.
Nothing else sees the state.

| Actor | Owns (today scattered) | Messages, in short |
|---|---|---|
| `Db` (one per file: durable, cache, logs) | the `rusqlite::Connection`, on its own std thread | `call(FnOnce(&mut Connection) -> R)`; typed methods on the handle wrap it. `tokio-rusqlite` is this exactly; adopt it or hand-roll 60 lines |
| `Sync` (done: `poller::Engine`) | `in_flight`, `generations`, `pr_states`, `seeded`, the two poll loops | `Start`, `Run(Project/Scope/Board)`, `Invalidate(id)`, `Observe(seen)`, `Merged(key)` |
| `Events` | the `broadcast::Sender<Event>` | `publish(Event)`; lag is handled here, once |
| `Forwarders` (done: `integrations::Forwarders`) | the `gh webhook forward` children | `Start`, `Reconcile(desired)`, `List`, `Statuses`, `Retry(repo)`, `Stop` |
| `Warmup` | `states`, `gates` | `Warm(worktree, ide)`, `Forget(worktree)` |
| `Usage` | the 300 s cache and its `busy` flag | `Get`, `Refresh` |
| `Permissions` (done: `agents::permission::Permissions`) | `PENDING` | `Offer(id)`, `Answer(id, decision)`, `Forget(id)` |

What this buys, concretely:

- **No `Mutex` across the crate.** A `HashSet<String>` behind `enter`/`leave` becomes a field
  of the `Sync` actor; the RAII guard added this week becomes unnecessary because there is one
  thread of control. The `Lagged` handling added this week lives in `Events`, once.
- **The database stops blocking the runtime.** Every call crosses to the connection's thread
  and back through a `oneshot`; the runtime workers only ever await. Batching becomes a message:
  `observe_prs` sends one `SetPrStates(Vec<..>)` and the actor wraps it in a transaction.
- **A subsystem is tested by sending it messages.** `Sync` with a scripted `CommandRunner`:
  send `SyncProject`, assert one `Event::Sync` was published; send it again, assert none.
- **Shutdown is a message, then the runtime.** `cascade_backend_stop` sends `Forwarders` a
  `Stop`, which kills the children, and then shuts the runtime down, which drops every actor
  task with whatever it still holds (a child is `kill_on_drop`). A started actor's tick loop
  holds an `AppState`, so its receiver never closes on its own.

Actors are for state that outlives a request. They are not for everything: `git diff`, reading a
file, creating a worktree have no state to own and stay plain functions.

### The request path: handler → service function → adapter

- A **handler** is ten lines: deserialize, call one function, `Ok(Json(reply))`, `?` on a typed
  error. No `state.db`, no `cli::run`, no `json!` body, no `if`.
- A **service function** is a plain `pub async fn` in `services/` that takes what it needs as
  arguments: `pub async fn diff(runner: &dyn CommandRunner, dir: &Path) -> Result<Diff, GitError>`.
  It owns the rule and returns a domain type. It is unit-tested with a `ScriptedRunner`.
- An **adapter** is the only code that touches a process, a file or SQLite. `adapters/cli/`
  holds `CommandRunner` and the per-tool argument builders (`gh.rs`, `git.rs`, `acli.rs`,
  `xcodebuild.rs`, `curl.rs`). The `Semaphore` bounding concurrent `gh` lives in the runner; the
  `stamp_of` and `remembered` caches live beside the tool they cache.
- **`AppState` is the composition root**: it builds the actors and the runner once and hands
  handlers the handles. Handlers take `State<Handles>`; nothing else imports `AppState`.

### Types and errors

- `domain/` holds `PullRequest`, `Project`, `Snapshot<T>`, `Tab`, `Task`, `Event`, plus the
  pure functions `lean` (as `impl From<GhPullRequest> for PullRequest`), `stale`,
  `snapshot_changed`. It depends on `serde` and `chrono` only, so its tests are plain
  `#[test]`s and it could become a crate the day something else needs it.
- IDs are newtypes: `ProjectId(String)`, `PrNumber(i64)`, `WorktreePath(PathBuf)`. A function
  that takes a `ProjectId` cannot be handed a repo name.
- `Event` is an enum with `#[serde(tag = "type", rename_all = "kebab-case")]`, so the app's
  `ServerEvent` decoder reads it unchanged. The publish rule: **content equal to what is stored
  is not an event.** The poller does this for PRs now; it becomes the rule for Jira too.
- Errors are `thiserror` enums per service (`GitError::Held`, `GitError::BadBranch(String)`,
  `WorktreeError::FolderExists(PathBuf)`), mapped to statuses in `error.rs` once (`409`,
  `422`, `404`, `500`). `anyhow` stays in `main.rs` and tests. Then `create_worktree` and
  `git_switch` stop answering `200 {"error"}`, and the Swift client's `request` can gate its
  `Failure` decode on the status as `get` already does.

### Module layout

The tree stays flat; the layers are a rule about who may call whom, not folders. As it stands:

```
src/
  main.rs · ffi.rs · lib.rs            composition root: AppState, start_background, the router
  routes.rs sessions.rs fork.rs        handlers; automation/routes.rs and integrations.rs hold theirs
  error.rs                             ApiError: the one status map
  poller.rs                            the Sync engine (Engine + Poller handle) and the sync functions
  integrations.rs                      the Forwarders task and the agent-hook installer
  agents/permission.rs                 the Permissions task
  db.rs                                Database over three db::Store threads; the SQL, one file
  domain/                              Project, Session, PrSnapshot; event.rs beside it
  local/ worktrees.rs xcode.rs         services: files, IDE, worktrees, git, patches, Xcode
  github.rs jira.rs issues.rs agents/  adapters: gh, acli and Jira REST, gh issue, the CLIs
  cli.rs settings_file.rs              the process seam (CommandRunner) and the CLIs' settings files
  automation/                          pipelines: triggers, filters, actions, version, runner, store
  warmup.rs usage.rs recovery.rs
```

A directory split (`transport/`, `actors/`, `services/`, `adapters/`, `sqlite/` one file per
aggregate) is a rename with no behaviour in it; do it when a module outgrows one file, not
before. The rules that still sit in `db.rs` (review-state pruning, log retention, the delete
cascade) move up with it.

### Tests, by layer

| Layer | Tested with | Example |
|---|---|---|
| domain | `#[test]` | `lean` drops fields; `snapshot_changed` on an unchanged list is false |
| services | `ScriptedRunner` + in-memory `Db` | `diff` maps a `git` failure to `GitError`; `worktrees::create` refuses a symlinked root |
| actors | send messages, assert replies and published events | `Sync`: two ticks, same PRs, one `Event::Sync` |
| adapters | the real thing, sandboxed | SQLite in memory; `git` in a temp repo (as `tests/worktrees.rs` does now) |
| transport | `route_contract` + `oneshot` | every Swift route is served; `GitError::Held` is a 409 |

The service and actor rows are where coverage is missing and where the bugs have been: a
missed `leave` that wedged a key, a broadcast on every tick, a login asked of `gh` twice per
tick. Each becomes a five-line test.

## What belongs in the backend, and what does not

The rule: **the backend owns what a CLI, a file system, a poll loop or a second process needs;
the app owns how one window looks.** There is one client (the `Cargo.toml` note about "the web
client" is stale; AGENTS.md is right that none exists), so nothing is stored server-side for the
sake of sharing it.

### Was stored in the backend, though only the app read it (moved on 2026-09-29)

| State | Was | Now |
|---|---|---|
| **Tabs** (URL, title, position, pinned, active, pane view, category) | `tabs` table behind `/api/tabs` with five methods and the position and dedupe rules in `db.rs`; every open, close, rename, pin and reorder a round trip | `TabStore` (`Services/Workspace/TabStore.swift`), one JSON file in the shape the backend answered with plus an `imported` flag. It stays out of the format-1 recovery checkpoint on purpose: an earlier build would refuse a fourth entry at its next start (`docs/DATA-RECOVERY.md`). `GET /api/tabs` stays read-only for one release so the old list is adopted once, with the first inventory read; then the route and table go. |
| **Preferences** (theme, fonts, terminal, editor, icon theme, sounds, memory limits, board filters) | `settings` table behind two routes, mirrored from `UserDefaults` on every change and adopted back on every connect | `UserDefaults` alone. The write route is gone; `GET /api/settings` stays read-only for one release so the boards' assignee filters, the one preference that lived only in the backend, are adopted once (`ShellStore.importLegacyPreferences`). Dropping the table is a follow-up. The backend reads its own knobs (`worktree_fetch`, poll intervals, Jira URL and token, `board_query_*`) from `config`, as it did. |
| **Page tabs per context** (`native.context.<id>`) | Written to the `settings` table and to `page-tabs.json`, restored from the backend on connect | `page-tabs.json` alone, read when `ViewerStore` is made. `recovery.rs` keeps hashing that file in its checkpoint: it is now the whole page state, not pending writes, so it earns its place there (`docs/DATA-RECOVERY.md`). |

### Was done in the app, though it is backend logic

| Logic | Was | Now |
|---|---|---|
| **Ticket stage, priority and "reopened" from Jira text** | `TicketStage.init(status:category:)`, `TicketPriority.init(_:)` and a `contains("reopen")` in the attention ranking: `acli`-shaped rules in a scene model | `tickets.rs` puts `stage`, `level` and `reopened` on every ticket the backend hands out, Jira or GitHub issue; the app reads them. A ticket from a snapshot written before that reads as in progress and Medium until the next sync. |
| **Creating a session** | `GET /api/worktree`, an optional free-the-main-checkout step, `POST /api/worktree`, `POST /api/tasks`, sequential, with "a worktree without a task is invisible" enforced by the client not failing halfway | `POST /api/sessions` (`sessions.rs`): resolves the branch's worktree, parks the main checkout on the base when it holds the branch, makes or reuses the worktree, writes the record last and answers with it. Typed statuses: 400 for a bad address, 404 for the project, 409 for a checkout it cannot free or a worktree that changed, 422 for a worktree git refused. The app makes one call. |

### Correctly placed; leave alone

Projects, links, tasks (sessions: `fork.rs`, the worktree paths and hook relay need them),
review state (the tray's pending rule runs in `prs_tray`), snapshots, Xcode answers, agent hooks,
logs, automations: backend. Bookmarks, history, ad-block lists, shortcuts, welcome state, sidebar
selection, window layout, file-icon theme packages: app.

`sessions.rs` is also the first handler written as the target describes: it composes the work
of `local.rs` through `pub(crate)` functions rather than other handlers, returns typed statuses,
and is covered end to end against a real repository in `tests/worktrees.rs`.

## Getting there without a big bang

One pull request per step; `route_contract` stays green. Seams first, so everything after them
moves under test. Status as of 2026-09-29:

1. **Done. `Event` enum and change-gated publishing.** `src/event.rs` is the contract the app's
   `ServerEvent` decodes; `AppState::publish` sends one, and the one untyped path left is an agent
   hook relayed as it came. PR and Jira snapshots publish only when their content changed
   (`poller::snapshot_changed`, `poller::jira_snapshot_changed`).
2. **Done. `CommandRunner` seam.** `cli::Invocation`, `cli::CommandRunner`, `ProcessRunner` and
   `ScriptedRunner`; a test installs a runner with `cli::scoped(runner, future)` and the whole
   sync engine runs against scripted `gh` (`poller::snapshot_tests`). The `gh` burst is bounded
   where it starts: the sync engine runs four project syncs at a time (`poller::GH_LANES`), and
   a request the user is waiting on never queues behind it. The runner is a task-local rather than
   a parameter for now: threading it through every signature is the remaining half of this step.
3. **Done. Database stores on their own threads.** `db::Store` owns one connection each; every
   `Database` and `automation::store` function is async and runs its closure there. No SQLite
   statement runs on a runtime worker, and no connection is behind a mutex. Twenty-six functions
   that reached the database became async with it.
4. **Done. `local.rs` split** into `local/{files,ide,worktree,git,patch}.rs` under one `mod.rs`
   that holds what they share and re-exports their handlers. The avatar fetch is still in
   `local/git.rs`.
5. **Done for the records, deferred for the pull request. Domain types.** `src/domain/` holds
   `Project`, `Session` (the task record) and `PrSnapshot` (`{prs, lastSynced, error}`), converted
   at the SQLite functions: `projects`, `project`, `add_project`, `update_project`, `tasks`,
   `task`, `upsert_task`, `pr_snapshot`, `set_pr_snapshot`, `set_pr_scope_snapshot` and
   `all_pr_snapshots` answer and take the struct, and the poller, automation, worktrees, fork,
   session, dashboard and tray code read fields instead of indexing `Value`. Staleness and
   change detection are the snapshot's own methods (`is_stale`, `differs`). Serde names are the
   JSON the app already reads, so the wire is unchanged, checked by the domain tests' shape
   assertions, `route_contract` and the Swift `Codable` types. `patch_task` and
   `update_project` still take a `Map` because a patch is a partial record by definition.
   **Not done: the pull request itself.** `PrSnapshot::prs` is `Vec<Value>` because a PR is read
   in three shapes: enriched, before `lean`, by `observe_prs`, `fingerprint` and
   `record_lifecycle` (with `reviewRequests`, `body`, `mergedAt`); lean, from the snapshot, with
   24 keys plus `repo` and several optional (`myReview` absent, `ci` null, `requestedAt` added
   by the poller); and a REST hybrid that `merged_pr` builds for a webhook merge
   (`author.is_bot`, `labels[].name` only). One struct for the three, across 43 read sites, is
   its own change with its own review, and it should start by making `lean` the single
   producer. `Tab` is not coming: tabs moved to the app on 2026-09-29 and the backend only
   serves the one-time import.
6. **Done. `Sync` and the other actors.** The sync engine is the first: `poller.rs`
   `Engine` is one task owning what four std mutexes and a static semaphore held (running syncs,
   generations, `pr_states`, `seeded`, the GitHub lanes), and `Poller` is its `Clone` handle
   whose every method is a message. A sync is a free function the engine spawns with the
   `Generation` it started under; the same sync asked for while it runs is coalesced; a task's
   end is observed through its `JoinSet`, so a panic releases its key too; the key is released
   before the caller hears, so a sync asked for right after is a new one. The RAII guard and
   `SYNC_LANES` are gone. Lifecycle decisions (`observe`, `merged`) are pure methods on the
   engine, tested without a runtime. `Forwarders` followed: `integrations::Forwarders` owns
   the `gh webhook forward` children and their backoff, handles every message without an
   await, and answers a reconcile with the log lines for its loop to write, so the list, the
   statuses and a retry are never behind a reconcile (before, two tokio mutexes were held across
   the whole of it). `AppState` holds both handles directly, as they are `Clone`. `Permissions`
   followed the same shape for the offers waiting on an answer (`PENDING` is gone), and the
   automation runner's hourly limits are a value on `AppState` (`automation::Limits`) instead of
   two statics: a table behind a short lock that is never held across an await, which is the
   rule for state with no loop and no children of its own (`Usage` and `Warmup` already are).
   Statics that stay, on purpose: the adapters' own caches of what a CLI answered (`gh`'s login,
   `claude`'s initialize reply), the serialisers for forks and simulator devices, and the shell
   discovery in `cli.rs`; none depends on an `AppState`, and a test pins the login through
   `CASCADE_AUTOMATION_LOGIN`. The module cycles are broken, each by moving code to the layer
   that owns it: the `acli` calls (`search_jira`, `active_sprint`, `transition`, `assign`) left
   `poller` for the `jira` adapter, so `automation` no longer imports the engine and reaches it
   only through `AppState.poller`; the per-CLI usage probes left `usage` for `agents/usage.rs`,
   so `agents` no longer imports the service that aggregates them; the JSON settings-file
   helpers became `settings_file.rs` and `shell_quote` joined `cli`, so `agents/statusline`
   no longer imports `integrations`; the transcript route joins the transcript with its hook
   status in `routes.rs`, so `agents` does not ask `integrations`; the Fix Version template moved
   to `automation/version.rs` and the forwarder routes to `automation/routes.rs`, and the
   forwarders take the wanted repos as a function from `start_background` in `lib.rs`, so
   `integrations` no longer imports `automation`. What is left is one direction: `poller` tells
   `automation` what a sync saw, and `automation` and `routes` call the adapters.
7. **Done. Statuses instead of `200 {"error"}`.** Every such reply in `local` is a 409, 413 or
   422 with the same message; the Swift client decodes a failure body only on a non-2xx status,
   so a success body is decoded once. `thiserror` enums per service are still to come: the
   statuses are chosen at the handler, not carried by a typed error.

## What is left

Not in the seven steps, and not started; each is its own change with its own review.

- **The pull request as a type.** `PrSnapshot::prs` is `Vec<Value>`; step 5 says what makes it
  three shapes today and that `lean` should become the one producer first.
- **Handlers that hold logic** (`prs_tray`, `project_board`, `issues_search`, `rename_tab`):
  each becomes a service function with the handler as the thin edge, so it can be tested with
  a scripted runner instead of a router.
- **`Database` as one file**, with rules that are not storage (review-state pruning, log
  retention, the cross-database delete cascade); split by aggregate and move the rules up.
- **`thiserror` enums per service** in place of `anyhow` inside, so statuses are carried by
  the error rather than chosen at the handler (step 7 left this).
- **`CommandRunner` as a parameter** rather than a task-local, threaded through the signatures
  (step 2 left this; `cli::inherited` bridges a spawn meanwhile).

## What not to do

- **No trait for every module.** Traits at the two seams a test must replace (the runner, the
  clock). Actors are already mockable through their handle, and services are plain functions.
- **No `async` trait for storage.** The `Db` actor takes closures over `&mut Connection`;
  SQLite is synchronous and the actor thread is where it runs.
- **No crate split yet.** `domain/` is written so it could become one; do it when something
  else needs it without tokio.
- **No event sourcing, no command bus, no CQRS.** One `broadcast` channel of a typed enum.
- **Do not move rules into the app to avoid the work.** Views present what the API returns.
