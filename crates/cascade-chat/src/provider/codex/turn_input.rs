//! Ported from Synara `apps/server/src/codexTurnInput.ts`: the `input` array of a Codex
//! `turn/start` or `turn/steer`.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::contracts::provider::{ProviderMentionReference, ProviderSkillReference};

/// Synara `CodexImageInputItem` (codexTurnInput.ts:3)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum CodexImageInputItem {
    #[serde(rename = "image")]
    Image { url: String },
    #[serde(rename = "localImage")]
    LocalImage { path: String },
}

/// Synara `CodexTurnInputItem` (codexTurnInput.ts:7). `text_elements` is always empty; Synara
/// types it as the empty tuple.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum CodexTurnInputItem {
    #[serde(rename = "text")]
    Text { text: String, text_elements: Vec<Value> },
    #[serde(rename = "image")]
    Image { url: String },
    #[serde(rename = "localImage")]
    LocalImage { path: String },
    #[serde(rename = "skill")]
    Skill { name: String, path: String },
    #[serde(rename = "mention")]
    Mention { name: String, path: String },
}

impl From<CodexImageInputItem> for CodexTurnInputItem {
    fn from(item: CodexImageInputItem) -> Self {
        match item {
            CodexImageInputItem::Image { url } => Self::Image { url },
            CodexImageInputItem::LocalImage { path } => Self::LocalImage { path },
        }
    }
}

/// The input of Synara `buildCodexTurnInput` (codexTurnInput.ts:13).
#[derive(Clone, Copy, Debug, Default)]
pub struct CodexTurnInputParts<'a> {
    pub input: Option<&'a str>,
    pub attachments: Option<&'a [CodexImageInputItem]>,
    pub skills: Option<&'a [ProviderSkillReference]>,
    pub mentions: Option<&'a [ProviderMentionReference]>,
}

/// Synara `buildCodexTurnInput` (codexTurnInput.ts:13)
pub fn build_codex_turn_input(input: CodexTurnInputParts<'_>) -> Vec<CodexTurnInputItem> {
    let mut items = Vec::new();
    if let Some(text) = input.input.filter(|text| !text.is_empty()) {
        items.push(CodexTurnInputItem::Text { text: text.to_string(), text_elements: Vec::new() });
    }
    for attachment in input.attachments.unwrap_or_default() {
        items.push(attachment.clone().into());
    }
    for skill in input.skills.unwrap_or_default() {
        items.push(CodexTurnInputItem::Skill { name: skill.name.clone(), path: skill.path.clone() });
    }
    for mention in input.mentions.unwrap_or_default() {
        items.push(CodexTurnInputItem::Mention { name: mention.name.clone(), path: mention.path.clone() });
    }
    items
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn builds_text_images_skills_and_mentions_in_order() {
        let images = [CodexImageInputItem::LocalImage { path: "/tmp/a.png".into() }];
        let skills = [ProviderSkillReference { name: "lint".into(), path: "/skills/lint".into() }];
        let mentions = [ProviderMentionReference { name: "app".into(), path: "/src/app".into() }];
        let items = build_codex_turn_input(CodexTurnInputParts {
            input: Some("hello"),
            attachments: Some(&images),
            skills: Some(&skills),
            mentions: Some(&mentions),
        });
        assert_eq!(
            serde_json::to_value(items).unwrap(),
            json!([
                { "type": "text", "text": "hello", "text_elements": [] },
                { "type": "localImage", "path": "/tmp/a.png" },
                { "type": "skill", "name": "lint", "path": "/skills/lint" },
                { "type": "mention", "name": "app", "path": "/src/app" }
            ])
        );
    }

    #[test]
    fn empty_text_is_left_out() {
        assert!(build_codex_turn_input(CodexTurnInputParts { input: Some(""), ..Default::default() }).is_empty());
    }
}
