//! What a run knows about its event: the PR, the Jira tickets it touches (narrowed by Jira
//! filters, so later Jira actions act only on the tickets that passed), and lazily fetched
//! extras such as changed files.

use std::{
    collections::HashMap,
    sync::Mutex,
    time::{Duration, Instant},
};

use anyhow::{anyhow, Result};
use serde_json::{json, Value};

use super::model::Event;
use crate::{cli, github, AppState};

pub struct Ctx<'a> {
    pub event: &'a Event,
    pub me: Option<String>,
    /// The Jira tickets later Jira steps act on.
    pub jira_keys: Vec<String>,
    tickets: HashMap<String, Value>,
    files: Option<Vec<String>>,
}

impl<'a> Ctx<'a> {
    pub async fn new(app: &'a AppState, event: &'a Event) -> Ctx<'a> {
        let me = cached_login().await;
        let mut tickets = HashMap::new();
        let jira_keys = if let Some(ticket) = &event.ticket {
            let key = ticket["key"].as_str().unwrap_or("").to_owned();
            tickets.insert(key.clone(), ticket.clone());
            vec![key]
        } else {
            linked_keys(app, event)
        };
        Ctx {
            event,
            me,
            jira_keys,
            tickets,
            files: None,
        }
    }

    pub fn pr(&self) -> Result<&Value> {
        self.event
            .pr
            .as_ref()
            .ok_or_else(|| anyhow!("this step needs a pull request, and the event has none"))
    }

    pub fn number(&self) -> Result<i64> {
        self.pr()?["number"]
            .as_i64()
            .filter(|n| *n > 0)
            .ok_or_else(|| anyhow!("the event's PR has no number"))
    }

    pub fn repo(&self) -> Result<&str> {
        let repo = self.event.repo();
        if repo.is_empty() {
            Err(anyhow!("the event has no GitHub repo"))
        } else {
            Ok(repo)
        }
    }

    pub fn author(&self) -> String {
        self.event
            .pr
            .as_ref()
            .and_then(|pr| pr.pointer("/author/login").and_then(Value::as_str))
            .unwrap_or("")
            .to_owned()
    }

    pub fn author_is_bot(&self) -> bool {
        let Some(pr) = &self.event.pr else {
            return false;
        };
        pr.pointer("/author/__typename").and_then(Value::as_str) == Some("Bot")
            || pr.pointer("/author/is_bot").and_then(Value::as_bool) == Some(true)
            || self.author().ends_with("[bot]")
    }

    /// Files the PR changes, fetched once per run.
    pub async fn files(&mut self) -> Result<Vec<String>> {
        if let Some(files) = &self.files {
            return Ok(files.clone());
        }
        let number = self.number()?.to_string();
        let repo = self.repo()?.to_owned();
        let raw = cli::run(
            "gh",
            ["pr", "view", &number, "-R", &repo, "--json", "files", "--jq", ".files[].path"],
            Duration::from_secs(60),
        )
        .await?;
        let files: Vec<String> = raw.lines().map(str::to_owned).filter(|v| !v.is_empty()).collect();
        self.files = Some(files.clone());
        Ok(files)
    }

    /// The current tickets' fields, fetched once per run.
    pub async fn tickets(&mut self) -> Result<Vec<Value>> {
        let missing: Vec<String> = self
            .jira_keys
            .iter()
            .filter(|key| !self.tickets.contains_key(*key))
            .cloned()
            .collect();
        if !missing.is_empty() {
            let jql = format!("key in ({})", missing.join(","));
            for ticket in crate::poller::search_jira(&jql, missing.len().max(1)).await? {
                if let Some(key) = ticket["key"].as_str() {
                    self.tickets.insert(key.to_owned(), ticket.clone());
                }
            }
        }
        Ok(self
            .jira_keys
            .iter()
            .filter_map(|key| self.tickets.get(key).cloned())
            .collect())
    }

    pub fn workspace(&self) -> Option<String> {
        self.event.project["workspace"]
            .as_str()
            .filter(|v| !v.is_empty())
            .map(str::to_owned)
    }

    /// Template variables, for `{{name}}` placeholders and CRAFT_* script variables.
    pub fn variables(&self) -> Vec<(&'static str, String)> {
        let pr = self.event.pr.as_ref();
        let text = |pointer: &str| {
            pr.and_then(|pr| pr.pointer(pointer))
                .map(|v| match v {
                    Value::String(s) => s.clone(),
                    Value::Null => String::new(),
                    other => other.to_string(),
                })
                .unwrap_or_default()
        };
        let ticket = self.event.ticket.as_ref();
        let ticket_text = |key: &str| {
            ticket
                .and_then(|t| t[key].as_str())
                .unwrap_or("")
                .to_owned()
        };
        vec![
            ("event", self.event.kind.clone()),
            ("repo", self.event.repo().to_owned()),
            ("project.name", self.event.project["name"].as_str().unwrap_or("").to_owned()),
            ("pr.number", text("/number")),
            ("pr.title", text("/title")),
            ("pr.url", text("/url")),
            ("pr.author", self.author()),
            ("pr.base", text("/baseRefName")),
            ("pr.head", text("/headRefName")),
            ("jira.key", self.jira_keys.first().cloned().unwrap_or_default()),
            ("jira.keys", self.jira_keys.join(", ")),
            ("jira.summary", ticket_text("summary")),
            ("jira.status", ticket_text("status")),
            ("me", self.me.clone().unwrap_or_default()),
        ]
    }

    pub fn render(&self, template: &str) -> String {
        render(template, &self.variables())
    }

    pub fn event_json(&self) -> Value {
        json!({
            "event": self.event.kind,
            "subject": self.event.subject(),
            "repo": self.event.repo(),
            "project": self.event.project.get("name"),
            "pr": self.event.pr,
            "ticket": self.event.ticket,
            "jiraKeys": self.jira_keys,
        })
    }
}

/// Replace `{{name}}` with its value; unknown names are left as written so a typo shows.
pub fn render(template: &str, variables: &[(&str, String)]) -> String {
    let mut out = template.to_owned();
    for (name, value) in variables {
        out = out.replace(&format!("{{{{{name}}}}}"), value);
        out = out.replace(&format!("{{{{ {name} }}}}"), value);
    }
    out
}

fn linked_keys(app: &AppState, event: &Event) -> Vec<String> {
    let Some(pr) = &event.pr else {
        return Vec::new();
    };
    let project_key = event.project["jiraProjectKey"].as_str().unwrap_or("");
    let mut keys: Vec<String> = pr["jiraKeys"]
        .as_array()
        .map(|v| v.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default();
    for key in github::jira_keys(
        pr["title"].as_str().unwrap_or(""),
        pr["body"].as_str().unwrap_or(""),
        project_key,
    ) {
        if !keys.contains(&key) {
            keys.push(key);
        }
    }
    let number = pr["number"].as_i64().unwrap_or(0);
    let repo = event.repo();
    for link in app.db.links(None).unwrap_or_default() {
        if link["pr_number"] == number
            && link["pr_repo"]
                .as_str()
                .is_some_and(|r| r.eq_ignore_ascii_case(repo))
        {
            if let Some(key) = link["jira_key"].as_str().filter(|v| !v.is_empty()) {
                if !keys.iter().any(|v| v == key) {
                    keys.push(key.into());
                }
            }
        }
    }
    keys
}

/// `gh api user` once every ten minutes, not once per run.
async fn cached_login() -> Option<String> {
    // Tests pin the login rather than asking `gh` who is signed in.
    if let Some(login) = std::env::var("CRAFT_AUTOMATION_LOGIN").ok().filter(|v| !v.is_empty()) {
        return Some(login);
    }
    if cfg!(test) {
        return None;
    }
    static CACHE: Mutex<Option<(String, Instant)>> = Mutex::new(None);
    if let Some((login, at)) = CACHE.lock().unwrap().as_ref() {
        if at.elapsed() < Duration::from_secs(600) {
            return Some(login.clone());
        }
    }
    let login = github::current_user().await?;
    *CACHE.lock().unwrap() = Some((login.clone(), Instant::now()));
    Some(login)
}

#[cfg(test)]
mod tests {
    use super::render;

    #[test]
    fn placeholders_render_and_unknown_ones_stay() {
        let vars = vec![("pr.number", "12".to_owned()), ("repo", "a/b".to_owned())];
        assert_eq!(render("{{repo}}#{{pr.number}}", &vars), "a/b#12");
        assert_eq!(render("{{ repo }} {{nope}}", &vars), "a/b {{nope}}");
    }
}
