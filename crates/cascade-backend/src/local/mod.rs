//! What the app asks of the checkout on disk: files, the IDE, worktrees, git and patches. One
//! module per concern; the parent holds what they share and re-exports their handlers, so the
//! router still names `local::diff`, `local::create_worktree` and the rest.

use std::{
    collections::BTreeMap,
    fs,
    os::unix::{
        ffi::OsStringExt,
        fs::{MetadataExt, PermissionsExt},
    },
    path::{Path, PathBuf},
    time::Duration,
};

use axum::{
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use regex::Regex;
use serde::Deserialize;
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{cli, error::ApiError, worktrees, AppState};

type ApiResult<T> = Result<Json<T>, ApiError>;
const MAX_FILE_BYTES: u64 = 5 * 1024 * 1024;
const MAX_DIFF_BYTES: usize = 8 * 1024 * 1024;

#[derive(Default, Deserialize)]
pub struct LocalQuery {
    path: Option<String>,
    rel: Option<String>,
    kind: Option<String>,
    branch: Option<String>,
    key: Option<String>,
    strict: Option<String>,
    limit: Option<usize>,
    skip: Option<usize>,
    #[serde(rename = "ref")]
    reference: Option<String>,
    #[serde(rename = "aheadOnly")]
    ahead_only: Option<String>,
    base: Option<String>,
    repo: Option<String>,
    sha: Option<String>,
    q: Option<String>,
    all: Option<String>,
}

pub(crate) fn foreign_origin(headers: &HeaderMap) -> bool {
    let Some(raw) = headers.get("origin").and_then(|v| v.to_str().ok()) else {
        return false;
    };
    let Ok(url) = url::Url::parse(raw) else {
        return true;
    };
    !matches!(
        url.host_str(),
        Some("localhost" | "127.0.0.1" | "::1" | "[::1]")
    )
}

pub(crate) fn resolve_path(raw: &str) -> PathBuf {
    let mut value = raw.to_owned();
    if let Some(rest) = value.strip_prefix("file://") {
        value = percent_decode(rest);
    }
    if value == "~" || value.starts_with("~/") {
        if let Some(home) = std::env::var_os("HOME") {
            value = PathBuf::from(home)
                .join(value.trim_start_matches('~').trim_start_matches('/'))
                .to_string_lossy()
                .into_owned();
        }
    }
    let path = PathBuf::from(value);
    if path.is_absolute() {
        path
    } else {
        std::env::current_dir().unwrap_or_default().join(path)
    }
}

fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let hex = |byte: u8| match byte {
                b'0'..=b'9' => Some(byte - b'0'),
                b'a'..=b'f' => Some(byte - b'a' + 10),
                b'A'..=b'F' => Some(byte - b'A' + 10),
                _ => None,
            };
            if let (Some(high), Some(low)) = (hex(bytes[index + 1]), hex(bytes[index + 2])) {
                out.push((high << 4) | low);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// `--no-optional-locks`: a read such as `git diff` or `git status` may otherwise refresh the index
/// and take `index.lock` to write it back. The Changes pane reads as the worktree changes, so without
/// it a commit made in a terminal meanwhile could find the lock held.
async fn git(dir: &str, args: Vec<String>, timeout: u64) -> anyhow::Result<String> {
    let mut all = vec!["--no-optional-locks".into(), "-C".into(), dir.into()];
    all.extend(args);
    cli::run("git", all, Duration::from_secs(timeout)).await
}

/// The request named something that is not there or cannot be used as asked: a branch name, a
/// base, a checkout, or an operation git refused. Its message is git's own words when it has them.
fn unprocessable(message: impl Into<String>) -> ApiError {
    ApiError::status(StatusCode::UNPROCESSABLE_ENTITY, message)
}

mod files;
mod git;
mod ide;
mod patch;
mod worktree;

pub(crate) use files::*;
pub(crate) use git::*;
pub(crate) use ide::*;
pub(crate) use patch::*;
pub(crate) use worktree::*;
