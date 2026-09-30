//! The JSON settings files a CLI reads (`~/.claude/settings.json`, Codex's config): read whole,
//! and written whole, atomically, readable by the owner alone. Shared by the hook installer and
//! the status line installer.

use std::{fs, os::unix::fs::PermissionsExt, path::PathBuf};

use serde_json::Value;
use uuid::Uuid;

use crate::error::ApiError;

pub(crate) fn read_json(path: &PathBuf) -> Option<Value> {
    fs::read_to_string(path)
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
}

pub(crate) fn write_json(path: &PathBuf, value: &Value) -> Result<(), ApiError> {
    let destination = fs::canonicalize(path).unwrap_or_else(|_| path.clone());
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent).map_err(ApiError::internal)?
    }
    let temporary = destination.with_file_name(format!(".cascade-hooks-{}.json", Uuid::new_v4()));
    let mut bytes = serde_json::to_vec_pretty(value).map_err(ApiError::internal)?;
    bytes.push(b'\n');
    fs::write(&temporary, bytes).map_err(ApiError::internal)?;
    fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))
        .map_err(ApiError::internal)?;
    fs::rename(temporary, destination).map_err(ApiError::internal)
}
