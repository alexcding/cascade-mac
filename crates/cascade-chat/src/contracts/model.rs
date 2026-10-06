//! Ported from Synara `packages/contracts/src/model.ts`: the effort ladders and the Claude and
//! Codex model options. The static model catalogs (`MODEL_OPTIONS_BY_PROVIDER` and the
//! capability tables) are not ported: each adapter reports the models its CLI offers.

use serde::{Deserialize, Serialize};

use super::orchestration::ProviderKind;

/// Synara `CODEX_REASONING_EFFORT_OPTIONS` (model.ts:5)
pub const CODEX_REASONING_EFFORT_OPTIONS: &[&str] = &["low", "medium", "high", "xhigh"];
/// Synara `CLAUDE_API_EFFORT_OPTIONS` (model.ts:8)
pub const CLAUDE_API_EFFORT_OPTIONS: &[&str] = &["low", "medium", "high", "xhigh", "max"];
/// Synara `CLAUDE_PROMPT_MODE_OPTIONS` (model.ts:10)
pub const CLAUDE_PROMPT_MODE_OPTIONS: &[&str] = &["ultrathink"];
/// Synara `CLAUDE_CODE_MODE_OPTIONS` (model.ts:12)
pub const CLAUDE_CODE_MODE_OPTIONS: &[&str] = &["ultracode"];
/// Synara `CLAUDE_CODE_EFFORT_OPTIONS` (model.ts:14): the API efforts, then the prompt and code modes.
pub const CLAUDE_CODE_EFFORT_OPTIONS: &[&str] =
    &["low", "medium", "high", "xhigh", "max", "ultrathink", "ultracode"];
/// Synara `PI_THINKING_LEVEL_OPTIONS` (model.ts:20)
pub const PI_THINKING_LEVEL_OPTIONS: &[&str] =
    &["off", "minimal", "low", "medium", "high", "xhigh", "max"];
/// Synara `OMP_THINKING_LEVEL_OPTIONS` (model.ts:33)
pub const OMP_THINKING_LEVEL_OPTIONS: &[&str] =
    &["off", "auto", "minimal", "low", "medium", "high", "xhigh", "max"];
/// Synara `GROK_REASONING_EFFORT_OPTIONS` (model.ts:46)
pub const GROK_REASONING_EFFORT_OPTIONS: &[&str] = &["none", "low", "medium", "high", "xhigh"];
/// Synara `DROID_REASONING_EFFORT_OPTIONS` (model.ts:48)
pub const DROID_REASONING_EFFORT_OPTIONS: &[&str] =
    &["off", "none", "minimal", "low", "medium", "high", "xhigh", "max"];

/// Synara `ClaudeCodeEffort` (model.ts:19)
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ClaudeCodeEffort {
    Low,
    Medium,
    High,
    Xhigh,
    Max,
    Ultrathink,
    Ultracode,
}

/// Synara `ProviderOptionChoice` (model.ts:68). `isDefault` is `Literal(true)` there.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderOptionChoice {
    pub id: String,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_default: Option<bool>,
}

/// Synara `SelectProviderOptionDescriptor` (model.ts:82), without its `type` literal: the
/// [`ProviderOptionDescriptor`] it belongs to carries it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SelectProviderOptionDescriptor {
    pub id: String,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    pub options: Vec<ProviderOptionChoice>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_value: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt_injected_values: Option<Vec<String>>,
}

/// Synara `BooleanProviderOptionDescriptor` (model.ts:91), without its `type` literal.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BooleanProviderOptionDescriptor {
    pub id: String,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_value: Option<bool>,
}

/// Synara `ProviderOptionDescriptor` (model.ts:98)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ProviderOptionDescriptor {
    #[serde(rename = "select")]
    Select(SelectProviderOptionDescriptor),
    #[serde(rename = "boolean")]
    Boolean(BooleanProviderOptionDescriptor),
}

/// The `value` of a [`ProviderOptionSelection`]: Synara's `Union([TrimmedNonEmptyString, Boolean])`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ProviderOptionValue {
    Text(String),
    Flag(bool),
}

/// Synara `ProviderOptionSelection` (model.ts:104)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderOptionSelection {
    pub id: String,
    pub value: ProviderOptionValue,
}

/// Synara `ProviderOptionSelections` (model.ts:110)
pub type ProviderOptionSelections = Vec<ProviderOptionSelection>;

/// Synara `CodexModelOptions` (model.ts:113)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexModelOptions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning_effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fast_mode: Option<bool>,
}

/// Synara `ClaudeModelOptions` (model.ts:120)
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeModelOptions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thinking: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<ClaudeCodeEffort>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fast_mode: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_compact_window: Option<String>,
    /// Legacy persisted field; Synara's normalization migrates it to `autoCompactWindow`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_window: Option<String>,
}

/// Synara `ProviderModelOptions` (model.ts:180), Claude and Codex only.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderModelOptions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex: Option<CodexModelOptions>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claude_agent: Option<ClaudeModelOptions>,
}

/// Synara `DEFAULT_MODEL` (model.ts:1192)
pub const DEFAULT_MODEL: &str = "gpt-6-astra";

/// Synara `DEFAULT_MODEL_BY_PROVIDER` (model.ts:1180), the providers this crate drives.
pub fn default_model_by_provider(provider: ProviderKind) -> Option<&'static str> {
    match provider {
        ProviderKind::Codex => Some("gpt-6-astra"),
        ProviderKind::ClaudeAgent => Some("claude-sonnet-5"),
        _ => None,
    }
}
