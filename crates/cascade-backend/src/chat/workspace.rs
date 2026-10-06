//! The chat page's reads of the folder a chat works in: the `@` menu (`projects.searchEntries`),
//! file-reference previews (`projects.readFile`) and which references name a file
//! (`projects.resolveWorkspaceFileReferences`). Each resolves against the chat's folder, which
//! the caller works out (`chat::working_folder`: the thread's own working folder when the call
//! names a thread the engine has, the page's `cwd` only when it names none yet), and never reads
//! outside it: a path that leaves it, by `..`, an absolute path or a symbolic link, is refused.

use std::{
    collections::{HashMap, HashSet},
    fs,
    io::{self, Read},
    os::unix::fs::OpenOptionsExt,
    path::{Component, Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use super::{flight::Flights, params, RpcError, RpcResult};
use crate::cli;

/// How long a folder's file list stands; the `@` menu asks on every keystroke.
const INDEX_TTL: Duration = Duration::from_secs(10);
/// The most files one folder lists, so a home folder cannot hand the page a list it chokes on.
const MAX_FILES: usize = 25_000;
/// The most folders the cache keeps.
const MAX_FOLDERS: usize = 16;
/// Synara's `PROJECT_SEARCH_ENTRIES_MAX_LIMIT`.
const MAX_SEARCH_LIMIT: usize = 200;
/// Synara's `PROJECT_READ_FILE_MAX_BYTES`.
const MAX_READ_BYTES: usize = 1_000_000;
/// Folders a walk of a folder git does not know skips: what they hold is never what is meant.
const SKIPPED: [&str; 6] = ["node_modules", "target", ".build", "DerivedData", "build", "dist"];

/// The file lists of the folders chats work in, each kept for `INDEX_TTL`; calls that come
/// while a folder is being listed wait for that listing.
pub(super) struct Index {
    folders: Flights<PathBuf, Arc<Vec<String>>>,
}

impl Default for Index {
    fn default() -> Self {
        Self { folders: Flights::new(INDEX_TTL, MAX_FOLDERS) }
    }
}

impl Index {
    /// `root`'s files, relative to it, `/`-separated: what git lists in a checkout (tracked and
    /// untracked but not ignored), else a walk that skips hidden and build folders.
    async fn files(&self, root: &Path) -> Arc<Vec<String>> {
        self.folders.get(&root.to_path_buf(), || async { Arc::new(list_files(root).await) }).await
    }
}

async fn list_files(root: &Path) -> Vec<String> {
    let git = cli::run_nul(
        "git",
        ["--no-optional-locks", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        None,
        Duration::from_secs(20),
        Some(root),
        &[],
    )
    .await;
    if let Ok(records) = git {
        let mut files: Vec<String> = records.into_iter().map(|record| String::from_utf8_lossy(&record).into_owned()).collect();
        files.sort_unstable();
        files.dedup();
        files.truncate(MAX_FILES);
        return files;
    }
    let root = root.to_path_buf();
    tokio::task::spawn_blocking(move || walk(&root)).await.unwrap_or_default()
}

fn walk(root: &Path) -> Vec<String> {
    let mut files = Vec::new();
    let mut pending = vec![(root.to_path_buf(), 0usize)];
    while let Some((dir, depth)) = pending.pop() {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                continue;
            }
            // Not followed: a link may lead out of the folder.
            let Ok(kind) = entry.file_type() else { continue };
            let path = entry.path();
            if kind.is_dir() {
                if depth < 12 && !SKIPPED.contains(&name.as_str()) {
                    pending.push((path, depth + 1));
                }
            } else if kind.is_file() {
                if let Ok(relative) = path.strip_prefix(root) {
                    files.push(relative.to_string_lossy().into_owned());
                    if files.len() >= MAX_FILES {
                        files.sort_unstable();
                        return files;
                    }
                }
            }
        }
    }
    files.sort_unstable();
    files
}

/// The chat's folder: absolute, there, and a directory; answered as its real path, so a path
/// read in it is compared with what it really is.
fn root(folder: &str) -> Result<PathBuf, RpcError> {
    let path = Path::new(folder.trim());
    if !path.is_absolute() {
        return Err(RpcError::invalid("cwd must be an absolute path"));
    }
    let real = fs::canonicalize(path).map_err(|_| RpcError::not_found("The folder is not there."))?;
    if !real.is_dir() {
        return Err(RpcError::invalid("cwd is not a folder"));
    }
    Ok(real)
}

/// A workspace-relative path with its `.` parts dropped, `/`-separated; `None` for one that is
/// absolute, empty, or climbs out with `..` (Synara `isWorkspaceRelativePathSafe`).
fn normalized_relative(reference: &str) -> Option<String> {
    let trimmed = reference.trim();
    if trimmed.is_empty() || trimmed.contains('\0') {
        return None;
    }
    let mut parts = Vec::new();
    for component in Path::new(trimmed).components() {
        match component {
            Component::Normal(part) => parts.push(part.to_string_lossy().into_owned()),
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    (!parts.is_empty()).then(|| parts.join("/"))
}

/// The file `relative` names inside `root`, opened, following links only as far as `root`
/// reaches: its normalized path, the open file, and whether the name was a link.
///
/// What is checked is what was opened, not a path that could change between a check and an
/// open: the link the name may be is resolved first, so a link that stays inside is read, but
/// the open itself follows no link in the last part, and the opened file's own path
/// (`F_GETPATH`) must then lie inside the root. A folder or link swapped in on the way in is
/// either not opened or refused after.
fn open_inside(root: &Path, relative: &str) -> Result<(String, fs::File, bool), RpcError> {
    let normalized = normalized_relative(relative).ok_or_else(|| RpcError::invalid("The path leaves the folder."))?;
    let joined = root.join(&normalized);
    let symlink = fs::symlink_metadata(&joined).map_err(|_| RpcError::not_found("The file is not there."))?.file_type().is_symlink();
    let real = fs::canonicalize(&joined).map_err(|_| RpcError::not_found("The file is not there."))?;
    let file = fs::OpenOptions::new()
        .read(true)
        // Non-blocking, so a FIFO is not waited on; it is then not a file, and refused.
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(&real)
        .map_err(|error| match error.raw_os_error() {
            Some(libc::ELOOP) => RpcError::invalid("The path leaves the folder."),
            _ => RpcError::not_found("The file is not there."),
        })?;
    confined(&file, root)?;
    Ok((normalized, file, symlink))
}

/// Refuses an open file whose real path is not inside `root`.
fn confined(file: &fs::File, root: &Path) -> Result<(), RpcError> {
    let opened = path_of(file).map_err(RpcError::internal)?;
    if !opened.starts_with(root) {
        return Err(RpcError::invalid("The path leaves the folder."));
    }
    Ok(())
}

/// The path the system knows an open file by.
#[cfg(target_os = "macos")]
fn path_of(file: &fs::File) -> io::Result<PathBuf> {
    use std::os::{fd::AsRawFd, unix::ffi::OsStringExt};
    let mut buffer = vec![0u8; libc::PATH_MAX as usize];
    // SAFETY: F_GETPATH writes at most MAXPATHLEN (PATH_MAX) bytes, NUL-terminated, into the buffer.
    if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETPATH, buffer.as_mut_ptr()) } == -1 {
        return Err(io::Error::last_os_error());
    }
    let length = buffer.iter().position(|byte| *byte == 0).unwrap_or(buffer.len());
    buffer.truncate(length);
    Ok(PathBuf::from(std::ffi::OsString::from_vec(buffer)))
}

#[cfg(not(target_os = "macos"))]
fn path_of(file: &fs::File) -> io::Result<PathBuf> {
    use std::os::fd::AsRawFd;
    fs::read_link(format!("/proc/self/fd/{}", file.as_raw_fd()))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SearchParams {
    #[serde(default)]
    query: String,
    #[serde(default)]
    limit: Option<usize>,
    #[serde(default)]
    kind: Option<String>,
}

/// Files and the folders that hold them whose path answers the query, best first, as the
/// Files pane's search ranks them (`local::file_match_rank`).
pub(super) async fn search_entries(index: &Index, folder: &str, raw: Value) -> RpcResult {
    let SearchParams { query, limit, kind } = params(raw)?;
    let root = root(folder)?;
    let files = index.files(&root).await;
    let needle = query.trim().trim_start_matches('@').to_lowercase();
    let limit = limit.unwrap_or(50).clamp(1, MAX_SEARCH_LIMIT);
    let want_files = kind.as_deref() != Some("directory");
    let want_folders = kind.as_deref() != Some("file");
    let mut folders = HashSet::new();
    if want_folders {
        for file in files.iter() {
            let mut path = file.as_str();
            while let Some((parent, _)) = path.rsplit_once('/') {
                if !folders.insert(parent.to_owned()) {
                    break;
                }
                path = parent;
            }
        }
    }
    let mut ranked: Vec<(u8, &str, &str)> = Vec::new();
    let entries = files
        .iter()
        .filter(|_| want_files)
        .map(|path| (path.as_str(), "file"))
        .chain(folders.iter().map(|path| (path.as_str(), "directory")));
    for (path, kind) in entries {
        let rank = if needle.is_empty() { Some(0) } else { crate::local::file_match_rank(path, &needle) };
        if let Some(rank) = rank {
            ranked.push((rank, path, kind));
        }
    }
    ranked.sort_by(|a, b| (a.0, a.1.len(), a.1).cmp(&(b.0, b.1.len(), b.1)));
    let truncated = ranked.len() > limit;
    let entries: Vec<Value> = ranked
        .into_iter()
        .take(limit)
        .map(|(_, path, kind)| {
            let mut entry = json!({ "path": path, "kind": kind });
            if let Some((parent, _)) = path.rsplit_once('/') {
                entry["parentPath"] = json!(parent);
            }
            entry
        })
        .collect();
    Ok(json!({ "entries": entries, "truncated": truncated }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReadParams {
    relative_path: String,
    #[serde(default)]
    max_bytes: Option<usize>,
}

/// A text file's start, for a reference's hover preview: Synara's `ProjectReadFileResult`.
pub(super) async fn read_file(folder: &str, raw: Value) -> RpcResult {
    let ReadParams { relative_path, max_bytes } = params(raw)?;
    let root = root(folder)?;
    let limit = max_bytes.unwrap_or(MAX_READ_BYTES).clamp(1, MAX_READ_BYTES);
    tokio::task::spawn_blocking(move || {
        let (relative, file, symlink) = open_inside(&root, &relative_path)?;
        read_text(&relative, file, symlink, limit)
    })
    .await
    .map_err(RpcError::internal)?
}

fn read_text(relative: &str, file: fs::File, symlink: bool, limit: usize) -> RpcResult {
    let metadata = file.metadata().map_err(RpcError::internal)?;
    if !metadata.is_file() {
        return Err(RpcError::invalid("Not a file."));
    }
    let mut bytes = Vec::with_capacity(limit.min(metadata.len() as usize) + 1);
    file.take(limit as u64 + 1).read_to_end(&mut bytes).map_err(RpcError::internal)?;
    let truncated = bytes.len() > limit;
    bytes.truncate(limit);
    if bytes.contains(&0) {
        return Err(RpcError::invalid("Not a text file."));
    }
    let bom = bytes.starts_with(&[0xEF, 0xBB, 0xBF]);
    let body = if bom { &bytes[3..] } else { &bytes[..] };
    let contents = match std::str::from_utf8(body) {
        Ok(text) => text.to_owned(),
        // A cut in the middle of a character is not a file that is not UTF-8.
        Err(error) if truncated && error.error_len().is_none() => String::from_utf8_lossy(&body[..error.valid_up_to()]).into_owned(),
        Err(_) => return Err(RpcError::invalid("Not a UTF-8 text file.")),
    };
    let mut hash = Sha256::new();
    hash.update(metadata.len().to_le_bytes());
    if let Ok(modified) = metadata.modified().and_then(|time| time.duration_since(std::time::UNIX_EPOCH).map_err(std::io::Error::other)) {
        hash.update(modified.as_nanos().to_le_bytes());
    }
    hash.update(&bytes);
    let mut result = json!({
        "relativePath": relative,
        "contents": contents,
        "truncated": truncated,
        "version": format!("{:x}", hash.finalize()),
        "encoding": if bom { "utf8-bom" } else { "utf8" },
        "lineEnding": line_ending(&contents),
    });
    if symlink {
        result["symlink"] = json!(true);
    }
    Ok(result)
}

fn line_ending(text: &str) -> &'static str {
    let crlf = text.matches("\r\n").count();
    let cr = text.matches('\r').count() - crlf;
    let lf = text.matches('\n').count() - crlf;
    match (crlf > 0, cr > 0, lf > 0) {
        (true, false, false) => "crlf",
        (false, true, false) => "cr",
        (false, false, _) => "lf",
        _ => "mixed",
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReferenceParams {
    relative_paths: Vec<String>,
}

/// Which references name a file in the folder, and which: the one file the reference is the path
/// or a path suffix of, or null when none or more than one is (Synara
/// `resolveWorkspaceFileReferenceFromIndex`).
pub(super) async fn resolve_references(index: &Index, folder: &str, raw: Value) -> RpcResult {
    let ReferenceParams { relative_paths } = params(raw)?;
    let root = root(folder)?;
    let files = index.files(&root).await;
    let mut by_name: HashMap<&str, Vec<&str>> = HashMap::new();
    for file in files.iter() {
        let name = file.rsplit('/').next().unwrap_or(file);
        by_name.entry(name).or_default().push(file);
    }
    let resolved: Vec<Value> = relative_paths
        .iter()
        .take(128)
        .map(|reference| {
            let Some(normalized) = normalized_relative(reference) else { return Value::Null };
            let name = normalized.rsplit('/').next().unwrap_or(&normalized);
            let suffix = format!("/{normalized}");
            let mut found = by_name
                .get(name)
                .into_iter()
                .flatten()
                .filter(|candidate| **candidate == normalized || candidate.ends_with(&suffix));
            match (found.next(), found.next()) {
                (Some(only), None) => json!(only),
                _ => Value::Null,
            }
        })
        .collect();
    Ok(json!({ "relativePaths": resolved }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reference_that_climbs_out_or_is_absolute_is_not_a_workspace_path() {
        assert_eq!(normalized_relative("./src/a.rs").as_deref(), Some("src/a.rs"));
        assert_eq!(normalized_relative("src//b/./c.rs").as_deref(), Some("src/b/c.rs"));
        assert_eq!(normalized_relative("../secret"), None);
        assert_eq!(normalized_relative("a/../../b"), None);
        assert_eq!(normalized_relative("/etc/passwd"), None);
        assert_eq!(normalized_relative("  "), None);
    }

    #[test]
    fn an_open_file_outside_the_root_is_refused_by_its_real_path() {
        let outside = tempfile::tempdir().unwrap();
        let root = fs::canonicalize(outside.path()).unwrap().join("work");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("in.txt"), "in").unwrap();
        fs::write(outside.path().join("out.txt"), "out").unwrap();
        let inside = fs::File::open(root.join("in.txt")).unwrap();
        assert_eq!(path_of(&inside).unwrap(), root.join("in.txt"));
        assert!(confined(&inside, &root).is_ok());
        let foreign = fs::File::open(outside.path().join("out.txt")).unwrap();
        assert_eq!(confined(&foreign, &root).unwrap_err().code, Some("invalid"));
    }

    #[test]
    fn the_last_part_is_opened_without_following_a_link() {
        let dir = tempfile::tempdir().unwrap();
        let root = fs::canonicalize(dir.path()).unwrap();
        fs::write(root.join("a.txt"), "a").unwrap();
        std::os::unix::fs::symlink(root.join("a.txt"), root.join("link2.txt")).unwrap();
        let (relative, _, symlink) = open_inside(&root, "link2.txt").unwrap();
        assert_eq!((relative.as_str(), symlink), ("link2.txt", true), "a link inside is resolved, then opened");
        let error = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(root.join("link2.txt"))
            .unwrap_err();
        assert_eq!(error.raw_os_error(), Some(libc::ELOOP), "the open itself never follows one");
        let (_, file, _) = open_inside(&root, "a.txt").unwrap();
        assert!(read_text("a.txt", file, false, 10).is_ok());
        fs::create_dir(root.join("folder")).unwrap();
        let (_, folder, _) = open_inside(&root, "folder").unwrap();
        assert_eq!(read_text("folder", folder, false, 10).unwrap_err().code, Some("invalid"));
    }

    #[test]
    fn line_endings_are_told_apart() {
        assert_eq!(line_ending("a\nb\n"), "lf");
        assert_eq!(line_ending("a\r\nb\r\n"), "crlf");
        assert_eq!(line_ending("a\rb"), "cr");
        assert_eq!(line_ending("a\r\nb\n"), "mixed");
        assert_eq!(line_ending("one line"), "lf");
    }
}
