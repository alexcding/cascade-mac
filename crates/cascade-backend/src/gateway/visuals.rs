//! `synara_show_visual`: Synara's `apps/server/src/agentGateway/inlineVisualTools.ts`. A chat's
//! agent publishes a visual into its own running turn, shown inline in its reply: usually a
//! component spec the page draws with Synara's components, or a self-contained HTML document for
//! anything the spec cannot express, run in a sandboxed frame. The source is stored
//! (`visuals/store.rs`) and the turn gets a small `visual.shown` activity; the page fetches the
//! source by id over `orchestration.getInlineVisual` (`chat.rs`).
//!
//! The tool keeps Synara's name, description, limits, ids, activity and fence, so the page's
//! vendored components read what it records unchanged. It is offered to a chat's CLI only: no
//! page shows a terminal agent's turn.

mod formula;
mod spec;
pub mod store;

use std::{
    collections::{HashMap, HashSet, VecDeque},
    future::Future,
    path::PathBuf,
    sync::{Arc, LazyLock},
};

use cascade_chat::{
    contracts::{
        base::{now_iso, CommandId, ThreadId, TurnId},
        orchestration::OrchestrationThreadActivity,
    },
    ChatError,
};
use serde_json::{json, Value};

use super::{Caller, Tool, ToolDefinition, ToolFuture, ToolResult};
use crate::AppState;

// Synara `packages/contracts/src/inlineVisual.ts`.
pub const TOOL_NAME: &str = "synara_show_visual";
pub const ACTIVITY_KIND: &str = "visual.shown";
pub const EMBED_FENCE: &str = "synara-visual";
/// Kept well under the gateway's 1 MiB request limit, since JSON escaping can double HTML.
pub const MAX_HTML_BYTES: usize = 256 * 1024;
pub const MAX_TITLE_LENGTH: usize = 120;
pub const MIN_HEIGHT: i64 = 80;
pub const MAX_HEIGHT: i64 = 1600;
pub const DEFAULT_HEIGHT: i64 = 320;

/// A turn that keeps publishing visuals is almost certainly looping; refuse past this.
pub const PER_TURN_LIMIT: usize = 6;
const TRACKED_TURNS_MAX: usize = 512;

/// Synara `harnessPolicy.ts`'s inline-visuals line, given as the server's instructions.
const INSTRUCTIONS: &str =
    "When a chart, table, or comparison says more than prose, call synara_show_visual and place its block in your reply.";

/// What a call made without a running turn is told (Synara `assertCallerTurnActive`).
const TURN_INACTIVE: &str =
    "This write was rejected because this chat had no active turn when the MCP request arrived.";

fn description() -> String {
    let fence = EMBED_FENCE;
    [
        "Show a finished visual - stats, a chart, a table, a comparison, a checklist, a small calculator, or follow-up choices - inside your reply, as part of the answer. Use it only when a visual reads faster than text.".to_owned(),
        format!("Call it before writing the reply. The result gives a short ```{fence} fenced block: write that block in your reply on its own lines exactly where the visual belongs, like a paragraph, with your text before and after it. A visual you do not place shows above the reply."),
        "The reader sees the visual, so keep the text around it brief: state the key finding in words and do not describe the visual or say where it is.".to_owned(),
        "Send blocks: a list of components the app draws with its own design system, in its theme and font size. Use blocks for everything they can express; the title is not shown.".to_owned(),
        "Block types (field? is optional): ".to_owned() +
            "markdown {text} short prose, lists, links, or a code fence. " +
            "stats {items:[{label, value, detail?, trend?: up|down|flat, tone?}]} 1-6 headline numbers as tiles. " +
            "bar-chart {title?, unit?, items:[{label, value, baseline?, highlight?}], sort?: none|value, baselineLabel?, valueLabel?, better?: lower|higher} horizontal bars; highlight the one that matters. For before/after, give each item its old value as baseline and its new value as value instead of separate before and after bars; name them with baselineLabel and valueLabel, and set better so changes are colored. " +
            "line-chart {title?, unit?, labels:[x labels], series:[{name, values:[number|null, one per label]}]} trends over time. " +
            "table {title?, columns:[{label, format?: text|number|percent}], rows:[[cell per column]], highlightRow?} cells are strings, numbers, or null. " +
            "list {title?, style?: bullets|numbered|checklist|steps, items:[{title, detail?, status?: done|current|pending|failed, tone?}]} a checklist the reader can tick, or steps on a progress rail. " +
            "callout {tone?: info|success|warning|danger, title?, text} one important note. " +
            "compare {options:[{title, subtitle?, highlight?, points:[{label, value}]}]} 2-4 options side by side; use the same point labels in each and highlight the recommended one. " +
            "calculator {title?, inputs:[{id, label, value, min?, max?, step?, unit?}], outputs:[{id?, label, formula, prefix?, unit?, decimals?, emphasis?}]} live results as the reader edits inputs; formulas use input ids and the ids of outputs above them, + - * / % ^, parentheses, and min max round floor ceil abs sqrt. " +
            "choices {prompt?, options:[{label, description?, message?}]} 1-6 next steps; a click sends message (default label) as the reader's next message. " +
            "tabs {tabs:[{label, blocks:[...]}]} 2-6 views of the same subject; tabs hold any block except tabs.",
        "tone is neutral, accent, success, warning, or danger: accent marks the one thing that matters, the rest are statuses. Keep labels short, put units in unit instead of every value, and order blocks as the reader should read them: the answer first, then detail.".to_owned(),
        "Send html instead of blocks only for what blocks cannot draw, such as a diagram, a map, or a custom interactive view: one complete, self-contained HTML document with inline <style> and <script>.".to_owned(),
        "Network loads are blocked: fetch, remote URLs, external scripts, fonts, and images do not load. Draw with inline SVG, canvas, or HTML, and embed images as data: URIs.".to_owned(),
        "Link clicks open http(s) URLs in the reader's browser. Navigating the frame stops the visual; the page cannot open windows or show dialogs, and storage is in-memory only.".to_owned(),
        "Placement: borderless on the chat background, left-aligned with your reply text, as wide as the reply column (728px on desktop, about 360px on phones). Start the page with a short h3 when it needs a heading. No outer card, border, padding, banner, or page background.".to_owned(),
        "Base styles already match the app: text at --font-size, h1-h4, p, small, hr, tables, and buttons, inputs, selects, checkboxes, and ranges with a visible focus ring. Helpers: class num right-aligns numbers; muted is secondary text; a .segmented group of buttons with aria-pressed is a segmented control; .tag with data-tone accent, success, warning, or danger is a status tag.".to_owned(),
        "Theme variables on :root follow the app's theme live: --background --foreground --muted-foreground --secondary --border --rule (hairlines) --surface (a faint panel fill) --primary --primary-foreground --success --warning --destructive --ring --radius --font-sans --font-mono --font-size, and for data --chart-accent --chart-muted --chart-grid --series-1 to --series-6.".to_owned(),
        "Use one accent (--chart-accent) for what matters and --chart-muted for the rest. Size by content, not the column: draw inline SVG at its viewBox size (max-width:100%;height:auto) and never use preserveAspectRatio=\"none\". Keep text at the inherited size and never under 11px.".to_owned(),
        "Diagrams: nodes are rounded boxes with --surface fill and a --rule outline, edges in --muted-foreground with arrowheads, at most one highlighted node in --chart-accent; lay them out left to right and stack them below about 560px.".to_owned(),
        "Let content set the page's height: no 100vh; the frame grows to fit. Respect prefers-reduced-motion.".to_owned(),
    ]
    .join(" ")
}

const MAX_SPEC_BYTES_KIB: usize = spec::MAX_SPEC_BYTES / 1024;

static DEFINITION: LazyLock<ToolDefinition> = LazyLock::new(|| ToolDefinition {
    name: TOOL_NAME,
    description: description(),
    input_schema: json!({
        "type": "object",
        "properties": {
            "title": {
                "type": "string",
                "minLength": 1,
                "maxLength": MAX_TITLE_LENGTH,
                "description": "Short name for the visual; also its accessible name.",
            },
            "blocks": {
                "type": "array",
                "minItems": 1,
                "description": format!("Components to draw, in reading order (see the tool description). At most {MAX_SPEC_BYTES_KIB} KiB as JSON. Send this or html."),
                "items": {
                    "type": "object",
                    "properties": { "type": { "type": "string", "enum": spec::BLOCK_TYPES } },
                    "required": ["type"],
                },
            },
            "html": {
                "type": "string",
                "minLength": 1,
                "description": format!("Only when blocks cannot express the visual: one complete, self-contained HTML document, at most {} KiB.", MAX_HTML_BYTES / 1024),
            },
            "height": {
                "type": "integer",
                "minimum": MIN_HEIGHT,
                "maximum": MAX_HEIGHT,
                "description": format!("html only: expected height in CSS pixels at the 728px column. Space is reserved at this height until the page reports its own. Defaults to {DEFAULT_HEIGHT}."),
            },
        },
        "required": ["title"],
        "additionalProperties": false,
    }),
    annotations: json!({
        "title": "Show a visual",
        "readOnlyHint": false,
        "destructiveHint": false,
        "idempotentHint": true,
        "openWorldHint": false,
    }),
});

/// Synara `InlineVisualDraft`.
struct Draft {
    title: String,
    format: &'static str,
    /// What is stored: the normalized spec JSON, or the HTML document.
    source: String,
    height: i64,
    byte_length: usize,
}

/// Synara `readInlineVisualDraft`: the call's arguments as a visual, or why not.
fn read_draft(args: &Value) -> Result<Draft, String> {
    let not_empty = "Argument \"title\" must be a non-empty string.";
    let raw_title = args.get("title").and_then(Value::as_str).ok_or(not_empty)?;
    // Control characters would render as junk in the transcript label.
    let title = raw_title
        .chars()
        .map(|c| if c.is_control() || c.is_whitespace() { ' ' } else { c })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if title.is_empty() {
        return Err(not_empty.into());
    }
    if title.encode_utf16().count() > MAX_TITLE_LENGTH {
        return Err(format!("Argument \"title\" must be at most {MAX_TITLE_LENGTH} characters."));
    }
    let present = |key: &str| args.get(key).is_some_and(|value| !value.is_null());
    let (has_blocks, has_html) = (present("blocks"), present("html"));
    if has_blocks == has_html {
        return Err("Send exactly one of \"blocks\" or \"html\".".into());
    }
    if has_blocks {
        let blocks = read_spec_blocks(&args["blocks"])?;
        let height = estimate_spec_height(&blocks);
        let source = json!({ "blocks": blocks }).to_string();
        let byte_length = source.len();
        if byte_length > spec::MAX_SPEC_BYTES {
            return Err(format!(
                "The blocks are {} KiB; the limit is {MAX_SPEC_BYTES_KIB} KiB. Show fewer rows or points.",
                byte_length.div_ceil(1024)
            ));
        }
        return Ok(Draft { title, format: "components", source, height, byte_length });
    }
    let html = args["html"].as_str().filter(|html| !html.trim().is_empty());
    let html = html.ok_or("Argument \"html\" must be a non-empty HTML document.")?;
    let byte_length = html.len();
    if byte_length > MAX_HTML_BYTES {
        return Err(format!(
            "The page is {} KiB; the limit is {} KiB. Remove embedded data or simplify the page.",
            byte_length.div_ceil(1024),
            MAX_HTML_BYTES / 1024
        ));
    }
    // Synara `readNumberArg`.
    let height = match args.get("height") {
        None | Some(Value::Null) => None,
        Some(value) => Some(value.as_f64().ok_or("Argument \"height\" must be a number.")?),
    };
    Ok(Draft { title, format: "html", source: html.to_owned(), height: clamp_height(height), byte_length })
}

/// Synara `clampHeight`. JavaScript's `Math.round` rounds a half up.
fn clamp_height(height: Option<f64>) -> i64 {
    let rounded = (height.unwrap_or(DEFAULT_HEIGHT as f64) + 0.5).floor();
    (rounded.clamp(MIN_HEIGHT as f64, MAX_HEIGHT as f64)) as i64
}

/// Synara `readSpecBlocks`: the schema checks shapes; this adds the rules that span fields, so a
/// spec that passes always renders as the agent meant. Errors name the block path.
fn read_spec_blocks(raw: &Value) -> Result<Vec<Value>, String> {
    let blocks = spec::decode_blocks(raw)
        .map_err(|error| format!("Invalid blocks: {error}\nBlock types: {}.", spec::BLOCK_TYPES.join(", ")))?;
    fn check(block: &Value, path: &str) -> Result<(), String> {
        let fail = |message: String| Err(format!("Invalid blocks: {message}\n  at {path}"));
        let array = |key: &str| block[key].as_array().cloned().unwrap_or_default();
        match block["type"].as_str() {
            Some("line-chart") => {
                let labels = array("labels").len();
                for (index, series) in array("series").iter().enumerate() {
                    let values = series["values"].as_array().map_or(0, Vec::len);
                    if values != labels {
                        let name = series["name"].as_str().unwrap_or_default();
                        return fail(format!("series {index} \"{name}\" has {values} values for {labels} labels"));
                    }
                }
            }
            Some("table") => {
                let columns = array("columns").len();
                let rows = array("rows");
                for (index, row) in rows.iter().enumerate() {
                    let cells = row.as_array().map_or(0, Vec::len);
                    if cells != columns {
                        return fail(format!("row {index} has {cells} cells for {columns} columns"));
                    }
                }
                if let Some(highlight) = block["highlightRow"].as_f64() {
                    if highlight >= rows.len() as f64 {
                        return fail(format!("highlightRow {highlight} is past the last row"));
                    }
                }
            }
            Some("calculator") => {
                let mut ids: HashSet<String> = HashSet::new();
                for input in array("inputs") {
                    let id = input["id"].as_str().unwrap_or_default().to_owned();
                    if !ids.insert(id.clone()) {
                        return fail(format!("id \"{id}\" is used twice"));
                    }
                    if let (Some(min), Some(max)) = (input["min"].as_f64(), input["max"].as_f64()) {
                        if min > max {
                            return fail(format!("input \"{id}\" has min above max"));
                        }
                    }
                }
                // Outputs read inputs and the outputs above them, in order.
                for output in array("outputs") {
                    let label = output["label"].as_str().unwrap_or_default();
                    if let Err(error) = formula::compile(output["formula"].as_str().unwrap_or_default(), &ids) {
                        return fail(format!("formula of \"{label}\": {error}"));
                    }
                    if let Some(id) = output["id"].as_str() {
                        if !ids.insert(id.to_owned()) {
                            return fail(format!("id \"{id}\" is used twice"));
                        }
                    }
                }
            }
            Some("tabs") => {
                for (tab_index, tab) in array("tabs").iter().enumerate() {
                    for (index, child) in tab["blocks"].as_array().cloned().unwrap_or_default().iter().enumerate() {
                        check(child, &format!("{path}.tabs[{tab_index}].blocks[{index}]"))?;
                    }
                }
            }
            _ => {}
        }
        Ok(())
    }
    for (index, block) in blocks.iter().enumerate() {
        check(block, &format!("blocks[{index}]"))?;
    }
    Ok(blocks)
}

/// Synara `estimateSpecHeight`: space held while the spec loads, so the transcript grows once
/// rather than jumping.
fn estimate_spec_height(blocks: &[Value]) -> i64 {
    const GAP: i64 = 16;
    fn len(block: &Value, key: &str) -> i64 {
        block[key].as_array().map_or(0, |items| items.len() as i64)
    }
    fn items(block: &Value, key: &str) -> Vec<Value> {
        block[key].as_array().cloned().unwrap_or_default()
    }
    fn estimate(block: &Value) -> i64 {
        let titled = if block.get("title").is_some() { 28 } else { 0 };
        match block["type"].as_str().unwrap_or_default() {
            "markdown" => {
                let text = block["text"].as_str().unwrap_or_default().encode_utf16().count() as i64;
                24 * ((text + 89) / 90).max(1)
            }
            "stats" => 88,
            "bar-chart" => {
                let baselines = items(block, "items").iter().any(|item| item.get("baseline").is_some());
                titled + len(block, "items") * if baselines { 40 } else { 28 }
            }
            "line-chart" => titled + 220,
            "table" => titled + 36 + len(block, "rows").min(12) * 34,
            "list" => {
                let detailed = items(block, "items").iter().any(|item| item.get("detail").is_some());
                titled + len(block, "items") * if detailed { 48 } else { 30 }
            }
            "callout" => 64,
            "compare" => 72 + items(block, "options").iter().map(|option| len(option, "points")).max().unwrap_or(0) * 28,
            "calculator" => titled + 32 + len(block, "inputs") * 52 + len(block, "outputs") * 32,
            "choices" => (if block.get("prompt").is_some() { 28 } else { 0 }) + len(block, "options") * 36,
            "tabs" => {
                44 + items(block, "tabs")
                    .iter()
                    .map(|tab| items(tab, "blocks").iter().map(|child| estimate(child) + GAP).sum::<i64>() - GAP)
                    .max()
                    .unwrap_or(0)
            }
            _ => 0,
        }
    }
    let total = blocks.iter().map(|block| estimate(block) + GAP).sum::<i64>() - GAP;
    clamp_height(Some(total as f64))
}

/// Synara `canonicalJson` of the digest's fields: keys sorted, strings as JSON writes them.
fn stable_digest(fields: &[(&str, Value)]) -> String {
    let mut sorted: Vec<&(&str, Value)> = fields.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(b.0));
    let body: Vec<String> = sorted.iter().map(|(key, value)| format!("{}:{}", json!(key), value)).collect();
    let canonical = format!("{{{}}}", body.join(","));
    store::sha256_hex(canonical.as_bytes())[..32].to_owned()
}

/// What the tool records on the caller's thread (Synara `AppendInlineVisualActivityInput`).
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Appended {
    pub thread_id: String,
    pub turn_id: String,
    /// Stable for identical content in the same turn, so a retried call is the same row.
    pub digest: String,
    /// Synara `InlineVisualActivityPayload`.
    pub payload: Value,
}

/// Why the visual's row was not recorded.
#[derive(Debug)]
pub(crate) enum AppendError {
    /// The turn ended (or another started) while the page was saved: Synara `assertCallerTurnActive`.
    TurnInactive(String),
    Failed(String),
}

fn error_text(message: impl Into<String>) -> ToolResult {
    let mut result = ToolResult::text(message);
    result.is_error = true;
    result
}

/// Visual ids published per running turn. In memory only: a restart resets the count, which is
/// fine for a guard against a looping agent.
#[derive(Default)]
struct Turns {
    visuals: HashMap<String, HashSet<String>>,
    order: VecDeque<String>,
}

impl Turns {
    fn of(&mut self, key: &str) -> &mut HashSet<String> {
        if !self.visuals.contains_key(key) {
            while self.visuals.len() >= TRACKED_TURNS_MAX {
                let Some(oldest) = self.order.pop_front() else { break };
                self.visuals.remove(&oldest);
            }
            self.order.push_back(key.to_owned());
        }
        self.visuals.entry(key.to_owned()).or_default()
    }
}

/// The publication, apart from the engine: Synara's handler with its publication lock. Held
/// through creation, activity append and rollback, so overlapping retries never delete a document
/// a successful publication references.
#[derive(Default)]
pub(crate) struct Publisher {
    turns: tokio::sync::Mutex<Turns>,
}

impl Publisher {
    pub(crate) async fn publish<F, Fut>(&self, attachments: PathBuf, thread_id: &str, turn_id: &str, args: &Value, append: F) -> ToolResult
    where
        F: FnOnce(Appended) -> Fut,
        Fut: Future<Output = Result<(), AppendError>>,
    {
        let mut turns = self.turns.lock().await;
        let draft = match read_draft(args) {
            Ok(draft) => draft,
            Err(message) => return error_text(message),
        };
        let sha256 = store::sha256_hex(draft.source.as_bytes());
        let digest = stable_digest(&[
            ("kind", json!("inline-visual")),
            ("threadId", json!(thread_id)),
            ("turnId", json!(turn_id)),
            ("sha256", json!(sha256)),
            ("title", json!(draft.title)),
            ("height", json!(draft.height)),
        ]);
        let visual_id = format!("vis_{digest}");
        let turn_key = format!("{thread_id}\u{0}{turn_id}");
        let published = turns.of(&turn_key);
        if !published.contains(&visual_id) && published.len() >= PER_TURN_LIMIT {
            return error_text(format!(
                "This turn already shows {PER_TURN_LIMIT} visuals. Combine them into one visual instead."
            ));
        }

        let stored = {
            let (attachments, thread_id, visual_id, source) =
                (attachments.clone(), thread_id.to_owned(), visual_id.clone(), draft.source.clone());
            tokio::task::spawn_blocking(move || store::write(&attachments, &thread_id, &visual_id, &source)).await
        };
        let (file, existed) = match stored {
            Ok(Ok(stored)) => stored,
            Ok(Err(error)) => return error_text(format!("The visual could not be saved: {error}")),
            Err(error) => return error_text(format!("The visual could not be saved: {error}")),
        };
        // Only a file this call created is removed on failure: an identical retry shares the id,
        // and its earlier success must keep its page.
        let discard_new_file = || async {
            if !existed {
                let _ = tokio::task::spawn_blocking(move || {
                    let _ = std::fs::remove_file(&file);
                    // A thread deleted while this call wrote may have had its folder made again
                    // by the write: removed when empty, kept when it holds other visuals.
                    if let Some(folder) = file.parent() {
                        let _ = std::fs::remove_dir(folder);
                    }
                })
                .await;
            }
        };

        let appended = Appended {
            thread_id: thread_id.to_owned(),
            turn_id: turn_id.to_owned(),
            digest: digest.clone(),
            payload: json!({
                "visualId": visual_id,
                "format": draft.format,
                "title": draft.title,
                "height": draft.height,
                "byteLength": draft.byte_length,
                "sha256": sha256,
            }),
        };
        // The engine checks the turn still runs as it appends: Stop may have ended it while the
        // page was written, and a stopped turn must not gain a row.
        match append(appended).await {
            Ok(()) => {}
            Err(AppendError::TurnInactive(message)) => {
                discard_new_file().await;
                return error_text(message);
            }
            Err(AppendError::Failed(cause)) => {
                discard_new_file().await;
                return error_text(format!("The visual could not be shown: {cause}"));
            }
        }
        turns.of(&turn_key).insert(visual_id.clone());
        let embed = format!("```{EMBED_FENCE}\n{visual_id}\n```");
        ToolResult::json(&json!({
            "visualId": visual_id,
            "title": draft.title,
            "embed": embed,
            "message": format!("Place the visual in your reply by writing this block on its own lines where it belongs:\n{embed}\nState the key finding in words around it; do not describe the visual or say where it is."),
        }))
    }
}

/// The tool, as the gateway serves it.
#[derive(Default)]
pub struct ShowVisual {
    publisher: Arc<Publisher>,
}

impl Tool for ShowVisual {
    fn definition(&self) -> &ToolDefinition {
        &DEFINITION
    }

    fn instructions(&self) -> Option<&'static str> {
        Some(INSTRUCTIONS)
    }

    fn offered_to(&self, state: &AppState, caller: &Caller) -> bool {
        matches!(caller, Caller::Chat { .. }) && state.chat.engine().is_some()
    }

    fn call(&self, state: AppState, caller: Caller, arguments: Value) -> ToolFuture {
        let publisher = self.publisher.clone();
        Box::pin(async move {
            let Caller::Chat { thread_id } = caller else {
                return ToolResult::error("caller_not_chat", "Visuals are shown in a chat.");
            };
            let (Some(engine), Some(attachments)) = (state.chat.engine().cloned(), state.chat.attachments_dir()) else {
                return ToolResult::error("unavailable", "Chats are not available.");
            };
            // Synara `requiresActiveTurn`: the call's authority is the turn running when it came.
            let turn = match engine.running_turn(ThreadId::new(thread_id.clone())).await {
                Ok(Some(turn)) => turn,
                _ => return ToolResult::error("caller_turn_inactive", TURN_INACTIVE),
            };
            publisher
                .publish(attachments, &thread_id, turn.as_str(), &arguments, |appended| async move {
                    let created_at = now_iso();
                    let title = appended.payload["title"].as_str().unwrap_or_default().to_owned();
                    let activity: OrchestrationThreadActivity = serde_json::from_value(json!({
                        "id": format!("gateway:{}:inline-visual", appended.digest),
                        "tone": "info",
                        "kind": ACTIVITY_KIND,
                        "summary": format!("Visual: {title}"),
                        "payload": appended.payload,
                        "turnId": appended.turn_id,
                        "createdAt": created_at,
                    }))
                    .map_err(|error| AppendError::Failed(error.to_string()))?;
                    engine
                        .append_turn_activity(
                            ThreadId::new(appended.thread_id),
                            TurnId::new(appended.turn_id),
                            CommandId::new(format!("agent:{}:inline-visual", appended.digest)),
                            activity,
                        )
                        .await
                        .map_err(|error| match error {
                            ChatError::Invalid(message) => AppendError::TurnInactive(message),
                            ChatError::Internal(error) => AppendError::Failed(format!("{error:#}")),
                        })
                })
                .await
        })
    }
}

#[cfg(test)]
mod tests;
