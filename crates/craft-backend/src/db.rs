use std::{
    fs,
    path::{Path, PathBuf},
    sync::{Mutex, MutexGuard},
};

use anyhow::{Context, Result};
use chrono::Utc;
use rusqlite::{params, params_from_iter, Connection, OptionalExtension, Row};
use serde_json::{json, Map, Value};
use uuid::Uuid;

pub struct Database {
    durable: Mutex<Connection>,
    cache: Mutex<Connection>,
    logs: Mutex<Connection>,
    pub data_dir: PathBuf,
}

impl Database {
    pub fn open(data_dir: &Path) -> Result<Self> {
        fs::create_dir_all(data_dir)?;
        migrate_legacy_name(data_dir);
        let durable = open_db(&data_dir.join("craft.db"))?;
        let cache = open_db(&data_dir.join("data.db"))?;
        let logs = open_db(&data_dir.join("logs.db"))?;
        initialize_durable(&durable)?;
        initialize_cache(&cache)?;
        initialize_logs(&logs)?;
        let result = Self {
            durable: Mutex::new(durable),
            cache: Mutex::new(cache),
            logs: Mutex::new(logs),
            data_dir: data_dir.to_path_buf(),
        };
        result.migrate_events_to_logs()?;
        Ok(result)
    }

    fn durable(&self) -> MutexGuard<'_, Connection> {
        self.durable.lock().expect("durable db mutex poisoned")
    }
    fn cache(&self) -> MutexGuard<'_, Connection> {
        self.cache.lock().expect("cache db mutex poisoned")
    }
    fn logs_conn(&self) -> MutexGuard<'_, Connection> {
        self.logs.lock().expect("logs db mutex poisoned")
    }

    pub fn config(&self) -> rusqlite::Result<Value> {
        key_values(&self.durable(), "config")
    }

    pub fn config_value(&self, key: &str) -> rusqlite::Result<Option<String>> {
        self.durable()
            .query_row("SELECT value FROM config WHERE key=?1", [key], |row| {
                row.get(0)
            })
            .optional()
    }

    pub fn set_config(&self, values: &Map<String, Value>) -> rusqlite::Result<()> {
        let mut conn = self.durable();
        let tx = conn.transaction()?;
        for (key, value) in values {
            tx.execute(
                "INSERT INTO config (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                params![key, js_string(value)],
            )?;
        }
        tx.commit()
    }

    pub fn setting(&self, key: &str, value: &Value) -> rusqlite::Result<()> {
        self.durable().execute(
            "INSERT INTO settings (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            params![key, if value.is_null() { None } else { Some(js_string(value)) }],
        )?;
        Ok(())
    }

    pub fn settings(&self) -> rusqlite::Result<Value> {
        key_values(&self.durable(), "settings")
    }

    pub fn projects(&self) -> rusqlite::Result<Vec<Value>> {
        let conn = self.durable();
        let mut statement = conn.prepare("SELECT * FROM projects ORDER BY created_at ASC")?;
        let result = statement.query_map([], project_from_row)?.collect();
        result
    }

    pub fn project(&self, id: &str) -> rusqlite::Result<Option<Value>> {
        self.durable()
            .query_row("SELECT * FROM projects WHERE id=?1", [id], project_from_row)
            .optional()
    }

    pub fn add_project(&self, patch: &Map<String, Value>) -> rusqlite::Result<Value> {
        let id = Uuid::new_v4().to_string();
        let created_at = patch
            .get("created_at")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .unwrap_or_else(now);
        let get = |key: &str| patch.get(key).and_then(Value::as_str).unwrap_or("");
        let workflows = patch
            .get("workflows")
            .cloned()
            .unwrap_or_else(|| json!([]))
            .to_string();
        self.durable().execute(
            "INSERT INTO projects (id,name,repo,workspace,jira_project_key,jql,merge_transition,forward_webhooks,fix_version_enabled,fix_version_prefix,fix_version_script,workflows,ide,ide_cmd,ide_target,run_scheme,run_sim,created_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18)",
            params![
                id, get("name"), get("repo"), get("workspace"), get("jiraProjectKey"), get("jql"),
                get("mergeTransition"), bool_int(patch.get("forwardWebhooks"), true),
                bool_int(patch.get("fixVersionEnabled"), false), get("fixVersionPrefix"),
                get("fixVersionScript"), workflows, get("ide"), get("ideCmd"), get("ideTarget"),
                get("runScheme"), get("runSim"), created_at,
            ],
        )?;
        self.project(&id)?
            .ok_or(rusqlite::Error::QueryReturnedNoRows)
    }

    pub fn update_project(
        &self,
        id: &str,
        patch: &Map<String, Value>,
    ) -> rusqlite::Result<Option<Value>> {
        if self.project(id)?.is_none() {
            return Ok(None);
        }
        const FIELDS: &[(&str, &str, FieldKind)] = &[
            ("name", "name", FieldKind::String),
            ("repo", "repo", FieldKind::String),
            ("workspace", "workspace", FieldKind::String),
            ("jiraProjectKey", "jira_project_key", FieldKind::String),
            ("jql", "jql", FieldKind::String),
            ("mergeTransition", "merge_transition", FieldKind::String),
            ("forwardWebhooks", "forward_webhooks", FieldKind::Bool),
            ("fixVersionEnabled", "fix_version_enabled", FieldKind::Bool),
            ("fixVersionPrefix", "fix_version_prefix", FieldKind::String),
            ("fixVersionScript", "fix_version_script", FieldKind::String),
            ("workflows", "workflows", FieldKind::Json),
            ("ide", "ide", FieldKind::String),
            ("ideCmd", "ide_cmd", FieldKind::String),
            ("ideTarget", "ide_target", FieldKind::String),
            ("runScheme", "run_scheme", FieldKind::String),
            ("runSim", "run_sim", FieldKind::String),
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
                FieldKind::Bool => {
                    rusqlite::types::Value::Integer(i64::from(value.as_bool().unwrap_or(false)))
                }
                FieldKind::Json => rusqlite::types::Value::Text(value.to_string()),
            });
        }
        if !sets.is_empty() {
            values.push(rusqlite::types::Value::Text(id.to_owned()));
            self.durable().execute(
                &format!("UPDATE projects SET {} WHERE id=?", sets.join(",")),
                params_from_iter(values),
            )?;
        }
        self.project(id)
    }

    pub fn invalidate_snapshots(&self, id: &str) -> rusqlite::Result<()> {
        let cache = self.cache();
        cache.execute("DELETE FROM pr_snapshots WHERE id=?1", [id])?;
        cache.execute("DELETE FROM pr_scope_snapshots WHERE id=?1", [id])?;
        cache.execute(
            "DELETE FROM jira_snapshots WHERE id=?1 OR id=?2",
            params![id, format!("board:{id}")],
        )?;
        Ok(())
    }

    pub fn delete_project(&self, id: &str) -> rusqlite::Result<()> {
        let mut durable = self.durable();
        let tx = durable.transaction()?;
        tx.execute("DELETE FROM projects WHERE id=?1", [id])?;
        tx.execute("DELETE FROM links WHERE project_id=?1", [id])?;
        tx.commit()?;
        let cache = self.cache();
        cache.execute("DELETE FROM pr_snapshots WHERE id=?1", [id])?;
        cache.execute(
            "DELETE FROM jira_snapshots WHERE id=?1 OR id=?2",
            params![id, format!("board:{id}")],
        )?;
        cache.execute("DELETE FROM pr_scope_snapshots WHERE id=?1", [id])?;
        Ok(())
    }

    pub fn tabs(&self) -> rusqlite::Result<Value> {
        let conn = self.durable();
        let mut statement = conn.prepare("SELECT * FROM tabs ORDER BY position ASC")?;
        let rows: Vec<Value> = statement
            .query_map([], tab_from_row)?
            .collect::<rusqlite::Result<_>>()?;
        let active = rows
            .iter()
            .find(|row| row.get("_active").and_then(Value::as_bool) == Some(true))
            .and_then(|row| row.get("id"))
            .cloned()
            .unwrap_or(Value::Null);
        let tabs = rows
            .into_iter()
            .map(|mut row| {
                row.as_object_mut().unwrap().remove("_active");
                row
            })
            .collect::<Vec<_>>();
        Ok(json!({ "tabs": tabs, "active": active }))
    }

    pub fn set_tabs(&self, tabs: &[Value], active: Option<&str>) -> rusqlite::Result<()> {
        let mut conn = self.durable();
        let tx = conn.transaction()?;
        tx.execute("DELETE FROM tabs", [])?;
        for (position, tab) in tabs.iter().enumerate() {
            let Some(tab) = tab.as_object() else { continue };
            let Some(url) = tab
                .get("url")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
            else {
                continue;
            };
            let id = tab.get("id").and_then(Value::as_str).unwrap_or(url);
            insert_tab(&tx, tab, position as i64, active == Some(id))?;
        }
        tx.commit()
    }

    /// Opening a page always makes a new tab: the same URL may be open several times. A caller
    /// that already holds an id (a draft tab getting its first address) reuses it.
    pub fn open_tab(&self, tab: &Map<String, Value>) -> rusqlite::Result<Value> {
        let id = tab
            .get("id")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
            .unwrap_or_else(|| Uuid::new_v4().to_string());
        let mut conn = self.durable();
        let tx = conn.transaction()?;
        let exists: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM tabs WHERE id=?1)",
            [&id],
            |row| row.get(0),
        )?;
        if !exists {
            let position: i64 = tx.query_row(
                "SELECT COALESCE(MAX(position), -1) + 1 FROM tabs",
                [],
                |row| row.get(0),
            )?;
            let mut with_id = tab.clone();
            with_id.insert("id".into(), Value::String(id.clone()));
            insert_tab(&tx, &with_id, position, false)?;
        }
        tx.execute(
            "UPDATE tabs SET active=CASE WHEN id=?1 THEN 1 ELSE 0 END",
            [&id],
        )?;
        tx.commit()?;
        drop(conn);
        self.tabs()
    }

    /// A title change alone. Narrower than `set_tabs`, so it cannot erase a tab another
    /// request is inserting at the same time.
    pub fn rename_tab(&self, id: &str, title: &str) -> rusqlite::Result<Value> {
        self.durable()
            .execute("UPDATE tabs SET title=?2 WHERE id=?1", params![id, title])?;
        self.tabs()
    }

    /// Pins or unpins one tab. A pinned tab leaves the Tabs list for the favourites grid under
    /// Dashboard, so the flag is its own narrow update like a rename.
    pub fn pin_tab(&self, id: &str, pinned: bool) -> rusqlite::Result<Value> {
        self.durable()
            .execute("UPDATE tabs SET pinned=?2 WHERE id=?1", params![id, i64::from(pinned)])?;
        self.tabs()
    }

    /// Places the listed tabs first, in the given order; tabs not listed keep their relative
    /// order after them. Unknown ids are ignored.
    pub fn reorder_tabs(&self, order: &[&str]) -> rusqlite::Result<Value> {
        {
            let mut conn = self.durable();
            let tx = conn.transaction()?;
            let existing: Vec<String> = tx
                .prepare("SELECT id FROM tabs ORDER BY position ASC")?
                .query_map([], |row| row.get(0))?
                .collect::<rusqlite::Result<_>>()?;
            // Listed ids first (a repeated id keeps its first place), unlisted ones after.
            let mut ordered: Vec<&str> = Vec::with_capacity(existing.len());
            for id in order.iter().copied().chain(existing.iter().map(String::as_str)) {
                if existing.iter().any(|e| e == id) && !ordered.contains(&id) {
                    ordered.push(id);
                }
            }
            for (position, id) in ordered.iter().enumerate() {
                tx.execute(
                    "UPDATE tabs SET position=?2 WHERE id=?1",
                    params![id, position as i64],
                )?;
            }
            tx.commit()?;
        }
        self.tabs()
    }

    pub fn close_tab(&self, id: &str) -> rusqlite::Result<Value> {
        self.durable()
            .execute("DELETE FROM tabs WHERE id=?1", [id])?;
        self.tabs()
    }

    pub fn tasks(&self) -> rusqlite::Result<Vec<Value>> {
        let conn = self.durable();
        let mut statement = conn.prepare("SELECT * FROM tasks ORDER BY created_at ASC")?;
        let result = statement.query_map([], |row| Ok(json!({
            "id": row.get::<_, String>("id")?, "projectId": row.get::<_, String>("project_id")?,
            "workspace": row.get::<_, String>("workspace")?, "worktree": row.get::<_, String>("worktree")?,
            "branch": text(row, "branch")?, "title": text(row, "title")?, "kind": text(row, "kind")?,
            "url": text(row, "url")?, "jiraKey": text(row, "jira_key")?, "cli": text(row, "cli")?,
            "sessionId": text(row, "session_id")?, "createdAt": row.get::<_, String>("created_at")?,
            "pinned": row.get::<_, i64>("pinned")? != 0,
            "runScheme": text(row, "run_scheme")?, "runSim": text(row, "run_sim")?,
        })))?.collect();
        result
    }

    pub fn upsert_task(&self, task: &Map<String, Value>) -> rusqlite::Result<bool> {
        let required = |key: &str| {
            task.get(key)
                .and_then(Value::as_str)
                .filter(|v| !v.is_empty())
        };
        let (Some(id), Some(project), Some(workspace), Some(worktree)) = (
            required("id"),
            required("projectId"),
            required("workspace"),
            required("worktree"),
        ) else {
            return Ok(false);
        };
        let get = |key: &str| task.get(key).and_then(Value::as_str).unwrap_or("");
        self.durable().execute(
            "INSERT INTO tasks (id,project_id,workspace,worktree,branch,title,kind,url,jira_key,cli,session_id,created_at,pinned) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13) ON CONFLICT(id) DO UPDATE SET project_id=excluded.project_id,workspace=excluded.workspace,worktree=excluded.worktree,branch=excluded.branch,title=excluded.title,kind=excluded.kind,url=excluded.url,jira_key=excluded.jira_key,cli=excluded.cli,session_id=excluded.session_id,pinned=excluded.pinned",
            params![id, project, workspace, worktree, get("branch"), get("title"), get("kind"), get("url"), get("jiraKey"), get("cli"), get("sessionId"), task.get("createdAt").and_then(Value::as_str).map(str::to_owned).unwrap_or_else(now), bool_int(task.get("pinned"), false)],
        )?;
        Ok(true)
    }

    pub fn delete_task(&self, id: &str) -> rusqlite::Result<()> {
        self.durable()
            .execute("DELETE FROM tasks WHERE id=?1", [id])?;
        Ok(())
    }

    pub fn pin_task(&self, id: &str, pinned: bool) -> rusqlite::Result<bool> {
        Ok(self.durable().execute(
            "UPDATE tasks SET pinned=?1 WHERE id=?2",
            params![i64::from(pinned), id],
        )? > 0)
    }

    pub fn patch_task(&self, id: &str, patch: &Map<String, Value>) -> rusqlite::Result<bool> {
        const FIELDS: &[(&str, &str)] = &[
            ("title", "title"),
            ("kind", "kind"),
            ("url", "url"),
            ("jiraKey", "jira_key"),
            ("cli", "cli"),
            ("sessionId", "session_id"),
            ("runScheme", "run_scheme"),
            ("runSim", "run_sim"),
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
        Ok(self.durable().execute(
            &format!("UPDATE tasks SET {} WHERE id=?", sets.join(",")),
            params_from_iter(values),
        )? > 0)
    }

    pub fn links(&self, project: Option<&str>) -> rusqlite::Result<Vec<Value>> {
        let conn = self.durable();
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
    }

    pub fn add_link(
        &self,
        number: i64,
        repo: &str,
        jira_key: &str,
        project: Option<&str>,
    ) -> rusqlite::Result<()> {
        self.durable().execute(
            "INSERT INTO links (id,pr_number,pr_repo,jira_key,project_id,created_at) SELECT ?1,?2,?3,?4,?5,?6 WHERE NOT EXISTS (SELECT 1 FROM links WHERE pr_number=?2 AND pr_repo=?3 AND jira_key=?4)",
            params![Uuid::new_v4().to_string(), number, repo, jira_key.to_uppercase(), project, now()],
        )?;
        Ok(())
    }

    pub fn delete_link(&self, id: &str) -> rusqlite::Result<()> {
        self.durable()
            .execute("DELETE FROM links WHERE id=?1", [id])?;
        Ok(())
    }

    pub fn pr_snapshot(
        &self,
        id: &str,
        state: &str,
        identity: Option<&str>,
    ) -> rusqlite::Result<Option<Value>> {
        let conn = self.cache();
        if state == "open" {
            conn.query_row(
                "SELECT prs,last_synced,error FROM pr_snapshots WHERE id=?1",
                [id],
                snapshot_from_row,
            )
            .optional()
        } else {
            conn.query_row("SELECT prs,last_synced,error FROM pr_scope_snapshots WHERE id=?1 AND state=?2 AND identity=?3", params![id,state,identity.unwrap_or("")], snapshot_from_row).optional()
        }
    }

    pub fn set_pr_snapshot(&self, id: &str, snapshot: &Value) -> rusqlite::Result<()> {
        self.cache().execute(
            "INSERT INTO pr_snapshots(id,prs,last_synced,error) VALUES (?1,?2,?3,?4) ON CONFLICT(id) DO UPDATE SET prs=excluded.prs,last_synced=excluded.last_synced,error=excluded.error",
            params![id, snapshot.get("prs").cloned().unwrap_or_else(||json!([])).to_string(), snapshot.get("lastSynced").and_then(Value::as_str), snapshot.get("error").and_then(Value::as_str)],
        )?;
        Ok(())
    }

    pub fn set_pr_scope_snapshot(
        &self,
        project: &Value,
        state: &str,
        snapshot: &Value,
    ) -> rusqlite::Result<()> {
        let id = project.get("id").and_then(Value::as_str).unwrap_or("");
        let identity = project_identity(project);
        self.cache().execute(
            "INSERT INTO pr_scope_snapshots(id,state,identity,prs,last_synced,error) VALUES (?1,?2,?3,?4,?5,?6) ON CONFLICT(id,state) DO UPDATE SET identity=excluded.identity,prs=excluded.prs,last_synced=excluded.last_synced,error=excluded.error",
            params![id,state,identity,snapshot.get("prs").cloned().unwrap_or_else(||json!([])).to_string(),snapshot.get("lastSynced").and_then(Value::as_str),snapshot.get("error").and_then(Value::as_str)],
        )?;
        Ok(())
    }

    pub fn jira_snapshot(&self, id: &str) -> rusqlite::Result<Option<Value>> {
        self.cache()
            .query_row(
                "SELECT items,jql,last_synced,error,meta FROM jira_snapshots WHERE id=?1",
                [id],
                jira_snapshot_from_row,
            )
            .optional()
    }

    pub fn set_jira_snapshot(&self, id: &str, snapshot: &Value) -> rusqlite::Result<()> {
        let meta = match snapshot.get("meta") {
            Some(Value::Object(value)) => Some(Value::Object(value.clone()).to_string()),
            _ => None,
        };
        self.cache().execute(
            "INSERT INTO jira_snapshots(id,items,jql,last_synced,error,meta) VALUES (?1,?2,?3,?4,?5,?6) ON CONFLICT(id) DO UPDATE SET items=excluded.items,jql=excluded.jql,last_synced=excluded.last_synced,error=excluded.error,meta=excluded.meta",
            params![id,snapshot.get("items").cloned().unwrap_or_else(||json!([])).to_string(),snapshot.get("jql").and_then(Value::as_str).unwrap_or(""),snapshot.get("lastSynced").and_then(Value::as_str),snapshot.get("error").and_then(Value::as_str),meta],
        )?;
        Ok(())
    }

    pub fn all_pr_snapshots(&self) -> rusqlite::Result<Value> {
        let conn = self.cache();
        let mut statement = conn.prepare("SELECT id,prs,last_synced,error FROM pr_snapshots")?;
        let mut out = Map::new();
        for row in statement.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, snapshot_from_row_offset(row, 1)?))
        })? {
            let (id, value) = row?;
            out.insert(id, value);
        }
        Ok(Value::Object(out))
    }

    pub fn all_jira_snapshots(&self) -> rusqlite::Result<Value> {
        let conn = self.cache();
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
    }

    pub fn review_state(
        &self,
        key: &str,
    ) -> rusqlite::Result<Option<(Option<String>, Option<String>)>> {
        self.durable()
            .query_row(
                "SELECT requested_at,viewed_at FROM review_state WHERE key=?1",
                [key],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
    }

    pub fn mark_review_viewed(&self, key: &str) -> rusqlite::Result<()> {
        self.durable().execute("INSERT INTO review_state (key,viewed_at) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET viewed_at=excluded.viewed_at", params![key,now()])?;
        Ok(())
    }

    pub fn mark_review_requested(&self, key: &str, timestamp: &str) -> rusqlite::Result<()> {
        self.durable().execute("INSERT INTO review_state(key,requested_at) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET requested_at=excluded.requested_at WHERE review_state.requested_at IS NULL OR review_state.requested_at < excluded.requested_at",params![key,timestamp])?;
        Ok(())
    }

    pub fn prune_review_state(&self, repo: &str, open_numbers: &[i64]) -> rusqlite::Result<()> {
        let conn = self.durable();
        let mut statement = conn.prepare("SELECT key FROM review_state WHERE key LIKE ?1")?;
        let keys = statement
            .query_map([format!("{repo}#%")], |row| row.get::<_, String>(0))?
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
    }

    pub fn add_log(
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
        let conn = self.logs_conn();
        conn.execute(
            "INSERT INTO logs(category,level,type,payload,created_at) VALUES (?1,?2,?3,?4,?5)",
            params![category, level, kind, body, created_at],
        )?;
        conn.execute(
            "DELETE FROM logs WHERE seq <= (SELECT MAX(seq) FROM logs) - 5000",
            [],
        )?;
        Ok(json!({"type":kind,"payload":body,"level":level,"created_at":created_at}))
    }

    pub fn add_event(&self, kind: &str, payload: &Value) -> rusqlite::Result<Value> {
        let level = if kind.to_ascii_lowercase().contains("fail")
            || kind.to_ascii_lowercase().contains("error")
        {
            "error"
        } else {
            "info"
        };
        self.add_log("event", level, kind, payload)
    }

    pub fn query_logs(
        &self,
        category: Option<&str>,
        level: Option<&str>,
        limit: i64,
    ) -> rusqlite::Result<Vec<Value>> {
        let conn = self.logs_conn();
        let limit = limit.clamp(1, 2000);
        let (sql, values): (&str, Vec<rusqlite::types::Value>) = match (category.filter(|c| *c != "all"), level) {
            (Some(c), Some(l)) => ("SELECT seq,category,level,type,payload,created_at FROM logs WHERE category=? AND level=? ORDER BY seq DESC LIMIT ?", vec![c.to_owned().into(),l.to_owned().into(),limit.into()]),
            (Some(c), None) => ("SELECT seq,category,level,type,payload,created_at FROM logs WHERE category=? ORDER BY seq DESC LIMIT ?", vec![c.to_owned().into(),limit.into()]),
            (None, Some(l)) => ("SELECT seq,category,level,type,payload,created_at FROM logs WHERE level=? ORDER BY seq DESC LIMIT ?", vec![l.to_owned().into(),limit.into()]),
            (None, None) => ("SELECT seq,category,level,type,payload,created_at FROM logs ORDER BY seq DESC LIMIT ?", vec![limit.into()]),
        };
        let mut statement = conn.prepare(sql)?;
        let result = statement
            .query_map(params_from_iter(values), log_from_row)?
            .collect();
        result
    }

    pub fn log_categories(&self) -> rusqlite::Result<Vec<String>> {
        let conn = self.logs_conn();
        let mut statement = conn.prepare("SELECT DISTINCT category FROM logs ORDER BY category")?;
        let result = statement.query_map([], |row| row.get(0))?.collect();
        result
    }

    pub fn clear_logs(&self, category: Option<&str>) -> rusqlite::Result<()> {
        if let Some(category) = category.filter(|c| *c != "all") {
            self.logs_conn()
                .execute("DELETE FROM logs WHERE category=?1", [category])?;
        } else {
            self.logs_conn().execute("DELETE FROM logs", [])?;
        }
        Ok(())
    }

    pub fn event_count(&self) -> rusqlite::Result<i64> {
        self.logs_conn().query_row(
            "SELECT COUNT(*) FROM logs WHERE category='event'",
            [],
            |r| r.get(0),
        )
    }

    fn migrate_events_to_logs(&self) -> rusqlite::Result<()> {
        let migrated: Option<String> = self
            .durable()
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
            let conn = self.durable();
            let mut statement = conn
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
        let mut logs = self.logs_conn();
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
        self.durable().execute("INSERT INTO config(key,value) VALUES ('events_migrated_to_logs','1') ON CONFLICT(key) DO UPDATE SET value='1'", [])?;
        Ok(())
    }
}

#[derive(Clone, Copy)]
enum FieldKind {
    String,
    Bool,
    Json,
}

fn migrate_legacy_name(data_dir: &Path) {
    let [current, legacy @ ..] = crate::recovery::DURABLE_NAMES;
    if data_dir.join(current).exists() {
        return;
    }
    // The newest earlier name wins; a directory never held two of them at once.
    let Some(found) = legacy.into_iter().find(|name| data_dir.join(name).exists()) else {
        return;
    };
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let from = data_dir.join(format!("{found}{suffix}"));
        if from.exists() {
            let _ = fs::rename(&from, data_dir.join(format!("{current}{suffix}")));
        }
    }
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
        "ALTER TABLE projects ADD COLUMN forward_webhooks INTEGER NOT NULL DEFAULT 1",
        "ALTER TABLE projects ADD COLUMN fix_version_enabled INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE projects ADD COLUMN fix_version_prefix TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE projects ADD COLUMN fix_version_script TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE projects ADD COLUMN workflows TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE projects ADD COLUMN ide TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE projects ADD COLUMN ide_cmd TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE projects ADD COLUMN ide_target TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE projects ADD COLUMN run_scheme TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE projects ADD COLUMN run_sim TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE tasks ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE tasks ADD COLUMN run_scheme TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE tasks ADD COLUMN run_sim TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE tabs ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0",
    ] {
        let _ = conn.execute(migration, []);
    }
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
           pinned INTEGER NOT NULL DEFAULT 0
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

fn project_from_row(row: &Row<'_>) -> rusqlite::Result<Value> {
    Ok(json!({
        "id": row.get::<_,String>("id")?, "name": row.get::<_,String>("name")?, "repo": row.get::<_,String>("repo")?,
        "workspace": row.get::<_,String>("workspace")?, "jiraProjectKey": row.get::<_,String>("jira_project_key")?,
        "jql": row.get::<_,String>("jql")?, "mergeTransition": row.get::<_,String>("merge_transition")?,
        "forwardWebhooks": row.get::<_,i64>("forward_webhooks")? != 0, "created_at": row.get::<_,String>("created_at")?,
        "fixVersionEnabled": row.get::<_,i64>("fix_version_enabled")? != 0, "fixVersionPrefix": text(row,"fix_version_prefix")?,
        "fixVersionScript": text(row,"fix_version_script")?, "workflows": parse_json(&text(row,"workflows")?, json!([])),
        "ide": text(row,"ide")?, "ideCmd": text(row,"ide_cmd")?, "ideTarget": text(row,"ide_target")?,
        "runScheme": text(row,"run_scheme")?, "runSim": text(row,"run_sim")?,
    }))
}

fn tab_from_row(row: &Row<'_>) -> rusqlite::Result<Value> {
    let pane = text(row, "pane_view")?;
    let pane = if pane.is_empty() {
        "term".to_owned()
    } else {
        pane
    };
    Ok(json!({
        "id": row.get::<_,String>("id")?,
        "kind": row.get::<_,String>("kind")?, "title": text(row,"title")?, "url": row.get::<_,String>("url")?,
        "cur": text(row,"cur")?, "repo": text(row,"repo")?, "branch": text(row,"branch")?,
        "paneView": pane,
        "diffOpen": row.get::<_,i64>("diff_open")? != 0, "pageClosed": row.get::<_,i64>("page_closed")? != 0,
        "diffIdx": row.get::<_,i64>("diff_pos")?, "history": parse_json(&text(row,"history")?,json!([])),
        "category": text(row,"category")?, "login": text(row,"login")?, "avatar": text(row,"avatar")?,
        "links": parse_json(&text(row,"links")?,json!([])), "_active": row.get::<_,i64>("active")? != 0,
        "pinned": row.get::<_,i64>("pinned")? != 0,
    }))
}

fn insert_tab(
    conn: &Connection,
    tab: &Map<String, Value>,
    position: i64,
    active: bool,
) -> rusqlite::Result<()> {
    let get = |key: &str| tab.get(key).and_then(Value::as_str).unwrap_or("");
    let url = get("url");
    let generated = Uuid::new_v4().to_string();
    let id = match get("id") {
        "" => generated.as_str(),
        value => value,
    };
    let kind = match get("kind") {
        "jira" => "jira",
        "web" => "web",
        _ => "github",
    };
    let title = if get("title").is_empty() {
        url
    } else {
        get("title")
    };
    let pane = match get("paneView") {
        "off" => "off",
        "diff" => "diff",
        _ => "term",
    };
    let links = tab
        .get("links")
        .filter(|v| v.is_array())
        .cloned()
        .unwrap_or_else(|| json!([]))
        .to_string();
    let history = tab
        .get("history")
        .filter(|v| v.is_array())
        .cloned()
        .unwrap_or_else(|| json!([]))
        .to_string();
    conn.execute("INSERT INTO tabs(id,url,kind,title,cur,repo,branch,pane_view,diff_open,page_closed,diff_pos,category,login,avatar,links,history,position,active,pinned) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19)",
        params![id,url,kind,title,get("cur"),get("repo"),get("branch"),pane,bool_int(tab.get("diffOpen"),false),bool_int(tab.get("pageClosed"),false),tab.get("diffIdx").and_then(Value::as_i64).unwrap_or(0).max(0),get("category"),get("login"),get("avatar"),links,history,position,i64::from(active),bool_int(tab.get("pinned"),false)])?;
    Ok(())
}

fn snapshot_from_row(row: &Row<'_>) -> rusqlite::Result<Value> {
    snapshot_from_row_offset(row, 0)
}
fn snapshot_from_row_offset(row: &Row<'_>, offset: usize) -> rusqlite::Result<Value> {
    let raw: String = row.get(offset)?;
    Ok(
        json!({ "prs": parse_json(&raw,json!([])), "lastSynced": row.get::<_,Option<String>>(offset+1)?, "error": row.get::<_,Option<String>>(offset+2)? }),
    )
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
pub fn project_identity(project: &Value) -> String {
    json!([
        project.get("repo").and_then(Value::as_str).unwrap_or(""),
        project
            .get("jiraProjectKey")
            .and_then(Value::as_str)
            .unwrap_or(""),
        project
            .get("created_at")
            .and_then(Value::as_str)
            .unwrap_or("")
    ])
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_database_under_an_earlier_name_is_carried_to_the_current_one() {
        for legacy in ["taskhub.db", "config.db"] {
            let dir = tempfile::tempdir().unwrap();
            fs::write(dir.path().join(legacy), b"rows").unwrap();
            fs::write(dir.path().join(format!("{legacy}-wal")), b"log").unwrap();
            migrate_legacy_name(dir.path());
            assert_eq!(fs::read(dir.path().join("craft.db")).unwrap(), b"rows");
            assert_eq!(fs::read(dir.path().join("craft.db-wal")).unwrap(), b"log");
            assert!(!dir.path().join(legacy).exists());
        }
    }

    #[test]
    fn a_current_database_is_never_replaced_by_an_earlier_one() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("craft.db"), b"new").unwrap();
        fs::write(dir.path().join("taskhub.db"), b"old").unwrap();
        migrate_legacy_name(dir.path());
        assert_eq!(fs::read(dir.path().join("craft.db")).unwrap(), b"new");
        assert!(dir.path().join("taskhub.db").exists());
    }
}
