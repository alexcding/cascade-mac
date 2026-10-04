use crate::{cli, http_client, AppState};
use anyhow::{anyhow, ensure, Context, Result};
use serde_json::{json, Value};
use std::{collections::HashMap, time::Duration};

pub async fn auth() -> Result<(String, String)> {
    let raw = cli::run("acli", ["jira", "auth", "status"], Duration::from_secs(15)).await?;
    let field = |name: &str| {
        raw.lines().find_map(|line| {
            line.split_once(':')
                .filter(|(key, _)| key.trim().eq_ignore_ascii_case(name))
                .map(|(_, v)| v.trim().to_owned())
        })
    };
    let site = field("Site").context("Could not resolve the Jira site from acli")?;
    let email = field("Email").context("Could not resolve the Jira account from acli")?;
    let site = if site.starts_with("https://") {
        site
    } else {
        format!("https://{site}")
    };
    Ok((site.trim_end_matches('/').into(), email))
}

/// Whose a failed Jira call is: Jira's for now, or the request's until someone changes it. A
/// timeout is known from how the command ended; the rest is read from what `acli` or `curl`
/// said (`Fault::read`), a refused REST call included, which names its HTTP status.
pub fn fault(error: &anyhow::Error) -> crate::Fault {
    match cli::Failure::of(error) {
        Some(cli::Failure::TimedOut) => crate::Fault::Transient,
        Some(cli::Failure::Start) => crate::Fault::Permanent,
        Some(cli::Failure::Exited(_)) | None => crate::Fault::read(&error.to_string()),
    }
}

pub async fn rest(app: &AppState, method: &str, path: &str, body: Option<&Value>) -> Result<Value> {
    let token = app
        .db
        .config_value("jira_api_token").await?
        .filter(|v| !v.is_empty())
        .context("No Jira API token set (Settings → Jira)")?;
    let (site, email) = auth().await?;
    http_client::request(
        &format!("{site}{path}"),
        method,
        &[
            ("Content-Type", "application/json".into()),
            ("Accept", "application/json".into()),
        ],
        Some(&format!("{email}:{token}")),
        body,
    )
    .await
}

pub(crate) fn segment(value: &str) -> String {
    url::form_urlencoded::byte_serialize(value.as_bytes())
        .collect::<String>()
        .replace('+', "%20")
}

/// A project's versions (releases) as Jira orders them, each with `name`, `released`, `archived`.
async fn version_list(key: &str) -> Result<Vec<Value>> {
    let raw = cli::run(
        "acli",
        ["jira", "project", "view", "--key", key, "--json"],
        Duration::from_secs(30),
    )
    .await?;
    let value: Value = serde_json::from_str(&raw)?;
    Ok(match value {
        Value::Object(mut project) => match project.remove("versions") {
            Some(Value::Array(versions)) => versions,
            _ => Vec::new(),
        },
        _ => Vec::new(),
    })
}

pub async fn versions(key: &str) -> Result<Vec<String>> {
    Ok(version_list(key)
        .await?
        .iter()
        .filter_map(|v| v["name"].as_str().map(str::to_owned))
        .collect())
}

/// The release a ticket merged today ships in: the first version, in the project's own order,
/// that is neither released nor archived.
pub async fn next_unreleased(key: &str) -> Result<Option<String>> {
    Ok(next_unreleased_in(&version_list(key).await?))
}

fn next_unreleased_in(versions: &[Value]) -> Option<String> {
    versions
        .iter()
        .filter(|v| v["released"] != true && v["archived"] != true)
        .find_map(|v| v["name"].as_str().map(str::trim).filter(|name| !name.is_empty()))
        .map(str::to_owned)
}

pub async fn board_columns(app: &AppState, board: i64) -> Result<Value> {
    let value = rest(
        app,
        "GET",
        &format!("/rest/agile/1.0/board/{board}/configuration"),
        None,
    )
    .await?;
    let statuses = rest(app, "GET", "/rest/api/3/status", None)
        .await
        .unwrap_or(Value::Null);
    let names: HashMap<String, String> = statuses
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|s| Some((s["id"].as_str()?.into(), s["name"].as_str()?.into())))
        .collect();
    Ok(json!(value
        .pointer("/columnConfig/columns")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|c| {
            let ids: Vec<String> = c["statuses"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|s| s["id"].as_str().map(str::to_owned))
                .collect();
            let statuses: Vec<Value> = ids
                .iter()
                .map(|id| json!({"id":id,"name":names.get(id).cloned().unwrap_or_default()}))
                .collect();
            json!({"name":c["name"],"statusIds":ids,"statuses":statuses})
        })
        .collect::<Vec<_>>()))
}

async fn event(app: &AppState, kind: &str, payload: Value) {
    if let Ok(event) = app.db.add_event(kind, &payload).await {
        app.publish(crate::Event::Activity { event });
    }
}

/// Make sure `project` has a release named `version`, creating it when missing.
pub async fn ensure_version(app: &AppState, project: &str, version: &str, trigger: &str) -> Result<()> {
    ensure!(
        !version.is_empty() && version.len() <= 255,
        "Invalid Jira version name"
    );
    if versions(project).await?.iter().any(|v| v == version) {
        return Ok(());
    }
    let found = rest(
        app,
        "GET",
        &format!("/rest/api/3/project/{}", segment(project)),
        None,
    )
    .await?;
    let id = found["id"]
        .as_i64()
        .or_else(|| found["id"].as_str()?.parse().ok())
        .context("Missing Jira project ID")?;
    let created = rest(
        app,
        "POST",
        "/rest/api/3/version",
        Some(&json!({"name":version,"projectId":id})),
    )
    .await;
    // Concurrent PRs may create the same release; accept only a confirmed match.
    if let Err(error) = created {
        if !versions(project).await?.iter().any(|v| v == version) {
            return Err(error);
        }
    } else {
        event(
            app,
            "jira_version_created",
            json!({"version":version,"project":project,"trigger":trigger}),
        ).await;
    }
    Ok(())
}

/// The tickets a JQL query finds, in the shape every ticket source answers with (`stage`, `level`
/// and `reopened` included), at most `limit` of them.
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
    Ok(array
        .iter()
        .map(|item| {
            let fields = &item["fields"];
            let text = |pointer: &str| fields.pointer(pointer).and_then(Value::as_str).unwrap_or("");
            let status = text("/status/name");
            let category = text("/status/statusCategory/key");
            let priority = text("/priority/name");
            json!({
                "key": item["key"],
                "summary": fields["summary"].as_str().unwrap_or(""),
                "status": status,
                "statusCategory": category,
                "statusId": text("/status/id"),
                "stage": crate::tickets::stage(status, category),
                "reopened": crate::tickets::reopened(status),
                "type": text("/issuetype/name"),
                "priority": priority,
                "level": crate::tickets::level(priority),
                "assignee": fields.pointer("/assignee/displayName").or_else(|| fields.pointer("/assignee/emailAddress")).and_then(Value::as_str).unwrap_or(""),
                "assigneeId": text("/assignee/accountId"),
                "assigneeEmail": text("/assignee/emailAddress"),
                "labels": fields["labels"].as_array().map(|v| v.iter().filter_map(Value::as_str).collect::<Vec<_>>()).unwrap_or_default(),
                "reporter": fields.pointer("/reporter/displayName").or_else(|| fields.pointer("/reporter/emailAddress")).and_then(Value::as_str).unwrap_or(""),
            })
        })
        .collect())
}
/// The project's active scrum sprint, as `{id, name, endDate, boardId}`; `Null` without a project
/// key, a scrum board or an active sprint.
pub(crate) async fn active_sprint(key: &str) -> Result<Value> {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_next_release_is_the_first_open_one_in_jira_order() {
        let versions = vec![
            json!({"name":"1.0","released":true,"archived":false}),
            json!({"name":"1.1","released":false,"archived":true}),
            json!({"name":"1.2","released":false,"archived":false}),
            json!({"name":"2.0","released":false,"archived":false}),
        ];
        assert_eq!(next_unreleased_in(&versions).as_deref(), Some("1.2"));
        assert_eq!(next_unreleased_in(&versions[..2]), None);
        let blank_first = vec![json!({"name":" ","released":false}), json!({"name":"3.0","released":false})];
        assert_eq!(next_unreleased_in(&blank_first).as_deref(), Some("3.0"));
    }
}
