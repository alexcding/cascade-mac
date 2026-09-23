use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// A pipeline: one trigger, then an ordered chain of filters and actions. Stored as JSON so a
/// later canvas editor can add branching step kinds without touching the table.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Automation {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub mode: Mode,
    /// When the pipeline last left `off`. Events that happened before it never fire, so turning
    /// a pipeline on does not act on every PR that already matched.
    #[serde(default)]
    pub armed_at: Option<String>,
    #[serde(default)]
    pub trigger: Trigger,
    #[serde(default)]
    pub steps: Vec<Step>,
    #[serde(default)]
    pub position: i64,
    #[serde(default)]
    pub created_at: String,
    #[serde(default)]
    pub updated_at: String,
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    /// A pipeline saved in the retired watch-only mode reads as off: it never acted, so it does
    /// not start acting now. Dry runs are how a pipeline is tried before it is switched on.
    #[default]
    #[serde(alias = "shadow")]
    Off,
    Live,
}

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Off => "off",
            Mode::Live => "live",
        }
    }
    pub fn parse(value: &str) -> Self {
        match value {
            "live" => Mode::Live,
            _ => Mode::Off,
        }
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Trigger {
    /// Any of these event kinds starts a run.
    #[serde(default)]
    pub types: Vec<String>,
    /// Project IDs a PR event must belong to; empty means every project.
    #[serde(default)]
    pub projects: Vec<String>,
    #[serde(default)]
    pub params: Map<String, Value>,
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum StepKind {
    #[default]
    Filter,
    Action,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Step {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub kind: StepKind,
    #[serde(rename = "type", default)]
    pub node: String,
    #[serde(default)]
    pub params: Map<String, Value>,
    /// An action whose failure is recorded but does not stop the actions after it.
    #[serde(rename = "continueOnError", default)]
    pub continue_on_error: bool,
}

impl Step {
    pub fn text(&self, key: &str) -> &str {
        self.params.get(key).and_then(Value::as_str).unwrap_or("").trim()
    }
    pub fn flag(&self, key: &str) -> bool {
        self.params.get(key).and_then(Value::as_bool).unwrap_or(false)
    }
    pub fn number(&self, key: &str) -> Option<i64> {
        match self.params.get(key) {
            Some(Value::Number(n)) => n.as_i64(),
            Some(Value::String(s)) => s.trim().parse().ok(),
            _ => None,
        }
    }
    /// Where a Fix Version step takes its version from: `next` (the project's next unreleased
    /// version) or `template`. Steps from before the choice existed named a template.
    pub fn version_source(&self) -> &str {
        match self.text("source") {
            "" if !self.text("template").is_empty() => "template",
            "" => "next",
            other => other,
        }
    }
    /// A list param, accepting either a JSON array or a comma/newline separated string.
    pub fn list(&self, key: &str) -> Vec<String> {
        list_value(self.params.get(key))
    }
}

pub fn list_value(value: Option<&Value>) -> Vec<String> {
    let items: Vec<String> = match value {
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect(),
        Some(Value::String(text)) => text.split([',', '\n']).map(str::to_owned).collect(),
        _ => Vec::new(),
    };
    items
        .into_iter()
        .map(|v| v.trim().to_owned())
        .filter(|v| !v.is_empty())
        .collect()
}

/// Something that happened, which pipelines may react to.
#[derive(Clone, Debug)]
pub struct Event {
    pub kind: String,
    /// Stable identity for the ledger: the same key never fires the same pipeline twice.
    pub key: String,
    pub at: DateTime<Utc>,
    pub project: Value,
    pub pr: Option<Value>,
    pub ticket: Option<Value>,
}

impl Event {
    pub fn repo(&self) -> &str {
        self.pr
            .as_ref()
            .and_then(|pr| pr["repo"].as_str())
            .filter(|v| !v.is_empty())
            .or_else(|| self.project["repo"].as_str())
            .unwrap_or("")
    }
    pub fn subject(&self) -> String {
        if let Some(pr) = &self.pr {
            format!(
                "{}#{} {}",
                self.repo(),
                pr["number"].as_i64().unwrap_or(0),
                pr["title"].as_str().unwrap_or("")
            )
        } else if let Some(ticket) = &self.ticket {
            format!(
                "{} {}",
                ticket["key"].as_str().unwrap_or(""),
                ticket["summary"].as_str().unwrap_or("")
            )
        } else {
            self.kind.clone()
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RunMode {
    Dry,
    Live,
}

impl RunMode {
    pub fn as_str(self) -> &'static str {
        match self {
            RunMode::Dry => "dry",
            RunMode::Live => "live",
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StepResult {
    pub step_id: String,
    pub node: String,
    pub label: String,
    /// `passed`, `failed` (a filter stopped the chain), `planned`, `done`, `error`, `skipped`.
    pub status: String,
    pub detail: String,
    pub commands: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Trace {
    pub automation_id: String,
    pub automation_name: String,
    pub event_kind: String,
    pub event_key: String,
    pub subject: String,
    pub mode: String,
    pub trigger_matched: bool,
    pub trigger_detail: String,
    /// `completed`, `filtered`, `error`, `limited`.
    pub status: String,
    pub steps: Vec<StepResult>,
    pub started_at: String,
    pub finished_at: String,
}
