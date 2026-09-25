//! Turning syncs into events. The poller already fetches every open PR; comparing each against
//! the fingerprint from the previous sync yields "CI turned green", "left draft" and so on.
//! Jira triggers diff each pipeline's own JQL the same way.

use std::collections::HashSet;

use chrono::Utc;
use serde_json::{json, Value};

use super::{armed, filters::ci_state, model::{Event, Mode}, offer, store};
use crate::AppState;

/// The fields a PR trigger reacts to.
pub fn fingerprint(pr: &Value, me: Option<&str>) -> Value {
    let requested = pr["category"].as_str() == Some("review")
        || me.is_some_and(|me| {
            pr["reviewRequests"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|r| r["login"].as_str() == Some(me))
        });
    json!({
        "draft": pr["isDraft"].as_bool().unwrap_or(false),
        "ci": ci_state(pr),
        "review": pr["reviewDecision"].as_str().unwrap_or(""),
        "sha": pr["headRefOid"].as_str().unwrap_or(""),
        "mergeable": pr["mergeable"].as_str().unwrap_or(""),
        "requested": requested,
    })
}

/// The event kinds between two fingerprints (`previous` None: first sighting of an open PR).
pub fn transitions(previous: Option<&Value>, current: &Value) -> Vec<&'static str> {
    let mut kinds = Vec::new();
    let Some(previous) = previous else {
        kinds.push("pr.opened");
        if current["requested"] == true {
            kinds.push("pr.review_requested");
        }
        match current["ci"].as_str() {
            Some("passing") => kinds.push("pr.ci_passed"),
            Some("failing") => kinds.push("pr.ci_failed"),
            _ => {}
        }
        return kinds;
    };
    let changed = |key: &str| previous[key] != current[key];
    if previous["draft"] == true && current["draft"] == false {
        kinds.push("pr.ready_for_review");
    }
    if changed("sha") && !previous["sha"].as_str().unwrap_or("").is_empty() {
        kinds.push("pr.updated");
    }
    if changed("ci") || changed("sha") {
        match current["ci"].as_str() {
            Some("passing") if previous["ci"] != "passing" || changed("sha") => kinds.push("pr.ci_passed"),
            Some("failing") if previous["ci"] != "failing" || changed("sha") => kinds.push("pr.ci_failed"),
            _ => {}
        }
    }
    if changed("review") {
        match current["review"].as_str() {
            Some("APPROVED") => kinds.push("pr.approved"),
            Some("CHANGES_REQUESTED") => kinds.push("pr.changes_requested"),
            _ => {}
        }
    }
    if changed("mergeable") && current["mergeable"] == "CONFLICTING" {
        kinds.push("pr.conflicted");
    }
    if previous["requested"] != true && current["requested"] == true {
        kinds.push("pr.review_requested");
    }
    kinds
}

fn pr_key(repo: &str, number: i64) -> String {
    format!("{}#{number}", repo.to_ascii_lowercase())
}

/// Ledger identity: re-firing needs a new commit (CI, updates) or a new state value.
fn event_key(kind: &str, repo: &str, pr: &Value, fingerprint: &Value) -> String {
    let base = format!("{kind}:{}", pr_key(repo, pr["number"].as_i64().unwrap_or(0)));
    match kind {
        "pr.opened" | "pr.ready_for_review" | "pr.closed" | "pr.merged" => base,
        "pr.review_requested" => format!("{base}@{}", pr["requestedAt"].as_str().unwrap_or_else(|| fingerprint["sha"].as_str().unwrap_or(""))),
        _ => format!("{base}@{}", fingerprint["sha"].as_str().unwrap_or("")),
    }
}

/// Called by the poller after each successful sync of a project, with the enriched open PRs and
/// the recently closed ones.
pub fn observe_prs(app: &AppState, project: &Value, open: &[Value], closed: &[Value], me: Option<&str>) {
    let repo = project["repo"].as_str().unwrap_or("");
    if repo.is_empty() {
        return;
    }
    let seed = format!("seed:{}", repo.to_ascii_lowercase());
    let first = store::pr_state(&app.db, &seed).ok().flatten().is_none();
    // Loaded once per sync, not once per event: a stale check is offered for every open PR.
    let armed = armed(app);
    let emit = |event: Event| offer(app, &armed, event);
    let now = Utc::now();
    let mut keep = vec![seed.clone()];
    for pr in open {
        let number = pr["number"].as_i64().unwrap_or(0);
        if number <= 0 {
            continue;
        }
        let key = pr_key(repo, number);
        keep.push(key.clone());
        let current = fingerprint(pr, me);
        let previous = store::pr_state(&app.db, &key).ok().flatten();
        if !first {
            let pr = github_pr(pr, repo);
            for kind in transitions(previous.as_ref(), &current) {
                let key = event_key(kind, repo, &pr, &current);
                emit(Event { kind: kind.into(), key, at: now, project: project.clone(), pr: Some(pr.clone()), ticket: None });
            }
            // Stale is a state, not a change: offered every sync, the ledger keeps it to once
            // per quiet period and `matches` checks each pipeline's own day count.
            if let Some(updated) = pr["updatedAt"].as_str() {
                let key = format!("pr.stale:{}@{updated}", pr_key(repo, number));
                emit(Event { kind: "pr.stale".into(), key, at: now, project: project.clone(), pr: Some(pr), ticket: None });
            }
        }
        let _ = store::set_pr_state(&app.db, &key, &repo.to_ascii_lowercase(), &current);
    }
    for pr in closed {
        let number = pr["number"].as_i64().unwrap_or(0);
        let key = pr_key(repo, number);
        let was_open = store::pr_state(&app.db, &key).ok().flatten().is_some();
        if !first && was_open && pr["state"] == "CLOSED" {
            let pr = github_pr(pr, repo);
            let key = event_key("pr.closed", repo, &pr, &Value::Null);
            emit(Event { kind: "pr.closed".into(), key, at: now, project: project.clone(), pr: Some(pr), ticket: None });
        }
    }
    let _ = store::set_pr_state(&app.db, &seed, &repo.to_ascii_lowercase(), &json!({}));
    let _ = store::prune_pr_state(&app.db, &repo.to_ascii_lowercase(), &keep);
}

/// A PR value with `repo` set, as every automation step reads it.
fn github_pr(pr: &Value, repo: &str) -> Value {
    let mut pr = pr.clone();
    pr["repo"] = json!(repo);
    pr
}

/// Normalise a merged PR from either source. The poll gives a GraphQL node, the webhook a REST
/// payload; both are filled in from the last open snapshot so filters see labels and branches.
pub fn merged_pr(app: &AppState, project: &Value, pr: &Value) -> Value {
    let repo = project["repo"].as_str().unwrap_or("");
    let number = pr["number"].as_i64().unwrap_or(0);
    let mut out = app
        .db
        .pr_snapshot(project["id"].as_str().unwrap_or(""), "open", None)
        .ok()
        .flatten()
        .and_then(|snapshot| {
            snapshot["prs"]
                .as_array()?
                .iter()
                .find(|p| p["number"].as_i64() == Some(number))
                .cloned()
        })
        .unwrap_or_else(|| json!({}));
    for (key, value) in pr.as_object().into_iter().flatten() {
        if !value.is_null() {
            out[key] = value.clone();
        }
    }
    if out.get("author").is_none_or(Value::is_null) {
        if let Some(login) = pr.pointer("/user/login") {
            out["author"] = json!({"login":login,"is_bot":pr.pointer("/user/type").and_then(Value::as_str) == Some("Bot")});
        }
    }
    for (rest, graph) in [("/base/ref", "baseRefName"), ("/head/ref", "headRefName"), ("/head/sha", "headRefOid")] {
        if let Some(value) = pr.pointer(rest) {
            out[graph] = value.clone();
        }
    }
    if let Some(labels) = pr["labels"].as_array() {
        out["labels"] = json!(labels.iter().map(|l| json!({"name": l["name"].as_str().or_else(|| l.as_str()).unwrap_or("")})).collect::<Vec<_>>());
    }
    out["repo"] = json!(repo);
    out["state"] = json!("MERGED");
    out
}

pub fn merge_event(app: &AppState, project: &Value, pr: &Value) -> Event {
    let pr = merged_pr(app, project, pr);
    let repo = project["repo"].as_str().unwrap_or("");
    let at = pr["mergedAt"]
        .as_str()
        .or_else(|| pr["merged_at"].as_str())
        .and_then(|v| chrono::DateTime::parse_from_rfc3339(v).ok())
        .map(|v| v.with_timezone(&Utc))
        .unwrap_or_else(Utc::now);
    Event {
        kind: "pr.merged".into(),
        key: event_key("pr.merged", repo, &pr, &Value::Null),
        at,
        project: project.clone(),
        pr: Some(pr),
        ticket: None,
    }
}

/// Poll each armed pipeline's JQL and emit ticket events against its own baseline.
pub async fn poll_jira(app: &AppState) {
    let Ok(automations) = store::list(&app.db) else {
        return;
    };
    let projects = app.db.projects().unwrap_or_default();
    for automation in automations {
        if automation.mode == Mode::Off
            || !automation.trigger.types.iter().any(|t| t.starts_with("jira."))
        {
            continue;
        }
        let jql = automation.trigger.params.get("jql").and_then(Value::as_str).unwrap_or("").trim().to_owned();
        if jql.is_empty() {
            continue;
        }
        let Ok(items) = crate::poller::search_jira(&jql, JIRA_LIMIT).await else {
            continue;
        };
        let previous = store::jira_state(&app.db, &automation.id).unwrap_or_default();
        let had_baseline = !previous.is_empty();
        // The seed row records the query it was taken with: a baseline from another JQL is none.
        let seeded = previous.iter().any(|(key, seed)| key == "__seeded__" && *seed == jql);
        let now = Utc::now();
        let mut current = vec![("__seeded__".to_owned(), jql.clone())];
        for item in &items {
            let key = item["key"].as_str().unwrap_or("").to_owned();
            let status = item["status"].as_str().unwrap_or("").to_owned();
            if key.is_empty() {
                continue;
            }
            current.push((key.clone(), status.clone()));
            if !seeded {
                continue;
            }
            let before = previous.iter().find(|(k, _)| *k == key).map(|(_, s)| s.clone());
            let (kind, event_key) = match before {
                None => ("jira.entered", format!("jira.entered:{key}@{}", now.timestamp())),
                Some(old) if old != status => ("jira.status_changed", format!("jira.status_changed:{key}@{status}@{}", now.timestamp())),
                _ => continue,
            };
            let prefix = key.split('-').next().unwrap_or("");
            let project = projects
                .iter()
                .find(|p| p["jiraProjectKey"].as_str().is_some_and(|k| k.eq_ignore_ascii_case(prefix)))
                .cloned()
                .unwrap_or(Value::Null);
            super::fire(app, &automation, Event { kind: kind.into(), key: event_key, at: now, project, pr: None, ticket: Some(item.clone()) });
        }
        // A full page may have left matching tickets out. Keep what it did not return, so a
        // ticket that drops below the page and comes back is not taken for a new one.
        if items.len() >= JIRA_LIMIT {
            let returned: HashSet<String> = current.iter().map(|(k, _)| k.clone()).collect();
            current.extend(previous.into_iter().filter(|(k, _)| !returned.contains(k)));
        }
        // A save that re-seeds (switched on, new query) clears the baseline, and writing this one
        // would undo that. Any other save, a rename say, leaves it: skipping the write then would
        // have the next poll fire again for every ticket this one just fired for.
        let exists = store::get(&app.db, &automation.id).ok().flatten().is_some();
        let reset = had_baseline && store::jira_state(&app.db, &automation.id).is_ok_and(|now| now.is_empty());
        if exists && !reset {
            let _ = store::set_jira_state(&app.db, &automation.id, &current);
        }
    }
}

/// Tickets fetched per pipeline per Jira poll.
const JIRA_LIMIT: usize = 200;

#[cfg(test)]
mod tests {
    use super::*;

    fn print(draft: bool, ci: &str, review: &str, sha: &str, mergeable: &str, requested: bool) -> Value {
        json!({"draft":draft,"ci":ci,"review":review,"sha":sha,"mergeable":mergeable,"requested":requested})
    }

    #[test]
    fn first_sighting_reports_open_and_current_ci() {
        let now = print(false, "passing", "", "a", "MERGEABLE", true);
        assert_eq!(transitions(None, &now), vec!["pr.opened", "pr.review_requested", "pr.ci_passed"]);
    }

    #[test]
    fn changes_between_syncs_become_events() {
        let before = print(true, "pending", "", "a", "MERGEABLE", false);
        assert_eq!(transitions(Some(&before), &print(false, "pending", "", "a", "MERGEABLE", false)), vec!["pr.ready_for_review"]);
        assert_eq!(transitions(Some(&before), &print(true, "passing", "", "a", "MERGEABLE", false)), vec!["pr.ci_passed"]);
        assert_eq!(transitions(Some(&before), &print(true, "pending", "", "b", "MERGEABLE", false)), vec!["pr.updated"]);
        assert_eq!(transitions(Some(&before), &print(true, "pending", "APPROVED", "a", "MERGEABLE", false)), vec!["pr.approved"]);
        assert_eq!(transitions(Some(&before), &print(true, "pending", "", "a", "CONFLICTING", false)), vec!["pr.conflicted"]);
        assert_eq!(transitions(Some(&before), &print(true, "pending", "", "a", "MERGEABLE", true)), vec!["pr.review_requested"]);
        assert!(transitions(Some(&before), &before).is_empty());
    }

    #[test]
    fn a_new_commit_that_is_green_again_fires_ci_passed_again() {
        let before = print(false, "passing", "", "a", "MERGEABLE", false);
        assert_eq!(transitions(Some(&before), &print(false, "passing", "", "b", "MERGEABLE", false)), vec!["pr.updated", "pr.ci_passed"]);
    }

    #[test]
    fn event_keys_include_the_commit_where_it_matters() {
        let pr = json!({"number":7});
        let fp = json!({"sha":"abc"});
        assert_eq!(event_key("pr.opened", "A/B", &pr, &fp), "pr.opened:a/b#7");
        assert_eq!(event_key("pr.ci_passed", "A/B", &pr, &fp), "pr.ci_passed:a/b#7@abc");
    }

    #[test]
    fn a_webhook_payload_is_normalised_to_the_graphql_shape() {
        let directory = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::Database::open(directory.path()).unwrap(), None);
        let project = json!({"id":"p","repo":"a/b"});
        let pr = json!({"number":3,"title":"T","user":{"login":"bot","type":"Bot"},"base":{"ref":"main"},"head":{"ref":"x","sha":"s"},"labels":[{"name":"deps"}]});
        let out = merged_pr(&app, &project, &pr);
        assert_eq!(out["author"]["login"], "bot");
        assert_eq!(out["baseRefName"], "main");
        assert_eq!(out["headRefOid"], "s");
        assert_eq!(out["labels"][0]["name"], "deps");
        assert_eq!(out["repo"], "a/b");
    }
}
