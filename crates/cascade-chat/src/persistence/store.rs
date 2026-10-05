//! `chat.db`, the chat threads as they are shown. Synara keeps an event store and projects it;
//! here the projection itself is what is kept (see SYNARA.md). A thread is a row for its own
//! fields and one row per message, activity, proposed plan and checkpoint, each the JSON Synara
//! would send, so a field Synara adds needs no migration. The engine saves a thread by handing
//! the store the thread before and after an event: only the rows that changed are written.
//!
//! The connection lives on a thread of its own, as the backend's stores do; work reaches it as a
//! closure and the answer comes back over a oneshot.

use std::{
    path::Path,
    sync::mpsc,
};

use anyhow::{Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{de::DeserializeOwned, Serialize};
use serde_json::Value;

use crate::contracts::{
    base::ThreadId,
    orchestration::{OrchestrationThread, OrchestrationThreadShell},
};

const SCHEMA: &str = include_str!("schema.sql");

type Job = Box<dyn FnOnce(&mut Connection) + Send>;

pub struct ChatStore {
    jobs: mpsc::Sender<Job>,
}

/// What a session needs to pick its conversation up again after the CLI has gone.
#[derive(Clone, Debug, PartialEq)]
pub struct ProviderSessionRecord {
    pub thread_id: ThreadId,
    pub provider: String,
    pub resume_cursor: Option<Value>,
}

impl ChatStore {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let connection = Connection::open(path).with_context(|| format!("open {}", path.display()))?;
        Self::start(connection)
    }

    pub fn open_in_memory() -> Result<Self> {
        Self::start(Connection::open_in_memory()?)
    }

    fn start(connection: Connection) -> Result<Self> {
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        connection.execute_batch(SCHEMA)?;
        let (jobs, inbox) = mpsc::channel::<Job>();
        let mut connection = connection;
        std::thread::Builder::new()
            .name("cascade-db-chat".into())
            .spawn(move || {
                for job in inbox {
                    let outcome =
                        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| job(&mut connection)));
                    if outcome.is_err() {
                        tracing::error!("a chat database job panicked; the store keeps serving");
                    }
                }
            })
            .context("start the chat database thread")?;
        Ok(Self { jobs })
    }

    async fn call<T, F>(&self, work: F) -> Result<T>
    where
        T: Send + 'static,
        F: FnOnce(&mut Connection) -> Result<T> + Send + 'static,
    {
        let (reply, answer) = tokio::sync::oneshot::channel();
        self.jobs
            .send(Box::new(move |connection| {
                let _ = reply.send(work(connection));
            }))
            .map_err(|_| anyhow::anyhow!("the chat database thread is gone"))?;
        answer.await.map_err(|_| anyhow::anyhow!("the chat database job was dropped"))?
    }

    /// Threads not deleted, newest first, without their messages and activities. `project` is a
    /// Cascade project id, or [`crate::STANDALONE_PROJECT_ID`] for chats that belong to no project; `None` lists
    /// every thread.
    pub async fn list_shells(&self, project: Option<String>) -> Result<Vec<OrchestrationThreadShell>> {
        self.call(move |connection| {
            let mut statement = connection.prepare(
                "SELECT id, json FROM threads WHERE deleted = 0 AND (?1 IS NULL OR project_id = ?1)
                 ORDER BY updated_at DESC",
            )?;
            let rows = statement
                .query_map(params![project], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?;
            let mut shells = Vec::new();
            for row in rows {
                let (id, json) = row?;
                // A shell is the thread row read as the lighter type, without its children. A row
                // this build cannot read is left out rather than failing the whole list.
                let shell = serde_json::from_str::<Value>(&json).and_then(|mut value| {
                    strip_to_shell(&mut value);
                    serde_json::from_value::<OrchestrationThreadShell>(value)
                });
                match shell {
                    Ok(shell) => shells.push(shell),
                    Err(error) => tracing::warn!(thread = %id, "chat: a thread row could not be read and is skipped: {error}"),
                }
            }
            Ok(shells)
        })
        .await
    }

    /// The whole thread, or `None` for one never made or deleted.
    pub async fn load_thread(&self, id: ThreadId) -> Result<Option<OrchestrationThread>> {
        self.call(move |connection| load_thread(connection, id.as_str())).await
    }

    /// Writes the rows that differ between `before` (the thread as last saved, `None` for a new
    /// one) and `after`. A thread whose `deletedAt` is set is kept as a row but its children go.
    pub async fn save_thread(
        &self,
        mut before: Option<OrchestrationThread>,
        mut after: OrchestrationThread,
    ) -> Result<()> {
        self.call(move |connection| {
            let tx = connection.transaction()?;
            save_thread(&tx, before.as_mut(), &mut after)?;
            tx.commit()?;
            Ok(())
        })
        .await
    }

    /// [`Self::save_thread`] and the thread's last event `sequence`, in one transaction.
    pub async fn save_thread_at(
        &self,
        mut before: Option<OrchestrationThread>,
        mut after: OrchestrationThread,
        sequence: u64,
    ) -> Result<()> {
        self.call(move |connection| {
            let tx = connection.transaction()?;
            save_thread(&tx, before.as_mut(), &mut after)?;
            tx.execute(
                "INSERT INTO thread_sequences (thread_id, sequence) VALUES (?1, ?2)
                 ON CONFLICT(thread_id) DO UPDATE SET sequence = ?2",
                params![after.id.as_str(), sequence as i64],
            )?;
            tx.commit()?;
            Ok(())
        })
        .await
    }

    /// The last event `sequence` saved for a thread, 0 for one never saved with one.
    pub async fn thread_sequence(&self, thread: ThreadId) -> Result<u64> {
        self.call(move |connection| {
            Ok(connection
                .query_row("SELECT sequence FROM thread_sequences WHERE thread_id = ?1", [thread.as_str()], |row| {
                    row.get::<_, i64>(0)
                })
                .optional()?
                .unwrap_or(0) as u64)
        })
        .await
    }

    pub async fn provider_session(&self, thread: ThreadId) -> Result<Option<ProviderSessionRecord>> {
        self.call(move |connection| {
            connection
                .query_row(
                    "SELECT provider, resume_cursor FROM provider_sessions WHERE thread_id = ?1",
                    [thread.as_str()],
                    |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
                )
                .optional()?
                .map(|(provider, cursor)| {
                    Ok(ProviderSessionRecord {
                        thread_id: thread.clone(),
                        provider,
                        resume_cursor: cursor.map(|text| serde_json::from_str(&text)).transpose()?,
                    })
                })
                .transpose()
        })
        .await
    }

    pub async fn set_provider_session(&self, record: ProviderSessionRecord) -> Result<()> {
        self.call(move |connection| {
            let cursor = record.resume_cursor.as_ref().map(serde_json::to_string).transpose()?;
            connection.execute(
                "INSERT INTO provider_sessions (thread_id, provider, resume_cursor, updated_at)
                 VALUES (?1, ?2, ?3, datetime('now'))
                 ON CONFLICT(thread_id) DO UPDATE SET provider = ?2, resume_cursor = ?3,
                   updated_at = datetime('now')",
                params![record.thread_id.as_str(), record.provider, cursor],
            )?;
            Ok(())
        })
        .await
    }

    pub async fn clear_provider_session(&self, thread: ThreadId) -> Result<()> {
        self.call(move |connection| {
            connection.execute("DELETE FROM provider_sessions WHERE thread_id = ?1", [thread.as_str()])?;
            Ok(())
        })
        .await
    }
}

/// The child collections a thread row leaves out, and the table each is kept in.
const CHILDREN: [(&str, &str); 4] = [
    ("messages", "messages"),
    ("activities", "activities"),
    ("proposedPlans", "proposed_plans"),
    ("checkpoints", "checkpoints"),
];

fn strip_to_shell(value: &mut Value) {
    if let Some(object) = value.as_object_mut() {
        for (field, _) in CHILDREN {
            object.remove(field);
        }
    }
}

fn load_thread(connection: &Connection, id: &str) -> Result<Option<OrchestrationThread>> {
    let Some(json) = connection
        .query_row("SELECT json FROM threads WHERE id = ?1 AND deleted = 0", [id], |row| {
            row.get::<_, String>(0)
        })
        .optional()?
    else {
        return Ok(None);
    };
    let mut value: Value = serde_json::from_str(&json)?;
    let object = value.as_object_mut().context("a thread row is not an object")?;
    for (field, table) in CHILDREN {
        let mut statement =
            connection.prepare(&format!("SELECT json FROM {table} WHERE thread_id = ?1 ORDER BY ordinal"))?;
        let rows = statement
            .query_map([id], |row| row.get::<_, String>(0))?
            .map(|json| Ok(serde_json::from_str::<Value>(&json?)?))
            .collect::<Result<Vec<_>>>()?;
        object.insert(field.into(), Value::Array(rows));
    }
    Ok(Some(serde_json::from_value(value)?))
}

fn save_thread(
    tx: &rusqlite::Transaction<'_>,
    mut before: Option<&mut OrchestrationThread>,
    after: &mut OrchestrationThread,
) -> Result<()> {
    let row = shell_row(after)?;
    let before_row = before.as_deref_mut().map(shell_row).transpose()?;
    let (before, after) = (before.as_deref(), &*after);
    let id = after.id.as_str();
    let deleted = after.deleted_at.is_some();
    if before_row.as_ref() != Some(&row) {
        tx.execute(
            "INSERT INTO threads (id, project_id, deleted, updated_at, json) VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(id) DO UPDATE SET project_id = ?2, deleted = ?3, updated_at = ?4, json = ?5",
            params![id, after.project_id.as_str(), deleted, after.updated_at.as_str(), row.to_string()],
        )?;
    }
    if deleted {
        for (_, table) in CHILDREN {
            tx.execute(&format!("DELETE FROM {table} WHERE thread_id = ?1"), [id])?;
        }
        tx.execute("DELETE FROM provider_sessions WHERE thread_id = ?1", [id])?;
        return Ok(());
    }
    save_children(tx, id, "messages", before.map(|t| &t.messages[..]), &after.messages, |m| m.id.as_str())?;
    save_children(tx, id, "activities", before.map(|t| &t.activities[..]), &after.activities, |a| {
        a.id.as_str()
    })?;
    save_children(
        tx,
        id,
        "proposed_plans",
        before.map(|t| &t.proposed_plans[..]),
        &after.proposed_plans,
        |p| p.id.as_str(),
    )?;
    save_children(tx, id, "checkpoints", before.map(|t| &t.checkpoints[..]), &after.checkpoints, |c| {
        c.turn_id.as_str()
    })?;
    Ok(())
}

/// The thread row: the thread's own fields. The children are set aside while it is serialized,
/// so comparing two rows does not serialize every message and activity.
fn shell_row(thread: &mut OrchestrationThread) -> Result<Value> {
    let messages = std::mem::take(&mut thread.messages);
    let activities = std::mem::take(&mut thread.activities);
    let proposed_plans = std::mem::take(&mut thread.proposed_plans);
    let checkpoints = std::mem::take(&mut thread.checkpoints);
    let value = serde_json::to_value(&*thread);
    thread.messages = messages;
    thread.activities = activities;
    thread.proposed_plans = proposed_plans;
    thread.checkpoints = checkpoints;
    let mut value = value?;
    strip_to_shell(&mut value);
    Ok(value)
}

/// Writes the children of one kind that are new or changed, and deletes the ones that are gone.
/// A row keeps its `ordinal` for as long as it stays in order: a new one takes a key between its
/// neighbours' (after the last, for an append), so dropping the oldest activity at the cap or
/// adding one rewrites one row, not every row after it. Only when the order itself changed and no
/// key fits are the rows numbered again.
fn save_children<T, F>(
    tx: &rusqlite::Transaction<'_>,
    thread: &str,
    table: &str,
    before: Option<&[T]>,
    after: &[T],
    key: F,
) -> Result<()>
where
    T: Serialize + DeserializeOwned + PartialEq,
    F: Fn(&T) -> &str,
{
    let before = before.unwrap_or(&[]);
    if before.len() == after.len() && before.iter().zip(after).all(|(old, new)| key(old) == key(new) && old == new) {
        return Ok(());
    }
    let previous: std::collections::HashMap<&str, &T> = before.iter().map(|item| (key(item), item)).collect();
    let stored: std::collections::HashMap<String, i64> = tx
        .prepare_cached(&format!("SELECT id, ordinal FROM {table} WHERE thread_id = ?1"))?
        .query_map([thread], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    let existing: Vec<Option<i64>> = after.iter().map(|item| stored.get(key(item)).copied()).collect();
    let ordinals = assign_ordinals(&existing).unwrap_or_else(|| renumber_ordinals(after.len()));
    let mut upsert = tx.prepare_cached(&format!(
        "INSERT INTO {table} (thread_id, id, ordinal, json) VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(thread_id, id) DO UPDATE SET ordinal = ?3, json = ?4"
    ))?;
    let mut kept = std::collections::HashSet::new();
    for ((item, ordinal), stored_ordinal) in after.iter().zip(&ordinals).zip(&existing) {
        let id = key(item);
        kept.insert(id);
        let unchanged = *stored_ordinal == Some(*ordinal) && previous.get(id).is_some_and(|old| *old == item);
        if !unchanged {
            upsert.execute(params![thread, id, ordinal, serde_json::to_string(item)?])?;
        }
    }
    let mut remove = tx.prepare_cached(&format!("DELETE FROM {table} WHERE thread_id = ?1 AND id = ?2"))?;
    for id in stored.keys() {
        if !kept.contains(id.as_str()) {
            remove.execute(params![thread, id])?;
        }
    }
    Ok(())
}

/// The space left between two children's ordinals when they are numbered, for later inserts.
const ORDINAL_STEP: i64 = 1 << 16;

/// Ordinals for children in their new order, keeping each stored one (`Some`) and giving each new
/// one (`None`) a key between its neighbours'. `None` when a stored one is out of order or no key
/// fits: the children must then be numbered again.
fn assign_ordinals(existing: &[Option<i64>]) -> Option<Vec<i64>> {
    let mut ordinals = Vec::with_capacity(existing.len());
    let mut previous: Option<i64> = None;
    let mut index = 0;
    while index < existing.len() {
        if let Some(ordinal) = existing[index] {
            if previous.is_some_and(|previous| ordinal <= previous) {
                return None;
            }
            ordinals.push(ordinal);
            previous = Some(ordinal);
            index += 1;
            continue;
        }
        let run_end = existing[index..].iter().position(Option::is_some).map_or(existing.len(), |at| index + at);
        let run = (run_end - index) as i64;
        let next = existing.get(run_end).copied().flatten();
        for step in 1..=run {
            let ordinal = match (previous, next) {
                (Some(low), Some(high)) => {
                    let gap = high.checked_sub(low)?;
                    if gap <= run {
                        return None;
                    }
                    low.checked_add(gap / (run + 1) * step)?
                }
                (Some(low), None) => low.checked_add(ORDINAL_STEP.checked_mul(step)?)?,
                (None, Some(high)) => high.checked_sub(ORDINAL_STEP.checked_mul(run + 1 - step)?)?,
                (None, None) => ORDINAL_STEP.checked_mul(step)?,
            };
            ordinals.push(ordinal);
        }
        previous = ordinals.last().copied();
        index = run_end;
    }
    Some(ordinals)
}

fn renumber_ordinals(count: usize) -> Vec<i64> {
    (1..=count as i64).map(|n| n * ORDINAL_STEP).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        contracts::{
            base::{now_iso, EventId, IsoDateTime},
            orchestration::{OrchestrationCommand, OrchestrationThreadActivity, OrchestrationThreadActivityTone},
        },
        orchestration::{decider::decide, projector::project},
    };

    fn thread() -> OrchestrationThread {
        let command: OrchestrationCommand = OrchestrationCommand::Client(
            serde_json::from_value(serde_json::json!({
                "type": "thread.create", "commandId": "create", "threadId": "thread-1", "projectId": "",
                "title": "New thread", "modelSelection": { "provider": "claudeAgent", "model": "haiku" },
                "runtimeMode": "full-access", "branch": null, "worktreePath": "/tmp", "createdAt": "2026-10-05T10:00:00.000Z",
            }))
            .unwrap(),
        );
        let mut thread = None;
        for event in decide(&command, None, &now_iso()).unwrap() {
            thread = project(thread, &event);
        }
        thread.unwrap()
    }

    fn activity(n: usize) -> OrchestrationThreadActivity {
        OrchestrationThreadActivity {
            id: EventId::new(format!("activity-{n:04}")),
            tone: OrchestrationThreadActivityTone::Info,
            kind: "test".into(),
            summary: format!("activity {n}"),
            payload: serde_json::json!({}),
            turn_id: None,
            sequence: None,
            created_at: IsoDateTime::new(format!("2026-10-05T10:00:00.{n:03}Z")),
        }
    }

    fn connection() -> Connection {
        let connection = Connection::open_in_memory().unwrap();
        connection.execute_batch(SCHEMA).unwrap();
        connection
    }

    /// Saves `after` over `before` and returns how many rows it wrote.
    fn save(connection: &mut Connection, before: Option<&OrchestrationThread>, after: &OrchestrationThread) -> u64 {
        let written = connection.total_changes();
        let tx = connection.transaction().unwrap();
        save_thread(&tx, before.cloned().as_mut(), &mut after.clone()).unwrap();
        tx.commit().unwrap();
        connection.total_changes() - written
    }

    #[test]
    fn a_capped_insert_writes_one_row_not_every_row() {
        let mut connection = connection();
        let mut before = thread();
        before.activities = (0..500).map(activity).collect();
        save(&mut connection, None, &before);

        // What the projector does at the cap: the oldest goes, the newest is appended.
        let mut after = before.clone();
        after.activities.remove(0);
        after.activities.push(activity(500));
        assert_eq!(save(&mut connection, Some(&before), &after), 2, "one delete and one insert");
        assert_eq!(load_thread(&connection, "thread-1").unwrap().unwrap().activities, after.activities);

        // Inserted between two others, as a late activity sorts in: still one row.
        let mut middle = after.clone();
        let mut late = activity(250);
        late.id = EventId::new("activity-0250-late");
        middle.activities.insert(250, late);
        assert_eq!(save(&mut connection, Some(&after), &middle), 1);
        assert_eq!(load_thread(&connection, "thread-1").unwrap().unwrap().activities, middle.activities);

        // A real reorder is still kept.
        let mut reordered = middle.clone();
        reordered.activities.swap(0, 400);
        save(&mut connection, Some(&middle), &reordered);
        assert_eq!(load_thread(&connection, "thread-1").unwrap().unwrap().activities, reordered.activities);

        // Nothing changed, nothing written.
        assert_eq!(save(&mut connection, Some(&reordered), &reordered), 0);
    }

    #[test]
    fn ordinals_keep_stored_keys_and_fit_new_ones_between() {
        assert_eq!(assign_ordinals(&[Some(5), None, Some(9)]), Some(vec![5, 7, 9]));
        assert_eq!(assign_ordinals(&[Some(5), None, None]), Some(vec![5, 5 + ORDINAL_STEP, 5 + 2 * ORDINAL_STEP]));
        assert_eq!(assign_ordinals(&[None, Some(0)]), Some(vec![-ORDINAL_STEP, 0]));
        assert_eq!(assign_ordinals(&[None, None]), Some(vec![ORDINAL_STEP, 2 * ORDINAL_STEP]));
        assert_eq!(assign_ordinals(&[Some(5), None, Some(6)]), None, "no room");
        assert_eq!(assign_ordinals(&[Some(9), Some(5)]), None, "out of order");
        assert_eq!(assign_ordinals(&[Some(i64::MAX), None]), None, "overflow");
    }
}
