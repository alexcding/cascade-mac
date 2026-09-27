//! GitHub issues as tickets. `gh issue` is the source; every issue is mapped onto the ticket
//! shape the Jira source returns (`poller::search_jira`), with `source: "github"`, so the app
//! lists, filters and opens both through one model. GitHub has no priority or sprint, so those
//! fields stay empty rather than being made up.

use std::{sync::LazyLock, time::Duration};

use anyhow::{anyhow, bail, Result};
use regex::Regex;
use serde_json::{json, Value};

use crate::{cli, AppState};

const FIELDS: &str = "number,title,state,stateReason,labels,assignees,author,url,updatedAt,issueType";
/// A project that sets no query of its own lists what is open, most recently touched first.
pub const DEFAULT_QUERY: &str = "is:open sort:updated-desc";

/// The status names the app shows and moves between. A closed issue is "Closed" unless it was
/// closed as not planned; GitHub's `DUPLICATE` reason reads as closed.
pub const OPEN: &str = "Open";
pub const CLOSED: &str = "Closed";
pub const NOT_PLANNED: &str = "Not planned";

static ISSUE_URL: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^https?://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/issues/(\d+)(?:[/?#].*)?$")
        .unwrap()
});
static NUMBER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^#?(\d+)$").unwrap());

/// The search a project's issue snapshot runs, or empty when the project has no repo or has
/// turned issues off. The board filter (`board_query_<id>`) is Jira's and is not applied here.
pub fn project_query(project: &Value) -> String {
    let repo = project["repo"].as_str().unwrap_or("");
    let enabled = project["issuesEnabled"].as_bool().unwrap_or(true);
    if repo.is_empty() || !enabled {
        return String::new();
    }
    project["issueQuery"]
        .as_str()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .unwrap_or(DEFAULT_QUERY)
        .to_owned()
}

pub fn issue_limit(app: &AppState) -> usize {
    app.db
        .config_value("issue_limit")
        .ok()
        .flatten()
        .and_then(|v| v.parse().ok())
        .unwrap_or(100usize)
        .max(1)
}

/// `gh issue list --search` over one repo. The query decides the state (`is:open`, `is:closed`),
/// so `--state all` keeps gh from adding one of its own.
pub async fn search(repo: &str, query: &str, limit: usize) -> Result<Vec<Value>> {
    let raw = cli::run(
        "gh",
        [
            "issue", "list", "--repo", repo, "--search", query, "--state", "all", "--limit",
            &limit.to_string(), "--json", FIELDS,
        ],
        Duration::from_secs(30),
    )
    .await
    .map_err(friendly)?;
    let items: Value = serde_json::from_str(&raw)?;
    let array = items
        .as_array()
        .ok_or_else(|| anyhow!("unexpected gh issue list response"))?;
    Ok(array.iter().map(|item| ticket(item, repo)).collect())
}

/// One issue by number, as a one-item list, for a search typed as `#123` or `123`. `gh issue view`
/// also answers for a pull request's number; that is not an issue, so the list is then empty.
pub async fn view(repo: &str, number: u64) -> Result<Vec<Value>> {
    let raw = cli::run(
        "gh",
        ["issue", "view", &number.to_string(), "--repo", repo, "--json", FIELDS],
        Duration::from_secs(30),
    )
    .await
    .map_err(friendly)?;
    let item: Value = serde_json::from_str(&raw)?;
    if !item["url"].as_str().is_some_and(|url| ISSUE_URL.is_match(url)) {
        return Ok(Vec::new());
    }
    Ok(vec![ticket(&item, repo)])
}

/// Searches each repo and merges the results, newest first. A repo that fails is reported only
/// when every repo failed, so one project without issues does not hide the others.
pub async fn search_repos(repos: &[String], query: &str, limit: usize) -> Result<Vec<Value>> {
    let number = NUMBER
        .captures(query.trim())
        .and_then(|c| c[1].parse::<u64>().ok())
        .filter(|n| *n > 0);
    let jobs = repos.iter().map(|repo| async move {
        match number {
            Some(number) => view(repo, number).await,
            None => search(repo, query, limit).await,
        }
    });
    let results = futures_util::future::join_all(jobs).await;
    let mut items = Vec::new();
    let mut last_error = None;
    let mut succeeded = false;
    for result in results {
        match result {
            Ok(found) => {
                succeeded = true;
                items.extend(found);
            }
            Err(error) => last_error = Some(error),
        }
    }
    if let (false, Some(error)) = (succeeded, last_error) {
        return Err(error);
    }
    items.sort_by(|a, b| b["updated"].as_str().cmp(&a["updated"].as_str()));
    items.truncate(limit);
    Ok(items)
}

/// The issue a GitHub issue URL names, or `None` for any other URL.
pub fn parse_url(url: &str) -> Option<(String, u64)> {
    let captures = ISSUE_URL.captures(url.trim())?;
    let number = captures[2].parse::<u64>().ok().filter(|n| *n > 0)?;
    Some((captures[1].to_owned(), number))
}

/// An issue's ticket key, `owner/repo#12`, lowercased as PRs and sessions record it.
pub fn key(repo: &str, number: u64) -> String {
    format!("{}#{number}", repo.to_ascii_lowercase())
}

pub fn parse_key(key: &str) -> Option<(String, u64)> {
    let (repo, number) = key.rsplit_once('#')?;
    let number = number.parse::<u64>().ok().filter(|n| *n > 0)?;
    crate::github::parse_repo(repo).map(|repo| (repo, number))
}

/// The issues a PR closes when it merges, for an event whose PR came without `issueKeys` (a
/// webhook delivery).
pub async fn closing_keys(repo: &str, number: &str) -> Result<Vec<String>> {
    let raw = cli::run(
        "gh",
        ["pr", "view", number, "-R", repo, "--json", "closingIssuesReferences"],
        Duration::from_secs(60),
    )
    .await?;
    let value: Value = serde_json::from_str(&raw)?;
    Ok(value["closingIssuesReferences"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|issue| issue["url"].as_str().and_then(parse_url))
        .map(|(repo, number)| key(&repo, number))
        .collect())
}

pub async fn lookup(url: &str) -> Option<Value> {
    let (repo, number) = parse_url(url)?;
    view(&repo, number).await.ok()?.into_iter().next()
}

/// Moves an issue to one of the three statuses: reopening, closing as completed, or closing
/// as not planned.
pub async fn set_status(repo: &str, number: u64, status: &str) -> Result<()> {
    let number = number.to_string();
    let args: Vec<&str> = match status {
        OPEN => vec!["issue", "reopen", &number, "--repo", repo],
        CLOSED => vec!["issue", "close", &number, "--repo", repo, "--reason", "completed"],
        NOT_PLANNED => vec!["issue", "close", &number, "--repo", repo, "--reason", "not planned"],
        other => bail!("unknown issue status {other:?}"),
    };
    cli::run("gh", args, Duration::from_secs(30))
        .await
        .map_err(friendly)?;
    Ok(())
}

pub fn status(state: &str, reason: &str) -> &'static str {
    if state.eq_ignore_ascii_case("open") {
        OPEN
    } else if reason.eq_ignore_ascii_case("not_planned") || reason.eq_ignore_ascii_case("not planned") {
        NOT_PLANNED
    } else {
        CLOSED
    }
}

/// One `gh` issue as a ticket. `statusCategory` uses Jira's keys (`new`, `done`) so the app
/// groups and colours both sources the same way.
pub fn ticket(item: &Value, repo: &str) -> Value {
    let state = item["state"].as_str().unwrap_or("");
    let status = status(state, item["stateReason"].as_str().unwrap_or(""));
    let number = item["number"].as_u64().unwrap_or(0);
    let person = |value: &Value| {
        value["name"]
            .as_str()
            .filter(|v| !v.is_empty())
            .or_else(|| value["login"].as_str())
            .unwrap_or("")
            .to_owned()
    };
    let assignee = item["assignees"].as_array().and_then(|v| v.first());
    json!({
        "source": "github",
        "key": format!("#{number}"),
        "number": number,
        "repo": repo,
        "url": item["url"].as_str().unwrap_or(""),
        "summary": item["title"].as_str().unwrap_or(""),
        "status": status,
        "statusCategory": if status == OPEN { "new" } else { "done" },
        "statusId": "",
        "type": item.pointer("/issueType/name").and_then(Value::as_str).unwrap_or(""),
        "priority": "",
        "assignee": assignee.map(person).unwrap_or_default(),
        "assigneeId": assignee.and_then(|v| v["login"].as_str()).unwrap_or(""),
        "assigneeEmail": "",
        "labels": item["labels"].as_array().map(|v| v.iter().filter_map(|l| l["name"].as_str()).collect::<Vec<_>>()).unwrap_or_default(),
        "reporter": person(&item["author"]),
        "updated": item["updatedAt"].as_str().unwrap_or(""),
    })
}

/// `gh` says a repo has issues turned off in a sentence buried in its stderr; say it plainly.
fn friendly(error: anyhow::Error) -> anyhow::Error {
    let message = error.to_string();
    if message.to_ascii_lowercase().contains("disabled issues") {
        anyhow!("Issues are turned off for this repository on GitHub.")
    } else {
        error
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_an_open_issue_onto_the_ticket_shape() {
        let item = json!({"number":12,"title":"Crash on launch","state":"OPEN","stateReason":"",
            "labels":[{"name":"bug"}],"assignees":[{"login":"octo","name":"Octo Cat"}],
            "author":{"login":"alice","name":""},"url":"https://github.com/o/r/issues/12",
            "updatedAt":"2026-09-01T00:00:00Z","issueType":{"name":"Bug"}});
        let ticket = ticket(&item, "o/r");
        assert_eq!(ticket["source"], "github");
        assert_eq!(ticket["key"], "#12");
        assert_eq!(ticket["status"], "Open");
        assert_eq!(ticket["statusCategory"], "new");
        assert_eq!(ticket["type"], "Bug");
        assert_eq!(ticket["assignee"], "Octo Cat");
        assert_eq!(ticket["assigneeId"], "octo");
        assert_eq!(ticket["reporter"], "alice");
        assert_eq!(ticket["labels"], json!(["bug"]));
        assert_eq!(ticket["repo"], "o/r");
    }

    #[test]
    fn a_closed_issue_keeps_its_reason() {
        assert_eq!(status("CLOSED", "NOT_PLANNED"), NOT_PLANNED);
        assert_eq!(status("CLOSED", "COMPLETED"), CLOSED);
        assert_eq!(status("CLOSED", "DUPLICATE"), CLOSED);
        assert_eq!(status("open", ""), OPEN);
    }

    #[test]
    fn project_query_follows_repo_and_toggle() {
        assert_eq!(project_query(&json!({"repo":"o/r"})), DEFAULT_QUERY);
        assert_eq!(project_query(&json!({"repo":"o/r","issueQuery":" label:bug "})), "label:bug");
        assert_eq!(project_query(&json!({"repo":"o/r","issuesEnabled":false})), "");
        assert_eq!(project_query(&json!({"repo":"","issuesEnabled":true})), "");
    }

    #[test]
    fn keys_round_trip() {
        assert_eq!(key("Owner/Repo", 12), "owner/repo#12");
        assert_eq!(parse_key("owner/repo#12"), Some(("owner/repo".into(), 12)));
        assert_eq!(parse_key("owner/repo#0"), None);
        assert_eq!(parse_key("REC-12"), None);
    }

    #[test]
    fn parses_only_issue_urls() {
        assert_eq!(parse_url("https://github.com/o/r/issues/7"), Some(("o/r".into(), 7)));
        assert_eq!(parse_url("https://github.com/o/r/issues/7#issuecomment-1"), Some(("o/r".into(), 7)));
        assert_eq!(parse_url("https://github.com/o/r/pull/7"), None);
        assert_eq!(parse_url("https://github.com/o/r/issues/0"), None);
        assert_eq!(parse_url("https://example.com/o/r/issues/7"), None);
    }
}
