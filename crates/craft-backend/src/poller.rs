use std::{
    collections::{HashMap, HashSet},
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex,
    },
    time::Duration,
};

use anyhow::{anyhow, Result};
use chrono::{Duration as ChronoDuration, Utc};
use serde_json::{json, Value};

use crate::{cli, github, AppState};

pub struct Poller {
    running: AtomicBool,
    in_flight: Mutex<HashSet<String>>,
    pr_states: Mutex<HashMap<String, String>>,
    seeded: Mutex<HashSet<String>>,
    generations: Mutex<HashMap<String, u64>>,
}

impl Poller {
    pub fn new() -> Self {
        Self {
            running: AtomicBool::new(false),
            in_flight: Mutex::new(HashSet::new()),
            pr_states: Mutex::new(HashMap::new()),
            seeded: Mutex::new(HashSet::new()),
            generations: Mutex::new(HashMap::new()),
        }
    }

    pub fn invalidate(&self, id: &str) {
        *self
            .generations
            .lock()
            .unwrap()
            .entry(id.into())
            .or_default() += 1;
    }
    fn generation(&self, id: &str) -> u64 {
        *self.generations.lock().unwrap().get(id).unwrap_or(&0)
    }

    fn pr_sync_key(project: &Value, state: &str, generation: u64) -> String {
        let id = project["id"].as_str().unwrap_or("");
        let repo = project["repo"].as_str().unwrap_or("");
        if state == "open" {
            format!("pr:{id}:{repo}:{generation}")
        } else {
            format!("scope:{id}:{state}:{repo}:{generation}")
        }
    }

    pub fn pr_syncing(&self, project: &Value, state: &str) -> bool {
        let key = Self::pr_sync_key(
            project,
            state,
            self.generation(project["id"].as_str().unwrap_or("")),
        );
        self.in_flight.lock().unwrap().contains(&key)
    }
    fn current(&self, app: &AppState, id: &str, generation: u64) -> bool {
        self.generation(id) == generation && app.db.project(id).ok().flatten().is_some()
    }

    pub fn start(&self, app: AppState) {
        if self.running.swap(true, Ordering::SeqCst) {
            return;
        }
        let pr_app = app.clone();
        tokio::spawn(async move {
            loop {
                pr_app.poller.sync_all(&pr_app).await;
                let seconds = pr_app
                    .db
                    .config_value("poll_interval")
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
                let seconds = app
                    .db
                    .config_value("jira_poll_interval")
                    .ok()
                    .flatten()
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(120)
                    .clamp(30, 86400);
                tokio::time::sleep(Duration::from_secs(seconds)).await;
            }
        });
    }

    pub async fn sync_all(&self, app: &AppState) {
        let Ok(projects) = app.db.projects() else {
            return;
        };
        let mut jobs = Vec::new();
        for project in projects {
            let app = app.clone();
            jobs.push(tokio::spawn(async move {
                let poller = app.poller.clone();
                poller.sync_project(&app, project).await;
            }));
        }
        for job in jobs {
            let _ = job.await;
        }
    }

    pub async fn sync_project(&self, app: &AppState, project: Value) {
        let id = project
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned();
        let repo = project
            .get("repo")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned();
        let generation = self.generation(&id);
        let key = Self::pr_sync_key(&project, "open", generation);
        if !self.enter(&key) {
            return;
        }
        if repo.is_empty() {
            let _ = app
                .db
                .set_pr_snapshot(&id, &json!({"prs":[],"lastSynced":now(),"error":null}));
            self.leave(&key);
            app.broadcast(json!({"type":"sync","scope":"prs","projectId":id}));
            return;
        }
        let jira_key = project
            .get("jiraProjectKey")
            .and_then(Value::as_str)
            .unwrap_or("");
        let previous = app.db.pr_snapshot(&id, "open", None).ok().flatten();
        let since = previous
            .as_ref()
            .and_then(|v| v.get("lastSynced"))
            .and_then(Value::as_str)
            .and_then(|v| chrono::DateTime::parse_from_rfc3339(v).ok())
            .map(|v| (v - ChronoDuration::seconds(60)).to_rfc3339());
        let result = tokio::join!(
            github::fetch_prs(&repo, "open", None, true, jira_key),
            github::fetch_recent_closed(&repo, since.as_deref())
        );
        if !self.current(app, &id, generation) {
            self.leave(&key);
            return;
        }
        match result {
            (Ok(open), Ok(closed)) => {
                let me = github::current_user().await;
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
                if !self.current(app, &id, generation) {
                    self.leave(&key);
                    return;
                }
                self.record_lifecycle(app, &project, &open, &closed);
                let mut lean = Vec::new();
                let mut numbers = Vec::new();
                for mut pr in open {
                    let number = pr.get("number").and_then(Value::as_i64).unwrap_or(0);
                    numbers.push(number);
                    if let Some(timestamp) = timeline.get(&number) {
                        pr.as_object_mut()
                            .unwrap()
                            .insert("requestedAt".into(), json!(timestamp));
                        let _ = app
                            .db
                            .mark_review_requested(&format!("{repo}#{number}"), timestamp);
                    }
                    lean.push(github::lean(&pr, &repo));
                }
                let _ = app.db.prune_review_state(&repo, &numbers);
                let _ = app
                    .db
                    .set_pr_snapshot(&id, &json!({"prs":lean,"lastSynced":now(),"error":null}));
            }
            (Err(error), _) | (_, Err(error)) => {
                let message = error.to_string();
                let prs = previous
                    .as_ref()
                    .and_then(|v| v.get("prs"))
                    .cloned()
                    .unwrap_or_else(|| json!([]));
                if previous
                    .as_ref()
                    .and_then(|v| v.get("error"))
                    .and_then(Value::as_str)
                    != Some(&message)
                {
                    self.event(app, "sync_failed", json!({"repo":repo,"error":message}));
                }
                let _ = app
                    .db
                    .set_pr_snapshot(&id, &json!({"prs":prs,"lastSynced":now(),"error":message}));
            }
        }
        self.leave(&key);
        app.broadcast(json!({"type":"sync","scope":"prs","projectId":id}));
    }

    pub async fn sync_pr_scope(&self, app: &AppState, project: Value, state: &str) {
        let id = project.get("id").and_then(Value::as_str).unwrap_or("");
        let repo = project.get("repo").and_then(Value::as_str).unwrap_or("");
        let generation = self.generation(id);
        let key = Self::pr_sync_key(&project, state, generation);
        if !self.enter(&key) {
            return;
        }
        let previous = app
            .db
            .pr_snapshot(id, state, Some(&crate::db::project_identity(&project)))
            .ok()
            .flatten();
        let jira = project
            .get("jiraProjectKey")
            .and_then(Value::as_str)
            .unwrap_or("");
        let snapshot = match github::fetch_prs(repo, state, Some(30), true, jira).await {
            Ok(prs) => {
                json!({"prs":prs.iter().map(|p|github::lean(p,repo)).collect::<Vec<_>>(),"lastSynced":now(),"error":null})
            }
            Err(error) => {
                json!({"prs":previous.and_then(|v|v.get("prs").cloned()).unwrap_or_else(||json!([])),"lastSynced":now(),"error":error.to_string()})
            }
        };
        if !self.current(app, id, generation) {
            self.leave(&key);
            return;
        }
        let _ = app.db.set_pr_scope_snapshot(&project, state, &snapshot);
        self.leave(&key);
        app.broadcast(json!({"type":"sync","scope":"prs","projectId":id}));
    }

    pub async fn sync_all_jira(&self, app: &AppState) {
        if let Ok(projects) = app.db.projects() {
            for project in projects {
                self.sync_project_jira(app, &project).await;
                self.sync_board(app, &project).await;
            }
        }
    }

    pub async fn sync_project_jira(&self, app: &AppState, project: &Value) {
        let id = project["id"].as_str().unwrap_or("");
        let jql = project_jql(app, project);
        self.write_jira(
            app,
            id,
            &jql,
            jira_limit(app, "jira_limit", 100),
            None,
            self.generation(id),
        )
        .await;
    }

    pub async fn sync_board(&self, app: &AppState, project: &Value) {
        let project_id = project["id"].as_str().unwrap_or("");
        let id = format!("board:{project_id}");
        let jira_key = project["jiraProjectKey"].as_str().unwrap_or("");
        let clause = app
            .db
            .config_value(&format!("board_query_{project_id}"))
            .ok()
            .flatten()
            .unwrap_or_default();
        let generation = self.generation(project_id);
        let flight = format!("board-fetch:{project_id}:{generation}");
        if !self.enter(&flight) {
            return;
        }
        let sprint = match active_sprint(jira_key).await {
            Ok(sprint) => sprint,
            Err(error) => {
                if !self.current(app, project_id, generation) {
                    self.leave(&flight);
                    return;
                }
                let mut snapshot = app
                    .db
                    .jira_snapshot(&id)
                    .ok()
                    .flatten()
                    .unwrap_or_else(|| json!({"items":[],"jql":"","meta":null}));
                snapshot["meta"] = json!({"sprint":snapshot["sprint"],"query":snapshot["query"],"columns":snapshot["columns"]});
                snapshot["error"] = json!(error.to_string());
                snapshot["lastSynced"] = json!(now());
                let _ = app.db.set_jira_snapshot(&id, &snapshot);
                app.broadcast(json!({"type":"jira-sync","id":id}));
                self.leave(&flight);
                return;
            }
        };
        if !self.current(app, project_id, generation) {
            self.leave(&flight);
            return;
        }
        let Some(sprint_id) = sprint.get("id").and_then(Value::as_i64) else {
            let _=app.db.set_jira_snapshot(&id,&json!({"items":[],"jql":"","lastSynced":now(),"error":null,"meta":{"sprint":null,"query":clause,"columns":null}}));
            app.broadcast(json!({"type":"jira-sync","id":id}));
            self.leave(&flight);
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
        self.write_jira(
            app,
            &id,
            &jql,
            jira_limit(app, "board_limit", 200),
            Some(json!({"sprint":sprint,"query":clause,"columns":columns})),
            generation,
        )
        .await;
        self.leave(&flight);
    }

    async fn write_jira(
        &self,
        app: &AppState,
        id: &str,
        jql: &str,
        limit: usize,
        meta: Option<Value>,
        generation: u64,
    ) {
        let project_id = id.strip_prefix("board:").unwrap_or(id);
        if !self.current(app, project_id, generation) {
            return;
        }
        let key = format!("jira:{id}:{generation}");
        if !self.enter(&key) {
            return;
        }
        let previous = app.db.jira_snapshot(id).ok().flatten();
        let snapshot = if jql.is_empty() {
            json!({"items":[],"jql":"","lastSynced":now(),"error":null,"meta":meta})
        } else {
            match search_jira(jql, limit).await {
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
                        self.event(
                            app,
                            "jira_sync_failed",
                            json!({"id":id,"jql":jql,"error":message}),
                        );
                    }
                    json!({"items":previous.and_then(|v|v.get("items").cloned()).unwrap_or_else(||json!([])),"jql":jql,"lastSynced":now(),"error":message,"meta":meta})
                }
            }
        };
        if !self.current(app, project_id, generation) {
            self.leave(&key);
            return;
        }
        let _ = app.db.set_jira_snapshot(id, &snapshot);
        app.broadcast(json!({"type":"jira-sync","id":id}));
        self.leave(&key);
    }

    fn record_lifecycle(&self, app: &AppState, project: &Value, open: &[Value], closed: &[Value]) {
        let repo = project["repo"].as_str().unwrap_or("");
        let first = !self.seeded.lock().unwrap().contains(repo);
        let mut merged = Vec::new();
        {
            let mut states = self.pr_states.lock().unwrap();
            for pr in open.iter().chain(closed) {
                let number = pr["number"].as_i64().unwrap_or(0);
                let key = format!("{}#{number}", repo.to_ascii_lowercase());
                let state = pr["state"].as_str().unwrap_or("");
                let previous = states.get(&key).map(String::as_str);
                // A webhook may have already recorded this merge during the poll.
                if previous == Some("MERGED") {
                    continue;
                }
                if !first && state == "MERGED" {
                    states.insert(key, state.into());
                    merged.push(pr.clone());
                    continue;
                }
                if !first {
                    let kind = if state == "OPEN" && previous.is_none() {
                        Some("pr_opened")
                    } else if state == "CLOSED" && previous != Some("CLOSED") {
                        Some("pr_closed")
                    } else {
                        None
                    };
                    if let Some(kind) = kind {
                        self.event(app, kind, json!({"repo":repo,"pr":{"number":number,"title":pr["title"],"url":pr["url"]}}));
                    }
                }
                states.insert(key, state.into());
            }
        }
        self.seeded.lock().unwrap().insert(repo.into());
        for pr in merged {
            self.dispatch_merge(app, project, &pr);
        }
    }

    pub fn handle_merge(&self, app: &AppState, project: &Value, pr: &Value) {
        let Some(number) = pr["number"].as_i64().filter(|n| *n > 0) else {
            return;
        };
        let repo = project["repo"].as_str().unwrap_or("").to_ascii_lowercase();
        let key = format!("{repo}#{number}");
        if self
            .pr_states
            .lock()
            .unwrap()
            .insert(key, "MERGED".into())
            .as_deref()
            == Some("MERGED")
        {
            return;
        }
        self.dispatch_merge(app, project, pr);
    }

    fn dispatch_merge(&self, app: &AppState, project: &Value, pr: &Value) {
        self.event(app, "pr_merged", json!({"repo":project["repo"],"pr":{"number":pr["number"],"title":pr["title"],"url":pr["url"]}}));
        let (app, project, pr) = (app.clone(), project.clone(), pr.clone());
        tokio::spawn(async move {
            crate::jira::apply_merge(&app, &project, &pr).await;
        });
    }
    fn event(&self, app: &AppState, kind: &str, payload: Value) {
        if let Ok(event) = app.db.add_event(kind, &payload) {
            app.broadcast(json!({"type":"activity","event":event}));
        }
    }
    fn enter(&self, key: &str) -> bool {
        self.in_flight.lock().unwrap().insert(key.into())
    }
    fn leave(&self, key: &str) {
        self.in_flight.lock().unwrap().remove(key);
    }
}

pub fn project_jql(app: &AppState, project: &Value) -> String {
    let id = project["id"].as_str().unwrap_or("");
    let clause = app
        .db
        .config_value(&format!("board_query_{id}"))
        .ok()
        .flatten()
        .unwrap_or_default();
    let base = project["jql"]
        .as_str()
        .filter(|v| !v.is_empty())
        .map(str::to_owned)
        .or_else(|| {
            project["jiraProjectKey"]
                .as_str()
                .filter(|v| !v.is_empty())
                .map(|v| format!("project = {v} AND statusCategory != Done ORDER BY updated DESC"))
        })
        .unwrap_or_default();
    with_clause(&base, &clause)
}
fn with_clause(base: &str, clause: &str) -> String {
    if base.is_empty() || clause.is_empty() {
        return base.into();
    }
    let lower = base.to_ascii_lowercase();
    if let Some(index) = lower.find("order by") {
        format!(
            "({}) AND ({}) {}",
            base[..index].trim(),
            clause.trim(),
            base[index..].trim()
        )
    } else {
        format!("({base}) AND ({})", clause.trim())
    }
}
fn jira_limit(app: &AppState, key: &str, default: usize) -> usize {
    app.db
        .config_value(key)
        .ok()
        .flatten()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
        .max(1)
}
pub async fn search_jira(jql: &str, limit: usize) -> Result<Vec<Value>> {
    let raw = cli::run(
        "acli",
        [
            "jira",
            "workitem",
            "search",
            "--jql",
            jql,
            "--limit",
            &limit.to_string(),
            "--fields",
            "key,summary,status,issuetype,priority,assignee,labels,reporter",
            "--json",
        ],
        Duration::from_secs(30),
    )
    .await?;
    let items: Value = serde_json::from_str(&raw)?;
    let array = items
        .as_array()
        .ok_or_else(|| anyhow!("unexpected acli search response"))?;
    Ok(array.iter().map(|item|{let fields=&item["fields"];json!({"key":item["key"],"summary":fields["summary"].as_str().unwrap_or(""),"status":fields.pointer("/status/name").and_then(Value::as_str).unwrap_or(""),"statusCategory":fields.pointer("/status/statusCategory/key").and_then(Value::as_str).unwrap_or(""),"statusId":fields.pointer("/status/id").and_then(Value::as_str).unwrap_or(""),"type":fields.pointer("/issuetype/name").and_then(Value::as_str).unwrap_or(""),"priority":fields.pointer("/priority/name").and_then(Value::as_str).unwrap_or(""),"assignee":fields.pointer("/assignee/displayName").or_else(||fields.pointer("/assignee/emailAddress")).and_then(Value::as_str).unwrap_or(""),"assigneeId":fields.pointer("/assignee/accountId").and_then(Value::as_str).unwrap_or(""),"assigneeEmail":fields.pointer("/assignee/emailAddress").and_then(Value::as_str).unwrap_or(""),"labels":fields["labels"].as_array().map(|v|v.iter().filter_map(Value::as_str).collect::<Vec<_>>()).unwrap_or_default(),"reporter":fields.pointer("/reporter/displayName").or_else(||fields.pointer("/reporter/emailAddress")).and_then(Value::as_str).unwrap_or("")})}).collect())
}
async fn active_sprint(key: &str) -> Result<Value> {
    if key.is_empty() {
        return Ok(Value::Null);
    }
    let boards: Value = serde_json::from_str(
        &cli::run(
            "acli",
            [
                "jira",
                "board",
                "search",
                "--project",
                key,
                "--json",
                "--limit",
                "50",
            ],
            Duration::from_secs(30),
        )
        .await?,
    )?;
    let board = boards
        .get("values")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .find(|v| v["type"] == "scrum")
        .ok_or_else(|| anyhow!("no scrum board"))?;
    let board_id = board["id"]
        .as_i64()
        .ok_or_else(|| anyhow!("invalid board id"))?;
    let raw = cli::run(
        "acli",
        [
            "jira",
            "board",
            "list-sprints",
            "--id",
            &board_id.to_string(),
            "--state",
            "active",
            "--json",
        ],
        Duration::from_secs(30),
    )
    .await?;
    let value: Value = serde_json::from_str(&raw)?;
    let sprint = value
        .get("sprints")
        .and_then(Value::as_array)
        .and_then(|v| v.first())
        .cloned()
        .unwrap_or(Value::Null);
    if sprint.is_null() {
        Ok(sprint)
    } else {
        Ok(
            json!({"id":sprint["id"],"name":sprint["name"],"endDate":sprint.get("endDate").cloned().unwrap_or(Value::Null),"boardId":board_id}),
        )
    }
}
pub async fn transition(key: &str, status: &str) -> Result<()> {
    let raw = cli::run(
        "acli",
        [
            "jira",
            "workitem",
            "transition",
            "--key",
            key,
            "--status",
            status,
            "--yes",
            "--json",
        ],
        Duration::from_secs(30),
    )
    .await?;
    validate_acli_mutation(&raw, &format!("Could not move {key} to {status:?}"))
}
pub async fn assign(key: &str, assignee: &str) -> Result<()> {
    let mut args = vec![
        "jira", "workitem", "assign", "--key", key, "--yes", "--json",
    ];
    if assignee.is_empty() {
        args.push("--remove-assignee")
    } else {
        args.extend(["--assignee", assignee])
    }
    let raw = cli::run("acli", args, Duration::from_secs(30)).await?;
    validate_acli_mutation(&raw, &format!("Could not assign {key}"))
}
fn validate_acli_mutation(raw: &str, fallback: &str) -> Result<()> {
    let Ok(value) = serde_json::from_str::<Value>(raw) else {
        return Ok(());
    };
    let failed = value
        .get("results")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .find(|v| v["status"] != "SUCCESS");
    if value["successCount"].as_i64() == Some(0) || failed.is_some() {
        Err(anyhow!(failed
            .and_then(|v| v["message"].as_str())
            .unwrap_or(fallback)
            .to_owned()))
    } else {
        Ok(())
    }
}
fn now() -> String {
    Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}
