use crate::agents::{usage::ccusage, Agent};
use crate::AppState;
use axum::{extract::State, Json};
use chrono::Utc;
use serde_json::{json, Value};
use std::{
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
            // Each agent's CLI reads its own; a read that fails keeps what was read before.
            let agents = futures_util::future::join_all(
                Agent::ALL.map(|agent| async move { (agent, tokio::join!(agent.usage(), agent.limits())) }),
            );
            let (agents, block) = tokio::join!(agents, active_block());
            let mut state = app.usage.state.lock().unwrap();
            let previous = state.value.clone();
            let mut value = state.value.take().unwrap_or_else(empty);
            for (agent, (usage, limits)) in agents {
                let entry = &mut value["agents"][agent.profile().id];
                for (name, result) in [("usage", usage), ("limits", limits)] {
                    match result {
                        Some(result) => entry[name] = result,
                        None if entry.get(name).is_none() => entry[name] = Value::Null,
                        None => {}
                    }
                }
            }
            if let Some(block) = block {
                value["block"] = block;
            }
            // `asOf` moves on every read; the app hears only about use or limits that changed.
            let changed = previous
                .as_ref()
                .is_none_or(|old| old["agents"] != value["agents"] || old["block"] != value["block"]);
            value["asOf"] = json!(Utc::now().to_rfc3339());
            state.value = Some(value);
            state.fetched = Some(Instant::now());
            state.busy = false;
            drop(state);
            if changed {
                app.publish(crate::Event::Sync { scope: Some("usage"), project_id: None });
            }
        });
    }
    Json(state.value.clone().unwrap_or_else(empty))
}

/// `{"agents":{id:{"usage","limits"}},"block","asOf"}`: each agent's CLI under its own id.
fn empty() -> Value {
    json!({"agents":{},"block":null,"asOf":null})
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
