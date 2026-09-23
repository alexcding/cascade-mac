//! Persistence: pipelines and the fired ledger live in `craft.db` (they must survive a cache
//! reset, or a merge would fire twice), trigger baselines in `data.db`, run history in `logs.db`.

use chrono::{Duration, Utc};
use rusqlite::{params, OptionalExtension, Row};
use serde_json::{json, Value};
use uuid::Uuid;

use super::model::{Automation, Mode, Step, Trace};
use crate::Database;

fn now() -> String {
    Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

fn from_row(row: &Row<'_>) -> rusqlite::Result<Automation> {
    let trigger: String = row.get("trigger")?;
    let steps: String = row.get("steps")?;
    let mode: String = row.get("mode")?;
    let mut steps: Vec<Step> = serde_json::from_str(&steps).unwrap_or_default();
    for step in steps.iter_mut().filter(|s| s.node == "jira.fix_version" && !s.params.contains_key("source")) {
        let source = step.version_source().to_owned();
        step.params.insert("source".into(), Value::String(source));
    }
    Ok(Automation {
        id: row.get("id")?,
        name: row.get("name")?,
        mode: Mode::parse(&mode),
        armed_at: row.get("armed_at")?,
        trigger: serde_json::from_str(&trigger).unwrap_or_default(),
        steps,
        position: row.get("position")?,
        created_at: row.get("created_at")?,
        updated_at: row.get("updated_at")?,
    })
}

pub fn list(db: &Database) -> rusqlite::Result<Vec<Automation>> {
    let conn = db.durable();
    let mut statement =
        conn.prepare("SELECT * FROM automations ORDER BY position ASC, created_at ASC")?;
    let rows = statement.query_map([], from_row)?.collect();
    rows
}

pub fn get(db: &Database, id: &str) -> rusqlite::Result<Option<Automation>> {
    db.durable()
        .query_row("SELECT * FROM automations WHERE id=?1", [id], from_row)
        .optional()
}

/// Insert or replace. A pipeline that leaves `off` is re-armed now.
pub fn save(db: &Database, mut automation: Automation) -> rusqlite::Result<Automation> {
    let existing = if automation.id.is_empty() {
        None
    } else {
        get(db, &automation.id)?
    };
    let stamp = now();
    if automation.id.is_empty() {
        automation.id = Uuid::new_v4().to_string();
    }
    automation.created_at = existing
        .as_ref()
        .map(|a| a.created_at.clone())
        .unwrap_or_else(|| stamp.clone());
    automation.updated_at = stamp.clone();
    let was_off = existing.as_ref().is_none_or(|a| a.mode == Mode::Off);
    // The JQL baseline only describes what the pipeline saw while armed with this query. A
    // pipeline switched back on, or pointed at another query, re-seeds instead of firing on
    // everything that changed meanwhile.
    let jql = |a: &Automation| a.trigger.params.get("jql").cloned();
    let reseed = automation.mode == Mode::Off
        || was_off
        || existing.as_ref().is_some_and(|a| jql(a) != jql(&automation));
    automation.armed_at = if automation.mode == Mode::Off {
        None
    } else if was_off {
        Some(stamp)
    } else {
        existing.and_then(|a| a.armed_at).or(Some(now()))
    };
    if automation.position == 0 {
        let next: i64 = db.durable().query_row(
            "SELECT COALESCE(MAX(position),0)+1 FROM automations WHERE id != ?1",
            [&automation.id],
            |row| row.get(0),
        )?;
        automation.position = next;
    }
    db.durable().execute(
        "INSERT INTO automations(id,name,mode,armed_at,trigger,steps,position,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)
         ON CONFLICT(id) DO UPDATE SET name=excluded.name,mode=excluded.mode,armed_at=excluded.armed_at,trigger=excluded.trigger,steps=excluded.steps,position=excluded.position,updated_at=excluded.updated_at",
        params![
            automation.id,
            automation.name,
            automation.mode.as_str(),
            automation.armed_at,
            serde_json::to_string(&automation.trigger).unwrap_or_else(|_| "{}".into()),
            serde_json::to_string(&automation.steps).unwrap_or_else(|_| "[]".into()),
            automation.position,
            automation.created_at,
            automation.updated_at,
        ],
    )?;
    if reseed {
        db.cache()
            .execute("DELETE FROM automation_jira_state WHERE automation_id=?1", [&automation.id])?;
    }
    Ok(automation)
}

pub fn delete(db: &Database, id: &str) -> rusqlite::Result<bool> {
    let removed = db.durable().execute("DELETE FROM automations WHERE id=?1", [id])?;
    db.durable()
        .execute("DELETE FROM automation_fired WHERE automation_id=?1", [id])?;
    db.cache()
        .execute("DELETE FROM automation_jira_state WHERE automation_id=?1", [id])?;
    Ok(removed > 0)
}

/// Record that `automation` fired for `key`. False when it already had: the poll loop and the
/// webhook both report a merge, and only the first may act.
pub fn claim(db: &Database, automation: &str, key: &str) -> rusqlite::Result<bool> {
    let inserted = db.durable().execute(
        "INSERT OR IGNORE INTO automation_fired(automation_id,event_key,fired_at) VALUES (?1,?2,?3)",
        params![automation, key, now()],
    )?;
    if inserted > 0 {
        let cutoff = (Utc::now() - Duration::days(90))
            .to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
        db.durable()
            .execute("DELETE FROM automation_fired WHERE fired_at < ?1", [cutoff])?;
    }
    Ok(inserted > 0)
}

/// Undo a `claim` whose action failed, so the next event may try again.
pub fn release(db: &Database, automation: &str, key: &str) -> rusqlite::Result<()> {
    db.durable()
        .execute("DELETE FROM automation_fired WHERE automation_id = ?1 AND event_key = ?2", params![automation, key])?;
    Ok(())
}

pub fn record_run(db: &Database, trace: &Trace) -> rusqlite::Result<()> {
    let conn = db.logs_conn();
    conn.execute(
        "INSERT INTO automation_runs(automation_id,event_key,mode,status,subject,trace,started_at,finished_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",
        params![
            trace.automation_id,
            trace.event_key,
            trace.mode,
            trace.status,
            trace.subject,
            serde_json::to_string(trace).unwrap_or_else(|_| "{}".into()),
            trace.started_at,
            trace.finished_at,
        ],
    )?;
    conn.execute(
        "DELETE FROM automation_runs WHERE seq <= (SELECT MAX(seq) FROM automation_runs) - 2000",
        [],
    )?;
    Ok(())
}

pub fn runs(db: &Database, automation: Option<&str>, limit: i64) -> rusqlite::Result<Vec<Value>> {
    let conn = db.logs_conn();
    let limit = limit.clamp(1, 500);
    let map = |row: &Row<'_>| -> rusqlite::Result<Value> {
        let trace: String = row.get("trace")?;
        let mut value: Value = serde_json::from_str(&trace).unwrap_or_else(|_| json!({}));
        value["id"] = json!(row.get::<_, i64>("seq")?);
        Ok(value)
    };
    let rows = if let Some(id) = automation {
        let mut statement = conn.prepare(
            "SELECT seq,trace FROM automation_runs WHERE automation_id=?1 ORDER BY seq DESC LIMIT ?2",
        )?;
        let rows = statement.query_map(params![id, limit], map)?.collect();
        rows
    } else {
        let mut statement =
            conn.prepare("SELECT seq,trace FROM automation_runs ORDER BY seq DESC LIMIT ?1")?;
        let rows = statement.query_map([limit], map)?.collect();
        rows
    };
    rows
}

/// The latest run of each pipeline, for the list's status column.
pub fn last_runs(db: &Database) -> rusqlite::Result<Vec<(String, String, String, String)>> {
    let conn = db.logs_conn();
    let mut statement = conn.prepare(
        "SELECT automation_id,status,mode,finished_at FROM automation_runs WHERE seq IN (SELECT MAX(seq) FROM automation_runs GROUP BY automation_id)",
    )?;
    let rows = statement
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)))?
        .collect();
    rows
}

/// Live runs of `automation` in the last hour, for the rate limit.
pub fn recent_live_runs(db: &Database, automation: &str) -> rusqlite::Result<i64> {
    let since = (Utc::now() - Duration::hours(1)).to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    db.logs_conn().query_row(
        "SELECT COUNT(*) FROM automation_runs WHERE automation_id=?1 AND mode='live' AND status IN ('completed','error') AND started_at >= ?2",
        params![automation, since],
        |row| row.get(0),
    )
}

// Trigger baselines, in the regenerable cache: losing them only re-baselines.

pub fn pr_state(db: &Database, key: &str) -> rusqlite::Result<Option<Value>> {
    db.cache()
        .query_row(
            "SELECT state FROM automation_pr_state WHERE key=?1",
            [key],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map(|raw| raw.and_then(|raw| serde_json::from_str(&raw).ok()))
}

pub fn set_pr_state(db: &Database, key: &str, repo: &str, state: &Value) -> rusqlite::Result<()> {
    db.cache().execute(
        "INSERT INTO automation_pr_state(key,repo,state) VALUES (?1,?2,?3) ON CONFLICT(key) DO UPDATE SET state=excluded.state",
        params![key, repo, state.to_string()],
    )?;
    Ok(())
}

/// Forget PRs of `repo` that are no longer open, keeping `keep`.
pub fn prune_pr_state(db: &Database, repo: &str, keep: &[String]) -> rusqlite::Result<()> {
    let conn = db.cache();
    let mut statement = conn.prepare("SELECT key FROM automation_pr_state WHERE repo=?1")?;
    let keys: Vec<String> = statement
        .query_map([repo], |row| row.get(0))?
        .filter_map(Result::ok)
        .collect();
    for key in keys {
        if !keep.contains(&key) {
            conn.execute("DELETE FROM automation_pr_state WHERE key=?1", [&key])?;
        }
    }
    Ok(())
}

pub fn jira_state(db: &Database, automation: &str) -> rusqlite::Result<Vec<(String, String)>> {
    let conn = db.cache();
    let mut statement =
        conn.prepare("SELECT key,status FROM automation_jira_state WHERE automation_id=?1")?;
    let rows = statement
        .query_map([automation], |row| Ok((row.get(0)?, row.get(1)?)))?
        .collect();
    rows
}

pub fn set_jira_state(db: &Database, automation: &str, items: &[(String, String)]) -> rusqlite::Result<()> {
    let mut conn = db.cache();
    let tx = conn.transaction()?;
    tx.execute("DELETE FROM automation_jira_state WHERE automation_id=?1", [automation])?;
    for (key, status) in items {
        tx.execute(
            "INSERT INTO automation_jira_state(automation_id,key,status) VALUES (?1,?2,?3)",
            params![automation, key, status],
        )?;
    }
    tx.commit()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::automation::model::Trigger;
    use serde_json::json;

    fn jira_pipeline(jql: &str, mode: Mode) -> Automation {
        let mut params = serde_json::Map::new();
        params.insert("jql".into(), json!(jql));
        Automation {
            id: "a".into(),
            name: "Entered".into(),
            mode,
            trigger: Trigger { types: vec!["jira.entered".into()], projects: vec![], params },
            ..Default::default()
        }
    }

    #[test]
    fn the_retired_watch_only_mode_reads_as_off() {
        assert_eq!(Mode::parse("shadow"), Mode::Off);
        assert_eq!(serde_json::from_value::<Mode>(json!("shadow")).unwrap(), Mode::Off);
    }

    #[test]
    fn a_jira_baseline_is_dropped_when_rearmed_or_requeried() {
        let directory = tempfile::tempdir().unwrap();
        let db = Database::open(directory.path()).unwrap();
        let seeded = [("__seeded__".to_owned(), String::new()), ("A-1".to_owned(), "To Do".to_owned())];
        save(&db, jira_pipeline("project = A", Mode::Live)).unwrap();
        set_jira_state(&db, "a", &seeded).unwrap();
        // Saving with nothing trigger-related changed keeps the baseline.
        save(&db, Automation { name: "Renamed".into(), ..jira_pipeline("project = A", Mode::Live) }).unwrap();
        assert_eq!(jira_state(&db, "a").unwrap().len(), 2);
        // A new query means a new baseline, not events for everything it matches.
        save(&db, jira_pipeline("project = B", Mode::Live)).unwrap();
        assert!(jira_state(&db, "a").unwrap().is_empty());
        // Switched off and back on: what changed while it was off does not fire it.
        set_jira_state(&db, "a", &seeded).unwrap();
        save(&db, jira_pipeline("project = B", Mode::Off)).unwrap();
        set_jira_state(&db, "a", &seeded).unwrap();
        save(&db, jira_pipeline("project = B", Mode::Live)).unwrap();
        assert!(jira_state(&db, "a").unwrap().is_empty());
    }

    #[test]
    fn a_released_claim_can_be_taken_again() {
        let directory = tempfile::tempdir().unwrap();
        let db = Database::open(directory.path()).unwrap();
        assert!(claim(&db, "github.approve", "a/b#1@s").unwrap());
        assert!(!claim(&db, "github.approve", "a/b#1@s").unwrap());
        release(&db, "github.approve", "a/b#1@s").unwrap();
        assert!(claim(&db, "github.approve", "a/b#1@s").unwrap());
    }
}
