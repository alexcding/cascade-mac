//! Actions plan first and execute second. A plan is the exact command or request, so a dry run
//! and a shadow run show precisely what a live run would do. Planning may read (look up failed
//! runs, check a Jira version exists) but never writes.

use std::{collections::BTreeMap, path::Path, time::Duration};

use anyhow::{anyhow, bail, ensure, Result};
use serde_json::{json, Value};

use super::{context::Ctx, model::Step};
use crate::{cli, http_client, integrations::render_version_template, jira, poller, AppState};

#[derive(Clone, Debug)]
pub enum Plan {
    Gh(Vec<String>),
    Transition { key: String, status: String },
    Assign { key: String, assignee: String },
    JiraComment { key: String, body: String },
    JiraLabels { key: String, labels: Vec<String> },
    FixVersion { project: String, version: String, keys: Vec<String>, exists: Option<bool> },
    Notify { title: String, body: String, url: String },
    Shell { script: String, cwd: Option<String>, env: Vec<(String, String)> },
    Webhook { url: String, body: Value },
    /// Nothing to do, with the reason (no linked ticket, no failed runs).
    Skip(String),
}

pub fn known(node: &str) -> bool {
    NODES.contains(&node)
}

const NODES: &[&str] = &[
    "github.approve",
    "github.request_changes",
    "github.comment",
    "github.add_label",
    "github.remove_label",
    "github.request_reviewers",
    "github.assign",
    "github.auto_merge",
    "github.merge",
    "github.close",
    "github.update_branch",
    "github.rerun_failed",
    "github.mark_ready",
    "jira.transition",
    "jira.fix_version",
    "jira.comment",
    "jira.assign",
    "jira.add_label",
    "craft.notify",
    "craft.shell",
    "craft.webhook",
];

/// Required params, checked at save.
pub fn validate(step: &Step) -> Result<()> {
    let need = |key: &str, what: &str| -> Result<()> {
        ensure!(!step.text(key).is_empty(), "{what} is required");
        Ok(())
    };
    let need_list = |key: &str, what: &str| -> Result<()> {
        ensure!(!step.list(key).is_empty(), "{what} needs at least one entry");
        Ok(())
    };
    match step.node.as_str() {
        "github.request_changes" => need("body", "Request changes: the review comment"),
        "github.comment" => need("body", "Comment: the comment"),
        "github.add_label" | "github.remove_label" => need_list("labels", "Labels"),
        "github.request_reviewers" => need_list("reviewers", "Request reviewers"),
        "github.assign" => need_list("assignees", "Assign"),
        "jira.transition" => need("status", "Transition ticket: the status"),
        "jira.fix_version" => {
            need("template", "Set Fix Version: the version template")?;
            render_version_template(step.text("template"), 1)
                .map(|_| ())
                .map_err(|e| anyhow!("Set Fix Version: {e}"))
        }
        "jira.comment" => need("body", "Comment on ticket: the comment"),
        "jira.add_label" => need_list("labels", "Add ticket labels"),
        "craft.shell" => need("script", "Run shell script: the script"),
        "craft.webhook" => {
            need("url", "POST to webhook: the URL")?;
            ensure!(step.text("url").starts_with("https://"), "POST to webhook: the URL must be https://");
            Ok(())
        }
        _ => Ok(()),
    }
}

pub async fn plan(step: &Step, ctx: &Ctx<'_>) -> Result<Vec<Plan>> {
    let node = step.node.as_str();
    if let Some(rest) = node.strip_prefix("github.") {
        return github(rest, step, ctx).await;
    }
    if let Some(rest) = node.strip_prefix("jira.") {
        return jira_plan(rest, step, ctx).await;
    }
    match node {
        "craft.notify" => {
            let title = match step.text("title") {
                "" => ctx.event.subject(),
                title => ctx.render(title),
            };
            let url = ctx.event.pr.as_ref().and_then(|pr| pr["url"].as_str()).unwrap_or("").to_owned();
            Ok(vec![Plan::Notify { title, body: ctx.render(step.text("body")), url }])
        }
        "craft.shell" => {
            let env = ctx
                .variables()
                .into_iter()
                .map(|(name, value)| (format!("CRAFT_{}", name.replace('.', "_").to_ascii_uppercase()), value))
                .collect();
            Ok(vec![Plan::Shell { script: step.text("script").to_owned(), cwd: ctx.workspace(), env }])
        }
        "craft.webhook" => {
            let mut body = ctx.event_json();
            let text = ctx.render(step.text("text"));
            body["text"] = json!(if text.is_empty() { ctx.event.subject() } else { text });
            Ok(vec![Plan::Webhook { url: step.text("url").to_owned(), body }])
        }
        other => bail!("unknown action {other}"),
    }
}

async fn github(action: &str, step: &Step, ctx: &Ctx<'_>) -> Result<Vec<Plan>> {
    let number = ctx.number()?.to_string();
    let repo = ctx.repo()?.to_owned();
    let pr = |verb: &str| -> Vec<String> {
        vec!["pr".into(), verb.into(), number.clone(), "-R".into(), repo.clone()]
    };
    let body = ctx.render(step.text("body"));
    let args = match action {
        "approve" => {
            let author = ctx.author();
            if ctx.me.as_deref().is_some_and(|me| me.eq_ignore_ascii_case(&author)) {
                bail!("won't approve your own PR");
            }
            let mut args = pr("review");
            args.push("--approve".into());
            if !body.is_empty() {
                args.extend(["-b".into(), body]);
            }
            args
        }
        "request_changes" => {
            let mut args = pr("review");
            args.extend(["--request-changes".into(), "-b".into(), body]);
            args
        }
        "comment" => {
            let mut args = pr("comment");
            args.extend(["-b".into(), body]);
            args
        }
        "add_label" | "remove_label" | "request_reviewers" | "assign" => {
            let (flag, key) = match action {
                "add_label" => ("--add-label", "labels"),
                "remove_label" => ("--remove-label", "labels"),
                "request_reviewers" => ("--add-reviewer", "reviewers"),
                _ => ("--add-assignee", "assignees"),
            };
            let values = step.list(key);
            ensure!(!values.is_empty(), "nothing to set");
            let mut args = pr("edit");
            args.extend([flag.into(), values.join(",")]);
            args
        }
        "auto_merge" | "merge" => {
            let mut args = pr("merge");
            if action == "auto_merge" {
                args.push("--auto".into());
            }
            args.push(match step.text("method") {
                "merge" => "--merge".into(),
                "rebase" => "--rebase".into(),
                _ => "--squash".into(),
            });
            if step.flag("deleteBranch") {
                args.push("--delete-branch".into());
            }
            args
        }
        "close" => {
            let mut args = pr("close");
            if !body.is_empty() {
                args.extend(["-c".into(), body]);
            }
            args
        }
        "update_branch" => {
            let mut args = pr("update-branch");
            if step.flag("rebase") {
                args.push("--rebase".into());
            }
            args
        }
        "mark_ready" => pr("ready"),
        "rerun_failed" => return rerun_plans(ctx, &number, &repo).await,
        other => bail!("unknown action github.{other}"),
    };
    Ok(vec![Plan::Gh(args)])
}

async fn rerun_plans(ctx: &Ctx<'_>, number: &str, repo: &str) -> Result<Vec<Plan>> {
    let sha = match ctx.pr()?["headRefOid"].as_str().filter(|v| !v.is_empty()) {
        Some(sha) => sha.to_owned(),
        None => cli::run(
            "gh",
            ["pr", "view", number, "-R", repo, "--json", "headRefOid", "--jq", ".headRefOid"],
            Duration::from_secs(60),
        )
        .await?,
    };
    let raw = cli::run(
        "gh",
        ["run", "list", "-R", repo, "--commit", &sha, "--status", "failure", "--json", "databaseId", "--jq", ".[].databaseId"],
        Duration::from_secs(60),
    )
    .await?;
    let plans: Vec<Plan> = raw
        .lines()
        .filter(|v| !v.trim().is_empty())
        .map(|id| Plan::Gh(vec!["run".into(), "rerun".into(), id.trim().into(), "-R".into(), repo.into(), "--failed".into()]))
        .collect();
    if plans.is_empty() {
        Ok(vec![Plan::Skip(format!("no failed runs on {}", &sha[..sha.len().min(7)]))])
    } else {
        Ok(plans)
    }
}

async fn jira_plan(action: &str, step: &Step, ctx: &Ctx<'_>) -> Result<Vec<Plan>> {
    if ctx.jira_keys.is_empty() {
        return Ok(vec![Plan::Skip("no Jira ticket to act on".into())]);
    }
    let keys = ctx.jira_keys.clone();
    Ok(match action {
        "transition" => keys
            .into_iter()
            .map(|key| Plan::Transition { key, status: step.text("status").to_owned() })
            .collect(),
        "assign" => {
            let assignee = step.text("assignee").to_owned();
            keys.into_iter().map(|key| Plan::Assign { key, assignee: assignee.clone() }).collect()
        }
        "comment" => {
            let body = ctx.render(step.text("body"));
            keys.into_iter().map(|key| Plan::JiraComment { key, body: body.clone() }).collect()
        }
        "add_label" => {
            let labels = step.list("labels");
            keys.into_iter().map(|key| Plan::JiraLabels { key, labels: labels.clone() }).collect()
        }
        "fix_version" => {
            let number = ctx.event.pr.as_ref().and_then(|pr| pr["number"].as_i64()).unwrap_or(0);
            let version = render_version_template(step.text("template"), number).map_err(|e| anyhow!(e.to_string()))?;
            let mut projects: BTreeMap<String, Vec<String>> = BTreeMap::new();
            for key in keys {
                if let Some((prefix, _)) = key.split_once('-') {
                    projects.entry(prefix.to_ascii_uppercase()).or_default().push(key.clone());
                }
            }
            let mut plans = Vec::new();
            for (project, keys) in projects {
                let exists = jira::versions(&project).await.ok().map(|v| v.contains(&version));
                plans.push(Plan::FixVersion { project, version: version.clone(), keys, exists });
            }
            plans
        }
        other => bail!("unknown action jira.{other}"),
    })
}

fn quote(arg: &str) -> String {
    if !arg.is_empty() && arg.chars().all(|c| c.is_ascii_alphanumeric() || "-_./:,@=#".contains(c)) {
        arg.to_owned()
    } else {
        format!("'{}'", arg.replace('\'', "'\\''"))
    }
}

impl Plan {
    pub fn is_skip(&self) -> bool {
        matches!(self, Plan::Skip(_))
    }

    /// What the plan will do, as a command where there is one.
    pub fn describe(&self) -> String {
        let command = |program: &str, args: &[&str]| {
            std::iter::once(program.to_owned()).chain(args.iter().map(|a| quote(a))).collect::<Vec<_>>().join(" ")
        };
        match self {
            Plan::Gh(args) => command("gh", &args.iter().map(String::as_str).collect::<Vec<_>>()),
            Plan::Transition { key, status } => {
                command("acli", &["jira", "workitem", "transition", "--key", key, "--status", status, "--yes"])
            }
            Plan::Assign { key, assignee } if assignee.is_empty() => {
                command("acli", &["jira", "workitem", "assign", "--key", key, "--remove-assignee", "--yes"])
            }
            Plan::Assign { key, assignee } => {
                command("acli", &["jira", "workitem", "assign", "--key", key, "--assignee", assignee, "--yes"])
            }
            Plan::JiraComment { key, body } => {
                command("acli", &["jira", "workitem", "comment", "create", "--key", key, "--body", body])
            }
            Plan::JiraLabels { key, labels } => format!("PUT /rest/api/3/issue/{key} add labels {}", labels.join(", ")),
            Plan::FixVersion { project, version, keys, exists } => format!(
                "Fix Version {version} on {}{}",
                keys.join(", "),
                match exists {
                    Some(true) => String::new(),
                    Some(false) => format!(" (creates release {version} in {project})"),
                    None => format!(" (could not check whether {project} has it)"),
                }
            ),
            Plan::Notify { title, body, .. } => format!("notify \"{title}\"{}", if body.is_empty() { String::new() } else { format!(": {body}") }),
            Plan::Shell { script, cwd, .. } => format!(
                "zsh -lc {}{}",
                quote(script),
                cwd.as_ref().map(|c| format!("  (in {c})")).unwrap_or_default()
            ),
            Plan::Webhook { url, .. } => format!("POST {url}"),
            Plan::Skip(reason) => reason.clone(),
        }
    }

    pub async fn execute(&self, app: &AppState, trigger: &str) -> Result<String> {
        match self {
            Plan::Gh(args) => cli::run("gh", args, Duration::from_secs(60)).await,
            Plan::Transition { key, status } => {
                poller::transition(key, status).await?;
                activity(app, "jira_transitioned", json!({"key":key,"transition":status,"trigger":trigger}));
                Ok(format!("{key} → {status}"))
            }
            Plan::Assign { key, assignee } => {
                poller::assign(key, assignee).await?;
                activity(app, "jira_assigned", json!({"key":key,"assignee":if assignee.is_empty(){"(unassigned)"}else{assignee},"trigger":trigger}));
                Ok(format!("{key} assigned"))
            }
            Plan::JiraComment { key, body } => {
                cli::run(
                    "acli",
                    ["jira", "workitem", "comment", "create", "--key", key, "--body", body],
                    Duration::from_secs(30),
                )
                .await
            }
            Plan::JiraLabels { key, labels } => {
                let update: Vec<Value> = labels.iter().map(|l| json!({"add":l})).collect();
                jira::rest(
                    app,
                    "PUT",
                    &format!("/rest/api/3/issue/{}", jira::segment(key)),
                    Some(&json!({"update":{"labels":update}})),
                )
                .await?;
                Ok(format!("{key} labelled"))
            }
            Plan::FixVersion { project, version, keys, .. } => {
                jira::ensure_version(app, project, version, trigger).await?;
                let (mut set, mut failed) = (Vec::new(), Vec::new());
                for key in keys {
                    match jira::rest(
                        app,
                        "PUT",
                        &format!("/rest/api/3/issue/{}", jira::segment(key)),
                        Some(&json!({"update":{"fixVersions":[{"add":{"name":version}}]}})),
                    )
                    .await
                    {
                        Ok(_) => {
                            activity(app, "jira_fixversion_set", json!({"key":key,"version":version,"trigger":trigger}));
                            set.push(key.as_str());
                        }
                        Err(error) => failed.push(format!("{key}: {error}")),
                    }
                }
                if !failed.is_empty() {
                    anyhow::bail!("{version} not set on {}", failed.join("; "));
                }
                Ok(format!("{version} on {}", set.join(", ")))
            }
            Plan::Notify { title, body, url } => {
                activity(app, "automation_notify", json!({"title":title,"body":body,"url":url,"trigger":trigger}));
                Ok("notified".into())
            }
            Plan::Shell { script, cwd, env } => {
                let mut args: Vec<String> = env.iter().map(|(k, v)| format!("{k}={v}")).collect();
                args.extend(["/bin/zsh".into(), "-lc".into(), script.clone()]);
                let cwd = cwd.as_deref().map(Path::new).filter(|p| p.is_dir());
                let out = cli::run_in("/usr/bin/env", &args, Duration::from_secs(60), cwd).await?;
                Ok(out.chars().take(500).collect())
            }
            Plan::Webhook { url, body } => {
                http_client::request(url, "POST", &[("Content-Type", "application/json".into())], None, Some(body)).await?;
                Ok("delivered".into())
            }
            Plan::Skip(reason) => Ok(reason.clone()),
        }
    }
}

fn activity(app: &AppState, kind: &str, payload: Value) {
    if let Ok(event) = app.db.add_event(kind, &payload) {
        app.broadcast(json!({"type":"activity","event":event}));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn describe_quotes_only_what_needs_it() {
        let plan = Plan::Gh(vec!["pr".into(), "review".into(), "12".into(), "-R".into(), "a/b".into(), "--approve".into(), "-b".into(), "Looks good".into()]);
        assert_eq!(plan.describe(), "gh pr review 12 -R a/b --approve -b 'Looks good'");
        let plan = Plan::Transition { key: "CRAFT-1".into(), status: "In Review".into() };
        assert_eq!(plan.describe(), "acli jira workitem transition --key CRAFT-1 --status 'In Review' --yes");
    }

    #[test]
    fn required_params_are_checked_at_save() {
        let step = |node: &str, params: Value| Step { node: node.into(), params: params.as_object().unwrap().clone(), ..Default::default() };
        assert!(validate(&step("github.comment", json!({}))).is_err());
        assert!(validate(&step("github.comment", json!({"body":"hi"}))).is_ok());
        assert!(validate(&step("github.add_label", json!({"labels":""}))).is_err());
        assert!(validate(&step("craft.webhook", json!({"url":"http://x"}))).is_err());
        assert!(validate(&step("jira.fix_version", json!({"template":"{year}.{isoWeek}"}))).is_ok());
        assert!(validate(&step("jira.fix_version", json!({"template":"{nope}"}))).is_err());
        assert!(validate(&step("github.approve", json!({}))).is_ok());
    }
}
