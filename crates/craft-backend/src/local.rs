use std::{
    collections::BTreeMap,
    fs,
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    time::Duration,
};

use axum::{extract::Query, http::HeaderMap, Json};
use regex::Regex;
use serde::Deserialize;
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{cli, error::ApiError};

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

/// The files of one worktree that match `q`, for the Files tab's search field: tracked and
/// untracked-but-not-ignored, exactly what git would show, so build output never appears.
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
    let mut ranked: Vec<(u8, &str)> = out
        .split('\0')
        .filter(|rel| !rel.is_empty())
        .filter_map(|rel| {
            if needle.is_empty() {
                Some((0, rel))
            } else {
                file_match_rank(rel, &needle).map(|rank| (rank, rel))
            }
        })
        .collect();
    ranked.sort_by(|a, b| (a.0, a.1.len(), a.1).cmp(&(b.0, b.1.len(), b.1)));
    let files: Vec<&str> = ranked.into_iter().take(limit).map(|(_, rel)| rel).collect();
    Ok(Json(json!({ "root": root.to_string_lossy(), "files": files })))
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
    let temporary = canonical.with_file_name(format!(".craft-save-{}", Uuid::new_v4()));
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

fn xcode_target(root: &Path) -> Option<PathBuf> {
    const SKIP: &[&str] = &[
        ".git",
        "node_modules",
        "Pods",
        "Carthage",
        "DerivedData",
        "build",
        ".build",
        "vendor",
        "fastlane",
        ".gradle",
        "dist",
    ];
    let mut level = vec![root.to_path_buf()];
    for _ in 0..=2 {
        let mut next = Vec::new();
        let mut workspaces = Vec::new();
        let mut projects = Vec::new();
        let mut packages = Vec::new();
        for directory in level {
            let Ok(entries) = fs::read_dir(&directory) else {
                continue;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                let name = entry.file_name().to_string_lossy().into_owned();
                if name.ends_with(".xcworkspace") {
                    workspaces.push(path);
                } else if name.ends_with(".xcodeproj") {
                    projects.push(path);
                } else if name == "Package.swift" && path.is_file() {
                    packages.push(path);
                } else if path.is_dir() && !name.starts_with('.') && !SKIP.contains(&name.as_str())
                {
                    next.push(path);
                }
            }
        }
        workspaces.sort();
        projects.sort();
        packages.sort();
        if let Some(hit) = workspaces
            .into_iter()
            .next()
            .or_else(|| projects.into_iter().next())
            .or_else(|| packages.into_iter().next())
        {
            return Some(hit);
        }
        next.sort();
        level = next;
    }
    None
}

pub(crate) fn resolve_launch(root: &Path, rel: &str, kind: &str) -> Result<(PathBuf, &'static str), ApiError> {
    let metadata = fs::metadata(root).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            ApiError::not_found("not found")
        } else {
            ApiError::internal(error)
        }
    })?;
    if !metadata.is_dir() {
        return Ok((root.to_path_buf(), "path"));
    }
    let rel = rel.trim().trim_start_matches('/');
    if !rel.is_empty()
        && !Path::new(rel)
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        let configured = root.join(rel);
        if configured.exists() {
            return Ok((configured, "configured"));
        }
    }
    if kind == "xcode" {
        if let Some(found) = xcode_target(root) {
            return Ok((found, "probe"));
        }
    }
    Ok((root.to_path_buf(), "folder"))
}

pub async fn launch_target(
    headers: HeaderMap,
    Query(query): Query<LocalQuery>,
) -> ApiResult<Value> {
    if foreign_origin(&headers) {
        return Err(ApiError::forbidden("forbidden"));
    }
    let raw = query
        .path
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let (path, source) = resolve_launch(
        &resolve_path(&raw),
        query.rel.as_deref().unwrap_or(""),
        query.kind.as_deref().unwrap_or(""),
    )?;
    Ok(Json(json!({"path":path,"source":source})))
}

#[derive(Clone)]
struct Worktree {
    path: String,
    branch: String,
    main: bool,
}
async fn git(dir: &str, args: Vec<String>, timeout: u64) -> anyhow::Result<String> {
    let mut all = vec!["-C".into(), dir.into()];
    all.extend(args);
    cli::run("git", all, Duration::from_secs(timeout)).await
}
async fn list_worktrees(dir: &str) -> Vec<Worktree> {
    let Ok(out) = git(
        dir,
        vec!["worktree".into(), "list".into(), "--porcelain".into()],
        20,
    )
    .await
    else {
        return vec![];
    };
    let mut result = Vec::new();
    for line in out.lines() {
        if let Some(path) = line.strip_prefix("worktree ") {
            result.push(Worktree {
                path: path.trim().into(),
                branch: String::new(),
                main: result.is_empty(),
            });
        } else if let Some(branch) = line.strip_prefix("branch ") {
            if let Some(last) = result.last_mut() {
                last.branch = branch.trim().trim_start_matches("refs/heads/").into();
            }
        }
    }
    result
}

pub async fn list_worktrees_route(Query(query): Query<LocalQuery>) -> ApiResult<Value> {
    let Some(dir) = query.path else {
        return Ok(Json(json!([])));
    };
    Ok(Json(Value::Array(
        list_worktrees(&dir)
            .await
            .into_iter()
            .filter(|w| !w.main)
            .map(|w| json!({"path":w.path,"branch":w.branch}))
            .collect(),
    )))
}

pub async fn resolve_worktree(Query(query): Query<LocalQuery>) -> ApiResult<Value> {
    let Some(dir) = query.path else {
        return Ok(Json(
            json!({"path":"","matched":false,"isWorktree":false,"branch":""}),
        ));
    };
    let trees = list_worktrees(&dir).await;
    let strict = matches!(query.strict.as_deref(), Some("1" | "true"));
    let found = if let Some(branch) = query.branch {
        trees.iter().find(|w| w.branch == branch).or_else(|| {
            if strict {
                None
            } else {
                let folder = branch.rsplit('/').next().unwrap_or(&branch);
                trees.iter().find(|w| {
                    !w.main
                        && Path::new(&w.path).file_name().and_then(|v| v.to_str()) == Some(folder)
                })
            }
        })
    } else if let Some(key) = query.key {
        let needle = key.to_ascii_lowercase();
        let pattern = Regex::new(&format!(
            r"(?i)(^|[^a-z0-9]){}([^0-9]|$)",
            regex::escape(&needle)
        ))
        .ok();
        let hits: Vec<_> = trees
            .iter()
            .filter(|w| {
                if strict {
                    pattern.as_ref().is_some_and(|r| r.is_match(&w.branch))
                } else {
                    w.branch.to_ascii_lowercase().contains(&needle)
                }
            })
            .collect();
        if hits.len() == 1 {
            Some(hits[0])
        } else {
            None
        }
    } else {
        None
    };
    Ok(Json(
        found
            .map(|w| json!({"path":w.path,"matched":true,"isWorktree":!w.main,"branch":w.branch}))
            .unwrap_or_else(|| json!({"path":"","matched":false,"isWorktree":false,"branch":""})),
    ))
}

fn valid_branch(value: &str) -> bool {
    !value.is_empty()
        && !value.starts_with('-')
        && !value.ends_with('/')
        && !value.ends_with('.')
        && !value.ends_with(".lock")
        && !value
            .split('/')
            .any(|v| v.is_empty() || v == "." || v == ".." || v.starts_with('.'))
        && !value
            .chars()
            .any(|c| c.is_control() || c.is_whitespace() || "~^:?*[\\|".contains(c))
        && !value.contains("..")
        && !value.contains("@{")
}

pub async fn create_worktree(Json(body): Json<Value>) -> ApiResult<Value> {
    let dir = body["path"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path and branch required"))?;
    let branch = body["branch"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path and branch required"))?;
    if !valid_branch(branch) {
        return Ok(Json(
            json!({"error":format!("\"{branch}\" is not a valid branch name")}),
        ));
    }
    let workspace = dir.trim_end_matches('/');
    let folder = branch.rsplit('/').next().unwrap_or(branch);
    let root = PathBuf::from(format!("{workspace}.worktrees"));
    let destination = root.join(folder);
    if list_worktrees(dir)
        .await
        .iter()
        .any(|w| Path::new(&w.path) == destination)
    {
        return Ok(Json(json!({"ok":true,"path":destination})));
    }
    if destination.exists() && !body["override"].as_bool().unwrap_or(false) {
        return Ok(Json(
            json!({"error":format!("A folder already exists at {}",destination.display()),"folderConflict":true,"path":destination,"disposable":false}),
        ));
    }
    fs::create_dir_all(&root).map_err(ApiError::internal)?;
    // Clear stale admin entries, then add. Adding an EXISTING branch is the first move and
    // `-b` the fallback, so a `create` request whose branch is already present adopts it
    // instead of failing. This shape came from the node backend this crate replaced.
    let _ = git(dir, vec!["worktree".into(), "prune".into()], 20).await;
    let target = destination.to_string_lossy().into_owned();
    let create = body["create"].as_bool().unwrap_or(false);
    let add = vec![
        "worktree".into(),
        "add".into(),
        target.clone(),
        branch.into(),
    ];
    let mut failure = match git(dir, add.clone(), 90).await {
        Ok(_) => return Ok(Json(json!({"ok":true,"path":destination}))),
        Err(error) => error.to_string(),
    };
    // The one place a fetch earns its cost: adopting a branch that exists only on origin, which
    // `worktree add` cannot resolve without refs/remotes/origin/<branch>. The JS backend fetched
    // up front on every path instead; that is what froze New Session for a minute, since a fetch
    // from the app (Xcode's git, a GUI process resolving credentials) is far slower than from a
    // shell, and on the create path the ref being fetched provably does not exist yet.
    if missing_ref(&failure) && !create {
        let _ = git(
            dir,
            vec!["fetch".into(), "origin".into(), branch.into()],
            10,
        )
        .await;
        match git(dir, add, 90).await {
            Ok(_) => return Ok(Json(json!({"ok":true,"path":destination}))),
            Err(error) => failure = error.to_string(),
        }
    }
    // Only a missing ref means "this branch does not exist yet, make it". Anything else (a bad
    // path, a flag error) must surface as itself rather than silently creating a branch.
    if !create || !missing_ref(&failure) {
        return Ok(Json(json!({"error": worktree_failure(branch, failure)})));
    }
    let explicit = body["base"].as_str().filter(|v| !v.is_empty());
    let base = match explicit {
        Some(base) => base.to_string(),
        None => default_branch(dir).await,
    };
    if explicit.is_some() && !valid_branch(&base) {
        return Ok(Json(
            json!({"error":format!("\"{base}\" is not a valid base branch name")}),
        ));
    }
    // No fetch for the base either: a new branch is cut from what this checkout already has, so
    // creating one never waits on the network. `origin/<base>` is still preferred when it is
    // present locally, so the start point is the newest tip the checkout knows about.
    // origin/<base> when it resolves — the freshest tip this checkout has — else the local branch
    // (a base that was never pushed). An EXPLICIT base resolving nowhere is an error: never
    // fork off whatever HEAD the main checkout happens to be on.
    let start = if ref_exists(dir, &format!("origin/{base}")).await {
        format!("origin/{base}")
    } else if ref_exists(dir, &base).await {
        base.clone()
    } else {
        String::new()
    };
    if start.is_empty() && explicit.is_some() {
        return Ok(Json(
            json!({"error":format!("Base branch \"{base}\" was not found locally or on origin")}),
        ));
    }
    let mut args = vec![
        "worktree".into(),
        "add".into(),
        "-b".into(),
        branch.into(),
        target,
    ];
    if !start.is_empty() {
        args.push(start);
    }
    match git(dir, args, 90).await {
        Ok(_) => Ok(Json(json!({"ok":true,"path":destination}))),
        Err(e) => Ok(Json(json!({"error": worktree_failure(branch, e.to_string())}))),
    }
}

/// Moves a checkout to another branch. A branch can only be checked out once, so the main repo
/// sitting on a branch is what stops a session for it from getting a worktree; the app asks here
/// to free it. Uncommitted tracked work is never carried across silently — that case reports and
/// leaves the checkout alone. Untracked files follow a switch harmlessly and do not block it.
pub async fn git_switch(Json(body): Json<Value>) -> ApiResult<Value> {
    let dir = body["path"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path and branch required"))?;
    let branch = body["branch"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path and branch required"))?;
    if !valid_branch(branch) {
        return Ok(Json(
            json!({"error":format!("\"{branch}\" is not a valid branch name")}),
        ));
    }
    // The branch is held by the MAIN worktree, which is not always the folder the app calls its
    // workspace — a project can be configured on a linked worktree. Switching the wrong one leaves
    // the branch just as held.
    let trees = list_worktrees(dir).await;
    let Some(main) = trees.iter().find(|w| w.main).map(|w| w.path.clone()) else {
        return Ok(Json(
            json!({"error":format!("{dir} is not a git checkout")}),
        ));
    };
    // A status that could not be read is treated as dirty: `switch` carries uncommitted work onto
    // the new branch whenever git sees no conflict, and that is not something to do on a guess.
    let dirty = match git(
        &main,
        vec![
            "status".into(),
            "--porcelain".into(),
            "--untracked-files=no".into(),
        ],
        30,
    )
    .await
    {
        Ok(out) => !out.trim().is_empty(),
        Err(e) => {
            return Ok(Json(
                json!({"error":format!("Could not read the state of {main}: {}", error_line(&e.to_string()))}),
            ))
        }
    };
    if dirty {
        return Ok(Json(
            json!({"error":format!("{main} has uncommitted changes. Commit or stash them before moving it to \"{branch}\".")}),
        ));
    }
    // A local branch only: `switch` would otherwise create a tracking branch from origin, which
    // is a different act than the one the app asked for.
    if !ref_exists(&main, &format!("refs/heads/{branch}")).await {
        return Ok(Json(
            json!({"error":format!("Branch \"{branch}\" was not found in {main}")}),
        ));
    }
    match git(&main, vec!["switch".into(), branch.into()], 60).await {
        Ok(_) => Ok(Json(json!({"ok":true}))),
        Err(e) => Ok(Json(json!({"error": error_line(&e.to_string())}))),
    }
}

/// The narrow set of phrases `worktree add` emits for a ref it cannot resolve — matched, as in
/// the JS backend, so an unrelated failure is never read as "the branch does not exist yet".
fn missing_ref(message: &str) -> bool {
    let message = message.to_ascii_lowercase();
    message.contains("invalid reference") || message.contains("unknown revision")
}

/// Git's "invalid reference" says nothing about what to do; a fork's PR branch is the usual way
/// to reach it, since that branch is on the fork's remote and never on origin.
fn worktree_failure(branch: &str, message: String) -> String {
    if missing_ref(&message) {
        return format!(
            "Branch \"{branch}\" isn't available locally or on origin (a PR from a fork needs its branch fetched first)"
        );
    }
    error_line(&message)
}

/// The line that says what went wrong, as the JS backend's `gitErrLine` picks it: git narrates
/// before it fails ("Preparing worktree (checking out 'x')\nfatal: …"), and a toast showing the
/// narration first reads as though nothing is wrong.
fn error_line(message: &str) -> String {
    message
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .find(|line| {
            let line = line.to_ascii_lowercase();
            line.contains("error") || line.contains("rejected") || line.contains("fatal")
        })
        .map(str::to_owned)
        .unwrap_or_else(|| message.trim().to_owned())
}

async fn ref_exists(dir: &str, reference: &str) -> bool {
    git(
        dir,
        vec![
            "rev-parse".into(),
            "--verify".into(),
            "--quiet".into(),
            format!("{reference}^{{commit}}"),
        ],
        15,
    )
    .await
    .is_ok()
}

/// origin/HEAD when the remote publishes one, else the first conventional branch that exists.
async fn default_branch(dir: &str) -> String {
    if let Ok(head) = git(
        dir,
        vec![
            "symbolic-ref".into(),
            "--short".into(),
            "refs/remotes/origin/HEAD".into(),
        ],
        15,
    )
    .await
    {
        let name = head.trim().trim_start_matches("origin/");
        if !name.is_empty() {
            return name.to_owned();
        }
    }
    for candidate in ["main", "master", "develop"] {
        if ref_exists(dir, &format!("refs/heads/{candidate}")).await {
            return candidate.to_owned();
        }
    }
    "main".to_owned()
}

pub async fn remove_worktree(Json(body): Json<Value>) -> ApiResult<Value> {
    let dir = body["path"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path and worktree required"))?;
    let target = body["worktree"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path and worktree required"))?;
    let trees = list_worktrees(dir).await;
    let Some(tree) = trees
        .iter()
        .find(|w| Path::new(&w.path) == Path::new(target))
    else {
        return Ok(Json(
            json!({"error":format!("{target} is not a worktree of this project")}),
        ));
    };
    if tree.main {
        return Ok(Json(
            json!({"error":"refusing to remove the main checkout"}),
        ));
    }
    let mut args = vec!["worktree".into(), "remove".into()];
    if body["force"].as_bool().unwrap_or(false) {
        args.push("--force".into())
    }
    args.push(target.into());
    match git(dir, args, 60).await {
        Ok(_) => Ok(Json(json!({"ok":true}))),
        Err(e) => Ok(Json(json!({"error":e.to_string()}))),
    }
}

pub async fn worktree_holders(Query(query): Query<LocalQuery>) -> ApiResult<Value> {
    let Some(path) = query.path else {
        return Ok(Json(json!({"holders":[]})));
    };
    let output = cli::run("lsof", ["-F", "pcft", "+D", &path], Duration::from_secs(8))
        .await
        .unwrap_or_default();
    let mut holders = BTreeMap::new();
    let (mut pid, mut command, mut fd) = (String::new(), String::new(), String::new());
    for line in output.lines() {
        let (tag, value) = line.split_at(1);
        match tag {
            "p" => {
                pid = value.into();
                command.clear();
                fd.clear()
            }
            "c" => command = value.into(),
            "f" => fd = value.into(),
            "t" if value == "REG" && fd.chars().next().is_some_and(|c| c.is_ascii_digit()) => {
                holders.insert(pid.clone(), command.clone());
            }
            _ => {}
        }
    }
    Ok(Json(
        json!({"holders":holders.into_iter().map(|(pid,command)|json!({"pid":pid.parse::<i64>().unwrap_or(0),"command":command})).collect::<Vec<_>>()}),
    ))
}

async fn git_meta(dir: &str) -> (String, Option<i64>, Option<i64>) {
    let branch = git(
        dir,
        vec!["rev-parse".into(), "--abbrev-ref".into(), "HEAD".into()],
        15,
    )
    .await
    .unwrap_or_default();
    let divergence = git(
        dir,
        vec![
            "rev-list".into(),
            "--left-right".into(),
            "--count".into(),
            "@{upstream}...HEAD".into(),
        ],
        15,
    )
    .await
    .ok();
    let counts = divergence
        .as_deref()
        .map(|v| {
            v.split_whitespace()
                .filter_map(|x| x.parse().ok())
                .collect::<Vec<i64>>()
        })
        .unwrap_or_default();
    (branch, counts.get(1).copied(), counts.first().copied())
}

pub async fn diff(Query(query): Query<LocalQuery>) -> ApiResult<Value> {
    let dir = query
        .path
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let patch = match git(
        &dir,
        vec![
            "diff".into(),
            "HEAD".into(),
            "--no-color".into(),
            "--no-ext-diff".into(),
        ],
        30,
    )
    .await
    {
        Ok(v) => v,
        Err(_) => git(
            &dir,
            vec!["diff".into(), "--no-color".into(), "--no-ext-diff".into()],
            30,
        )
        .await
        .map_err(ApiError::internal)?,
    };
    if patch.len() > MAX_DIFF_BYTES {
        return Ok(Json(json!({"error":"Diff too large to display"})));
    }
    let untracked = git(
        &dir,
        vec![
            "ls-files".into(),
            "--others".into(),
            "--exclude-standard".into(),
        ],
        15,
    )
    .await
    .unwrap_or_default()
    .lines()
    .map(String::from)
    .collect::<Vec<_>>();
    let (branch, ahead, behind) = git_meta(&dir).await;
    let revision = format!("{:x}", Sha256::digest(patch.as_bytes()));
    Ok(Json(
        json!({"diff":patch,"untracked":untracked,"branch":branch,"ahead":ahead,"behind":behind,"revision":revision}),
    ))
}

pub async fn git_commit(Json(body): Json<Value>) -> ApiResult<Value> {
    let dir = body["path"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let message = body["message"]
        .as_str()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("message required"))?;
    let flag = if body["includeUntracked"].as_bool().unwrap_or(true) {
        "-A"
    } else {
        "-u"
    };
    if let Err(e) = git(dir, vec!["add".into(), flag.into()], 30).await {
        return Ok(Json(json!({"error":e.to_string()})));
    }
    if let Err(e) = git(dir, vec!["commit".into(), "-m".into(), message.into()], 120).await {
        return Ok(Json(json!({"error":e.to_string()})));
    }
    let hash = git(
        dir,
        vec!["rev-parse".into(), "--short".into(), "HEAD".into()],
        15,
    )
    .await
    .map_err(ApiError::internal)?;
    Ok(Json(json!({"ok":true,"hash":hash})))
}

pub async fn git_push(Json(body): Json<Value>) -> ApiResult<Value> {
    let dir = body["path"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let result = match git(dir, vec!["push".into()], 60).await {
        Err(error)
            if error
                .to_string()
                .to_ascii_lowercase()
                .contains("no upstream") =>
        {
            git(
                dir,
                vec!["push".into(), "-u".into(), "origin".into(), "HEAD".into()],
                60,
            )
            .await
        }
        other => other,
    };
    Ok(Json(match result {
        Ok(_) => json!({"ok":true}),
        Err(e) => json!({"error":e.to_string()}),
    }))
}

fn default_branch_from_refs(branches: &[Value]) -> String {
    for name in ["main", "master", "develop"] {
        if branches.iter().any(|b| b["name"] == name) {
            return name.into();
        }
    }
    String::new()
}

pub async fn git_refs(Query(query): Query<LocalQuery>) -> ApiResult<Value> {
    let dir = query
        .path
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let format = format!(
        "%(HEAD){}%(refname:short){}%(upstream:short){}%(objectname:short)",
        '\x1f', '\x1f', '\x1f'
    );
    let raw = git(
        &dir,
        vec![
            "for-each-ref".into(),
            "--sort=-committerdate".into(),
            format!("--format={format}"),
            "refs/heads".into(),
        ],
        20,
    )
    .await
    .unwrap_or_default();
    let branches=raw.lines().map(|line|{let p=line.split('\x1f').collect::<Vec<_>>();json!({"name":p.get(1).copied().unwrap_or(""),"current":p.first().copied()==Some("*"),"upstream":p.get(2).copied().filter(|v|!v.is_empty()),"short":p.get(3).copied().unwrap_or("")})}).collect::<Vec<_>>();
    let worktrees = list_worktrees(&dir)
        .await
        .into_iter()
        .map(|w| json!({"path":w.path,"branch":w.branch,"isMain":w.main}))
        .collect::<Vec<_>>();
    let default = git(
        &dir,
        vec![
            "symbolic-ref".into(),
            "--short".into(),
            "refs/remotes/origin/HEAD".into(),
        ],
        15,
    )
    .await
    .ok()
    .map(|v| v.trim_start_matches("origin/").into())
    .unwrap_or_else(|| default_branch_from_refs(&branches));
    Ok(Json(
        json!({"branches":branches,"worktrees":worktrees,"defaultBranch":default}),
    ))
}

pub async fn git_log(Query(query): Query<LocalQuery>) -> ApiResult<Value> {
    let dir = query
        .path
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let (branch, ahead, behind) = git_meta(&dir).await;
    let default = git(
        &dir,
        vec![
            "symbolic-ref".into(),
            "--short".into(),
            "refs/remotes/origin/HEAD".into(),
        ],
        15,
    )
    .await
    .ok()
    .map(|v| v.trim_start_matches("origin/").to_owned())
    .unwrap_or_default();
    let viewing = query
        .reference
        .filter(|v| !v.starts_with('-'))
        .unwrap_or_else(|| {
            if default.is_empty() {
                "HEAD".into()
            } else {
                default.clone()
            }
        });
    let revision = if query.ahead_only.as_deref() == Some("1") && !branch.is_empty() {
        let base = query
            .base
            .clone()
            .filter(|v| !v.is_empty())
            .unwrap_or(default.clone());
        if !base.is_empty() && base != branch {
            format!("{base}..HEAD")
        } else {
            viewing.clone()
        }
    } else {
        viewing.clone()
    };
    let format = "%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%D%x1f%s%x1e";
    let raw = git(
        &dir,
        vec![
            "log".into(),
            "--no-color".into(),
            format!("--max-count={}", query.limit.unwrap_or(100).clamp(1, 1000)),
            format!("--skip={}", query.skip.unwrap_or(0)),
            format!("--pretty=format:{format}"),
            revision.clone(),
            "--".into(),
        ],
        30,
    )
    .await
    .unwrap_or_default();
    let commits=raw.split('\x1e').filter(|v|!v.trim().is_empty()).map(|record|{let p=record.trim_start_matches('\n').split('\x1f').collect::<Vec<_>>();json!({"sha":p.first().copied().unwrap_or(""),"short":p.get(1).copied().unwrap_or(""),"parents":p.get(2).copied().unwrap_or("").split_whitespace().collect::<Vec<_>>(),"author":p.get(3).copied().unwrap_or(""),"email":p.get(4).copied().unwrap_or(""),"date":p.get(5).copied().unwrap_or(""),"refs":[],"subject":p.get(7).copied().unwrap_or("")})}).collect::<Vec<_>>();
    let history_revision = format!("{:x}", Sha256::digest(revision.as_bytes()));
    Ok(Json(
        json!({"commits":commits,"branch":branch,"ahead":ahead,"behind":behind,"viewing":viewing,"defaultBranch":default,"base":query.base,"historyRevision":history_revision}),
    ))
}

pub async fn git_show(Query(query): Query<LocalQuery>) -> ApiResult<Value> {
    let dir = query
        .path
        .ok_or_else(|| ApiError::bad_request("path and sha required"))?;
    let sha = query
        .sha
        .filter(|v| Regex::new(r"^[0-9a-fA-F]{4,64}$").unwrap().is_match(v))
        .ok_or_else(|| ApiError::bad_request("path and sha required"))?;
    let format = "%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%cn%x1f%ce%x1f%cI%x1f%B";
    let info = git(
        &dir,
        vec![
            "show".into(),
            "-s".into(),
            format!("--pretty=format:{format}"),
            sha.clone(),
        ],
        30,
    )
    .await
    .map_err(ApiError::internal)?;
    let patch = git(
        &dir,
        vec![
            "show".into(),
            sha,
            "-m".into(),
            "--first-parent".into(),
            "--no-color".into(),
            "--no-ext-diff".into(),
            "--format=".into(),
        ],
        30,
    )
    .await
    .map_err(ApiError::internal)?;
    let p = info.split('\x1f').collect::<Vec<_>>();
    Ok(Json(
        json!({"meta":{"sha":p.first().copied().unwrap_or(""),"short":p.get(1).copied().unwrap_or(""),"parents":p.get(2).copied().unwrap_or("").split_whitespace().collect::<Vec<_>>(),"author":p.get(3).copied().unwrap_or(""),"authorEmail":p.get(4).copied().unwrap_or(""),"authorDate":p.get(5).copied().unwrap_or(""),"committer":p.get(6).copied().unwrap_or(""),"committerEmail":p.get(7).copied().unwrap_or(""),"commitDate":p.get(8).copied().unwrap_or(""),"message":p.get(9..).unwrap_or(&[]).join("\u{1f}")},"diff":patch.trim_start_matches('\n')}),
    ))
}

pub async fn commit_avatars(Query(query): Query<LocalQuery>) -> ApiResult<Value> {
    let Some(repo) = query
        .repo
        .filter(|v| Regex::new(r"^[\w.-]+/[\w.-]+$").unwrap().is_match(v))
    else {
        return Ok(Json(json!({})));
    };
    let mut endpoint = format!(
        "/repos/{repo}/commits?per_page={}",
        query.limit.unwrap_or(100).clamp(1, 100)
    );
    if let Some(reference) = query.reference {
        endpoint.push_str("&sha=");
        endpoint.push_str(&reference)
    }
    let raw = cli::run(
        "gh",
        [
            "api",
            &endpoint,
            "--jq",
            ".[] | [.sha, (.author.avatar_url // \"\")] | @tsv",
        ],
        Duration::from_secs(30),
    )
    .await
    .unwrap_or_default();
    let mut map = Map::new();
    for line in raw.lines() {
        if let Some((sha, url)) = line.split_once('\t') {
            if !url.is_empty() {
                map.insert(sha.into(), Value::String(url.into()));
            }
        }
    }
    Ok(Json(Value::Object(map)))
}

#[derive(Default)]
struct PatchFile {
    old_path: String,
    new_path: String,
    status: &'static str,
    binary: bool,
    hunks: Vec<PatchHunk>,
}

struct PatchHunk {
    header: String,
    new_start: usize,
    lines: Vec<PatchLine>,
}

struct PatchLine {
    kind: char,
    text: String,
    no_newline: bool,
}

fn clean_patch_path(raw: &str, strip_prefix: bool) -> String {
    let mut value = raw.trim().trim_matches('"').to_owned();
    if value == "/dev/null" {
        return String::new();
    }
    if strip_prefix && (value.starts_with("a/") || value.starts_with("b/")) {
        value.drain(..2);
    }
    value
}

fn parse_patch(patch: &str) -> Vec<PatchFile> {
    let hunk_re = Regex::new(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@").unwrap();
    let mut files = Vec::new();
    let mut file: Option<PatchFile> = None;
    let mut hunk: Option<PatchHunk> = None;
    let flush_hunk = |file: &mut Option<PatchFile>, hunk: &mut Option<PatchHunk>| {
        if let (Some(file), Some(hunk)) = (file.as_mut(), hunk.take()) {
            file.hunks.push(hunk);
        }
    };
    let flush_file = |files: &mut Vec<PatchFile>, file: &mut Option<PatchFile>| {
        if let Some(file) = file.take() {
            files.push(file);
        }
    };
    for line in patch.lines() {
        if line.starts_with("diff --git ") {
            flush_hunk(&mut file, &mut hunk);
            flush_file(&mut files, &mut file);
            file = Some(PatchFile {
                status: "modified",
                ..Default::default()
            });
            continue;
        }
        let Some(_) = file.as_mut() else {
            continue;
        };
        if let Some(active) = hunk.as_mut() {
            let kind = line.chars().next().unwrap_or('\0');
            if matches!(kind, '+' | '-' | ' ') {
                active.lines.push(PatchLine {
                    kind,
                    text: line[1..].to_owned(),
                    no_newline: false,
                });
                continue;
            }
            if kind == '\\' {
                if let Some(previous) = active.lines.last_mut() {
                    previous.no_newline = true;
                }
                continue;
            }
            if line.is_empty() {
                continue;
            }
            flush_hunk(&mut file, &mut hunk);
        }
        let current = file.as_mut().unwrap();
        if let Some(captures) = hunk_re.captures(line) {
            hunk = Some(PatchHunk {
                header: line.to_owned(),
                new_start: captures[1].parse().unwrap_or(1),
                lines: Vec::new(),
            });
        } else if let Some(path) = line.strip_prefix("--- ") {
            let path = clean_patch_path(path, true);
            if path.is_empty() {
                current.status = "added";
            } else {
                current.old_path = path;
            }
        } else if let Some(path) = line.strip_prefix("+++ ") {
            let path = clean_patch_path(path, true);
            if path.is_empty() {
                current.status = "deleted";
            } else {
                current.new_path = path;
            }
        } else if let Some(path) = line.strip_prefix("rename from ") {
            current.old_path = clean_patch_path(path, false);
            current.status = "renamed";
        } else if let Some(path) = line.strip_prefix("rename to ") {
            current.new_path = clean_patch_path(path, false);
            current.status = "renamed";
        } else if line.starts_with("new file mode ") {
            current.status = "added";
        } else if line.starts_with("deleted file mode ") {
            current.status = "deleted";
        } else if line.starts_with("Binary files ") || line == "GIT binary patch" {
            current.binary = true;
        }
    }
    flush_hunk(&mut file, &mut hunk);
    flush_file(&mut files, &mut file);
    files
}

fn block_ids(hunk: &PatchHunk) -> Vec<Option<usize>> {
    let mut ids = vec![None; hunk.lines.len()];
    let mut runs: Vec<(usize, usize)> = Vec::new();
    let mut last_changed: Option<usize> = None;
    for (index, line) in hunk.lines.iter().enumerate() {
        if line.kind == ' ' {
            continue;
        }
        if let (Some(last), Some(run)) = (last_changed, runs.last_mut()) {
            if index - last - 1 <= 3 {
                run.1 = index;
            } else {
                runs.push((index, index));
            }
        } else {
            runs.push((index, index));
        }
        last_changed = Some(index);
    }
    for (id, (start, end)) in runs.into_iter().enumerate() {
        for item in ids.iter_mut().take(end + 1).skip(start) {
            *item = Some(id);
        }
    }
    ids
}

fn patch_path(file: &PatchFile) -> &str {
    if file.status == "renamed" {
        &file.new_path
    } else if !file.old_path.is_empty() {
        &file.old_path
    } else {
        &file.new_path
    }
}

fn quote_patch_path(path: &str) -> String {
    if !path.bytes().any(|byte| {
        byte.is_ascii_whitespace() || byte == b'"' || byte == b'\\' || byte < 32 || byte >= 127
    }) {
        return path.to_owned();
    }
    let mut result = String::from("\"");
    for byte in path.bytes() {
        match byte {
            b'"' | b'\\' => {
                result.push('\\');
                result.push(byte as char);
            }
            32..=126 => result.push(byte as char),
            _ => result.push_str(&format!("\\{byte:03o}")),
        }
    }
    result.push('"');
    result
}

fn selected_patch(file: &PatchFile, hunk: &PatchHunk, target: usize) -> Result<String, ApiError> {
    let ids = block_ids(hunk);
    if !ids.contains(&Some(target)) {
        return Err(ApiError::conflict("This change block no longer exists"));
    }
    let other_blocks = ids.iter().flatten().any(|id| *id != target);
    let old_path = patch_path(file);
    let new_path = if file.new_path.is_empty() {
        &file.old_path
    } else {
        &file.new_path
    };
    let mut output = Vec::new();
    if !other_blocks {
        let old = if file.status == "added" {
            "/dev/null".to_owned()
        } else {
            format!("a/{old_path}")
        };
        let new = if file.status == "deleted" {
            "/dev/null".to_owned()
        } else {
            format!("b/{new_path}")
        };
        output.extend([
            format!("--- {}", quote_patch_path(&old)),
            format!("+++ {}", quote_patch_path(&new)),
            hunk.header.clone(),
        ]);
        for line in &hunk.lines {
            output.push(format!("{}{}", line.kind, line.text));
            if line.no_newline {
                output.push("\\ No newline at end of file".into());
            }
        }
    } else {
        output.extend([
            format!("--- {}", quote_patch_path(&format!("a/{old_path}"))),
            format!("+++ {}", quote_patch_path(&format!("b/{new_path}"))),
        ]);
        let mut body = Vec::new();
        let mut old_count = 0;
        let mut new_count = 0;
        for (index, line) in hunk.lines.iter().enumerate() {
            if ids[index] == Some(target) && line.kind != ' ' {
                body.push(format!("{}{}", line.kind, line.text));
                if line.kind == '-' {
                    old_count += 1;
                } else {
                    new_count += 1;
                }
            } else if line.kind != '-' {
                body.push(format!(" {}", line.text));
                old_count += 1;
                new_count += 1;
            } else {
                continue;
            }
            if line.no_newline {
                body.push("\\ No newline at end of file".into());
            }
        }
        output.push(format!(
            "@@ -{},{} +{},{} @@",
            hunk.new_start, old_count, hunk.new_start, new_count
        ));
        output.extend(body);
    }
    Ok(output.join("\n") + "\n")
}

fn validate_discard_path(root: &str, relative: &str) -> Result<(), ApiError> {
    let relative = Path::new(relative);
    if relative.is_absolute()
        || relative
            .components()
            .any(|part| matches!(part, std::path::Component::ParentDir))
    {
        return Err(ApiError::bad_request("Invalid discard file path"));
    }
    let root = fs::canonicalize(root).map_err(ApiError::internal)?;
    let target = root.join(relative);
    let mut current = target.as_path();
    while current != root {
        if let Ok(metadata) = fs::symlink_metadata(current) {
            if metadata.file_type().is_symlink() {
                return Err(ApiError::forbidden(
                    "Use the terminal to discard symbolic-link changes",
                ));
            }
        }
        current = current
            .parent()
            .ok_or_else(|| ApiError::forbidden("Discard file is outside the worktree"))?;
    }
    Ok(())
}

pub async fn git_discard(Json(body): Json<Value>) -> ApiResult<Value> {
    let dir = body["path"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ApiError::bad_request("path required"))?;
    let selection = body["selection"]
        .as_array()
        .filter(|items| items.len() == 3)
        .and_then(|items| {
            Some([
                items[0].as_u64()? as usize,
                items[1].as_u64()? as usize,
                items[2].as_u64()? as usize,
            ])
        })
        .ok_or_else(|| ApiError::bad_request("Invalid discard selection"))?;
    let revision = body["revision"]
        .as_str()
        .filter(|value| Regex::new(r"^[a-f0-9]{64}$").unwrap().is_match(value))
        .ok_or_else(|| ApiError::bad_request("Invalid discard selection"))?;
    let mode = body["mode"]
        .as_str()
        .filter(|value| matches!(*value, "preview" | "apply"))
        .ok_or_else(|| ApiError::bad_request("Invalid discard selection"))?;
    let snapshot = match git(
        dir,
        vec![
            "diff".into(),
            "HEAD".into(),
            "--no-color".into(),
            "--no-ext-diff".into(),
        ],
        30,
    )
    .await
    {
        Ok(patch) => patch,
        Err(_) => git(
            dir,
            vec!["diff".into(), "--no-color".into(), "--no-ext-diff".into()],
            30,
        )
        .await
        .map_err(ApiError::internal)?,
    };
    if snapshot.len() > MAX_DIFF_BYTES {
        return Err(ApiError::status(
            axum::http::StatusCode::PAYLOAD_TOO_LARGE,
            "Diff too large to discard from this view",
        ));
    }
    if format!("{:x}", Sha256::digest(snapshot.as_bytes())) != revision {
        return Err(ApiError::conflict(
            "Changes changed on disk. Refresh and review this block again.",
        ));
    }
    let files = parse_patch(&snapshot);
    let file = files
        .get(selection[0])
        .ok_or_else(|| ApiError::conflict("This change block no longer exists"))?;
    if file.binary {
        return Err(ApiError::conflict("This change block no longer exists"));
    }
    let hunk = file
        .hunks
        .get(selection[1])
        .ok_or_else(|| ApiError::conflict("This change block no longer exists"))?;
    let relative = patch_path(file);
    validate_discard_path(dir, relative)?;
    let patch = selected_patch(file, hunk, selection[2])?;
    if patch.len() > 1024 * 1024 {
        return Err(ApiError::status(
            axum::http::StatusCode::PAYLOAD_TOO_LARGE,
            "Change block too large to discard from this view",
        ));
    }
    if mode == "preview" {
        return Ok(Json(
            json!({"ok":true,"path":relative,"patch":patch,"revision":revision,"selection":selection}),
        ));
    }
    let result = cli::run_with_input(
        "git",
        ["-C", dir, "apply", "-R", "-"],
        patch.as_bytes(),
        Duration::from_secs(30),
        None,
    )
    .await;
    Ok(Json(match result {
        Ok(_) => json!({"ok":true}),
        Err(e) => json!({"error":e.to_string()}),
    }))
}

#[cfg(test)]
mod file_match_tests {
    use super::file_match_rank;

    #[test]
    fn ranks_name_hits_above_folder_hits_above_subsequences() {
        assert_eq!(file_match_rank("macos/App/AppDelegate.swift", "appd"), Some(0));
        assert_eq!(file_match_rank("macos/App/AppDelegate.swift", "delegate"), Some(1));
        assert_eq!(file_match_rank("macos/App/AppDelegate.swift", "macos/app"), Some(2));
        assert_eq!(file_match_rank("macos/Scenes/SessionWorkspaceViewModel.swift", "swvm"), Some(3));
        assert_eq!(file_match_rank("README.md", "zzz"), None);
    }
}
