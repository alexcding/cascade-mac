use crate::{cli, http_client, AppState};
use axum::{extract::State, Json};
use chrono::{Local, Utc};
use serde_json::{json, Value};
use std::{
    fs,
    io::{BufRead, BufReader},
    path::PathBuf,
    sync::Mutex,
    time::{Duration, Instant},
};

#[derive(Default)]
pub struct Usage {
    state: Mutex<Cache>,
}
#[derive(Default)]
struct Cache {
    value: Option<Value>,
    fetched: Option<Instant>,
    busy: bool,
}

pub async fn get(State(app): State<AppState>) -> Json<Value> {
    let mut state = app.usage.state.lock().unwrap();
    if !state.busy
        && state
            .fetched
            .is_none_or(|time| time.elapsed() > Duration::from_secs(300))
    {
        state.busy = true;
        let app = app.clone();
        tokio::spawn(async move {
            let (claude, codex, block, limits, codex_limits) = tokio::join!(
                agent_stats("claude"),
                agent_stats("codex"),
                active_block(),
                claude_limits(),
                codex_limits()
            );
            let mut state = app.usage.state.lock().unwrap();
            let mut value = state.value.take().unwrap_or_else(empty);
            for (name, result) in [
                ("claude", claude),
                ("codex", codex),
                ("block", block),
                ("limits", limits),
                ("codexLimits", codex_limits),
            ] {
                if let Some(result) = result {
                    value[name] = result;
                }
            }
            value["asOf"] = json!(Utc::now().to_rfc3339());
            state.value = Some(value);
            state.fetched = Some(Instant::now());
            state.busy = false;
            drop(state);
            app.broadcast(json!({"type":"sync","scope":"usage"}));
        });
    }
    Json(state.value.clone().unwrap_or_else(empty))
}

fn empty() -> Value {
    json!({"claude":null,"codex":null,"block":null,"limits":null,"codexLimits":null,"asOf":null})
}

async fn ccusage(args: &[&str]) -> Option<Value> {
    for (program, prefix) in [
        ("ccusage", vec![]),
        ("bunx", vec!["ccusage"]),
        ("npx", vec!["-y", "ccusage"]),
    ] {
        let arguments = prefix.into_iter().chain(args.iter().copied());
        if let Ok(raw) = cli::run(program, arguments, Duration::from_secs(30)).await {
            if let Ok(value) = serde_json::from_str(&raw) {
                return Some(value);
            }
        }
    }
    None
}

async fn agent_stats(agent: &str) -> Option<Value> {
    let today = Local::now().date_naive();
    let since = (today - chrono::Duration::days(29))
        .format("%Y%m%d")
        .to_string();
    let value = ccusage(&[agent, "daily", "--json", "--since", &since]).await?;
    let daily = value["daily"].as_array()?;
    let history: Vec<Value> = (0..30).rev().map(|days| {
        let date = (today - chrono::Duration::days(days)).to_string();
        let item = daily.iter().find(|v| v["date"] == date);
        json!({"date":date,"tokens":item.and_then(|v|v["totalTokens"].as_f64()).unwrap_or(0.0),
            "cost":item.and_then(|v|v["totalCost"].as_f64().or_else(||v["costUSD"].as_f64())).unwrap_or(0.0)})
    }).collect();
    let today = history.last()?;
    // The model that cost the most over the window, from ccusage's per-day model breakdowns.
    let mut by_model: std::collections::HashMap<String, f64> = std::collections::HashMap::new();
    for day in daily {
        for entry in day["modelBreakdowns"].as_array().into_iter().flatten() {
            let Some(name) = entry["modelName"].as_str() else { continue };
            let cost = entry["cost"].as_f64().or_else(|| entry["costUSD"].as_f64()).unwrap_or(0.0);
            *by_model.entry(name.to_owned()).or_default() += cost;
        }
    }
    let top_model = by_model
        .into_iter()
        .filter(|(_, cost)| *cost > 0.0)
        .max_by(|a, b| a.1.total_cmp(&b.1).then_with(|| b.0.cmp(&a.0)))
        .map(|(name, _)| name);
    Some(json!({"tokens":today["tokens"],"cost":today["cost"],"history":history,"topModel":top_model}))
}

async fn active_block() -> Option<Value> {
    let value = ccusage(&["blocks", "--active", "--json"]).await?;
    let block = value["blocks"]
        .as_array()?
        .iter()
        .find(|v| v["isActive"] == true)?;
    Some(
        json!({"startTime":block["startTime"],"endTime":block["endTime"],
        "tokens":block["totalTokens"],"cost":block["costUSD"],"projectedCost":block.pointer("/projection/totalCost")}),
    )
}

fn home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

async fn claude_limits() -> Option<Value> {
    let credentials = home()
        .and_then(|home| fs::read(home.join(".claude/.credentials.json")).ok())
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok());
    let token = credentials.and_then(|v| {
        v.pointer("/claudeAiOauth/accessToken")
            .and_then(Value::as_str)
            .map(str::to_owned)
    });
    let token = match token {
        Some(token) => token,
        None => {
            let raw = cli::run(
                "security",
                [
                    "find-generic-password",
                    "-s",
                    "Claude Code-credentials",
                    "-w",
                ],
                Duration::from_secs(10),
            )
            .await
            .ok()?;
            serde_json::from_str::<Value>(&raw)
                .ok()?
                .pointer("/claudeAiOauth/accessToken")?
                .as_str()?
                .to_owned()
        }
    };
    let value = http_client::request(
        "https://api.anthropic.com/api/oauth/usage",
        "GET",
        &[
            ("Authorization", format!("Bearer {token}")),
            ("anthropic-beta", "oauth-2025-04-20".into()),
        ],
        None,
        None,
    )
    .await
    .ok()?;
    let window = |v: &Value| {
        v["utilization"]
            .as_f64()
            .map(|pct| json!({"usedPct":pct.round().clamp(0.0,100.0),"resetsAt":v["resets_at"]}))
    };
    let session = window(&value["five_hour"]);
    let weekly = window(
        value
            .get("seven_day")
            .or_else(|| value.get("seven_day_overall"))
            .or_else(|| value.get("seven_day_oauth_apps"))
            .unwrap_or(&Value::Null),
    );
    let scoped: Vec<Value> = value["limits"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|v| {
            if v["kind"] != "weekly_scoped" {
                return None;
            }
            Some(
                json!({"label":v.pointer("/scope/model/display_name")?.as_str()?,
            "usedPct":v["percent"].as_f64()?.round().clamp(0.0,100.0),"resetsAt":v["resets_at"]}),
            )
        })
        .collect();
    if session.is_none() && weekly.is_none() && scoped.is_empty() {
        None
    } else {
        Some(json!({"session":session,"weekly":weekly,"scoped":scoped}))
    }
}

fn find_limits(value: &Value) -> Option<Value> {
    if let Some(value) = value.get("rate_limits").filter(|v| !v.is_null()) {
        return Some(value.clone());
    }
    match value {
        Value::Object(map) => map.values().find_map(find_limits),
        Value::Array(array) => array.iter().find_map(find_limits),
        _ => None,
    }
}

/// Codex's rate limits: live from its CLI, or failing that (no `codex`, signed out, offline) the
/// last ones a session log recorded.
async fn codex_limits() -> Option<Value> {
    match codex_live_limits().await {
        Some(limits) => Some(limits),
        None => tokio::task::spawn_blocking(codex_logged_limits).await.ok().flatten(),
    }
}

/// The limits as `codex app-server` reports them over JSON-RPC right now, the way Codex's own
/// apps read them. The CLI owns the sign-in, so nothing here touches its credentials.
async fn codex_live_limits() -> Option<Value> {
    let requests = concat!(
        r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"craft","version":"1"}}}"#,
        "\n",
        r#"{"jsonrpc":"2.0","method":"initialized"}"#,
        "\n",
        r#"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":true}}"#,
        "\n",
    );
    let is_reply = |line: &str| serde_json::from_str::<Value>(line).is_ok_and(|v| v["id"] == 2);
    let line = cli::first_line(
        "codex",
        ["-s", "read-only", "-a", "never", "app-server"],
        requests.as_bytes(),
        Duration::from_secs(15),
        is_reply,
    )
    .await
    .ok()?;
    let reply: Value = serde_json::from_str(&line).ok()?;
    let limits = &reply["result"]["rateLimits"];
    codex_windows([&limits["primary"], &limits["secondary"]], "usedPercent", "windowDurationMins", "resetsAt")
}

/// The last limits a session log recorded, from the newest log that has any. A session just
/// opened has none until its first turn, so this walks back through older logs rather than
/// report nothing.
fn codex_logged_limits() -> Option<Value> {
    let root = home()?.join(".codex/sessions");
    let logs = numbered(&root)
        .into_iter()
        .flat_map(|year| numbered(&year))
        .flat_map(|month| numbered(&month))
        .flat_map(|day| {
            let mut files: Vec<_> = fs::read_dir(day)
                .into_iter()
                .flatten()
                .filter_map(Result::ok)
                .filter(|entry| entry.path().extension().is_some_and(|e| e == "jsonl"))
                .map(|entry| (entry.metadata().and_then(|m| m.modified()).ok(), entry.path()))
                .collect();
            files.sort_by(|a, b| b.0.cmp(&a.0));
            files.into_iter().map(|(_, path)| path)
        });
    let value = logs.take(20).find_map(|path| latest_limits(&path))?;
    codex_windows([&value["primary"], &value["secondary"]], "used_percent", "window_minutes", "resets_at")
}

/// Codex's windows as session and weekly. Codex names them primary and secondary, and which is
/// weekly depends on the plan, so each goes by its length; one that gives no length goes by its
/// place. The log and the RPC spell the same fields differently, hence the keys.
fn codex_windows(windows: [&Value; 2], used: &str, minutes: &str, resets: &str) -> Option<Value> {
    let mut session = None;
    let mut weekly = None;
    for (index, window) in windows.into_iter().enumerate() {
        let Some(pct) = window[used].as_f64() else { continue };
        let entry = json!({"usedPct":pct.round().clamp(0.0,100.0),"resetsAt":window[resets].as_i64()
            .and_then(|seconds|chrono::DateTime::from_timestamp(seconds,0)).map(|date|date.to_rfc3339())});
        if window[minutes].as_i64().map_or(index == 1, |length| length >= 24 * 60) {
            weekly.get_or_insert(entry);
        } else {
            session.get_or_insert(entry);
        }
    }
    if session.is_none() && weekly.is_none() {
        None
    } else {
        Some(json!({"session":session,"weekly":weekly}))
    }
}

/// The digit-named directories under `directory`, newest first.
fn numbered(directory: &std::path::Path) -> Vec<PathBuf> {
    let mut entries: Vec<_> = fs::read_dir(directory)
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .filter(|entry| {
            entry.file_type().is_ok_and(|t| t.is_dir())
                && entry.file_name().to_string_lossy().bytes().all(|b| b.is_ascii_digit())
        })
        .map(|entry| entry.path())
        .collect();
    entries.sort_by(|a, b| b.cmp(a));
    entries
}

/// The last `rate_limits` a session log recorded.
fn latest_limits(path: &std::path::Path) -> Option<Value> {
    BufReader::new(fs::File::open(path).ok()?)
        .lines()
        .map_while(Result::ok)
        .filter(|line| line.contains("\"rate_limits\""))
        .filter_map(|line| serde_json::from_str::<Value>(&line).ok())
        .filter_map(|value| find_limits(&value))
        .last()
}

#[cfg(test)]
mod tests {
    use super::*;

    // Both spellings land in the same lanes, by window length: a lone seven-day window is
    // weekly even when Codex calls it primary.
    #[test]
    fn codex_windows_go_by_length() {
        let live = json!({"primary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1790551472},"secondary":null});
        let limits = codex_windows([&live["primary"], &live["secondary"]], "usedPercent", "windowDurationMins", "resetsAt").unwrap();
        assert!(limits["session"].is_null());
        assert_eq!(limits["weekly"]["usedPct"], 20.0);
        assert_eq!(limits["weekly"]["resetsAt"], "2026-09-27T23:24:32+00:00");

        let logged = json!({"primary":{"used_percent":41.6,"window_minutes":300},"secondary":{"used_percent":7,"window_minutes":10080}});
        let limits = codex_windows([&logged["primary"], &logged["secondary"]], "used_percent", "window_minutes", "resets_at").unwrap();
        assert_eq!(limits["session"]["usedPct"], 42.0);
        assert_eq!(limits["weekly"]["usedPct"], 7.0);

        let lengthless = json!({"primary":{"usedPercent":40,"windowDurationMins":null},"secondary":{"usedPercent":7}});
        let limits = codex_windows([&lengthless["primary"], &lengthless["secondary"]], "usedPercent", "windowDurationMins", "resetsAt").unwrap();
        assert_eq!(limits["session"]["usedPct"], 40.0);
        assert_eq!(limits["weekly"]["usedPct"], 7.0);

        assert!(codex_windows([&Value::Null, &Value::Null], "usedPercent", "windowDurationMins", "resetsAt").is_none());
    }
}
