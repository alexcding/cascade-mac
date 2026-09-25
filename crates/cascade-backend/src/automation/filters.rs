//! Filters: each answers pass/fail with a reason a person can read in the trace.

use anyhow::{anyhow, bail, Result};
use chrono::{Datelike, Local, NaiveTime, Weekday};
use regex::Regex;
use serde_json::Value;

use super::{context::Ctx, model::Step};

pub struct Outcome {
    pub passed: bool,
    pub detail: String,
}

fn pass(detail: impl Into<String>) -> Outcome {
    Outcome { passed: true, detail: detail.into() }
}
fn fail(detail: impl Into<String>) -> Outcome {
    Outcome { passed: false, detail: detail.into() }
}
fn verdict(passed: bool, detail: impl Into<String>) -> Outcome {
    Outcome { passed, detail: detail.into() }
}

pub fn known(node: &str) -> bool {
    NODES.contains(&node)
}

const NODES: &[&str] = &[
    "pr.author",
    "pr.base_branch",
    "pr.head_branch",
    "pr.labels",
    "pr.title",
    "pr.draft",
    "pr.ci",
    "pr.review",
    "pr.mergeable",
    "pr.size",
    "pr.paths",
    "jira.has_key",
    "jira.project",
    "jira.status",
    "jira.type",
    "jira.priority",
    "time.window",
];

/// Check params that can be wrong before anything runs, so a bad regex fails at save.
pub fn validate(step: &Step) -> Result<()> {
    match step.node.as_str() {
        "pr.title" => {
            Regex::new(step.text("regex")).map_err(|e| anyhow!("Title regex: {e}"))?;
        }
        "time.window" => {
            for key in ["from", "to"] {
                let value = step.text(key);
                if !value.is_empty() && NaiveTime::parse_from_str(value, "%H:%M").is_err() {
                    bail!("Time window: {key} must look like 09:00");
                }
            }
            for day in step.list("days") {
                weekday(&day).ok_or_else(|| anyhow!("Time window: unknown day {day:?}"))?;
            }
        }
        _ => {}
    }
    Ok(())
}

pub async fn eval(step: &Step, ctx: &mut Ctx<'_>) -> Result<Outcome> {
    match step.node.as_str() {
        "pr.author" => {
            let author = ctx.author();
            let users = step.list("users");
            let hit = users.iter().any(|user| match user.as_str() {
                "@me" => ctx.me.as_deref().is_some_and(|me| me.eq_ignore_ascii_case(&author)),
                "@bots" => ctx.author_is_bot(),
                user => user.trim_start_matches('@').eq_ignore_ascii_case(&author),
            });
            let negate = step.text("mode") == "not_in";
            ctx.pr()?;
            Ok(verdict(
                hit != negate,
                format!(
                    "author {author} {} {}",
                    if hit { "is in" } else { "is not in" },
                    users.join(", ")
                ),
            ))
        }
        "pr.base_branch" | "pr.head_branch" => {
            let field = if step.node == "pr.base_branch" { "baseRefName" } else { "headRefName" };
            let branch = ctx.pr()?[field].as_str().unwrap_or("").to_owned();
            let patterns = step.list("patterns");
            let hit = patterns.iter().any(|p| glob(p, &branch));
            Ok(verdict(hit, format!("{branch} {} {}", if hit { "matches" } else { "does not match" }, patterns.join(", "))))
        }
        "pr.labels" => {
            let have: Vec<String> = ctx.pr()?["labels"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|l| l["name"].as_str().or_else(|| l.as_str()))
                .map(str::to_ascii_lowercase)
                .collect();
            let want = step.list("labels");
            let has = |label: &String| have.contains(&label.to_ascii_lowercase());
            let passed = match step.text("mode") {
                "all" => want.iter().all(has),
                "none" => !want.iter().any(has),
                _ => want.iter().any(has),
            };
            Ok(verdict(passed, format!("labels [{}]", have.join(", "))))
        }
        "pr.title" => {
            let title = ctx.pr()?["title"].as_str().unwrap_or("").to_owned();
            let regex = Regex::new(step.text("regex"))?;
            let hit = regex.is_match(&title);
            Ok(verdict(hit, format!("title {} /{}/", if hit { "matches" } else { "does not match" }, step.text("regex"))))
        }
        "pr.draft" => {
            let draft = ctx.pr()?["isDraft"].as_bool().unwrap_or(false);
            let want = step.text("is") == "yes";
            Ok(verdict(draft == want, if draft { "PR is a draft" } else { "PR is not a draft" }))
        }
        "pr.ci" => {
            let state = ci_state(ctx.pr()?);
            let want = match step.text("is") { "" => "passing", other => other };
            Ok(verdict(state == want, format!("CI is {state}")))
        }
        "pr.review" => {
            let decision = ctx.pr()?["reviewDecision"].as_str().filter(|v| !v.is_empty()).unwrap_or("none").to_owned();
            Ok(verdict(decision == step.text("is"), format!("review decision is {decision}")))
        }
        "pr.mergeable" => {
            let state = ctx.pr()?["mergeable"].as_str().unwrap_or("UNKNOWN").to_owned();
            Ok(verdict(state == step.text("is"), format!("mergeable is {state}")))
        }
        "pr.size" => {
            let pr = ctx.pr()?;
            let lines = pr["additions"].as_i64().unwrap_or(0) + pr["deletions"].as_i64().unwrap_or(0);
            let files = pr["changedFiles"].as_i64().unwrap_or(0);
            let mut passed = true;
            if let Some(max) = step.number("maxLines") {
                passed &= lines <= max;
            }
            if let Some(max) = step.number("maxFiles") {
                passed &= files <= max;
            }
            Ok(verdict(passed, format!("{lines} lines in {files} files")))
        }
        "pr.paths" => {
            let files = ctx.files().await?;
            let patterns = step.list("patterns");
            let matches = |file: &String| patterns.iter().any(|p| glob(p, file));
            let hits = files.iter().filter(|f| matches(f)).count();
            let passed = match step.text("mode") {
                "any" => hits > 0,
                "none" => hits == 0,
                _ => !files.is_empty() && hits == files.len(),
            };
            Ok(verdict(passed, format!("{hits} of {} changed files match", files.len())))
        }
        "jira.has_key" => {
            if ctx.jira_keys.is_empty() {
                Ok(fail("no linked Jira ticket"))
            } else {
                Ok(pass(format!("linked {}", ctx.jira_keys.join(", "))))
            }
        }
        "jira.project" => {
            let projects: Vec<String> = step.list("keys").iter().map(|k| k.to_ascii_uppercase()).collect();
            ctx.jira_keys.retain(|key| {
                key.split_once('-').is_some_and(|(prefix, _)| projects.contains(&prefix.to_ascii_uppercase()))
            });
            narrowed(ctx, "in project")
        }
        "jira.status" | "jira.type" | "jira.priority" => {
            let (param, field) = match step.node.as_str() {
                "jira.status" => ("statuses", "status"),
                "jira.type" => ("types", "type"),
                _ => ("priorities", "priority"),
            };
            let wanted: Vec<String> = step.list(param).iter().map(|v| v.to_ascii_lowercase()).collect();
            let tickets = ctx.tickets().await?;
            let keep: Vec<String> = tickets
                .iter()
                .filter(|t| wanted.contains(&t[field].as_str().unwrap_or("").to_ascii_lowercase()))
                .filter_map(|t| t["key"].as_str().map(str::to_owned))
                .collect();
            let seen: Vec<String> = tickets
                .iter()
                .map(|t| format!("{} is {}", t["key"].as_str().unwrap_or(""), t[field].as_str().unwrap_or("?")))
                .collect();
            ctx.jira_keys.retain(|key| keep.contains(key));
            if ctx.jira_keys.is_empty() {
                Ok(fail(if seen.is_empty() { "no linked Jira ticket".to_owned() } else { seen.join(", ") }))
            } else {
                Ok(pass(seen.join(", ")))
            }
        }
        "time.window" => Ok(time_window(step, Local::now().naive_local())),
        other => bail!("unknown filter {other}"),
    }
}

fn narrowed(ctx: &Ctx<'_>, what: &str) -> Result<Outcome> {
    if ctx.jira_keys.is_empty() {
        Ok(fail(format!("no linked ticket {what}")))
    } else {
        Ok(pass(format!("{} {what}", ctx.jira_keys.join(", "))))
    }
}

pub fn ci_state(pr: &Value) -> &'static str {
    let ci = &pr["ci"];
    if ci.is_null() {
        return "none";
    }
    match (ci["status"].as_str(), ci["conclusion"].as_str()) {
        (_, Some("success")) => "passing",
        (_, Some("failure")) => "failing",
        (Some("in_progress"), _) => "pending",
        _ => "none",
    }
}

fn weekday(name: &str) -> Option<Weekday> {
    match name.trim().to_ascii_lowercase().get(..3)? {
        "mon" => Some(Weekday::Mon),
        "tue" => Some(Weekday::Tue),
        "wed" => Some(Weekday::Wed),
        "thu" => Some(Weekday::Thu),
        "fri" => Some(Weekday::Fri),
        "sat" => Some(Weekday::Sat),
        "sun" => Some(Weekday::Sun),
        _ => None,
    }
}

fn time_window(step: &Step, now: chrono::NaiveDateTime) -> Outcome {
    let days: Vec<Weekday> = step.list("days").iter().filter_map(|d| weekday(d)).collect();
    if !days.is_empty() && !days.contains(&now.weekday()) {
        return fail(format!("today is {}", now.weekday()));
    }
    let time = now.time();
    let parse = |key: &str| NaiveTime::parse_from_str(step.text(key), "%H:%M").ok();
    let inside = match (parse("from"), parse("to")) {
        (Some(from), Some(to)) if from <= to => time >= from && time < to,
        (Some(from), Some(to)) => time >= from || time < to,
        (Some(from), None) => time >= from,
        (None, Some(to)) => time < to,
        (None, None) => true,
    };
    verdict(inside, format!("{} {}", now.weekday(), time.format("%H:%M")))
}

/// `*` within a path segment, `**` across segments, `?` one character.
pub fn glob(pattern: &str, text: &str) -> bool {
    let mut regex = String::from("^");
    let chars: Vec<char> = pattern.trim().chars().collect();
    let mut i = 0;
    while i < chars.len() {
        match chars[i] {
            '*' if chars.get(i + 1) == Some(&'*') => {
                i += 1;
                if chars.get(i + 1) == Some(&'/') {
                    i += 1;
                    regex.push_str("(?:.*/)?");
                } else {
                    regex.push_str(".*");
                }
            }
            '*' => regex.push_str("[^/]*"),
            '?' => regex.push_str("[^/]"),
            c => regex.push_str(&regex::escape(&c.to_string())),
        }
        i += 1;
    }
    regex.push('$');
    Regex::new(&regex).is_ok_and(|r| r.is_match(text))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn globs_follow_path_segments() {
        assert!(glob("release/*", "release/1.2"));
        assert!(!glob("release/*", "release/1.2/hotfix"));
        assert!(glob("dependabot/**", "dependabot/npm/foo-1.2"));
        assert!(glob("**/*.strings", "App/en.lproj/Localizable.strings"));
        assert!(glob("**/*.strings", "Localizable.strings"));
        assert!(glob("main", "main"));
        assert!(!glob("main", "maint"));
    }

    #[test]
    fn ci_state_reads_the_lean_summary() {
        assert_eq!(ci_state(&json!({"ci":{"status":"completed","conclusion":"success"}})), "passing");
        assert_eq!(ci_state(&json!({"ci":{"status":"completed","conclusion":"failure"}})), "failing");
        assert_eq!(ci_state(&json!({"ci":{"status":"in_progress","conclusion":null}})), "pending");
        assert_eq!(ci_state(&json!({"ci":null})), "none");
    }

    #[test]
    fn time_windows_handle_days_and_overnight_ranges() {
        let step = |params: Value| Step { params: params.as_object().unwrap().clone(), ..Default::default() };
        let at = |d: u32, h: u32| chrono::NaiveDate::from_ymd_opt(2026, 9, d).unwrap().and_hms_opt(h, 0, 0).unwrap();
        // 2026-09-21 is a Monday.
        let office = step(json!({"days":"mon, tue, wed, thu, fri","from":"09:00","to":"18:00"}));
        assert!(time_window(&office, at(21, 10)).passed);
        assert!(!time_window(&office, at(21, 19)).passed);
        assert!(!time_window(&office, at(26, 10)).passed);
        let night = step(json!({"from":"22:00","to":"06:00"}));
        assert!(time_window(&night, at(21, 23)).passed);
        assert!(time_window(&night, at(21, 5)).passed);
        assert!(!time_window(&night, at(21, 12)).passed);
    }

    #[test]
    fn validation_rejects_bad_regex_and_times() {
        let step = |node: &str, params: Value| Step { node: node.into(), params: params.as_object().unwrap().clone(), ..Default::default() };
        assert!(validate(&step("pr.title", json!({"regex":"(unclosed"}))).is_err());
        assert!(validate(&step("pr.title", json!({"regex":"^chore"}))).is_ok());
        assert!(validate(&step("time.window", json!({"from":"9am"}))).is_err());
        assert!(validate(&step("time.window", json!({"days":"funday"}))).is_err());
    }
}
