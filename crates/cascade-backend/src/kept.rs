//! Answers the backend keeps: a search My Tickets shows, answered from what was stored the last
//! time and searched again behind the answer, so a screen opens on what it showed before rather
//! than on a spinner. A kept answer lives in the cache store beside the board snapshots, under
//! an id that names the whole question; a question never asked before waits for its answer once.
//!
//! The rules are the pull request snapshots' (`Read`): only a read made for someone looking
//! searches again, paced from when the last search of that question started; a read the app
//! makes because the backend said the answer changed is its echo, and starts nothing; and a
//! refresh someone asked for searches now and waits. A search behind a look that could not
//! reach its service leaves the answer as it was; one the service refused is kept as the
//! answer's error, since it stays wrong until someone changes something.

use std::{
    collections::{HashMap, HashSet},
    future::Future,
    sync::Mutex,
    time::{Duration, Instant},
};

use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::{json, Map, Value};

use crate::{cli, AppState, Fault};

/// Why a kept answer is read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Read {
    /// The backend said the answer changed, and the app reads it: what is stored, nothing more.
    Echo,
    /// Someone is looking: what is stored, and a search behind it when one is due.
    Look,
    /// Someone asked for a refresh: a search now, waited for.
    Now,
}

/// Which questions are being asked again right now, and when each was last asked. A value on
/// `AppState` behind a short lock, never held across an await.
#[derive(Default)]
pub struct Kept {
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    running: HashSet<String>,
    started: HashMap<String, Instant>,
}

impl Kept {
    /// Whether `id` is due another search, claiming it if so, with the instant the claim was
    /// made: not while one runs, and not within `pace` of the last one's start. `age` is the
    /// stored answer's own, which stands in when no search of it is remembered, as after a
    /// restart.
    fn claim(&self, id: &str, age: Option<Duration>, pace: Duration) -> Option<Instant> {
        let mut state = self.state.lock().unwrap();
        if state.running.contains(id) {
            return None;
        }
        let now = Instant::now();
        let since = state.started.get(id).map(|at| now.duration_since(*at)).or(age);
        if since.is_some_and(|since| since < pace) {
            return None;
        }
        state.running.insert(id.to_owned());
        state.started.insert(id.to_owned(), now);
        Some(now)
    }

    fn asked(&self, id: &str) {
        self.state.lock().unwrap().started.insert(id.to_owned(), Instant::now());
    }

    /// Whether the search claimed at `claimed` is still the last one asked of `id`. A refresh
    /// someone asked for meanwhile is a later one, and its answer is the newer.
    fn latest(&self, id: &str, claimed: Instant) -> bool {
        self.state.lock().unwrap().started.get(id) == Some(&claimed)
    }
}

/// A search behind a look, for as long as it runs: dropped, however the search ends, it is no
/// longer running, and the next look may claim the question again.
struct Running {
    kept: std::sync::Arc<Kept>,
    id: String,
}

impl Drop for Running {
    fn drop(&mut self) {
        self.kept.state.lock().unwrap().running.remove(&self.id);
    }
}

/// The answer to the question `id` names. Stored: that, at once; and for a look, when a search
/// is due (`pace`), `search` runs behind it, the new answer is stored, and the app hears a
/// `sync` of scope `tickets` if it differs. Never asked, or asked for now: `search`, waited for,
/// and its failure is the caller's. `fault` reads whose a failed search behind a look is.
pub async fn answer<F, Fut>(
    app: &AppState,
    id: String,
    read: Read,
    pace: Duration,
    fault: fn(&anyhow::Error) -> Fault,
    search: F,
) -> anyhow::Result<Value>
where
    F: FnOnce() -> Fut + Send + 'static,
    Fut: Future<Output = anyhow::Result<Value>> + Send + 'static,
{
    let stored = app.db.jira_snapshot(&id).await?;
    let (Some(stored), false) = (stored, read == Read::Now) else {
        app.kept.asked(&id);
        let fresh = search().await?;
        let _ = app.db.set_jira_snapshot(&id, &for_store(&fresh)).await;
        return Ok(fresh);
    };
    let claimed = (read == Read::Look).then(|| app.kept.claim(&id, age(&stored), pace)).flatten();
    if let Some(claimed) = claimed {
        let app = app.clone();
        let before = stored.clone();
        let runner = cli::inherited();
        let running = Running { kept: app.kept.clone(), id: id.clone() };
        tokio::spawn(async move {
            let again = async {
                let result = search().await;
                drop(running);
                // A refresh someone asked for while this ran searched later, and stored its
                // answer: this one is the older, and is not written over it.
                if !app.kept.latest(&id, claimed) {
                    return;
                }
                let next = match result {
                    Ok(fresh) => fresh,
                    // The service could not be reached: what is stored stands as it is.
                    Err(error) if fault(&error) == Fault::Transient => return,
                    Err(error) => {
                        let mut refused = before.clone();
                        refused["error"] = json!(error.to_string());
                        refused["lastSynced"] = json!(now());
                        refused
                    }
                };
                let changed = differs(&before, &next);
                let _ = app.db.set_jira_snapshot(&id, &for_store(&next)).await;
                if changed {
                    app.publish(crate::Event::Sync { scope: Some("tickets"), project_id: None });
                }
            };
            match runner {
                Some(runner) => cli::scoped(runner, again).await,
                None => again.await,
            }
        });
    }
    Ok(stored)
}

/// How old a stored answer is; none when it has no stamp, or one from the future.
fn age(stored: &Value) -> Option<Duration> {
    let stamp = DateTime::parse_from_rfc3339(stored.get("lastSynced")?.as_str()?).ok()?;
    Utc::now().signed_duration_since(stamp.with_timezone(&Utc)).to_std().ok()
}

/// Whether two answers differ in anything but when they were given.
fn differs(before: &Value, after: &Value) -> bool {
    let without_stamp = |value: &Value| {
        let mut value = value.clone();
        if let Some(object) = value.as_object_mut() {
            object.remove("lastSynced");
        }
        value
    };
    without_stamp(before) != without_stamp(after)
}

/// An answer as the snapshot store takes it: its list, question, stamp and error in their
/// columns, and whatever else it says (`warning`) under `meta`, which a read lays back beside
/// them.
fn for_store(answer: &Value) -> Value {
    let mut meta = Map::new();
    for (key, value) in answer.as_object().into_iter().flatten() {
        if !["items", "jql", "lastSynced", "error", "meta"].contains(&key.as_str()) {
            meta.insert(key.clone(), value.clone());
        }
    }
    json!({
        "items": answer.get("items").cloned().unwrap_or_else(|| json!([])),
        "jql": answer.get("jql").cloned().unwrap_or_else(|| json!("")),
        "lastSynced": answer.get("lastSynced").cloned().unwrap_or_else(|| json!(now())),
        "error": answer.get("error").cloned().unwrap_or(Value::Null),
        "meta": meta,
    })
}

fn now() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };

    /// A search that counts its runs and answers with whatever the test has set.
    #[derive(Clone)]
    struct Search {
        runs: Arc<AtomicUsize>,
        next: Arc<Mutex<Result<Value, String>>>,
    }

    impl Search {
        fn new(items: Value) -> Self {
            let search = Self { runs: Arc::default(), next: Arc::new(Mutex::new(Ok(json!(null)))) };
            search.finds(items);
            search
        }
        fn finds(&self, items: Value) {
            *self.next.lock().unwrap() = Ok(json!({"items":items,"jql":"q","lastSynced":now(),"error":null,"warning":null}));
        }
        fn fails(&self, message: &str) {
            *self.next.lock().unwrap() = Err(message.to_owned());
        }
        fn runs(&self) -> usize {
            self.runs.load(Ordering::SeqCst)
        }
        async fn ask(&self, app: &AppState, read: Read, pace: Duration) -> anyhow::Result<Value> {
            let search = self.clone();
            answer(app, "kept:test".into(), read, pace, Fault::read_error, move || async move {
                search.runs.fetch_add(1, Ordering::SeqCst);
                search.next.lock().unwrap().clone().map_err(|message| anyhow::anyhow!(message))
            })
            .await
        }
    }

    impl Fault {
        fn read_error(error: &anyhow::Error) -> Fault {
            Fault::read(&error.to_string())
        }
    }

    async fn told(events: &mut tokio::sync::broadcast::Receiver<Value>) -> Value {
        tokio::time::timeout(Duration::from_secs(5), events.recv()).await.unwrap().unwrap()
    }

    /// The first ask waits for its answer; after that the stored answer is given at once, an
    /// echo and a look inside the pace search nothing, a look past it searches behind the
    /// answer and tells only of a change, and a refresh searches now.
    #[tokio::test]
    async fn a_kept_answer_is_given_at_once_and_searched_again_only_behind_a_look() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let mut events = app.events.subscribe();
        let search = Search::new(json!([{"key":"A-1"}]));
        let (minute, none) = (Duration::from_secs(60), Duration::ZERO);

        let first = search.ask(&app, Read::Echo, minute).await.unwrap();
        assert_eq!((first["items"][0]["key"].as_str(), search.runs()), (Some("A-1"), 1), "never asked: searched now");

        search.finds(json!([{"key":"A-2"}]));
        for read in [Read::Echo, Read::Look] {
            let stored = search.ask(&app, read, minute).await.unwrap();
            assert_eq!(stored["items"][0]["key"], "A-1");
        }
        // An echo never searches, however old the answer is.
        search.ask(&app, Read::Echo, none).await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(search.runs(), 1);
        assert!(events.try_recv().is_err());

        // A look past the pace: the stored answer at once, the new one behind it, and word of it.
        let stored = search.ask(&app, Read::Look, none).await.unwrap();
        assert_eq!(stored["items"][0]["key"], "A-1");
        assert_eq!(told(&mut events).await, json!({"type":"sync","scope":"tickets"}));
        assert_eq!(search.runs(), 2);
        let echo = search.ask(&app, Read::Echo, none).await.unwrap();
        assert_eq!((echo["items"][0]["key"].as_str(), echo["warning"].is_null()), (Some("A-2"), true));

        // The same answer again is not news.
        search.ask(&app, Read::Look, none).await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(search.runs(), 3);
        assert!(events.try_recv().is_err());

        // A refresh someone asked for searches now, inside the pace or not, and is the answer.
        search.finds(json!([{"key":"A-3"}]));
        let fresh = search.ask(&app, Read::Now, minute).await.unwrap();
        assert_eq!((fresh["items"][0]["key"].as_str(), search.runs()), (Some("A-3"), 4));
        assert!(events.try_recv().is_err());
    }

    /// A refresh someone asks for while a look's search is still running stores the newer
    /// answer, and the look's, finishing later, is not written over it.
    #[tokio::test]
    async fn a_refresh_is_not_overwritten_by_an_older_search_still_running() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let mut events = app.events.subscribe();
        let none = Duration::ZERO;
        let first = Search::new(json!([{"key":"A-1"}]));
        first.ask(&app, Read::Look, none).await.unwrap();

        // The look's search: slow, and what it finds is already old by the time it ends.
        let (release, held) = tokio::sync::oneshot::channel::<()>();
        let slow = async move {
            let _ = held.await;
            Ok(json!({"items":[{"key":"OLD"}],"jql":"q","lastSynced":now(),"error":null,"warning":null}))
        };
        answer(&app, "kept:test".into(), Read::Look, none, Fault::read_error, move || slow).await.unwrap();

        first.finds(json!([{"key":"NEW"}]));
        let fresh = first.ask(&app, Read::Now, none).await.unwrap();
        assert_eq!(fresh["items"][0]["key"], "NEW");
        release.send(()).unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        let stored = first.ask(&app, Read::Echo, none).await.unwrap();
        assert_eq!(stored["items"][0]["key"], "NEW");
        assert!(events.try_recv().is_err(), "the older answer is not news");
        // The question is free again: the next look searches.
        let runs = first.runs();
        first.ask(&app, Read::Look, none).await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(first.runs(), runs + 1);
    }

    /// Behind a look, a service that could not be reached leaves the answer as it was and says
    /// nothing; one that refused is kept as the answer's error, with the rows it had. A refresh
    /// someone asked for hands its failure to them.
    #[tokio::test]
    async fn a_failed_search_behind_a_look_keeps_the_answer() {
        let dir = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(dir.path()).unwrap(), None);
        let mut events = app.events.subscribe();
        let search = Search::new(json!([{"key":"A-1"}]));
        let none = Duration::ZERO;
        search.ask(&app, Read::Look, none).await.unwrap();

        search.fails("acli timed out after 30s");
        search.ask(&app, Read::Look, none).await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        let stored = search.ask(&app, Read::Echo, none).await.unwrap();
        assert_eq!((search.runs(), stored["error"].is_null(), stored["items"][0]["key"].as_str()), (2, true, Some("A-1")));
        assert!(events.try_recv().is_err());

        search.fails("The JQL query is invalid");
        search.ask(&app, Read::Look, none).await.unwrap();
        assert_eq!(told(&mut events).await["scope"], "tickets");
        let refused = search.ask(&app, Read::Echo, none).await.unwrap();
        assert_eq!((refused["error"].as_str(), refused["items"][0]["key"].as_str()), (Some("The JQL query is invalid"), Some("A-1")));

        assert!(search.ask(&app, Read::Now, none).await.is_err());
    }
}
