//! Reading, searching and writing files in a checkout.

use super::*;


fn file_revision(path: &Path, metadata: &fs::Metadata, bytes: &[u8]) -> String {
    let mut hash = Sha256::new();
    hash.update(path.as_os_str().as_encoded_bytes());
    hash.update([0]);
    hash.update(metadata.dev().to_le_bytes());
    hash.update(metadata.ino().to_le_bytes());
    hash.update(metadata.mode().to_le_bytes());
    hash.update(metadata.len().to_le_bytes());
    hash.update(metadata.mtime().to_le_bytes());
    hash.update(metadata.mtime_nsec().to_le_bytes());
    hash.update(bytes);
    format!("{:x}", hash.finalize())
}

fn read_file_snapshot(path: &Path) -> Result<Value, ApiError> {
    let canonical = fs::canonicalize(path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            ApiError::not_found("not found")
        } else {
            ApiError::internal(error)
        }
    })?;
    let metadata = fs::symlink_metadata(&canonical).map_err(ApiError::internal)?;
    if !metadata.is_file() {
        return Err(ApiError::status(
            axum::http::StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "Only regular text files can be edited.",
        ));
    }
    if metadata.len() > MAX_FILE_BYTES {
        return Err(ApiError::status(
            axum::http::StatusCode::PAYLOAD_TOO_LARGE,
            "File too large to edit (maximum 5 MB).",
        ));
    }
    let bytes = fs::read(&canonical).map_err(ApiError::internal)?;
    if bytes.len() as u64 > MAX_FILE_BYTES {
        return Err(ApiError::status(
            axum::http::StatusCode::PAYLOAD_TOO_LARGE,
            "File too large to edit (maximum 5 MB).",
        ));
    }
    if bytes.contains(&0) {
        return Err(ApiError::status(
            axum::http::StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "Not a UTF-8 text file.",
        ));
    }
    let content = String::from_utf8(bytes.clone()).map_err(|_| {
        ApiError::status(
            axum::http::StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "Not a UTF-8 text file.",
        )
    })?;
    let read_only = metadata.permissions().readonly() || metadata.nlink() > 1;
    Ok(
        json!({"path":path.to_string_lossy(),"content":content,"readOnly":read_only,
        "revision":file_revision(&canonical,&metadata,&bytes),"canonical":canonical.to_string_lossy()}),
    )
}

pub async fn get_file(headers: HeaderMap, Query(query): Query<LocalQuery>) -> ApiResult<Value> {
    if foreign_origin(&headers) {
        return Err(ApiError::forbidden("forbidden"));
    }
    let raw = query
        .path
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let mut value = read_file_snapshot(&resolve_path(&raw))?;
    value.as_object_mut().unwrap().remove("canonical");
    Ok(Json(value))
}

/// How well a worktree-relative path answers a typed query; lower is better, None is no match.
/// A hit in the file name beats one in its folders, a prefix beats a substring, and a scattered
/// subsequence ("swvm" for SessionWorkspaceViewModel) comes last.
fn file_match_rank(rel: &str, needle: &str) -> Option<u8> {
    let path = rel.to_lowercase();
    let name = path.rsplit('/').next().unwrap_or_default();
    if name.starts_with(needle) {
        return Some(0);
    }
    if name.contains(needle) {
        return Some(1);
    }
    if path.contains(needle) {
        return Some(2);
    }
    let mut wanted = needle.chars().filter(|c| !c.is_whitespace());
    let mut next = wanted.next();
    for c in path.chars() {
        if Some(c) == next {
            next = wanted.next();
        }
    }
    next.is_none().then_some(3)
}

/// The most files `all` returns: a whole worktree for the pane's file tree, bounded so a
/// checkout of a monorepo cannot hand the app a list it would choke on.
const ALL_FILES_LIMIT: usize = 20_000;

/// Which of `ls-files`' NUL-separated paths answer: with `all`, every one in path order up to
/// `ALL_FILES_LIMIT`; otherwise those matching `needle`, best first, up to `limit`. The flag says
/// whether any were left out. A conflicted path is listed once per stage; it answers once. Dotfiles
/// and dot-folders git lists — `.github`, `.gitignore` — are files people edit, so the tree has
/// them too; what git ignores never reaches here.
fn select_files<'a>(out: &'a str, needle: &str, limit: usize, all: bool) -> (Vec<&'a str>, bool) {
    let paths = out.split('\0').filter(|rel| !rel.is_empty());
    if all {
        let mut files: Vec<&str> = paths.collect();
        files.sort_unstable();
        files.dedup();
        let truncated = files.len() > ALL_FILES_LIMIT;
        files.truncate(ALL_FILES_LIMIT);
        return (files, truncated);
    }
    let mut ranked: Vec<(u8, &str)> = paths
        .filter_map(|rel| {
            if needle.is_empty() {
                Some((0, rel))
            } else {
                file_match_rank(rel, needle).map(|rank| (rank, rel))
            }
        })
        .collect();
    ranked.sort_by(|a, b| (a.0, a.1.len(), a.1).cmp(&(b.0, b.1.len(), b.1)));
    ranked.dedup();
    let truncated = ranked.len() > limit;
    (ranked.into_iter().take(limit).map(|(_, rel)| rel).collect(), truncated)
}

/// The files of one worktree, for the pane's file tree (`all`) and its search field (`q`):
/// tracked and untracked-but-not-ignored, exactly what git would show, so build output never
/// appears.
pub async fn list_files(headers: HeaderMap, Query(query): Query<LocalQuery>) -> ApiResult<Value> {
    if foreign_origin(&headers) {
        return Err(ApiError::forbidden("forbidden"));
    }
    let raw = query
        .path
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let root = resolve_path(&raw);
    let needle = query.q.unwrap_or_default().trim().to_lowercase();
    let limit = query.limit.unwrap_or(50).clamp(1, 200);
    let all = matches!(query.all.as_deref(), Some("1" | "true"));
    let out = git(
        &root.to_string_lossy(),
        vec![
            "ls-files".into(),
            "--cached".into(),
            "--others".into(),
            "--exclude-standard".into(),
            "-z".into(),
        ],
        20,
    )
    .await
    .map_err(|_| ApiError::bad_request("not a git worktree"))?;
    let (files, truncated) = select_files(&out, &needle, limit, all);
    Ok(Json(json!({ "root": root.to_string_lossy(), "files": files, "truncated": truncated })))
}

pub async fn put_file(headers: HeaderMap, Json(body): Json<Value>) -> ApiResult<Value> {
    if foreign_origin(&headers) {
        return Err(ApiError::forbidden("forbidden"));
    }
    let raw = body
        .get("path")
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let content = body
        .get("content")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::bad_request("content required"))?;
    if content.as_bytes().len() as u64 > MAX_FILE_BYTES {
        return Err(ApiError::status(
            axum::http::StatusCode::PAYLOAD_TOO_LARGE,
            "content too large",
        ));
    }
    let expected = body
        .get("revision")
        .and_then(Value::as_str)
        .filter(|v| v.len() == 64)
        .ok_or_else(|| {
            ApiError::precondition(
                "Reload this file before saving so its current revision can be checked.",
            )
        })?;
    let path = resolve_path(raw);
    let original = read_file_snapshot(&path)?;
    if original["revision"] != expected {
        return Err(ApiError::conflict("The file changed on disk. Your edits have been kept; reload or save a copy before replacing it."));
    }
    if original["readOnly"] == true {
        return Err(ApiError::forbidden("This file is read-only."));
    }
    let canonical = PathBuf::from(original["canonical"].as_str().unwrap_or(raw));
    let metadata = fs::metadata(&canonical).map_err(ApiError::internal)?;
    let temporary = canonical.with_file_name(format!(".cascade-save-{}", Uuid::new_v4()));
    fs::write(&temporary, content.as_bytes()).map_err(ApiError::internal)?;
    fs::set_permissions(&temporary, fs::Permissions::from_mode(metadata.mode()))
        .map_err(ApiError::internal)?;
    if read_file_snapshot(&path)?["revision"] != expected {
        let _ = fs::remove_file(&temporary);
        return Err(ApiError::conflict("The file changed on disk. Your edits have been kept; reload or save a copy before replacing it."));
    }
    fs::rename(&temporary, &canonical).map_err(ApiError::internal)?;
    let saved = read_file_snapshot(&path)?;
    Ok(Json(
        json!({"ok":true,"path":raw,"revision":saved["revision"]}),
    ))
}

#[cfg(test)]
mod file_match_tests {
    use super::{file_match_rank, select_files};

    #[test]
    fn all_lists_every_path_in_order_and_a_query_ranks_a_few() {
        let out = "b/z.swift\0a.md\0b/a.swift\0\0";
        assert_eq!(select_files(out, "", 1, true), (vec!["a.md", "b/a.swift", "b/z.swift"], false));
        assert_eq!(select_files(out, "swift", 1, false), (vec!["b/a.swift"], true));
        assert_eq!(select_files(out, "zzz", 5, false), (vec![], false));
        let hidden = "a.swift\0.gitignore\0.github/ci.yml\0src/.env\0src/b.swift\0";
        assert_eq!(select_files(hidden, "", 10, true), (vec![".github/ci.yml", ".gitignore", "a.swift", "src/.env", "src/b.swift"], false));
        assert_eq!(select_files(hidden, "yml", 10, false).0, vec![".github/ci.yml"]);
        let conflicted = "f.swift\0f.swift\0f.swift\0g.swift\0";
        assert_eq!(select_files(conflicted, "", 5, true), (vec!["f.swift", "g.swift"], false));
        assert_eq!(select_files(conflicted, "swift", 5, false), (vec!["f.swift", "g.swift"], false));
    }

    #[test]
    fn ranks_name_hits_above_folder_hits_above_subsequences() {
        assert_eq!(file_match_rank("macos/App/AppDelegate.swift", "appd"), Some(0));
        assert_eq!(file_match_rank("macos/App/AppDelegate.swift", "delegate"), Some(1));
        assert_eq!(file_match_rank("macos/App/AppDelegate.swift", "macos/app"), Some(2));
        assert_eq!(file_match_rank("macos/Scenes/SessionWorkspaceViewModel.swift", "swvm"), Some(3));
        assert_eq!(file_match_rank("README.md", "zzz"), None);
    }
}
