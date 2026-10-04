//! Persistence: pipelines and the fired ledger live in `cascade.db` (they must survive a cache
//! reset, or a merge would fire twice), trigger baselines in `data.db`, run history in `logs.db`.
//! Each store answers from its own thread (`db::Store`); nothing here holds a connection.

use chrono::{Duration, Utc};
use rusqlite::{params, OptionalExtension, Row};
use serde_json::{json, Value};
use uuid::Uuid;

use super::model::{Automation, Kind, Mode, Schedule, Step, Trace};
use crate::Database;

fn now() -> String {
    Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

fn from_row(row: &Row<'_>) -> rusqlite::Result<Automation> {
    let trigger: String = row.get("trigger")?;
    let steps: String = row.get("steps")?;
    let mode: String = row.get("mode")?;
    let kind: String = row.get("kind")?;
    let schedule: String = row.get("schedule")?;
    let mut steps: Vec<Step> = serde_json::from_str(&steps).unwrap_or_default();
    for step in steps.iter_mut().filter(|s| s.node == "jira.fix_version" && !s.params.contains_key("source")) {
        let source = step.version_source().to_owned();
        step.params.insert("source".into(), Value::String(source));
    }
    Ok(Automation {
        id: row.get("id")?,
        name: row.get("name")?,
        mode: Mode::parse(&mode),
        kind: Kind::parse(&kind),
        schedule: serde_json::from_str(&schedule).unwrap_or_default(),
        armed_at: row.get("armed_at")?,
        trigger: serde_json::from_str(&trigger).unwrap_or_default(),
        steps,
        position: row.get("position")?,
        created_at: row.get("created_at")?,
        updated_at: row.get("updated_at")?,
    })
}

pub async fn list(db: &Database) -> rusqlite::Result<Vec<Automation>> {
    db.durable
        .call(|conn| {
            let mut statement =
                conn.prepare("SELECT * FROM automations ORDER BY position ASC, created_at ASC")?;
            let rows = statement.query_map([], from_row)?.collect();
            rows
        })
        .await
}

pub async fn get(db: &Database, id: &str) -> rusqlite::Result<Option<Automation>> {
    let id = id.to_owned();
    db.durable
        .call(move |conn| {
            conn.query_row("SELECT * FROM automations WHERE id=?1", [id], from_row)
                .optional()
        })
        .await
}

/// Insert or replace. A pipeline that leaves `off` is re-armed now.
pub async fn save(db: &Database, mut automation: Automation) -> rusqlite::Result<Automation> {
    let existing = if automation.id.is_empty() {
        None
    } else {
        get(db, &automation.id).await?
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
    // A schedule given new times, or a pipeline turned into one, starts counting from now: a time
    // the old schedule never named, already passed today, is not a run it missed.
    let timing = |s: &Schedule| (s.repeat, s.time.clone(), s.days.clone(), s.every_hours, s.cron.clone());
    let retimed = existing.as_ref().is_some_and(|a| {
        a.kind != automation.kind || (automation.kind == Kind::Schedule && timing(&a.schedule) != timing(&automation.schedule))
    });
    // The JQL baseline only describes what the pipeline saw while armed with this query. A
    // pipeline switched back on, or pointed at another query, re-seeds instead of firing on
    // everything that changed meanwhile.
    let jql = |a: &Automation| a.trigger.params.get("jql").cloned();
    let reseed = automation.mode == Mode::Off
        || was_off
        || existing.as_ref().is_some_and(|a| jql(a) != jql(&automation));
    automation.armed_at = if automation.mode == Mode::Off {
        None
    } else if was_off || retimed {
        Some(stamp)
    } else {
        existing.and_then(|a| a.armed_at).or(Some(now()))
    };
    let saved = db
        .durable
        .call(move |conn| {
            if automation.position == 0 {
                let next: i64 = conn.query_row(
                    "SELECT COALESCE(MAX(position),0)+1 FROM automations WHERE id != ?1",
                    [&automation.id],
                    |row| row.get(0),
                )?;
                automation.position = next;
            }
            conn.execute(
                "INSERT INTO automations(id,name,mode,armed_at,trigger,steps,position,created_at,updated_at,kind,schedule) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
                 ON CONFLICT(id) DO UPDATE SET name=excluded.name,mode=excluded.mode,armed_at=excluded.armed_at,trigger=excluded.trigger,steps=excluded.steps,position=excluded.position,updated_at=excluded.updated_at,kind=excluded.kind,schedule=excluded.schedule",
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
                    automation.kind.as_str(),
                    serde_json::to_string(&automation.schedule).unwrap_or_else(|_| "{}".into()),
                ],
            )?;
            Ok(automation)
        })
        .await?;
    if reseed {
        let id = saved.id.clone();
        db.cache
            .call(move |conn| {
                conn.execute("DELETE FROM automation_jira_state WHERE automation_id=?1", [id])?;
                Ok(())
            })
            .await?;
    }
    Ok(saved)
}

pub async fn delete(db: &Database, id: &str) -> rusqlite::Result<bool> {
    let durable_id = id.to_owned();
    let removed = db
        .durable
        .call(move |conn| {
            let removed = conn.execute("DELETE FROM automations WHERE id=?1", [&durable_id])?;
            conn.execute("DELETE FROM automation_fired WHERE automation_id=?1", [&durable_id])?;
            conn.execute("DELETE FROM automation_sessions WHERE automation_id=?1", [&durable_id])?;
            conn.execute("DELETE FROM automation_run_sessions WHERE automation_id=?1", [&durable_id])?;
            Ok(removed)
        })
        .await?;
    let id = id.to_owned();
    db.cache
        .call(move |conn| {
            conn.execute("DELETE FROM automation_jira_state WHERE automation_id=?1", [id])?;
            Ok(())
        })
        .await?;
    Ok(removed > 0)
}

/// Record that `automation` fired for `key`. False when it already had: the poll loop and the
/// webhook both report a merge, and only the first may act.
pub async fn claim(db: &Database, automation: &str, key: &str) -> rusqlite::Result<bool> {
    let automation = automation.to_owned();
    let key = key.to_owned();
    db.durable
        .call(move |conn| {
            let inserted = conn.execute(
                "INSERT OR IGNORE INTO automation_fired(automation_id,event_key,fired_at) VALUES (?1,?2,?3)",
                params![automation, key, now()],
            )?;
            if inserted > 0 {
                let cutoff = (Utc::now() - Duration::days(90))
                    .to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
                conn.execute("DELETE FROM automation_fired WHERE fired_at < ?1", [cutoff])?;
            }
            Ok(inserted > 0)
        })
        .await
}

/// Runs left `launching` by a backend that stopped before the app answered or the watchdog fired:
/// they will not hear now, so each is an error. How many there were.
pub async fn settle_stale_launches(db: &Database) -> rusqlite::Result<usize> {
    db.logs
        .call(move |conn| {
            let rows: Vec<(i64, String)> = {
                let mut statement = conn.prepare("SELECT seq,trace FROM automation_runs WHERE status='launching'")?;
                let rows = statement.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?.collect::<rusqlite::Result<_>>()?;
                rows
            };
            let finished = now();
            for (seq, trace) in &rows {
                let mut trace: Value = serde_json::from_str(trace).unwrap_or_else(|_| json!({}));
                trace["status"] = json!("error");
                trace["finishedAt"] = json!(finished);
                if let Some(step) = trace["steps"].as_array_mut().and_then(|steps| steps.iter_mut().find(|s| s["stepId"] == "launch")) {
                    step["status"] = json!("error");
                    step["detail"] = json!("Cascade closed before it said whether the agent started.");
                }
                conn.execute(
                    "UPDATE automation_runs SET status='error', trace=?1, finished_at=?2 WHERE seq=?3",
                    params![serde_json::to_string(&trace).unwrap_or_else(|_| "{}".into()), finished, seq],
                )?;
            }
            Ok(rows.len())
        })
        .await
}

/// Settle a scheduled run still `launching`: `completed` once the app has started its agent, else
/// `error`, with what the app said on its launch step. The settled run, or none when there is no
/// such run still waiting (settled already, by the app or by the watchdog).
pub async fn settle_launch(db: &Database, automation: &str, key: &str, ok: bool, detail: &str) -> rusqlite::Result<Option<Value>> {
    let (automation, key, detail) = (automation.to_owned(), key.to_owned(), detail.to_owned());
    db.logs
        .call(move |conn| {
            let found: Option<(i64, String)> = conn
                .query_row(
                    "SELECT seq,trace FROM automation_runs WHERE automation_id=?1 AND event_key=?2 AND status='launching' ORDER BY seq DESC LIMIT 1",
                    params![automation, key],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?;
            let Some((seq, trace)) = found else { return Ok(None) };
            let mut trace: Value = serde_json::from_str(&trace).unwrap_or_else(|_| json!({}));
            let status = if ok { "completed" } else { "error" };
            let finished = now();
            trace["status"] = json!(status);
            trace["finishedAt"] = json!(finished);
            if let Some(step) = trace["steps"].as_array_mut().and_then(|steps| steps.iter_mut().find(|s| s["stepId"] == "launch")) {
                step["status"] = json!(if ok { "done" } else { "error" });
                step["detail"] = json!(detail);
            }
            conn.execute(
                "UPDATE automation_runs SET status=?1, trace=?2, finished_at=?3 WHERE seq=?4",
                params![status, serde_json::to_string(&trace).unwrap_or_else(|_| "{}".into()), finished, seq],
            )?;
            Ok(Some(trace))
        })
        .await
}

/// Note a session a scheduled automation's New run made.
pub async fn add_run_session(db: &Database, automation: &str, task: &str) -> rusqlite::Result<()> {
    let (automation, task) = (automation.to_owned(), task.to_owned());
    db.durable
        .call(move |conn| {
            conn.execute(
                "INSERT OR IGNORE INTO automation_run_sessions(automation_id,task_id,created_at) VALUES (?1,?2,?3)",
                params![automation, task, now()],
            )?;
            Ok(())
        })
        .await
}

/// The sessions an automation's New runs made, newest first.
pub async fn run_sessions(db: &Database, automation: &str) -> rusqlite::Result<Vec<String>> {
    let automation = automation.to_owned();
    db.durable
        .call(move |conn| {
            let mut statement = conn.prepare(
                "SELECT task_id FROM automation_run_sessions WHERE automation_id=?1 ORDER BY created_at DESC, rowid DESC",
            )?;
            let rows = statement.query_map([automation], |row| row.get(0))?.collect();
            rows
        })
        .await
}

/// Forget a run's session that is gone.
pub async fn forget_run_session(db: &Database, task: &str) -> rusqlite::Result<()> {
    let task = task.to_owned();
    db.durable
        .call(move |conn| {
            conn.execute("DELETE FROM automation_run_sessions WHERE task_id=?1", [task])?;
            Ok(())
        })
        .await
}

/// The session a scheduled automation's last run started, if it recorded one.
pub async fn last_session(db: &Database, automation: &str) -> rusqlite::Result<Option<String>> {
    let automation = automation.to_owned();
    db.durable
        .call(move |conn| {
            conn.query_row("SELECT task_id FROM automation_sessions WHERE automation_id=?1", [automation], |row| row.get(0))
                .optional()
        })
        .await
}

pub async fn set_last_session(db: &Database, automation: &str, task: &str) -> rusqlite::Result<()> {
    let (automation, task) = (automation.to_owned(), task.to_owned());
    db.durable
        .call(move |conn| {
            conn.execute(
                "INSERT INTO automation_sessions(automation_id,task_id) VALUES (?1,?2)
                 ON CONFLICT(automation_id) DO UPDATE SET task_id=excluded.task_id",
                params![automation, task],
            )?;
            Ok(())
        })
        .await
}

/// Undo a `claim` whose action failed, so the next event may try again.
pub async fn release(db: &Database, automation: &str, key: &str) -> rusqlite::Result<()> {
    let automation = automation.to_owned();
    let key = key.to_owned();
    db.durable
        .call(move |conn| {
            conn.execute(
                "DELETE FROM automation_fired WHERE automation_id = ?1 AND event_key = ?2",
                params![automation, key],
            )?;
            Ok(())
        })
        .await
}

pub async fn record_run(db: &Database, trace: &Trace) -> rusqlite::Result<()> {
    let trace = trace.clone();
    db.logs
        .call(move |conn| {
            conn.execute(
                "INSERT INTO automation_runs(automation_id,event_key,mode,status,subject,trace,started_at,finished_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",
                params![
                    trace.automation_id,
                    trace.event_key,
                    trace.mode,
                    trace.status,
                    trace.subject,
                    serde_json::to_string(&trace).unwrap_or_else(|_| "{}".into()),
                    trace.started_at,
                    trace.finished_at,
                ],
            )?;
            conn.execute(
                "DELETE FROM automation_runs WHERE seq <= (SELECT MAX(seq) FROM automation_runs) - 2000",
                [],
            )?;
            Ok(())
        })
        .await
}

pub async fn runs(db: &Database, automation: Option<&str>, limit: i64) -> rusqlite::Result<Vec<Value>> {
    let automation = automation.map(str::to_owned);
    let limit = limit.clamp(1, 500);
    db.logs
        .call(move |conn| {
            let map = |row: &Row<'_>| -> rusqlite::Result<Value> {
                let trace: String = row.get("trace")?;
                let mut value: Value = serde_json::from_str(&trace).unwrap_or_else(|_| json!({}));
                value["id"] = json!(row.get::<_, i64>("seq")?);
                Ok(value)
            };
            if let Some(id) = automation {
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
            }
        })
        .await
}

/// The latest run of each pipeline, for the list's status column.
pub async fn last_runs(db: &Database) -> rusqlite::Result<Vec<(String, String, String, String)>> {
    db.logs
        .call(|conn| {
            let mut statement = conn.prepare(
                "SELECT automation_id,status,mode,finished_at FROM automation_runs WHERE seq IN (SELECT MAX(seq) FROM automation_runs GROUP BY automation_id)",
            )?;
            let rows = statement
                .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)))?
                .collect();
            rows
        })
        .await
}

/// Live runs of `automation` in the last hour, for the rate limit.
pub async fn recent_live_runs(db: &Database, automation: &str) -> rusqlite::Result<i64> {
    let automation = automation.to_owned();
    let since = (Utc::now() - Duration::hours(1)).to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    db.logs
        .call(move |conn| {
            conn.query_row(
                "SELECT COUNT(*) FROM automation_runs WHERE automation_id=?1 AND mode='live' AND status IN ('completed','error') AND started_at >= ?2",
                params![automation, since],
                |row| row.get(0),
            )
        })
        .await
}

// Trigger baselines, in the regenerable cache: losing them only re-baselines.

pub async fn pr_state(db: &Database, key: &str) -> rusqlite::Result<Option<Value>> {
    let key = key.to_owned();
    db.cache
        .call(move |conn| {
            conn.query_row(
                "SELECT state FROM automation_pr_state WHERE key=?1",
                [key],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map(|raw| raw.and_then(|raw| serde_json::from_str(&raw).ok()))
        })
        .await
}

pub async fn set_pr_state(db: &Database, key: &str, repo: &str, state: &Value) -> rusqlite::Result<()> {
    let key = key.to_owned();
    let repo = repo.to_owned();
    let state = state.to_string();
    db.cache
        .call(move |conn| {
            conn.execute(
                "INSERT INTO automation_pr_state(key,repo,state) VALUES (?1,?2,?3) ON CONFLICT(key) DO UPDATE SET state=excluded.state",
                params![key, repo, state],
            )?;
            Ok(())
        })
        .await
}

/// Forget PRs of `repo` that are no longer open, keeping `keep`.
pub async fn prune_pr_state(db: &Database, repo: &str, keep: &[String]) -> rusqlite::Result<()> {
    let repo = repo.to_owned();
    let keep = keep.to_vec();
    db.cache
        .call(move |conn| {
            let mut statement = conn.prepare("SELECT key FROM automation_pr_state WHERE repo=?1")?;
            let keys: Vec<String> = statement
                .query_map([repo], |row| row.get(0))?
                .filter_map(Result::ok)
                .collect();
            drop(statement);
            for key in keys {
                if !keep.contains(&key) {
                    conn.execute("DELETE FROM automation_pr_state WHERE key=?1", [&key])?;
                }
            }
            Ok(())
        })
        .await
}

pub async fn jira_state(db: &Database, automation: &str) -> rusqlite::Result<Vec<(String, String)>> {
    let automation = automation.to_owned();
    db.cache
        .call(move |conn| {
            let mut statement =
                conn.prepare("SELECT key,status FROM automation_jira_state WHERE automation_id=?1")?;
            let rows = statement
                .query_map([automation], |row| Ok((row.get(0)?, row.get(1)?)))?
                .collect();
            rows
        })
        .await
}

pub async fn set_jira_state(db: &Database, automation: &str, items: &[(String, String)]) -> rusqlite::Result<()> {
    let automation = automation.to_owned();
    let items = items.to_vec();
    db.cache
        .call(move |conn| {
            let tx = conn.transaction()?;
            tx.execute("DELETE FROM automation_jira_state WHERE automation_id=?1", [&automation])?;
            for (key, status) in &items {
                tx.execute(
                    "INSERT INTO automation_jira_state(automation_id,key,status) VALUES (?1,?2,?3)",
                    params![automation, key, status],
                )?;
            }
            tx.commit()
        })
        .await
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

    #[tokio::test]
    async fn a_jira_baseline_is_dropped_when_rearmed_or_requeried() {
        let directory = tempfile::tempdir().unwrap();
        let db = Database::open(directory.path()).unwrap();
        let seeded = [("__seeded__".to_owned(), String::new()), ("A-1".to_owned(), "To Do".to_owned())];
        save(&db, jira_pipeline("project = A", Mode::Live)).await.unwrap();
        set_jira_state(&db, "a", &seeded).await.unwrap();
        // Saving with nothing trigger-related changed keeps the baseline.
        save(&db, Automation { name: "Renamed".into(), ..jira_pipeline("project = A", Mode::Live) }).await.unwrap();
        assert_eq!(jira_state(&db, "a").await.unwrap().len(), 2);
        // A new query means a new baseline, not events for everything it matches.
        save(&db, jira_pipeline("project = B", Mode::Live)).await.unwrap();
        assert!(jira_state(&db, "a").await.unwrap().is_empty());
        // Switched off and back on: what changed while it was off does not fire it.
        set_jira_state(&db, "a", &seeded).await.unwrap();
        save(&db, jira_pipeline("project = B", Mode::Off)).await.unwrap();
        set_jira_state(&db, "a", &seeded).await.unwrap();
        save(&db, jira_pipeline("project = B", Mode::Live)).await.unwrap();
        assert!(jira_state(&db, "a").await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn a_scheduled_automation_keeps_its_kind_schedule_and_last_session() {
        use crate::automation::model::{Kind, Repeat, Schedule, SessionMode, Workspace};
        let directory = tempfile::tempdir().unwrap();
        let db = Database::open(directory.path()).unwrap();
        let schedule = Schedule {
            prompt: "Audit dependencies".into(),
            project: "p1".into(),
            workspace: Workspace::Worktree,
            branch: "main".into(),
            session: SessionMode::Reuse,
            repeat: Repeat::Cron,
            cron: "0 9 * * 1-5".into(),
            precheck: "true".into(),
            ..Schedule::default()
        };
        let saved = save(&db, Automation { name: "Audit".into(), kind: Kind::Schedule, schedule: schedule.clone(), ..Automation::default() })
            .await
            .unwrap();
        let read = get(&db, &saved.id).await.unwrap().unwrap();
        assert_eq!((read.kind, read.schedule), (Kind::Schedule, schedule));
        assert_eq!(last_session(&db, &saved.id).await.unwrap(), None);
        set_last_session(&db, &saved.id, "t1").await.unwrap();
        set_last_session(&db, &saved.id, "t2").await.unwrap();
        assert_eq!(last_session(&db, &saved.id).await.unwrap().as_deref(), Some("t2"));
        add_run_session(&db, &saved.id, "r1").await.unwrap();
        add_run_session(&db, &saved.id, "r2").await.unwrap();
        assert_eq!(run_sessions(&db, &saved.id).await.unwrap(), ["r2", "r1"], "newest first");
        forget_run_session(&db, "r2").await.unwrap();
        assert_eq!(run_sessions(&db, &saved.id).await.unwrap(), ["r1"]);
        delete(&db, &saved.id).await.unwrap();
        assert_eq!(last_session(&db, &saved.id).await.unwrap(), None);
        assert!(run_sessions(&db, &saved.id).await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn a_schedule_given_new_times_is_armed_again() {
        use crate::automation::model::{Kind, Schedule};
        let directory = tempfile::tempdir().unwrap();
        let db = Database::open(directory.path()).unwrap();
        let schedule = Schedule { prompt: "p".into(), project: "x".into(), ..Schedule::default() };
        let first = save(&db, Automation { kind: Kind::Schedule, mode: Mode::Live, schedule, ..Automation::default() }).await.unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        let renamed = save(&db, Automation { name: "Renamed".into(), ..first.clone() }).await.unwrap();
        assert_eq!(renamed.armed_at, first.armed_at, "a change to anything but its times keeps when it was armed");
        let mut retimed = renamed.clone();
        retimed.schedule.time = "18:00".into();
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        let retimed = save(&db, retimed).await.unwrap();
        assert!(retimed.armed_at > first.armed_at, "new times count from now");
    }

    #[tokio::test]
    async fn a_launching_run_is_settled_once() {
        let directory = tempfile::tempdir().unwrap();
        let db = Database::open(directory.path()).unwrap();
        let trace = Trace {
            automation_id: "a".into(), automation_name: "A".into(), event_kind: "schedule".into(), event_key: "slot:1".into(),
            subject: "p".into(), mode: "live".into(), trigger_matched: true, trigger_detail: String::new(),
            status: "launching".into(),
            steps: vec![crate::automation::model::StepResult {
                step_id: "launch".into(), node: "schedule.launch".into(), label: "Start agent".into(),
                status: "launching".into(), detail: "waiting".into(), commands: vec![],
            }],
            started_at: now(), finished_at: now(),
        };
        record_run(&db, &trace).await.unwrap();
        let settled = settle_launch(&db, "a", "slot:1", false, "terminal busy").await.unwrap().unwrap();
        assert_eq!(settled["status"], "error");
        assert_eq!(settled["steps"][0]["status"], "error");
        assert_eq!(settled["steps"][0]["detail"], "terminal busy");
        assert!(settle_launch(&db, "a", "slot:1", true, "").await.unwrap().is_none(), "the watchdog finds it settled");
        record_run(&db, &Trace { event_key: "slot:2".into(), ..trace.clone() }).await.unwrap();
        assert_eq!(settle_stale_launches(&db).await.unwrap(), 1, "the one a closed app left launching");
        assert_eq!(settle_stale_launches(&db).await.unwrap(), 0);
        assert_eq!(last_runs(&db).await.unwrap()[0].1, "error");
        assert_eq!(last_runs(&db).await.unwrap()[0].1, "error");
    }

    #[tokio::test]
    async fn a_released_claim_can_be_taken_again() {
        let directory = tempfile::tempdir().unwrap();
        let db = Database::open(directory.path()).unwrap();
        assert!(claim(&db, "github.approve", "a/b#1@s").await.unwrap());
        assert!(!claim(&db, "github.approve", "a/b#1@s").await.unwrap());
        release(&db, "github.approve", "a/b#1@s").await.unwrap();
        assert!(claim(&db, "github.approve", "a/b#1@s").await.unwrap());
    }
}
