use std::{collections::HashMap, time::Duration};

use anyhow::{anyhow, Context, Result};
use regex::Regex;
use serde_json::{json, Map, Value};

use crate::cli;

const CORE_FIELDS: &str = r#"number title state url headRefName baseRefName mergedAt isDraft createdAt updatedAt reviewDecision body
author{ login ... on User{ name } }
labels(first:20){ nodes{ name color description } }
reviewRequests(first:20){ nodes{ requestedReviewer{ ... on User{ login } } } }
latestReviews(first:20){ nodes{ state author{ login } } }"#;
const CI_FIELDS: &str = r#"commits(last:1){ nodes{ commit{ statusCheckRollup{ contexts(first:100){ nodes{
... on CheckRun{ status conclusion }
... on StatusContext{ state }
} } } } } }"#;

pub async fn current_user() -> Option<String> {
    cli::run(
        "gh",
        ["api", "user", "--jq", ".login"],
        Duration::from_secs(60),
    )
    .await
    .ok()
    .filter(|v| !v.is_empty())
}

pub async fn user_name() -> String {
    if let Ok(name) = cli::run(
        "gh",
        ["api", "user", "--jq", ".name"],
        Duration::from_secs(60),
    )
    .await
    {
        if !name.is_empty() {
            return name;
        }
    }
    if let Ok(name) = cli::run(
        "git",
        ["config", "--get", "user.name"],
        Duration::from_secs(10),
    )
    .await
    {
        if !name.is_empty() {
            return name;
        }
    }
    current_user().await.unwrap_or_default()
}

pub async fn remote_repo(dir: &str) -> Option<String> {
    let out = cli::run(
        "git",
        ["-C", dir, "remote", "get-url", "origin"],
        Duration::from_secs(10),
    )
    .await
    .ok()?;
    parse_repo(&out)
}

pub fn parse_repo(input: &str) -> Option<String> {
    let mut repo = input
        .trim()
        .trim_end_matches('/')
        .trim_end_matches(".git")
        .to_owned();
    if let Some(index) = repo.find("github.com") {
        repo = repo[index + 10..].trim_start_matches([':', '/']).to_owned();
    }
    let parts = repo.split('/').collect::<Vec<_>>();
    if parts.len() != 2
        || parts.iter().any(|part| {
            part.is_empty()
                || !part
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || "_.-".contains(c))
        })
    {
        None
    } else {
        Some(repo)
    }
}

pub async fn lookup_pr(url: &str) -> Option<Value> {
    let regex = Regex::new(r"(?i)^https?://github\.com/([^/]+/[^/]+)/pull/(\d+)").ok()?;
    let captures = regex.captures(url)?;
    let repo = captures.get(1)?.as_str();
    let number = captures.get(2)?.as_str();
    let out = cli::run(
        "gh",
        [
            "pr",
            "view",
            number,
            "--repo",
            repo,
            "--json",
            "number,title,headRefName,url,isCrossRepository",
        ],
        Duration::from_secs(60),
    )
    .await
    .ok()?;
    let value: Value = serde_json::from_str(&out).ok()?;
    Some(json!({
        "repo": repo, "number": value["number"], "title": value["title"].as_str().unwrap_or(""),
        "headRefName": value["headRefName"].as_str().unwrap_or(""), "url": value["url"].as_str().unwrap_or(url),
        "fork": value["isCrossRepository"].as_bool().unwrap_or(false)
    }))
}

pub async fn fetch_prs(
    repo: &str,
    state: &str,
    limit: Option<usize>,
    ci: bool,
    jira_key: &str,
) -> Result<Vec<Value>> {
    let states = match state {
        "merged" => "MERGED",
        "closed" => "CLOSED",
        "all" => "OPEN,MERGED,CLOSED",
        _ => "OPEN",
    };
    let fields = if ci {
        format!("{CORE_FIELDS}\n{CI_FIELDS}")
    } else {
        CORE_FIELDS.to_owned()
    };
    let nodes = fetch_pages(repo, states, &fields, limit, None).await?;
    let me = current_user().await;
    Ok(nodes
        .into_iter()
        .map(|node| enrich(node, me.as_deref(), jira_key, ci))
        .collect())
}

pub async fn fetch_recent_closed(repo: &str, since: Option<&str>) -> Result<Vec<Value>> {
    fetch_pages(
        repo,
        "MERGED,CLOSED",
        "number title body state url mergedAt updatedAt author{ login }",
        if since.is_some() { None } else { Some(30) },
        since,
    )
    .await
}

async fn fetch_pages(
    repo: &str,
    states: &str,
    fields: &str,
    limit: Option<usize>,
    until: Option<&str>,
) -> Result<Vec<Value>> {
    let (owner, name) = repo
        .split_once('/')
        .ok_or_else(|| anyhow!("invalid repo {repo:?} (expected owner/name)"))?;
    let query = "query($owner:String!,$name:String!,$first:Int!,$after:String){repository(owner:$owner,name:$name){pullRequests(states:[__STATES__],first:$first,after:$after,orderBy:{field:UPDATED_AT,direction:DESC}){pageInfo{hasNextPage endCursor} nodes{__FIELDS__}}}}"
        .replace("__STATES__", states).replace("__FIELDS__", fields);
    let mut result = Vec::new();
    let mut after: Option<String> = None;
    let mut more = false;
    for _ in 0..20 {
        let first = limit
            .map(|v| v.saturating_sub(result.len()).clamp(1, 100))
            .unwrap_or(100);
        let mut args = vec![
            "api".to_owned(),
            "graphql".into(),
            "-f".into(),
            format!("query={query}"),
            "-F".into(),
            format!("owner={owner}"),
            "-F".into(),
            format!("name={name}"),
            "-F".into(),
            format!("first={first}"),
        ];
        if let Some(cursor) = &after {
            args.extend(["-f".into(), format!("after={cursor}")]);
        }
        let out = cli::run("gh", &args, Duration::from_secs(60)).await?;
        let parsed: Value = serde_json::from_str(&out).context("parse gh GraphQL response")?;
        let connection = parsed
            .pointer("/data/repository/pullRequests")
            .ok_or_else(|| {
                anyhow!("unexpected gh graphql response for {repo} (no pullRequests connection)")
            })?;
        let mut nodes = connection
            .get("nodes")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter(|v| !v.is_null())
            .map(flatten)
            .collect::<Vec<_>>();
        if let Some(until) = until {
            if let Some(index) = nodes.iter().position(|node| {
                node.get("updatedAt")
                    .and_then(Value::as_str)
                    .is_some_and(|v| v < until)
            }) {
                nodes.truncate(index);
                result.extend(nodes);
                more = false;
                break;
            }
        }
        result.extend(nodes);
        if limit.is_some_and(|limit| result.len() >= limit) {
            result.truncate(limit.unwrap());
            more = false;
            break;
        }
        more = connection
            .pointer("/pageInfo/hasNextPage")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if !more {
            break;
        }
        after = connection
            .pointer("/pageInfo/endCursor")
            .and_then(Value::as_str)
            .map(str::to_owned);
    }
    if more {
        tracing::warn!(repo, "stopped after 20 GitHub PR pages");
    }
    Ok(result)
}

fn flatten(mut node: Value) -> Value {
    let checks = node
        .pointer("/commits/nodes/0/commit/statusCheckRollup/contexts/nodes")
        .and_then(Value::as_array)
        .cloned();
    let Some(object) = node.as_object_mut() else {
        return node;
    };
    for key in ["labels", "latestReviews"] {
        if let Some(nodes) = object
            .get(key)
            .and_then(|v| v.get("nodes"))
            .and_then(Value::as_array)
            .cloned()
        {
            object.insert(
                key.into(),
                Value::Array(nodes.into_iter().filter(|v| !v.is_null()).collect()),
            );
        }
    }
    if let Some(nodes) = object
        .get("reviewRequests")
        .and_then(|v| v.get("nodes"))
        .and_then(Value::as_array)
    {
        let reviewers = nodes
            .iter()
            .filter_map(|v| v.get("requestedReviewer"))
            .filter(|v| !v.is_null())
            .cloned()
            .collect();
        object.insert("reviewRequests".into(), Value::Array(reviewers));
    }
    if let Some(checks) = checks {
        object.insert("statusCheckRollup".into(), Value::Array(checks));
        object.remove("commits");
    }
    node
}

fn enrich(mut pr: Value, me: Option<&str>, project_key: &str, with_ci: bool) -> Value {
    let mine = me.is_some() && pr.pointer("/author/login").and_then(Value::as_str) == me;
    let requested = reviewers(&pr, "reviewRequests")
        .iter()
        .any(|v| Some(v.as_str()) == me);
    let reviewed = reviewers(&pr, "latestReviews")
        .iter()
        .any(|v| Some(v.as_str()) == me);
    let draft = pr.get("isDraft").and_then(Value::as_bool).unwrap_or(false);
    let category = if mine {
        "mine"
    } else if me.is_some() && requested && !draft {
        "review"
    } else {
        "other"
    };
    let awaiting = me.is_some() && !mine && !draft && (requested || reviewed);
    let keys = jira_keys(
        pr.get("title").and_then(Value::as_str).unwrap_or(""),
        pr.get("body").and_then(Value::as_str).unwrap_or(""),
        project_key,
    );
    let ci = if with_ci {
        summarize_ci(pr.get("statusCheckRollup"))
    } else {
        Value::Null
    };
    if let Some(object) = pr.as_object_mut() {
        object.insert("jiraKeys".into(), json!(keys));
        object.insert("category".into(), json!(category));
        object.insert("awaitingMyReview".into(), json!(awaiting));
        if with_ci {
            object.insert("ci".into(), ci);
            object.remove("statusCheckRollup");
        }
        object.remove("reviewRequests");
        object.remove("latestReviews");
    }
    pr
}

pub fn lean(pr: &Value, repo: &str) -> Value {
    let mut out = Map::new();
    for key in [
        "number",
        "title",
        "url",
        "state",
        "headRefName",
        "baseRefName",
        "author",
        "createdAt",
        "isDraft",
        "labels",
        "jiraKeys",
        "ci",
        "category",
        "awaitingMyReview",
        "reviewDecision",
        "requestedAt",
    ] {
        if let Some(value) = pr.get(key) {
            out.insert(key.into(), value.clone());
        }
    }
    out.insert("repo".into(), json!(repo));
    Value::Object(out)
}

fn reviewers(pr: &Value, key: &str) -> Vec<String> {
    pr.get(key)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|v| {
            v.pointer("/author/login")
                .or_else(|| v.get("login"))
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .collect()
}

fn summarize_ci(value: Option<&Value>) -> Value {
    let (mut running, mut failure, mut success) = (false, false, false);
    for item in value.and_then(Value::as_array).into_iter().flatten() {
        let status = item
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_ascii_uppercase();
        let conclusion = item
            .get("conclusion")
            .or_else(|| item.get("state"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_ascii_uppercase();
        running |= ["IN_PROGRESS", "QUEUED", "PENDING"].contains(&status.as_str())
            || conclusion == "PENDING";
        failure |= [
            "FAILURE",
            "ERROR",
            "CANCELLED",
            "TIMED_OUT",
            "ACTION_REQUIRED",
            "STARTUP_FAILURE",
        ]
        .contains(&conclusion.as_str());
        success |= conclusion == "SUCCESS";
    }
    if running {
        json!({"status":"in_progress","conclusion":null})
    } else if failure {
        json!({"status":"completed","conclusion":"failure"})
    } else if success {
        json!({"status":"completed","conclusion":"success"})
    } else {
        Value::Null
    }
}

pub(crate) fn jira_keys(title: &str, body: &str, project: &str) -> Vec<String> {
    let code = Regex::new(r"(?s)```.*?```|~~~.*?~~~|`[^`]*`").unwrap();
    let body = code.replace_all(body, " ");
    let title = code.replace_all(title, " ");
    let link = Regex::new(r"(?i)/browse/([A-Za-z][A-Za-z0-9]+-\d+)\b").unwrap();
    let plain = Regex::new(r"(?i)\b([A-Za-z][A-Za-z0-9]+-\d+)\b").unwrap();
    let prefix = project.to_ascii_uppercase();
    let extract = |source: &str, regex: &Regex| {
        let mut keys = Vec::new();
        for capture in regex.captures_iter(source) {
            let key = capture[1].to_ascii_uppercase();
            if (prefix.is_empty() || key.starts_with(&format!("{prefix}-"))) && !keys.contains(&key)
            {
                keys.push(key);
            }
        }
        keys
    };
    let linked = extract(&body, &link);
    if linked.is_empty() {
        extract(&title, &plain)
    } else {
        linked
    }
}

pub async fn review_requested_at(repo: &str, me: &str) -> Result<HashMap<i64, String>> {
    let (owner, name) = repo
        .split_once('/')
        .ok_or_else(|| anyhow!("invalid repo"))?;
    let query = "query($owner:String!,$name:String!){repository(owner:$owner,name:$name){pullRequests(states:OPEN,first:100,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{number timelineItems(itemTypes:[REVIEW_REQUESTED_EVENT],last:30){nodes{... on ReviewRequestedEvent{createdAt requestedReviewer{... on User{login}}}}}}}}}";
    let args = vec![
        "api".to_owned(),
        "graphql".into(),
        "-f".into(),
        format!("query={query}"),
        "-F".into(),
        format!("owner={owner}"),
        "-F".into(),
        format!("name={name}"),
    ];
    let raw = cli::run("gh", &args, Duration::from_secs(60)).await?;
    let value: Value = serde_json::from_str(&raw)?;
    let mut out = HashMap::new();
    for pr in value
        .pointer("/data/repository/pullRequests/nodes")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let number = pr.get("number").and_then(Value::as_i64).unwrap_or(0);
        for event in pr
            .pointer("/timelineItems/nodes")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if event
                .pointer("/requestedReviewer/login")
                .and_then(Value::as_str)
                == Some(me)
            {
                if let Some(timestamp) = event.get("createdAt").and_then(Value::as_str) {
                    if out
                        .get(&number)
                        .is_none_or(|old: &String| timestamp > old.as_str())
                    {
                        out.insert(number, timestamp.into());
                    }
                }
            }
        }
    }
    Ok(out)
}
