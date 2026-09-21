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
                tokio::task::spawn_blocking(codex_limits)
            );
            let mut state = app.usage.state.lock().unwrap();
            let mut value = state.value.take().unwrap_or_else(empty);
            for (name, result) in [
                ("claude", claude),
                ("codex", codex),
                ("block", block),
                ("limits", limits),
                ("codexLimits", codex_limits.ok().flatten()),
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

fn codex_limits() -> Option<Value> {
    let mut directory = home()?.join(".codex/sessions");
    for _ in 0..3 {
        directory = fs::read_dir(&directory)
            .ok()?
            .filter_map(Result::ok)
            .filter(|entry| {
                entry.file_type().is_ok_and(|t| t.is_dir())
                    && entry
                        .file_name()
                        .to_string_lossy()
                        .bytes()
                        .all(|b| b.is_ascii_digit())
            })
            .max_by_key(|entry| entry.file_name())?
            .path();
    }
    let path = fs::read_dir(directory)
        .ok()?
        .filter_map(Result::ok)
        .filter(|entry| entry.path().extension().is_some_and(|e| e == "jsonl"))
        .max_by_key(|entry| entry.metadata().and_then(|m| m.modified()).ok())?
        .path();
    let mut latest = None;
    for line in BufReader::new(fs::File::open(path).ok()?)
        .lines()
        .map_while(Result::ok)
    {
        if !line.contains("\"rate_limits\"") {
            continue;
        }
        if let Ok(value) = serde_json::from_str::<Value>(&line) {
            if let Some(value) = find_limits(&value) {
                latest = Some(value);
            }
        }
    }
    let value = latest?;
    let window = |v: &Value| {
        v["used_percent"].as_f64().map(|pct|
        json!({"usedPct":pct.round().clamp(0.0,100.0),"resetsAt":v["resets_at"].as_i64()
            .and_then(|seconds|chrono::DateTime::from_timestamp(seconds,0)).map(|date|date.to_rfc3339())}))
    };
    let session = window(&value["primary"]);
    let weekly = window(&value["secondary"]);
    if session.is_none() && weekly.is_none() {
        None
    } else {
        Some(json!({"session":session,"weekly":weekly}))
    }
}
