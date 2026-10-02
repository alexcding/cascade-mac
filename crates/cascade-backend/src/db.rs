//! The three SQLite stores, each behind the thread that owns its connection. rusqlite is
//! synchronous; here it runs on those threads, one statement after another, and the async
//! runtime only ever waits for an answer. `cascade.db` is durable, `data.db` and `logs.db` are
//! regenerable caches.

use std::{
    fs,
    path::{Path, PathBuf},
    sync::mpsc,
};

use anyhow::{Context, Result};
use chrono::Utc;
use rusqlite::{params, params_from_iter, Connection, OptionalExtension, Row};
use serde_json::{json, Map, Value};
use uuid::Uuid;

use crate::{PrSnapshot, Project, Session};

type Job = Box<dyn FnOnce(&mut Connection) + Send>;

/// One SQLite file and the thread that owns its connection. Work reaches it as a closure over a
/// channel and the answer comes back over a oneshot, so a caller awaits and never blocks a
/// runtime worker, and the statements of one store still run one after another.
pub(crate) struct Store {
    jobs: mpsc::Sender<Job>,
}

impl Store {
    fn spawn(name: &str, mut connection: Connection) -> Result<Self> {
        let (jobs, inbox) = mpsc::channel::<Job>();
        std::thread::Builder::new()
            .name(format!("cascade-db-{name}"))
            .spawn(move || {
                for job in inbox {
                    // `call` answers a panicking closure with its reason; this catch is the
                    // backstop that keeps the thread serving whatever else panics.
                    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        job(&mut connection)
                    }));
                    if let Err(payload) = outcome {
                        let reason = panic_reason(&payload);
                        tracing::error!(%reason, "a database job panicked; the store keeps serving");
                    }
                }
            })
            .with_context(|| format!("start the {name} database thread"))?;
        Ok(Self { jobs })
    }

    /// Runs `work` on the connection's thread and answers with what it returned.
    pub(crate) async fn call<T, F>(&self, work: F) -> rusqlite::Result<T>
    where
        T: Send + 'static,
        F: FnOnce(&mut Connection) -> rusqlite::Result<T> + Send + 'static,
    {
        let (reply, answer) = tokio::sync::oneshot::channel();
        let job: Job = Box::new(move |connection| {
            // A panic in `work` is the caller's error, named: a row that did not map is not a
            // dead thread, and the thread is not dead.
            let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| work(connection)));
            let _ = reply.send(outcome.unwrap_or_else(|payload| {
                let reason = panic_reason(&payload);
                tracing::error!(%reason, "a database job panicked; the store keeps serving");
                Err(panicked(&reason))
            }));
        });
        self.jobs.send(job).map_err(|_| gone())?;
        answer.await.map_err(|_| gone())?
    }
}

fn panic_reason(payload: &(dyn std::any::Any + Send)) -> String {
    payload
        .downcast_ref::<&str>()
        .map(|text| text.to_string())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "no message".into())
}

fn panicked(reason: &str) -> rusqlite::Error {
    rusqlite::Error::SqliteFailure(
        rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_INTERNAL),
        Some(format!("a database job panicked: {reason}")),
    )
}

fn gone() -> rusqlite::Error {
    rusqlite::Error::SqliteFailure(
        rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_MISUSE),
        Some("the database thread is gone".into()),
    )
}

pub struct Database {
    pub(crate) durable: Store,
    pub(crate) cache: Store,
    pub(crate) logs: Store,
    pub data_dir: PathBuf,
}

impl Database {
    pub fn open(data_dir: &Path) -> Result<Self> {
        fs::create_dir_all(data_dir)?;
        let durable = open_db(&data_dir.join("cascade.db"))?;
        let cache = open_db(&data_dir.join("data.db"))?;
        let mut logs = open_db(&data_dir.join("logs.db"))?;
        initialize_durable(&durable)?;
        initialize_cache(&cache)?;
        initialize_logs(&logs)?;
        migrate_events_to_logs(&durable, &mut logs)?;
        Ok(Self {
            durable: Store::spawn("durable", durable)?,
            cache: Store::spawn("cache", cache)?,
            logs: Store::spawn("logs", logs)?,
            data_dir: data_dir.to_path_buf(),
        })
    }

    pub async fn config(&self) -> rusqlite::Result<Value> {
        self.durable.call(|conn| key_values(conn, "config")).await
    }

    pub async fn config_value(&self, key: &str) -> rusqlite::Result<Option<String>> {
        let key = key.to_owned();
        self.durable
            .call(move |conn| {
                conn.query_row("SELECT value FROM config WHERE key=?1", [key], |row| {
                    row.get(0)
                })
                .optional()
            })
            .await
    }

    pub async fn set_config(&self, values: &Map<String, Value>) -> rusqlite::Result<()> {
        let values = values.clone();
        self.durable
            .call(move |conn| {
                let tx = conn.transaction()?;
                for (key, value) in &values {
                    tx.execute(
                        "INSERT INTO config (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                        params![key, js_string(value)],
                    )?;
                }
                tx.commit()
            })
            .await
    }

    pub async fn projects(&self) -> rusqlite::Result<Vec<Project>> {
        self.durable
            .call(|conn| {
                let mut statement =
                    conn.prepare("SELECT * FROM projects ORDER BY created_at ASC")?;
                let result = statement.query_map([], project_from_row)?.collect();
                result
            })
            .await
    }

    /// The preferences an earlier version mirrored here. Read only, for the app to adopt once;
    /// nothing writes this table any more.
    pub async fn settings(&self) -> rusqlite::Result<Value> {
        self.durable.call(|conn| key_values(conn, "settings")).await
    }

    pub async fn project(&self, id: &str) -> rusqlite::Result<Option<Project>> {
        let id = id.to_owned();
        self.durable.call(move |conn| project_row(conn, &id)).await
    }

    pub async fn add_project(&self, patch: &Map<String, Value>) -> rusqlite::Result<Project> {
        let patch = patch.clone();
        self.durable
            .call(move |conn| {
                let id = Uuid::new_v4().to_string();
                let created_at = patch
                    .get("created_at")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .unwrap_or_else(now);
                let get = |key: &str| patch.get(key).and_then(Value::as_str).unwrap_or("");
                conn.execute(
                    "INSERT INTO projects (id,name,repo,workspace,jira_project_key,merge_transition,forward_webhooks,fix_version_enabled,fix_version_prefix,fix_version_script,ide,ide_cmd,ide_target,run_scheme,run_sim,worktree_setup,worktree_include,issues_enabled,board_enabled,created_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20)",
                    params![
                        id, get("name"), get("repo"), get("workspace"), get("jiraProjectKey"),
                        get("mergeTransition"), bool_int(patch.get("forwardWebhooks"), true),
                        bool_int(patch.get("fixVersionEnabled"), false), get("fixVersionPrefix"),
                        get("fixVersionScript"), get("ide"), get("ideCmd"), get("ideTarget"),
                        get("runScheme"), get("runSim"), get("worktreeSetup"), get("worktreeInclude"),
                        bool_int(patch.get("issuesEnabled"), true),
                        bool_int(patch.get("boardEnabled"), false),
                        created_at,
                    ],
                )?;
                project_row(conn, &id)?.ok_or(rusqlite::Error::QueryReturnedNoRows)
            })
            .await
    }

    pub async fn update_project(
        &self,
        id: &str,
        patch: &Map<String, Value>,
    ) -> rusqlite::Result<Option<Project>> {
        let id = id.to_owned();
        let patch = patch.clone();
        self.durable
            .call(move |conn| {
                if project_row(conn, &id)?.is_none() {
                    return Ok(None);
                }
                const FIELDS: &[(&str, &str, FieldKind)] = &[
                    ("name", "name", FieldKind::String),
                    ("repo", "repo", FieldKind::String),
                    ("workspace", "workspace", FieldKind::String),
                    ("jiraProjectKey", "jira_project_key", FieldKind::String),
                    ("mergeTransition", "merge_transition", FieldKind::String),
                    ("forwardWebhooks", "forward_webhooks", FieldKind::Bool),
                    ("fixVersionEnabled", "fix_version_enabled", FieldKind::Bool),
                    ("fixVersionPrefix", "fix_version_prefix", FieldKind::String),
                    ("fixVersionScript", "fix_version_script", FieldKind::String),
                    ("ide", "ide", FieldKind::String),
                    ("ideCmd", "ide_cmd", FieldKind::String),
                    ("ideTarget", "ide_target", FieldKind::String),
                    ("runScheme", "run_scheme", FieldKind::String),
                    ("runSim", "run_sim", FieldKind::String),
                    ("worktreeSetup", "worktree_setup", FieldKind::String),
                    ("worktreeInclude", "worktree_include", FieldKind::String),
                    ("issuesEnabled", "issues_enabled", FieldKind::Bool),
                    ("boardEnabled", "board_enabled", FieldKind::Bool),
                ];
                let mut sets = Vec::new();
                let mut values = Vec::<rusqlite::types::Value>::new();
                for (field, column, kind) in FIELDS {
                    let Some(value) = patch.get(*field) else {
                        continue;
                    };
                    sets.push(format!("{column}=?"));
                    values.push(match kind {
                        FieldKind::String => {
                            rusqlite::types::Value::Text(value.as_str().unwrap_or("").to_owned())
                        }
                        FieldKind::Bool => rusqlite::types::Value::Integer(i64::from(
                            value.as_bool().unwrap_or(false),
                        )),
                    });
                }
                if !sets.is_empty() {
                    values.push(rusqlite::types::Value::Text(id.clone()));
                    conn.execute(
                        &format!("UPDATE projects SET {} WHERE id=?", sets.join(",")),
                        params_from_iter(values),
                    )?;
                }
                project_row(conn, &id)
            })
            .await
    }

    pub async fn invalidate_snapshots(&self, id: &str) -> rusqlite::Result<()> {
        let id = id.to_owned();
        self.cache
            .call(move |cache| {
                cache.execute("DELETE FROM pr_snapshots WHERE id=?1", [&id])?;
                cache.execute("DELETE FROM pr_scope_snapshots WHERE id=?1", [&id])?;
                cache.execute(
                    "DELETE FROM jira_snapshots WHERE id=?1 OR id=?2",
                    params![id, format!("board:{id}")],
                )?;
                Ok(())
            })
            .await
    }

    pub async fn delete_project(&self, id: &str) -> rusqlite::Result<()> {
        let durable_id = id.to_owned();
        self.durable
            .call(move |durable| {
                let tx = durable.transaction()?;
                tx.execute("DELETE FROM projects WHERE id=?1", [&durable_id])?;
                tx.execute("DELETE FROM links WHERE project_id=?1", [&durable_id])?;
                tx.commit()
            })
            .await?;
        let id = id.to_owned();
        self.cache
            .call(move |cache| {
                cache.execute("DELETE FROM pr_snapshots WHERE id=?1", [&id])?;
                cache.execute(
                    "DELETE FROM jira_snapshots WHERE id=?1 OR id=?2",
                    params![id, format!("board:{id}")],
                )?;
                cache.execute("DELETE FROM pr_scope_snapshots WHERE id=?1", [&id])?;
                Ok(())
            })
            .await
    }

    pub async fn tasks(&self) -> rusqlite::Result<Vec<Session>> {
        self.durable
            .call(|conn| {
                let mut statement = conn.prepare("SELECT * FROM tasks ORDER BY created_at ASC")?;
                let result = statement.query_map([], task_row)?.collect();
                result
            })
            .await
    }

    pub async fn task(&self, id: &str) -> rusqlite::Result<Option<Session>> {
        let id = id.to_owned();
        self.durable
            .call(move |conn| {
                conn.query_row("SELECT * FROM tasks WHERE id=?1", [id], task_row)
                    .optional()
            })
            .await
    }

    /// Saves the session's own columns; `false` when the record is not complete
    /// (`Session::is_complete`). The patch-only fields (name, run settings, fork links) are left
    /// as they are, and an empty `created_at` is now.
    pub async fn upsert_task(&self, session: &Session) -> rusqlite::Result<bool> {
        if !session.is_complete() {
            return Ok(false);
        }
        let session = session.clone();
        self.durable
            .call(move |conn| {
                let created_at = if session.created_at.is_empty() {
                    now()
                } else {
                    session.created_at.clone()
                };
                conn.execute(
                    "INSERT INTO tasks (id,project_id,workspace,worktree,branch,title,kind,url,jira_key,cli,session_id,created_at,pinned) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13) ON CONFLICT(id) DO UPDATE SET project_id=excluded.project_id,workspace=excluded.workspace,worktree=excluded.worktree,branch=excluded.branch,title=excluded.title,kind=excluded.kind,url=excluded.url,jira_key=excluded.jira_key,cli=excluded.cli,session_id=excluded.session_id,pinned=excluded.pinned",
                    params![session.id, session.project_id, session.workspace, session.worktree, session.branch, session.title, session.kind, session.url, session.jira_key, session.cli, session.session_id, created_at, i64::from(session.pinned)],
                )?;
                Ok(true)
            })
            .await
    }

    pub async fn delete_task(&self, id: &str) -> rusqlite::Result<()> {
        let id = id.to_owned();
        self.durable
            .call(move |conn| {
                conn.execute("DELETE FROM tasks WHERE id=?1", [id])?;
                Ok(())
            })
            .await
    }

    pub async fn pin_task(&self, id: &str, pinned: bool) -> rusqlite::Result<bool> {
        let id = id.to_owned();
        self.durable
            .call(move |conn| {
                Ok(conn.execute(
                    "UPDATE tasks SET pinned=?1 WHERE id=?2",
                    params![i64::from(pinned), id],
                )? > 0)
            })
            .await
    }

    pub async fn patch_task(&self, id: &str, patch: &Map<String, Value>) -> rusqlite::Result<bool> {
        const FIELDS: &[(&str, &str)] = &[
            ("title", "title"),
            ("kind", "kind"),
            ("url", "url"),
            ("jiraKey", "jira_key"),
            ("cli", "cli"),
            ("sessionId", "session_id"),
            ("runScheme", "run_scheme"),
            ("runSim", "run_sim"),
            ("name", "name"),
            ("forkFrom", "fork_from"),
            ("forkedFrom", "forked_from"),
        ];
        let mut sets = Vec::new();
        let mut values = Vec::<rusqlite::types::Value>::new();
        for (field, column) in FIELDS {
            if let Some(value) = patch.get(*field).and_then(Value::as_str) {
                sets.push(format!("{column}=?"));
                values.push(rusqlite::types::Value::Text(value.to_owned()));
            }
        }
        if sets.is_empty() {
            return Ok(false);
        }
        values.push(rusqlite::types::Value::Text(id.to_owned()));
        self.durable
            .call(move |conn| {
                Ok(conn.execute(
                    &format!("UPDATE tasks SET {} WHERE id=?", sets.join(",")),
                    params_from_iter(values),
                )? > 0)
            })
            .await
    }

    pub async fn links(&self, project: Option<&str>) -> rusqlite::Result<Vec<Value>> {
        let project = project.map(str::to_owned);
        self.durable
            .call(move |conn| {
                let sql = if project.is_some() {
                    "SELECT * FROM links WHERE project_id=?1"
                } else {
                    "SELECT * FROM links"
                };
                let mut statement = conn.prepare(sql)?;
                let map = |row: &Row<'_>| {
                    Ok(json!({
                        "id": row.get::<_, String>("id")?, "pr_number": row.get::<_, Option<i64>>("pr_number")?,
                        "pr_repo": row.get::<_, Option<String>>("pr_repo")?, "jira_key": row.get::<_, Option<String>>("jira_key")?,
                        "project_id": row.get::<_, Option<String>>("project_id")?, "created_at": row.get::<_, String>("created_at")?,
                    }))
                };
                if let Some(project) = project {
                    statement.query_map([project], map)?.collect()
                } else {
                    statement.query_map([], map)?.collect()
                }
            })
            .await
    }

    pub async fn add_link(
        &self,
        number: i64,
        repo: &str,
        jira_key: &str,
        project: Option<&str>,
    ) -> rusqlite::Result<()> {
        let repo = repo.to_owned();
        let jira_key = jira_key.to_uppercase();
        let project = project.map(str::to_owned);
        self.durable
            .call(move |conn| {
                conn.execute(
                    "INSERT INTO links (id,pr_number,pr_repo,jira_key,project_id,created_at) SELECT ?1,?2,?3,?4,?5,?6 WHERE NOT EXISTS (SELECT 1 FROM links WHERE pr_number=?2 AND pr_repo=?3 AND jira_key=?4)",
                    params![Uuid::new_v4().to_string(), number, repo, jira_key, project, now()],
                )?;
                Ok(())
            })
            .await
    }

    pub async fn delete_link(&self, id: &str) -> rusqlite::Result<()> {
        let id = id.to_owned();
        self.durable
            .call(move |conn| {
                conn.execute("DELETE FROM links WHERE id=?1", [id])?;
                Ok(())
            })
            .await
    }

    pub async fn pr_snapshot(
        &self,
        id: &str,
        state: &str,
        identity: Option<&str>,
    ) -> rusqlite::Result<Option<PrSnapshot>> {
        let id = id.to_owned();
        let state = state.to_owned();
        let identity = identity.unwrap_or("").to_owned();
        self.cache
            .call(move |conn| {
                if state == "open" {
                    conn.query_row(
                        "SELECT prs,last_synced,error FROM pr_snapshots WHERE id=?1",
                        [id],
                        snapshot_from_row,
                    )
                    .optional()
                } else {
                    conn.query_row("SELECT prs,last_synced,error FROM pr_scope_snapshots WHERE id=?1 AND state=?2 AND identity=?3", params![id,state,identity], snapshot_from_row).optional()
                }
            })
            .await
    }

    pub async fn set_pr_snapshot(&self, id: &str, snapshot: &PrSnapshot) -> rusqlite::Result<()> {
        let id = id.to_owned();
        let (prs, last_synced, error) = pr_snapshot_columns(snapshot);
        self.cache
            .call(move |conn| {
                conn.execute(
                    "INSERT INTO pr_snapshots(id,prs,last_synced,error) VALUES (?1,?2,?3,?4) ON CONFLICT(id) DO UPDATE SET prs=excluded.prs,last_synced=excluded.last_synced,error=excluded.error",
                    params![id, prs, last_synced, error],
                )?;
                Ok(())
            })
            .await
    }

    pub async fn set_pr_scope_snapshot(
        &self,
        project: &Project,
        state: &str,
        snapshot: &PrSnapshot,
    ) -> rusqlite::Result<()> {
        let id = project.id.clone();
        let identity = project_identity(project);
        let state = state.to_owned();
        let (prs, last_synced, error) = pr_snapshot_columns(snapshot);
        self.cache
            .call(move |conn| {
                conn.execute(
                    "INSERT INTO pr_scope_snapshots(id,state,identity,prs,last_synced,error) VALUES (?1,?2,?3,?4,?5,?6) ON CONFLICT(id,state) DO UPDATE SET identity=excluded.identity,prs=excluded.prs,last_synced=excluded.last_synced,error=excluded.error",
                    params![id, state, identity, prs, last_synced, error],
                )?;
                Ok(())
            })
            .await
    }

    /// What `xcodebuild` answered for `key`, if it was kept against the same `stamp` and
    /// answered at `since` (Unix seconds) or later.
    pub async fn xcode_answer(
        &self,
        key: &str,
        stamp: &str,
        since: i64,
    ) -> rusqlite::Result<Option<Value>> {
        let key = key.to_owned();
        let stamp = stamp.to_owned();
        self.cache
            .call(move |conn| {
                let raw: Option<String> = conn
                    .query_row(
                        "SELECT value FROM xcode_answers WHERE key=?1 AND stamp=?2 AND at>=?3",
                        params![key, stamp, since],
                        |row| row.get(0),
                    )
                    .optional()?;
                Ok(raw.and_then(|raw| serde_json::from_str(&raw).ok()))
            })
            .await
    }

    pub async fn set_xcode_answer(
        &self,
        key: &str,
        stamp: &str,
        value: &Value,
    ) -> rusqlite::Result<()> {
        let key = key.to_owned();
        let stamp = stamp.to_owned();
        let value = value.to_string();
        self.cache
            .call(move |conn| {
                conn.execute(
                    "INSERT INTO xcode_answers(key,stamp,value,at) VALUES (?1,?2,?3,?4) ON CONFLICT(key) DO UPDATE SET stamp=excluded.stamp,value=excluded.value,at=excluded.at",
                    params![key, stamp, value, Utc::now().timestamp()],
                )?;
                Ok(())
            })
            .await
    }

    /// The last turn hook the agent in terminal `run_id` sent.
    pub async fn agent_hook(&self, run_id: &str) -> rusqlite::Result<Option<Value>> {
        let run_id = run_id.to_owned();
        self.cache
            .call(move |conn| {
                let raw: Option<String> = conn
                    .query_row(
                        "SELECT event FROM agent_hooks WHERE run_id=?1",
                        [run_id],
                        |row| row.get(0),
                    )
                    .optional()?;
                Ok(raw.and_then(|raw| serde_json::from_str(&raw).ok()))
            })
            .await
    }

    /// Keeps `event` as terminal `run_id`'s last hook, and lets go of terminals not heard from in
    /// a month: a shell that old is long gone.
    pub async fn set_agent_hook(&self, run_id: &str, event: &Value) -> rusqlite::Result<()> {
        let run_id = run_id.to_owned();
        let event = event.to_string();
        self.cache
            .call(move |cache| {
                let now = Utc::now().timestamp();
                cache.execute(
                    "INSERT INTO agent_hooks(run_id,event,at) VALUES (?1,?2,?3) ON CONFLICT(run_id) DO UPDATE SET event=excluded.event,at=excluded.at",
                    params![run_id, event, now],
                )?;
                cache.execute("DELETE FROM agent_hooks WHERE at<?1", [now - 30 * 86_400])?;
                Ok(())
            })
            .await
    }

    /// Drops every answer whose key starts with `prefix`: one worktree's.
    pub async fn forget_xcode_answers(&self, prefix: &str) -> rusqlite::Result<()> {
        let prefix = prefix.to_owned();
        self.cache
            .call(move |conn| {
                conn.execute(
                    "DELETE FROM xcode_answers WHERE substr(key,1,length(?1))=?1",
                    [prefix],
                )?;
                Ok(())
            })
            .await
    }

    pub async fn jira_snapshot(&self, id: &str) -> rusqlite::Result<Option<Value>> {
        let id = id.to_owned();
        self.cache
            .call(move |conn| {
                conn.query_row(
                    "SELECT items,jql,last_synced,error,meta FROM jira_snapshots WHERE id=?1",
                    [id],
                    jira_snapshot_from_row,
                )
                .optional()
            })
            .await
    }

    pub async fn set_jira_snapshot(&self, id: &str, snapshot: &Value) -> rusqlite::Result<()> {
        let id = id.to_owned();
        let meta = match snapshot.get("meta") {
            Some(Value::Object(value)) => Some(Value::Object(value.clone()).to_string()),
            _ => None,
        };
        let (items, last_synced, error) = snapshot_columns(snapshot, "items");
        let jql = snapshot
            .get("jql")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned();
        self.cache
            .call(move |conn| {
                conn.execute(
                    "INSERT INTO jira_snapshots(id,items,jql,last_synced,error,meta) VALUES (?1,?2,?3,?4,?5,?6) ON CONFLICT(id) DO UPDATE SET items=excluded.items,jql=excluded.jql,last_synced=excluded.last_synced,error=excluded.error,meta=excluded.meta",
                    params![id, items, jql, last_synced, error, meta],
                )?;
                Ok(())
            })
            .await
    }

    /// Every project's open snapshot, by project ID.
    pub async fn all_pr_snapshots(&self) -> rusqlite::Result<Vec<(String, PrSnapshot)>> {
        self.cache
            .call(|conn| {
                let mut statement =
                    conn.prepare("SELECT id,prs,last_synced,error FROM pr_snapshots")?;
                let rows = statement.query_map([], |row| {
                    Ok((row.get::<_, String>(0)?, snapshot_from_row_offset(row, 1)?))
                })?;
                rows.collect()
            })
            .await
    }

    pub async fn all_jira_snapshots(&self) -> rusqlite::Result<Value> {
        self.cache
            .call(|conn| {
                let mut statement =
                    conn.prepare("SELECT id,items,jql,last_synced,error,meta FROM jira_snapshots")?;
                let mut out = Map::new();
                for row in statement.query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        jira_snapshot_from_row_offset(row, 1)?,
                    ))
                })? {
                    let (id, value) = row?;
                    out.insert(id, value);
                }
                Ok(Value::Object(out))
            })
            .await
    }

    pub async fn review_state(
        &self,
        key: &str,
    ) -> rusqlite::Result<Option<(Option<String>, Option<String>)>> {
        let key = key.to_owned();
        self.durable
            .call(move |conn| {
                conn.query_row(
                    "SELECT requested_at,viewed_at FROM review_state WHERE key=?1",
                    [key],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()
            })
            .await
    }

    pub async fn mark_review_viewed(&self, key: &str) -> rusqlite::Result<()> {
        let key = key.to_owned();
        self.durable
            .call(move |conn| {
                conn.execute("INSERT INTO review_state (key,viewed_at) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET viewed_at=excluded.viewed_at", params![key,now()])?;
                Ok(())
            })
            .await
    }

    pub async fn mark_review_requested(&self, key: &str, timestamp: &str) -> rusqlite::Result<()> {
        let key = key.to_owned();
        let timestamp = timestamp.to_owned();
        self.durable
            .call(move |conn| {
                conn.execute("INSERT INTO review_state(key,requested_at) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET requested_at=excluded.requested_at WHERE review_state.requested_at IS NULL OR review_state.requested_at < excluded.requested_at",params![key,timestamp])?;
                Ok(())
            })
            .await
    }

    pub async fn prune_review_state(&self, repo: &str, open_numbers: &[i64]) -> rusqlite::Result<()> {
        let repo = repo.to_owned();
        let open_numbers = open_numbers.to_vec();
        self.durable
            .call(move |conn| {
                // By prefix, not `LIKE`: `_` in a repo name would match any character and take
                // a sibling repo's rows (`acme/app_ios` against `acme/app-ios`).
                let mut statement = conn
                    .prepare("SELECT key FROM review_state WHERE substr(key, 1, length(?1)) = ?1")?;
                let keys = statement
                    .query_map([format!("{repo}#")], |row| row.get::<_, String>(0))?
                    .collect::<rusqlite::Result<Vec<_>>>()?;
                drop(statement);
                for key in keys {
                    let keep = open_numbers
                        .iter()
                        .any(|number| key == format!("{repo}#{number}"));
                    if !keep {
                        conn.execute("DELETE FROM review_state WHERE key=?1", [key])?;
                    }
                }
                Ok(())
            })
            .await
    }

    pub async fn add_log(
        &self,
        category: &str,
        level: &str,
        kind: &str,
        payload: &Value,
    ) -> rusqlite::Result<Value> {
        let created_at = now();
        let body = if payload.is_string() {
            payload.as_str().unwrap().to_owned()
        } else {
            payload.to_string()
        };
        let row = (
            category.to_owned(),
            level.to_owned(),
            kind.to_owned(),
            body.clone(),
            created_at.clone(),
        );
        self.logs
            .call(move |conn| {
                conn.execute(
                    "INSERT INTO logs(category,level,type,payload,created_at) VALUES (?1,?2,?3,?4,?5)",
                    params![row.0, row.1, row.2, row.3, row.4],
                )?;
                conn.execute(
                    "DELETE FROM logs WHERE seq <= (SELECT MAX(seq) FROM logs) - 5000",
                    [],
                )?;
                Ok(())
            })
            .await?;
        Ok(json!({"type":kind,"payload":body,"level":level,"created_at":created_at}))
    }

    pub async fn add_event(&self, kind: &str, payload: &Value) -> rusqlite::Result<Value> {
        let level = if kind.to_ascii_lowercase().contains("fail")
            || kind.to_ascii_lowercase().contains("error")
        {
            "error"
        } else {
            "info"
        };
        self.add_log("event", level, kind, payload).await
    }

    pub async fn query_logs(
        &self,
        category: Option<&str>,
        level: Option<&str>,
        limit: i64,
    ) -> rusqlite::Result<Vec<Value>> {
        let limit = limit.clamp(1, 2000);
        let (sql, values): (&str, Vec<rusqlite::types::Value>) = match (category.filter(|c| *c != "all"), level) {
            (Some(c), Some(l)) => ("SELECT seq,category,level,type,payload,created_at FROM logs WHERE category=? AND level=? ORDER BY seq DESC LIMIT ?", vec![c.to_owned().into(),l.to_owned().into(),limit.into()]),
            (Some(c), None) => ("SELECT seq,category,level,type,payload,created_at FROM logs WHERE category=? ORDER BY seq DESC LIMIT ?", vec![c.to_owned().into(),limit.into()]),
            (None, Some(l)) => ("SELECT seq,category,level,type,payload,created_at FROM logs WHERE level=? ORDER BY seq DESC LIMIT ?", vec![l.to_owned().into(),limit.into()]),
            (None, None) => ("SELECT seq,category,level,type,payload,created_at FROM logs ORDER BY seq DESC LIMIT ?", vec![limit.into()]),
        };
        self.logs
            .call(move |conn| {
                let mut statement = conn.prepare(sql)?;
                let result = statement
                    .query_map(params_from_iter(values), log_from_row)?
                    .collect();
                result
            })
            .await
    }

    pub async fn log_categories(&self) -> rusqlite::Result<Vec<String>> {
        self.logs
            .call(|conn| {
                let mut statement =
                    conn.prepare("SELECT DISTINCT category FROM logs ORDER BY category")?;
                let result = statement.query_map([], |row| row.get(0))?.collect();
                result
            })
            .await
    }

    pub async fn clear_logs(&self, category: Option<&str>) -> rusqlite::Result<()> {
        let category = category.filter(|c| *c != "all").map(str::to_owned);
        self.logs
            .call(move |conn| {
                if let Some(category) = category {
                    conn.execute("DELETE FROM logs WHERE category=?1", [category])?;
                } else {
                    conn.execute("DELETE FROM logs", [])?;
                }
                Ok(())
            })
            .await
    }

    pub async fn event_count(&self) -> rusqlite::Result<i64> {
        self.logs
            .call(|conn| {
                conn.query_row(
                    "SELECT COUNT(*) FROM logs WHERE category='event'",
                    [],
                    |r| r.get(0),
                )
            })
            .await
    }
}

fn project_row(conn: &Connection, id: &str) -> rusqlite::Result<Option<Project>> {
    conn.query_row("SELECT * FROM projects WHERE id=?1", [id], project_from_row)
        .optional()
}

/// A PR snapshot's stored columns: its list as JSON text, when it was synced, and its error.
fn pr_snapshot_columns(snapshot: &PrSnapshot) -> (String, Option<String>, Option<String>) {
    (
        serde_json::to_string(&snapshot.prs).expect("a list of values serializes"),
        snapshot.last_synced.clone(),
        snapshot.error.clone(),
    )
}

/// A Jira snapshot's stored columns: its list as JSON text, when it was synced, and its error.
fn snapshot_columns(snapshot: &Value, list: &str) -> (String, Option<String>, Option<String>) {
    (
        snapshot
            .get(list)
            .cloned()
            .unwrap_or_else(|| json!([]))
            .to_string(),
        snapshot
            .get("lastSynced")
            .and_then(Value::as_str)
            .map(str::to_owned),
        snapshot
            .get("error")
            .and_then(Value::as_str)
            .map(str::to_owned),
    )
}

fn migrate_events_to_logs(durable: &Connection, logs: &mut Connection) -> rusqlite::Result<()> {
    let migrated: Option<String> = durable
        .query_row(
            "SELECT value FROM config WHERE key='events_migrated_to_logs'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    if migrated.as_deref() == Some("1") {
        return Ok(());
    }
    let old = {
        let mut statement = durable
            .prepare("SELECT type,payload,created_at FROM events ORDER BY seq ASC LIMIT 500")?;
        let result = statement
            .query_map([], |r| {
                Ok((
                    r.get::<_, Option<String>>(0)?,
                    r.get::<_, Option<String>>(1)?,
                    r.get::<_, String>(2)?,
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        result
    };
    let tx = logs.transaction()?;
    for (kind, payload, created) in old {
        let level = if kind.as_deref().is_some_and(|k| {
            k.to_ascii_lowercase().contains("fail") || k.to_ascii_lowercase().contains("error")
        }) {
            "error"
        } else {
            "info"
        };
        tx.execute("INSERT INTO logs(category,level,type,payload,created_at) VALUES ('event',?1,?2,?3,?4)", params![level,kind,payload,created])?;
    }
    tx.commit()?;
    durable.execute("INSERT INTO config(key,value) VALUES ('events_migrated_to_logs','1') ON CONFLICT(key) DO UPDATE SET value='1'", [])?;
    Ok(())
}

#[derive(Clone, Copy)]
enum FieldKind {
    String,
    Bool,
}

fn open_db(path: &Path) -> Result<Connection> {
    let conn = Connection::open(path).with_context(|| format!("open {}", path.display()))?;
    let _ = conn.execute_batch("PRAGMA journal_mode=WAL;");
    conn.busy_timeout(std::time::Duration::from_secs(5))?;
    Ok(conn)
}

fn initialize_durable(conn: &Connection) -> rusqlite::Result<()> {
    let old_tasks = conn
        .prepare("PRAGMA table_info(tasks)")?
        .query_map([], |r| r.get::<_, String>(1))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if !old_tasks.is_empty() && !old_tasks.iter().any(|name| name == "id") {
        conn.execute("DROP TABLE tasks", [])?;
    }
    conn.execute_batch(include_str!("schema_durable.sql"))?;
    for migration in [
        "ALTER TABLE tabs ADD COLUMN category TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE tabs ADD COLUMN pane_view TEXT NOT NULL DEFAULT 'term'",
        "ALTER TABLE tabs ADD COLUMN login TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE tabs ADD COLUMN avatar TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE tabs ADD COLUMN links TEXT NOT NULL DEFAULT '[]'",
        "ALTER TABLE tabs ADD COLUMN cur TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE tabs ADD COLUMN diff_open INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE tabs ADD COLUMN diff_pos INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE tabs ADD COLUMN page_closed INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE tabs ADD COLUMN history TEXT NOT NULL DEFAULT '[]'",
        "ALTER TABLE tabs ADD COLUMN standalone INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE projects ADD COLUMN forward_webhooks INTEGER NOT NULL DEFAULT 1",
        "ALTER TABLE projects ADD COLUMN fix_version_enabled INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE projects ADD COLUMN fix_version_prefix TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE projects ADD COLUMN fix_version_script TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE projects ADD COLUMN ide TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE projects ADD COLUMN ide_cmd TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE projects ADD COLUMN ide_target TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE projects ADD COLUMN worktree_setup TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE projects ADD COLUMN worktree_include TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE projects ADD COLUMN run_scheme TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE projects ADD COLUMN run_sim TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE tasks ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE tasks ADD COLUMN run_scheme TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE tasks ADD COLUMN run_sim TEXT NOT NULL DEFAULT ''",
        // A name the user gave the session; empty means it is shown by its worktree folder.
        "ALTER TABLE tasks ADD COLUMN name TEXT NOT NULL DEFAULT ''",
        // What a forked session's agent starts from, until its own conversation exists.
        "ALTER TABLE tasks ADD COLUMN fork_from TEXT NOT NULL DEFAULT ''",
        // The session a fork was made from, kept for good so the sidebar can mark it.
        "ALTER TABLE tasks ADD COLUMN forked_from TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE tabs ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE projects ADD COLUMN issues_enabled INTEGER NOT NULL DEFAULT 1",
        // Whether the project page shows its Jira sprint board as a tab.
        "ALTER TABLE projects ADD COLUMN board_enabled INTEGER NOT NULL DEFAULT 0",
    ] {
        let _ = conn.execute(migration, []);
    }
    // The Fix Version prefix used to be its own field; it is now the start of the template.
    let _ = conn.execute(
        "UPDATE projects SET fix_version_script = fix_version_prefix || fix_version_script, fix_version_prefix = '' WHERE fix_version_prefix <> ''",
        [],
    );
    migrate_tabs_to_ids(conn)?;
    Ok(())
}

/// Tabs used to be keyed by URL, so two tabs could never show the same page. Each tab now has
/// its own id; existing rows get one and keep everything else.
fn migrate_tabs_to_ids(conn: &Connection) -> rusqlite::Result<()> {
    let columns: Vec<String> = conn
        .prepare("PRAGMA table_info(tabs)")?
        .query_map([], |r| r.get::<_, String>(1))?
        .collect::<rusqlite::Result<_>>()?;
    if columns.is_empty() || columns.iter().any(|name| name == "id") {
        return Ok(());
    }
    conn.execute_batch(
        "BEGIN;
         DROP TABLE IF EXISTS tabs_with_ids;
         CREATE TABLE tabs_with_ids (
           id TEXT PRIMARY KEY, url TEXT NOT NULL, kind TEXT NOT NULL, title TEXT, repo TEXT, branch TEXT,
           pane_view TEXT NOT NULL DEFAULT 'term', diff_open INTEGER NOT NULL DEFAULT 0,
           page_closed INTEGER NOT NULL DEFAULT 0, diff_pos INTEGER NOT NULL DEFAULT 0,
           category TEXT NOT NULL DEFAULT '', login TEXT NOT NULL DEFAULT '', avatar TEXT NOT NULL DEFAULT '',
           links TEXT NOT NULL DEFAULT '[]', cur TEXT NOT NULL DEFAULT '', history TEXT NOT NULL DEFAULT '[]',
           position INTEGER NOT NULL DEFAULT 0, active INTEGER NOT NULL DEFAULT 0,
           pinned INTEGER NOT NULL DEFAULT 0, standalone INTEGER NOT NULL DEFAULT 0
         );
         INSERT INTO tabs_with_ids(id,url,kind,title,repo,branch,pane_view,diff_open,page_closed,diff_pos,category,login,avatar,links,cur,history,position,active,pinned)
           SELECT lower(hex(randomblob(16))),url,kind,title,repo,branch,pane_view,diff_open,page_closed,diff_pos,category,login,avatar,links,cur,history,position,active,pinned FROM tabs;
         DROP TABLE tabs;
         ALTER TABLE tabs_with_ids RENAME TO tabs;
         COMMIT;",
    )
}

fn initialize_cache(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(include_str!("schema_cache.sql"))?;
    let _ = conn.execute("ALTER TABLE jira_snapshots ADD COLUMN meta TEXT", []);
    let _ = conn.execute("ALTER TABLE xcode_answers ADD COLUMN at INTEGER NOT NULL DEFAULT 0", []);
    Ok(())
}

fn initialize_logs(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(include_str!("schema_logs.sql"))
}

fn key_values(conn: &Connection, table: &str) -> rusqlite::Result<Value> {
    let mut statement = conn.prepare(&format!("SELECT key,value FROM {table}"))?;
    let rows = statement.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
    })?;
    let mut out = Map::new();
    for row in rows {
        let (key, value) = row?;
        out.insert(key, value.map(Value::String).unwrap_or(Value::Null));
    }
    Ok(Value::Object(out))
}

fn project_from_row(row: &Row<'_>) -> rusqlite::Result<Project> {
    Ok(Project {
        id: row.get("id")?,
        name: row.get("name")?,
        repo: row.get("repo")?,
        workspace: row.get("workspace")?,
        jira_project_key: row.get("jira_project_key")?,
        merge_transition: row.get("merge_transition")?,
        forward_webhooks: row.get::<_, i64>("forward_webhooks")? != 0,
        created_at: row.get("created_at")?,
        fix_version_enabled: row.get::<_, i64>("fix_version_enabled")? != 0,
        fix_version_script: text(row, "fix_version_script")?,
        ide: text(row, "ide")?,
        ide_cmd: text(row, "ide_cmd")?,
        ide_target: text(row, "ide_target")?,
        run_scheme: text(row, "run_scheme")?,
        run_sim: text(row, "run_sim")?,
        worktree_setup: text(row, "worktree_setup")?,
        worktree_include: text(row, "worktree_include")?,
        issues_enabled: row.get::<_, i64>("issues_enabled")? != 0,
        board_enabled: row.get::<_, i64>("board_enabled")? != 0,
    })
}

fn snapshot_from_row(row: &Row<'_>) -> rusqlite::Result<PrSnapshot> {
    snapshot_from_row_offset(row, 0)
}
fn snapshot_from_row_offset(row: &Row<'_>, offset: usize) -> rusqlite::Result<PrSnapshot> {
    let raw: String = row.get(offset)?;
    Ok(PrSnapshot {
        prs: serde_json::from_str(&raw).unwrap_or_default(),
        last_synced: row.get(offset + 1)?,
        error: row.get(offset + 2)?,
    })
}
fn jira_snapshot_from_row(row: &Row<'_>) -> rusqlite::Result<Value> {
    jira_snapshot_from_row_offset(row, 0)
}
fn jira_snapshot_from_row_offset(row: &Row<'_>, offset: usize) -> rusqlite::Result<Value> {
    let raw: String = row.get(offset)?;
    let meta: Option<String> = row.get(offset + 4)?;
    let mut value = json!({"items":parse_json(&raw,json!([])),"jql":row.get::<_,Option<String>>(offset+1)?.unwrap_or_default(),"lastSynced":row.get::<_,Option<String>>(offset+2)?,"error":row.get::<_,Option<String>>(offset+3)?});
    if let Some(Value::Object(meta)) = meta.map(|v| parse_json(&v, Value::Null)) {
        value.as_object_mut().unwrap().extend(meta);
    }
    Ok(value)
}
fn log_from_row(row: &Row<'_>) -> rusqlite::Result<Value> {
    Ok(
        json!({"seq":row.get::<_,i64>(0)?,"category":row.get::<_,String>(1)?,"level":row.get::<_,String>(2)?,"type":row.get::<_,Option<String>>(3)?,"payload":row.get::<_,Option<String>>(4)?,"created_at":row.get::<_,String>(5)?}),
    )
}
/// A `tasks` row as a session.
fn task_row(row: &Row<'_>) -> rusqlite::Result<Session> {
    Ok(Session {
        id: row.get("id")?,
        project_id: row.get("project_id")?,
        workspace: row.get("workspace")?,
        worktree: row.get("worktree")?,
        branch: text(row, "branch")?,
        title: text(row, "title")?,
        kind: text(row, "kind")?,
        url: text(row, "url")?,
        jira_key: text(row, "jira_key")?,
        cli: text(row, "cli")?,
        session_id: text(row, "session_id")?,
        created_at: row.get("created_at")?,
        pinned: row.get::<_, i64>("pinned")? != 0,
        run_scheme: text(row, "run_scheme")?,
        run_sim: text(row, "run_sim")?,
        name: text(row, "name")?,
        fork_from: text(row, "fork_from")?,
        forked_from: text(row, "forked_from")?,
    })
}

fn text(row: &Row<'_>, column: &str) -> rusqlite::Result<String> {
    Ok(row.get::<_, Option<String>>(column)?.unwrap_or_default())
}
fn parse_json(raw: &str, fallback: Value) -> Value {
    serde_json::from_str(raw).unwrap_or(fallback)
}
fn bool_int(value: Option<&Value>, default: bool) -> i64 {
    i64::from(value.and_then(Value::as_bool).unwrap_or(default))
}
fn js_string(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Null => "null".into(),
        _ => value.to_string(),
    }
}
fn now() -> String {
    Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}
/// What a scoped snapshot was taken for: a project whose repo, Jira key or creation changed is a
/// different one, and its old snapshot does not apply.
pub fn project_identity(project: &Project) -> String {
    json!([project.repo, project.jira_project_key, project.created_at]).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_terminal_keeps_only_its_last_hook() {
        let dir = tempfile::tempdir().unwrap();
        let opened = Database::open(dir.path()).unwrap();
        assert_eq!(opened.agent_hook("pty1-1").await.unwrap(), None, "nothing heard, nothing kept");
        opened.set_agent_hook("pty1-1", &json!({"type": "agent-turn-start"})).await.unwrap();
        opened.set_agent_hook("pty1-1", &json!({"type": "agent-turn-done"})).await.unwrap();
        opened.set_agent_hook("pty1-2", &json!({"type": "agent-session"})).await.unwrap();
        assert_eq!(opened.agent_hook("pty1-1").await.unwrap(), Some(json!({"type": "agent-turn-done"})));
        assert_eq!(opened.agent_hook("pty1-2").await.unwrap(), Some(json!({"type": "agent-session"})));
    }

    #[tokio::test]
    async fn a_project_board_starts_off_and_is_patched_on() {
        let opened = Database::open(tempfile::tempdir().unwrap().path()).unwrap();
        let mut fields = Map::new();
        fields.insert("name".into(), json!("App"));
        let created = opened.add_project(&fields).await.unwrap();
        assert!(!created.board_enabled);
        let mut patch = Map::new();
        patch.insert("boardEnabled".into(), json!(true));
        assert!(opened.update_project(&created.id, &patch).await.unwrap().unwrap().board_enabled);
    }

    #[tokio::test]
    async fn a_session_name_is_patched_alone_and_survives_an_upsert() {
        let opened = Database::open(tempfile::tempdir().unwrap().path()).unwrap();
        let task = Session {
            id: "t".into(),
            project_id: "p".into(),
            workspace: "/w".into(),
            worktree: "/w/t".into(),
            title: "Page".into(),
            ..Session::default()
        };
        assert!(opened.upsert_task(&task).await.unwrap());
        let first = &opened.tasks().await.unwrap()[0];
        assert_eq!(first.name, "");
        assert!(!first.created_at.is_empty(), "an empty createdAt is stamped now");
        let mut rename = Map::new();
        rename.insert("name".into(), json!("Checkout fix"));
        assert!(opened.patch_task("t", &rename).await.unwrap());
        // The app re-saves the whole record on other changes; that must not drop the name.
        assert!(opened.upsert_task(&task).await.unwrap());
        let saved = &opened.tasks().await.unwrap()[0];
        assert_eq!(saved.name, "Checkout fix");
        assert_eq!(saved.title, "Page");
        assert_eq!(saved.worktree, "/w/t");
        assert_eq!(saved.created_at, first.created_at, "an upsert keeps the first creation time");
        let incomplete = Session {
            worktree: String::new(),
            ..task.clone()
        };
        assert!(!opened.upsert_task(&incomplete).await.unwrap());
    }

    /// Every store answers from its own thread; the runtime's workers never run a statement.
    #[tokio::test]
    async fn statements_run_on_the_store_thread_not_the_runtime() {
        let opened = Database::open(tempfile::tempdir().unwrap().path()).unwrap();
        let thread = opened
            .durable
            .call(|_| Ok(std::thread::current().name().map(str::to_owned)))
            .await
            .unwrap();
        assert_eq!(thread.as_deref(), Some("cascade-db-durable"));
        assert_ne!(std::thread::current().name(), Some("cascade-db-durable"));
    }
}
