use std::{
    collections::HashMap,
    sync::{LazyLock, Mutex},
    time::{Duration, Instant},
};

use anyhow::{anyhow, Context, Result};
use regex::Regex;
use serde_json::{json, Map, Value};

use crate::{cli, Fault};

const CORE_FIELDS: &str = r#"number title state url headRefName baseRefName headRefOid mergedAt isDraft createdAt updatedAt reviewDecision body
mergeable additions deletions changedFiles
author{ login __typename ... on User{ name } }
labels(first:20){ nodes{ name color description } }
reviewRequests(first:20){ nodes{ requestedReviewer{ ... on User{ login } } } }
latestReviews(first:20){ nodes{ state author{ login } commit{ oid } } }"#;
/// The issues a PR closes when it merges — what `issueKeys` is read from.
const CLOSING_FIELDS: &str = "closingIssuesReferences(first:10){ nodes{ number repository{ nameWithOwner } } }";
/// A pull request's checks, as how many are in each state rather than the checks themselves:
/// the summary only asks whether any is running, failed or passed (`summarize_ci`), and a
/// hundred checks apiece for a page of pull requests is what made GitHub give up on a query.
const CI_FIELDS: &str = r#"commits(last:1){ nodes{ commit{ statusCheckRollup{ contexts(first:1){
checkRunCountsByState{ state count }
statusContextCountsByState{ state count }
} } } } }"#;

/// How long a sync's `gh` call may take. GitHub gives a GraphQL query ten seconds, so one still
/// unanswered after twenty is not coming, and waiting a minute for it only holds a lane.
const SYNC_TIMEOUT: Duration = Duration::from_secs(20);

/// What `gh` says, lowercased, when GitHub's GraphQL service gave up on a query: the service's
/// trouble, though it comes worded as an error in the query.
const GRAPHQL_GAVE_UP: [&str; 2] = [
    "something went wrong while executing your query",
    "couldn't respond to your request in time",
];

/// Whose a failed `gh` call is: GitHub's for now, or the request's until someone changes it.
/// A timeout is known from how the command ended; an exit is read from what `gh` printed
/// (`Fault::read`), since it exits 1 for a missing repository and a failing gateway alike.
pub fn fault(error: &anyhow::Error) -> Fault {
    match cli::Failure::of(error) {
        Some(cli::Failure::TimedOut) => Fault::Transient,
        // `gh` exits 4 when nobody is signed in.
        Some(cli::Failure::Exited(Some(4))) => Fault::Permanent,
        Some(cli::Failure::Exited(_)) if gave_up(error) => Fault::Transient,
        Some(cli::Failure::Exited(_)) => Fault::read(&error.to_string()),
        // `gh` is not installed, or the failure is not a command's: a reply that did not parse.
        Some(cli::Failure::Start) | None => Fault::Permanent,
    }
}

/// Whether GitHub's GraphQL service gave up on the query, rather than could not be reached.
fn gave_up(error: &anyhow::Error) -> bool {
    let text = error.to_string().to_ascii_lowercase();
    GRAPHQL_GAVE_UP.iter().any(|sign| text.contains(sign))
}

/// A repository's sync that failed: what it said, and whose fault it was.
#[derive(Debug, Clone)]
pub struct SyncError {
    pub message: String,
    pub fault: Fault,
}

impl From<anyhow::Error> for SyncError {
    fn from(error: anyhow::Error) -> Self {
        Self { fault: fault(&error), message: error.to_string() }
    }
}

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

/// The signed-in login, from `gh api user` at most once every ten minutes: what automations and
/// My Tickets' Mine compare against, asked for on every run and refresh.
pub async fn cached_login() -> Option<String> {
    // Tests pin the login rather than asking `gh` who is signed in.
    if let Some(login) = std::env::var("CASCADE_AUTOMATION_LOGIN").ok().filter(|v| !v.is_empty()) {
        return Some(login);
    }
    if cfg!(test) {
        return None;
    }
    if let Some(login) = fresh_login() {
        return Some(login);
    }
    if retry_deferred() {
        return last_login();
    }
    // One ask at a time: the syncs of every project start together on a cold cache, and the
    // ones that waited find the answer instead of each running `gh api user`.
    let _asking = ASKING.lock().await;
    if let Some(login) = fresh_login() {
        return Some(login);
    }
    if retry_deferred() {
        return last_login();
    }
    match current_user().await {
        Some(login) => {
            *LOGIN.lock().unwrap() = Some((login.clone(), Instant::now()));
            Some(login)
        }
        None => {
            // Not asked again for thirty seconds, and the last answer stands meanwhile: one bad
            // moment must not turn every pull request into somebody else's.
            *RETRY_AFTER.lock().unwrap() = Some(Instant::now() + Duration::from_secs(30));
            last_login()
        }
    }
}

/// Who `gh` is signed in as, kept for ten minutes: every sync of every project asks.
static LOGIN: Mutex<Option<(String, Instant)>> = Mutex::new(None);
/// Until when a failed ask is not repeated.
static RETRY_AFTER: Mutex<Option<Instant>> = Mutex::new(None);
static ASKING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

fn fresh_login() -> Option<String> {
    let cached = LOGIN.lock().unwrap();
    let (login, at) = cached.as_ref()?;
    (at.elapsed() < Duration::from_secs(600)).then(|| login.clone())
}

fn last_login() -> Option<String> {
    LOGIN.lock().unwrap().as_ref().map(|(login, _)| login.clone())
}

fn retry_deferred() -> bool {
    RETRY_AFTER.lock().unwrap().is_some_and(|until| Instant::now() < until)
}

/// Forgets the cached login, so the next sync asks `gh` again. A manual poll calls it: after
/// `gh auth switch`, refreshing is what a person does, and the review list must follow the
/// account.
pub fn forget_login() {
    *LOGIN.lock().unwrap() = None;
    *RETRY_AFTER.lock().unwrap() = None;
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
        format!("{CORE_FIELDS}\n{CLOSING_FIELDS}\n{CI_FIELDS}")
    } else {
        format!("{CORE_FIELDS}\n{CLOSING_FIELDS}")
    };
    let nodes = fetch_pages(repo, states, &fields, limit, None).await?;
    // The login changes rarely; asking `gh` for it on every fetch was one process per project per tick.
    let me = cached_login().await;
    Ok(nodes
        .into_iter()
        .map(|node| enrich(node, me.as_deref(), jira_key, ci))
        .collect())
}

pub async fn fetch_recent_closed(repo: &str, since: Option<&str>) -> Result<Vec<Value>> {
    fetch_pages(
        repo,
        "MERGED,CLOSED",
        &closed_fields(),
        if since.is_some() { None } else { Some(CLOSED_WINDOW) },
        since,
    )
    .await
}

fn closed_fields() -> String {
    format!("number title body state url mergedAt updatedAt author{{ login }} {CLOSING_FIELDS}")
}

/// How many closed pull requests a repository's first sync looks back over.
const CLOSED_WINDOW: usize = 30;

/// How many of each list a batched query asks a repository for. GitHub charges a query by the
/// sizes it asks for, not by what comes back, so a page sized for the rare repository costs the
/// same for every one that is nearly empty; a repository with more is fetched again alone, a
/// hundred at a time (`complete`).
const BATCH_PAGE: usize = 50;

/// How many repositories one batched query asks for. Each brings up to `BATCH_PAGE` open pull
/// requests, and GitHub gives a query ten seconds; more to a query risks that limit.
const REPOS_PER_QUERY: usize = 5;

/// One repository of a batched fetch (`fetch_repos`).
pub struct RepoQuery {
    pub repo: String,
    pub jira_key: String,
    /// Where the closed window starts, as `fetch_recent_closed`'s `since`.
    pub since: Option<String>,
    /// Its last sync failed: it is asked for by itself, so a repository that cannot be read
    /// does not fail the query of the ones that can, sync after sync.
    pub alone: bool,
}

/// A repository's open pull requests, as `fetch_prs` returns them with checks, and its recent
/// closed ones, as `fetch_recent_closed` returns them.
pub type RepoPrs = Result<(Vec<Value>, Vec<Value>), SyncError>;

/// What is left of the hour's GraphQL allowance, as a batched query's answer reports it for
/// free. The allowance is the signed-in account's, shared with everything else that uses it,
/// `gh` at the person's own hands included.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Budget {
    pub remaining: u64,
    pub limit: u64,
    /// How long until the allowance is whole again.
    pub reset_in: Duration,
}

/// Open and recently closed pull requests for several repositories, `REPOS_PER_QUERY` to one
/// GraphQL query rather than two queries each, one query after another; answers in the order
/// asked. A repository whose first page does not hold everything (over `BATCH_PAGE` open, or a
/// closed window longer than a page) is fetched again alone. A query GitHub refused, or gave up on, is
/// asked again repository by repository, so a renamed or inaccessible one fails alone; once
/// GitHub could not be reached at all (`Fault::Transient`), nothing more is asked: asking again
/// would only meet the same outage once more for each.
pub async fn fetch_repos(repos: &[RepoQuery]) -> (Vec<RepoPrs>, Option<Budget>) {
    let me = cached_login().await;
    let mut results: Vec<Option<RepoPrs>> = repos.iter().map(|_| None).collect();
    let mut budget = None;
    // The first failure that was GitHub's own. Once there is one, nothing more is asked: every
    // repository not answered yet fails with it.
    let mut outage: Option<SyncError> = None;
    let together: Vec<usize> = (0..repos.len()).filter(|index| !repos[*index].alone).collect();
    for indexes in together.chunks(REPOS_PER_QUERY) {
        if outage.is_some() {
            break;
        }
        let chunk: Vec<&RepoQuery> = indexes.iter().map(|index| &repos[*index]).collect();
        match fetch_chunk(&chunk).await {
            Ok((pages, left)) => {
                budget = left.or(budget);
                for (index, page) in indexes.iter().zip(pages) {
                    let query = &repos[*index];
                    let result = match page.map(|page| whole(query, page, me.as_deref())) {
                        Ok(Ok(lists)) => Ok(lists),
                        // More to fetch: not into an outage. What the page already answered
                        // in full, above, is kept whatever happened to the others.
                        Ok(Err(page)) => match &outage {
                            Some(error) => Err(error.clone()),
                            None => complete(query, page, me.as_deref()).await,
                        },
                        Err(error) => Err(error.into()),
                    };
                    outage = outage.or_else(|| outage_of(&result));
                    results[*index] = Some(result);
                }
            }
            Err(error) => {
                // GitHub giving up on a query of several repositories may only mean that all
                // of them were too much for one query: each is asked alone, below, and if
                // GitHub is in fact failing, the first of those meets the outage.
                let too_much = indexes.len() > 1 && gave_up(&error);
                let error = SyncError::from(error);
                if error.fault == Fault::Transient && !too_much {
                    outage = Some(error);
                } else if indexes.len() == 1 {
                    results[indexes[0]] = Some(Err(error));
                }
                // Refused with several repositories in it: each is asked alone, below.
            }
        }
    }
    for index in 0..repos.len() {
        if results[index].is_some() {
            continue;
        }
        let result = match &outage {
            Some(error) => Err(error.clone()),
            None => fetch_alone(&repos[index]).await,
        };
        outage = outage.or_else(|| outage_of(&result));
        results[index] = Some(result);
    }
    let results = results.into_iter().map(|result| result.expect("every repository is answered")).collect();
    (results, budget)
}

/// The failure, when a repository's fetch failed because GitHub could not answer.
fn outage_of(result: &RepoPrs) -> Option<SyncError> {
    result.as_ref().err().filter(|error| error.fault == Fault::Transient).cloned()
}

/// A repository's first page of each list, from a batched query.
struct RepoPage {
    open: Vec<Value>,
    open_more: bool,
    closed: Vec<Value>,
    closed_more: bool,
}

async fn fetch_chunk(chunk: &[&RepoQuery]) -> Result<(Vec<Result<RepoPage>>, Option<Budget>)> {
    let open_fields = format!("{CORE_FIELDS}\n{CLOSING_FIELDS}\n{CI_FIELDS}");
    let closed_fields = closed_fields();
    let order = "orderBy:{field:UPDATED_AT,direction:DESC}";
    let mut declared = Vec::new();
    let mut selections = Vec::new();
    let mut variables = Vec::new();
    for (index, query) in chunk.iter().enumerate() {
        let (owner, name) = query
            .repo
            .split_once('/')
            .ok_or_else(|| anyhow!("invalid repo {:?} (expected owner/name)", query.repo))?;
        let closed_first = if query.since.is_some() { BATCH_PAGE } else { CLOSED_WINDOW };
        declared.push(format!("$o{index}:String!,$n{index}:String!"));
        selections.push(format!(
            "r{index}:repository(owner:$o{index},name:$n{index}){{\
             open:pullRequests(states:[OPEN],first:{BATCH_PAGE},{order}){{pageInfo{{hasNextPage}} nodes{{{open_fields}}}}} \
             closed:pullRequests(states:[MERGED,CLOSED],first:{closed_first},{order}){{pageInfo{{hasNextPage}} nodes{{{closed_fields}}}}}}}"
        ));
        // `-f`, not `-F`: a repository named `123` or `true` stays a string.
        variables.extend(["-f".to_owned(), format!("o{index}={owner}")]);
        variables.extend(["-f".to_owned(), format!("n{index}={name}")]);
    }
    let mut args = vec![
        "api".to_owned(),
        "graphql".into(),
        "-f".into(),
        format!(
            "query=query({}){{{} rateLimit{{remaining limit resetAt}}}}",
            declared.join(","),
            selections.join(" ")
        ),
    ];
    args.extend(variables);
    let out = cli::run("gh", &args, SYNC_TIMEOUT).await?;
    let parsed: Value = serde_json::from_str(&out).context("parse gh GraphQL response")?;
    let budget = parsed.pointer("/data/rateLimit").and_then(|left| {
        let reset = chrono::DateTime::parse_from_rfc3339(left.get("resetAt")?.as_str()?).ok()?;
        let reset_in = reset.with_timezone(&chrono::Utc).signed_duration_since(chrono::Utc::now());
        Some(Budget {
            remaining: left.get("remaining")?.as_u64()?,
            limit: left.get("limit")?.as_u64()?,
            reset_in: reset_in.to_std().unwrap_or_default(),
        })
    });
    let pages = chunk
        .iter()
        .enumerate()
        .map(|(index, query)| {
            let list = |key: &str| {
                let connection = parsed
                    .pointer(&format!("/data/r{index}/{key}"))
                    .filter(|v| v.is_object())
                    .ok_or_else(|| {
                        anyhow!(
                            "unexpected gh graphql response for {} (no pullRequests connection)",
                            query.repo
                        )
                    })?;
                let nodes = connection
                    .get("nodes")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter(|v| !v.is_null())
                    .cloned()
                    .map(flatten)
                    .collect::<Vec<_>>();
                let more = connection
                    .pointer("/pageInfo/hasNextPage")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                Ok::<_, anyhow::Error>((nodes, more))
            };
            let (open, open_more) = list("open")?;
            let (closed, closed_more) = list("closed")?;
            Ok(RepoPage { open, open_more, closed, closed_more })
        })
        .collect();
    Ok((pages, budget))
}

/// A repository's lists, when its first page holds all of both; otherwise the page back, with
/// its closed list cut to the window, for `complete` to fetch what is missing.
fn whole(
    query: &RepoQuery,
    mut page: RepoPage,
    me: Option<&str>,
) -> std::result::Result<(Vec<Value>, Vec<Value>), RepoPage> {
    if let Some(since) = query.since.as_deref() {
        if let Some(index) = page.closed.iter().position(|node| {
            node.get("updatedAt").and_then(Value::as_str).is_some_and(|v| v < since)
        }) {
            page.closed.truncate(index);
            page.closed_more = false;
        }
    } else {
        // Without a window the first sync looks back over a fixed count, which one page holds.
        page.closed_more = false;
    }
    if page.open_more || page.closed_more {
        return Err(page);
    }
    let open = page
        .open
        .into_iter()
        .map(|node| enrich(node, me, &query.jira_key, true))
        .collect();
    Ok((open, page.closed))
}

/// The lists of a repository whose first page did not hold all of them (`whole` gave the page
/// back): each list that goes on past the page is fetched again alone.
async fn complete(query: &RepoQuery, page: RepoPage, me: Option<&str>) -> RepoPrs {
    let open = if page.open_more {
        fetch_prs(&query.repo, "open", None, true, &query.jira_key).await?
    } else {
        page.open
            .into_iter()
            .map(|node| enrich(node, me, &query.jira_key, true))
            .collect()
    };
    let closed = if page.closed_more {
        fetch_recent_closed(&query.repo, query.since.as_deref()).await?
    } else {
        page.closed
    };
    Ok((open, closed))
}

async fn fetch_alone(query: &RepoQuery) -> RepoPrs {
    let open = fetch_prs(&query.repo, "open", None, true, &query.jira_key).await?;
    let closed = fetch_recent_closed(&query.repo, query.since.as_deref()).await?;
    Ok((open, closed))
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
        let out = cli::run("gh", &args, SYNC_TIMEOUT).await?;
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
    // The states the pull request's checks are in, each once, from both kinds of check.
    let checks = node
        .pointer("/commits/nodes/0/commit/statusCheckRollup/contexts")
        .filter(|contexts| contexts.is_object())
        .map(|contexts| {
            ["checkRunCountsByState", "statusContextCountsByState"]
                .iter()
                .flat_map(|key| contexts.get(*key).and_then(Value::as_array).into_iter().flatten())
                .filter(|entry| entry.get("count").and_then(Value::as_u64).unwrap_or(0) > 0)
                .filter_map(|entry| entry.get("state").cloned())
                .collect::<Vec<Value>>()
        });
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
    if let Some(references) = object.remove("closingIssuesReferences") {
        object.insert("issueKeys".into(), json!(issue_keys(&references)));
    }
    node
}

/// `closingIssuesReferences` as ticket keys, `owner/repo#12`, lowercased so they compare as the
/// app's session keys do.
fn issue_keys(references: &Value) -> Vec<String> {
    references
        .get("nodes")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|node| {
            let number = node.get("number").and_then(Value::as_u64).filter(|n| *n > 0)?;
            let repo = node.pointer("/repository/nameWithOwner").and_then(Value::as_str)?;
            Some(crate::issues::key(repo, number))
        })
        .collect()
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
    let my_review = my_review(&pr, me);
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
        if let Some(review) = my_review {
            object.insert("myReview".into(), review);
        }
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
        "issueKeys",
        "ci",
        "category",
        "awaitingMyReview",
        "myReview",
        "reviewDecision",
        "requestedAt",
        "updatedAt",
        "headRefOid",
        "mergeable",
        "additions",
        "deletions",
        "changedFiles",
    ] {
        if let Some(value) = pr.get(key) {
            out.insert(key.into(), value.clone());
        }
    }
    out.insert("repo".into(), json!(repo));
    Value::Object(out)
}

/// My latest review, as `{state, commit}`: what the approve action reads so a commit is approved once.
fn my_review(pr: &Value, me: Option<&str>) -> Option<Value> {
    let me = me?;
    let review = pr
        .get("latestReviews")?
        .as_array()?
        .iter()
        .find(|review| review.pointer("/author/login").and_then(Value::as_str) == Some(me))?;
    Some(json!({
        "state": review["state"],
        "commit": review.pointer("/commit/oid").cloned().unwrap_or(Value::Null),
    }))
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

/// A pull request's checks in one line, from the states they are in (`flatten`): running while
/// any is still to finish, else failed if any failed, else passed if any passed; null when it
/// has none that says either. A check run's state is its conclusion once it has one and its
/// status until then, and a commit status has a state of its own; the names below are both.
fn summarize_ci(value: Option<&Value>) -> Value {
    let (mut running, mut failure, mut success) = (false, false, false);
    for state in value.and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str) {
        let state = state.to_ascii_uppercase();
        running |= ["IN_PROGRESS", "QUEUED", "PENDING"].contains(&state.as_str());
        failure |= [
            "FAILURE",
            "ERROR",
            "CANCELLED",
            "TIMED_OUT",
            "ACTION_REQUIRED",
            "STARTUP_FAILURE",
        ]
        .contains(&state.as_str());
        success |= state == "SUCCESS";
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
    static CODE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)```.*?```|~~~.*?~~~|`[^`]*`").unwrap());
    let code = &*CODE;
    let body = code.replace_all(body, " ");
    let title = code.replace_all(title, " ");
    static LINK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)/browse/([A-Za-z][A-Za-z0-9]+-\d+)\b").unwrap());
    static PLAIN: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\b([A-Za-z][A-Za-z0-9]+-\d+)\b").unwrap());
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
    let linked = extract(&body, &LINK);
    if linked.is_empty() {
        extract(&title, &PLAIN)
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
    let raw = cli::run("gh", &args, SYNC_TIMEOUT).await?;
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A timeout is GitHub's whatever it says; an exit is read from what `gh` printed; and what
    /// is not a command's failure, or not recognised, is shown rather than waited out.
    #[tokio::test]
    async fn a_failed_gh_call_is_githubs_or_the_requests() {
        let said = |text: &'static str| async move {
            let runner = std::sync::Arc::new(cli::ScriptedRunner::new().on("gh", move |_| Some(Err(text.into()))));
            let error = cli::scoped(runner, cli::run("gh", ["api"], Duration::from_secs(1))).await.unwrap_err();
            fault(&error)
        };
        assert_eq!(said("gh: HTTP 502: Bad Gateway (https://api.github.com/graphql)").await, Fault::Transient);
        assert_eq!(said("error connecting to api.github.com").await, Fault::Transient);
        assert_eq!(said("gh: Something went wrong while executing your query. This may be the result of a timeout").await, Fault::Transient);
        assert_eq!(said("gh: API rate limit exceeded for user ID 1.").await, Fault::Transient);
        assert_eq!(said("gh: Could not resolve to a Repository with the name 'o/gone'.").await, Fault::Permanent);
        assert_eq!(said("gh: Not Found (HTTP 404)").await, Fault::Permanent);
        let timed_out = anyhow::Error::new(cli::Failed::timed_out("gh", SYNC_TIMEOUT));
        assert_eq!(fault(&timed_out), Fault::Transient);
        assert_eq!(fault(&anyhow!("unexpected gh graphql response for o/r (no pullRequests connection)")), Fault::Permanent);
        let error = SyncError::from(timed_out);
        assert_eq!((error.fault, error.message.as_str()), (Fault::Transient, "gh timed out after 20s"));
    }

    /// The checks' summary is read from how many are in each state, and says what reading the
    /// checks one by one said: running while any is to finish, even beside one that failed.
    #[test]
    fn checks_are_summarised_from_their_states() {
        let ci = |runs: Value, statuses: Value| {
            let node = flatten(json!({"number":1,"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{
                "checkRunCountsByState":runs,"statusContextCountsByState":statuses}}}}]}}));
            assert!(node.get("commits").is_none());
            enrich(node, None, "", true)["ci"].clone()
        };
        let count = |state: &str, count: u64| json!({"state":state,"count":count});
        let (running, failed, passed) = (
            json!({"status":"in_progress","conclusion":null}),
            json!({"status":"completed","conclusion":"failure"}),
            json!({"status":"completed","conclusion":"success"}),
        );
        assert_eq!(ci(json!([count("SUCCESS", 9), count("FAILURE", 1), count("IN_PROGRESS", 2)]), json!([])), running);
        assert_eq!(ci(json!([count("SUCCESS", 9)]), json!([count("PENDING", 1)])), running);
        assert_eq!(ci(json!([count("SUCCESS", 9), count("TIMED_OUT", 1)]), json!([])), failed);
        assert_eq!(ci(json!([count("SUCCESS", 9)]), json!([count("ERROR", 1)])), failed);
        assert_eq!(ci(json!([count("SUCCESS", 3), count("SKIPPED", 2), count("NEUTRAL", 1)]), json!([count("SUCCESS", 1)])), passed);
        // A state that counts nothing is not there, and a pull request with no checks has none.
        assert_eq!(ci(json!([count("SUCCESS", 2), count("FAILURE", 0)]), json!([])), passed);
        assert_eq!(ci(json!([count("SKIPPED", 2)]), json!([count("EXPECTED", 1)])), Value::Null);
        let none = flatten(json!({"number":1,"commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}));
        assert_eq!(enrich(none, None, "", true)["ci"], Value::Null);
    }

    #[test]
    fn the_issues_a_pr_closes_reach_the_snapshot_as_keys() {
        let node = json!({
            "number": 4,
            "closingIssuesReferences": {"nodes": [
                {"number": 12, "repository": {"nameWithOwner": "Owner/Repo"}},
                {"number": 0, "repository": {"nameWithOwner": "owner/repo"}},
                null,
            ]},
        });
        let out = lean(&flatten(node), "owner/repo");
        assert_eq!(out["issueKeys"], json!(["owner/repo#12"]));
        assert!(out.get("closingIssuesReferences").is_none());
    }

    #[test]
    fn my_latest_review_and_its_commit_reach_the_snapshot() {
        let pr = json!({
            "number": 4, "author": {"login": "alice"},
            "latestReviews": [
                {"state": "COMMENTED", "author": {"login": "bob"}, "commit": {"oid": "a1"}},
                {"state": "APPROVED", "author": {"login": "me"}, "commit": {"oid": "b2"}},
            ],
        });
        let out = enrich(pr.clone(), Some("me"), "", false);
        assert_eq!(out["myReview"], json!({"state": "APPROVED", "commit": "b2"}));
        assert_eq!(lean(&out, "a/b")["myReview"], out["myReview"]);
        assert!(enrich(pr, Some("carol"), "", false).get("myReview").is_none());
    }
}
