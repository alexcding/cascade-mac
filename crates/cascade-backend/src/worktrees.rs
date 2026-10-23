//! What Settings → Worktrees changes about a session's worktree: where a new one lands, which
//! ignored files follow it from the main checkout, and the command that prepares it. Every option
//! is read from `config` at the moment it is used, so a change applies to the next worktree
//! without a restart.

use std::{
    collections::HashMap,
    fs, io,
    os::unix::ffi::OsStringExt,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use serde_json::json;
use sha2::{Digest, Sha256};

use crate::{cli, local::resolve_path, AppState};
use crate::Project;

pub(crate) const LOCATION: &str = "worktree_location";
pub(crate) const ROOT: &str = "worktree_root";
pub(crate) const INCLUDE: &str = "worktree_include";
pub(crate) const FETCH: &str = "worktree_fetch";
/// What a checkout with no `.worktreeinclude` copies when Settings never named its own patterns.
pub(crate) const DEFAULT_INCLUDE: &str = ".env*";
/// The file a repo commits to name its own patterns. It wins over Settings outright, as it does in
/// the other tools that read it: a repo that ships one has said exactly what it needs.
const INCLUDE_FILE: &str = ".worktreeinclude";
/// Long enough for a dependency install on a cold cache, short enough that a command waiting on
/// input it will never get does not sit in the process table all day.
const SETUP_TIMEOUT: Duration = Duration::from_secs(20 * 60);
/// The most an opted-in fetch may add to New Session. A fetch from the app (a GUI credential
/// helper, a slow remote) can take far longer than from a shell; past this the local ref is used.
const FETCH_TIMEOUT: Duration = Duration::from_secs(8);
/// How long the branch picker's fetch may take. Longer than `FETCH_TIMEOUT`, since nothing waits
/// on it: the picker shows what the checkout has and reads again when the fetch lands.
const PICKER_FETCH_TIMEOUT: Duration = Duration::from_secs(20);
/// A picker opened again within this of the last fetch of its checkout fetches nothing.
const PICKER_FETCH_INTERVAL: Duration = Duration::from_secs(60);
/// The part of a failed setup's output worth keeping in Activity.
const OUTPUT_TAIL: usize = 2000;

#[derive(Debug, PartialEq)]
pub(crate) enum Location {
    /// `<workspace>.worktrees/<leaf>`, beside the checkout: what every worktree made before the
    /// shared folder became the default already uses.
    Sibling,
    /// `<workspace>/.worktrees/<leaf>`, hidden from git through `info/exclude`.
    Inside,
    /// `<folder>/<repo folder>/<leaf>`, so one folder can hold every project's worktrees. The
    /// default is Cascade's own, `~/.cascade/worktrees`.
    Custom(PathBuf),
}

/// Where new worktrees land unless Settings names another place: one folder for every project,
/// out of the way of the checkouts themselves.
pub(crate) const DEFAULT_ROOT: &str = "~/.cascade/worktrees";

/// `DEFAULT_ROOT`, or the folder `CASCADE_WORKTREES_DIR` names in its place, as `CASCADE_DATA_DIR`
/// does for the data folder: a test or a development build keeps out of the real one, and out of
/// its one-time offer to move worktrees there (`local::relocate`).
pub(crate) fn default_root() -> PathBuf {
    match std::env::var("CASCADE_WORKTREES_DIR") {
        Ok(dir) if !dir.trim().is_empty() => resolve_path(dir.trim()),
        _ => resolve_path(DEFAULT_ROOT),
    }
}

async fn config(app: &AppState, key: &str) -> Option<String> {
    app.db.config_value(key).await.ok().flatten()
}

pub(crate) async fn location(app: &AppState) -> Location {
    match config(app, LOCATION).await.as_deref() {
        Some("sibling") => Location::Sibling,
        Some("inside") => Location::Inside,
        Some("custom") => match config(app, ROOT).await.filter(|v| !v.trim().is_empty()) {
            Some(root) => Location::Custom(resolve_path(root.trim())),
            // A custom location with no folder yet is a setting half made, not a reason to fail
            // New Session: keep landing where the default puts them.
            None => Location::Custom(default_root()),
        },
        // Nothing stored: `settle_location` could not write its answer. Where worktrees always
        // went, so an existing install is never moved without being asked.
        None => Location::Sibling,
        _ => Location::Custom(default_root()),
    }
}

/// The folders that hold every project's worktrees: Cascade's own, and the custom one Settings
/// names. A worktree there outlives a project removed from Cascade or a checkout deleted from
/// under it, so Settings lists what such a folder holds (`local::shared_worktrees_route`).
/// A custom folder counts while Settings still names it, chosen now or not: switching away leaves
/// its worktrees there, and they are listed until they are deleted.
pub(crate) async fn shared_roots(app: &AppState) -> Vec<PathBuf> {
    let mut roots = vec![default_root()];
    if let Some(folder) = config(app, ROOT).await.filter(|v| !v.trim().is_empty()) {
        let folder = resolve_path(folder.trim());
        if !roots.contains(&folder) {
            roots.push(folder);
        }
    }
    roots
}

/// Settles once, at the first start of this version, where an install's new worktrees go when it
/// never chose: one that already has projects or sessions is an install from before Cascade's
/// folder, and keeps making them next to the checkout as it always has; only a clean install
/// starts with Cascade's folder. Stored, so Settings shows it and it never changes on its own.
/// Unreadable counts as used: an existing install is never moved on a guess.
pub async fn settle_location(app: &AppState) {
    if config(app, LOCATION).await.is_some() {
        return;
    }
    let used = app.db.projects().await.map_or(true, |p| !p.is_empty())
        || app.db.tasks().await.map_or(true, |t| !t.is_empty());
    let settled = json!({ LOCATION: if used { "sibling" } else { "cascade" } });
    if let Err(error) = app.db.set_config(settled.as_object().unwrap()).await {
        tracing::warn!(%error, "worktrees: where new worktrees go was not stored; next to the checkout until it is");
    }
}

/// The folder a project's new worktrees are made in.
pub(crate) fn root(workspace: &str, location: &Location) -> PathBuf {
    let workspace = workspace.trim_end_matches('/');
    match location {
        Location::Sibling => PathBuf::from(format!("{workspace}.worktrees")),
        Location::Inside => Path::new(workspace).join(".worktrees"),
        Location::Custom(folder) => folder.join(project_folder(workspace)),
    }
}

/// Whether a folder in a shared root is one `project_folder` named. A shared root may be a custom
/// folder that holds other things, and only what Cascade made there is its to list or delete.
pub(crate) fn is_project_folder(name: &str) -> bool {
    name.rsplit_once('-').is_some_and(|(stem, hash)| {
        !stem.is_empty() && hash.len() == 8 && hash.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
    })
}

/// `<checkout folder>-<8 hex of its path>`: the name keeps it recognisable, the hash keeps
/// `~/work/app` and `~/oss/app` from sharing one folder and colliding on a common branch name.
fn project_folder(workspace: &str) -> String {
    let name = Path::new(workspace)
        .file_name()
        .and_then(|v| v.to_str())
        .unwrap_or("project");
    let digest = Sha256::digest(workspace.as_bytes());
    let short: String = digest[..4].iter().map(|b| format!("{b:02x}")).collect();
    format!("{name}-{short}")
}

/// Keeps `.worktrees/` inside the checkout out of `git status`. It goes in the repository's own
/// `info/exclude` rather than `.gitignore`, so choosing this location never leaves a change to
/// commit, and in the COMMON git dir, which is the one every linked worktree reads.
pub(crate) async fn exclude_inside_root(dir: &str) -> io::Result<()> {
    let common = cli::run(
        "git",
        ["-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir"],
        Duration::from_secs(15),
    )
    .await
    .map_err(io::Error::other)?;
    let info = Path::new(common.trim()).join("info");
    let file = info.join("exclude");
    let current = fs::read_to_string(&file).unwrap_or_default();
    if current
        .lines()
        .any(|line| matches!(line.trim(), "/.worktrees/" | ".worktrees/" | "/.worktrees" | ".worktrees"))
    {
        return Ok(());
    }
    fs::create_dir_all(&info)?;
    let separator = if current.is_empty() || current.ends_with('\n') { "" } else { "\n" };
    fs::write(&file, format!("{current}{separator}/.worktrees/\n"))
}

/// A field of the project whose workspace is `dir`, when it holds more than whitespace. Worktree
/// requests carry the checkout path, not a project id; one repo per project makes that the key.
async fn project_field(app: &AppState, dir: &Path, field: fn(&Project) -> &str) -> Option<String> {
    let dir = resolve_path(&dir.to_string_lossy());
    app.db
        .projects()
        .await
        .ok()?
        .into_iter()
        .find(|project| {
            !project.workspace.is_empty()
                && resolve_path(project.workspace.trim_end_matches('/')) == dir
        })
        .map(|project| field(&project).to_owned())
        .filter(|value| !value.trim().is_empty())
}

/// Include patterns in gitignore syntax, from the first of: the repo's `.worktreeinclude`, the
/// project's own patterns, the default in Settings, `.env*`. Comments and blank lines are dropped
/// here, since each pattern goes to git as its own `-x`.
async fn include_patterns(app: &AppState, source: &Path) -> Vec<String> {
    let text = match fs::read_to_string(source.join(INCLUDE_FILE)).ok() {
        Some(text) => text,
        None => match project_field(app, source, |project| &project.worktree_include).await {
            Some(text) => text,
            None => config(app, INCLUDE)
                .await
                .unwrap_or_else(|| DEFAULT_INCLUDE.to_owned()),
        },
    };
    parse_patterns(&text)
}

pub(crate) fn parse_patterns(text: &str) -> Vec<String> {
    text.lines()
        .map(|line| line.trim_end())
        .filter(|line| !line.trim().is_empty() && !line.starts_with('#'))
        .map(str::to_owned)
        .collect()
}

/// The files to copy: untracked files in `source` that match the include patterns AND that git
/// itself ignores. Git answers both halves, so the patterns mean exactly what they would in a
/// `.gitignore` (negation, anchors, `**`, directories) and a tracked or merely untracked file
/// can never be picked up, however broad a pattern is.
///
/// Paths stay raw bytes end to end: a name that is not UTF-8 is still a file git reports, and
/// a lossy decode would ask `check-ignore` about, and copy, some other path.
async fn included_files(source: &Path, patterns: &[String]) -> anyhow::Result<Vec<PathBuf>> {
    if patterns.is_empty() {
        return Ok(vec![]);
    }
    // `-x` patterns keep their order, and the last match wins, so a later `!` re-includes as it
    // does in a `.gitignore`.
    let mut args: Vec<String> = ["ls-files", "--others", "--ignored", "-z"]
        .map(str::to_owned)
        .to_vec();
    for pattern in patterns {
        args.push("-x".into());
        args.push(pattern.clone());
    }
    let matching =
        cli::run_nul("git", args, None, Duration::from_secs(60), Some(source), &[]).await?;
    if matching.is_empty() {
        return Ok(vec![]);
    }
    let input: Vec<u8> = matching
        .iter()
        .flat_map(|path| path.iter().copied().chain([0]))
        .collect();
    // Exits 1 when none of them are ignored: an empty answer, not a failure worth telling.
    let ignored = cli::run_nul(
        "git",
        ["check-ignore", "--stdin", "-z"],
        Some(&input),
        Duration::from_secs(60),
        Some(source),
        &[1],
    )
    .await?;
    Ok(ignored
        .into_iter()
        .map(|path| PathBuf::from(std::ffi::OsString::from_vec(path)))
        .collect())
}

#[derive(Default, Debug, PartialEq)]
pub(crate) struct Copied {
    pub copied: usize,
    /// Already present in the new worktree. Never overwritten: nothing here deletes or replaces.
    pub skipped: usize,
    pub failed: Vec<String>,
}

/// Copies the included ignored files from `source` into the new worktree at `destination`.
pub(crate) async fn copy_included(app: &AppState, source: &Path, destination: &Path) -> Copied {
    let patterns = include_patterns(app, source).await;
    // Git failing to answer is reported like a file that failed to copy, so Activity says why a
    // worktree came up without its .env instead of the create looking as though nothing matched.
    let files = match included_files(source, &patterns).await {
        Ok(files) => files,
        Err(error) => {
            return Copied {
                failed: vec![format!("listing files to copy: {}", crate::local::error_line(&error.to_string()))],
                ..Copied::default()
            }
        }
    };
    if files.is_empty() {
        return Copied::default();
    }
    let (source, destination) = (source.to_owned(), destination.to_owned());
    tokio::task::spawn_blocking(move || copy_files(&source, &destination, &files))
        .await
        .unwrap_or_default()
}

pub(crate) fn copy_files(source: &Path, destination: &Path, files: &[PathBuf]) -> Copied {
    let mut result = Copied::default();
    for rel in files {
        // Git reports paths inside the checkout; anything else is not ours to write.
        if rel
            .components()
            .any(|c| !matches!(c, std::path::Component::Normal(_)))
        {
            continue;
        }
        let (from, to) = (source.join(rel), destination.join(rel));
        let name = rel.display();
        // A tracked symlink in the new checkout (`config -> /etc`) would carry the copy outside
        // the worktree; the file is left behind instead.
        if linked_parent(destination, rel) {
            result.failed.push(format!("{name}: a folder on its path is a symlink"));
            continue;
        }
        if to.symlink_metadata().is_ok() {
            result.skipped += 1;
            continue;
        }
        match copy_one(&from, &to) {
            Ok(()) => result.copied += 1,
            Err(error) => result.failed.push(format!("{name}: {error}")),
        }
    }
    result
}

fn linked_parent(root: &Path, rel: &Path) -> bool {
    let mut path = root.to_owned();
    let Some(parent) = rel.parent() else {
        return false;
    };
    parent.components().any(|part| {
        path.push(part);
        path.symlink_metadata()
            .is_ok_and(|meta| meta.file_type().is_symlink())
    })
}

/// A symlink is recreated as a link, not followed, and keeps pointing where it did: a relative
/// target is resolved against the original's folder, since the same text read from inside the
/// worktree would name somewhere else. `fs::copy` clones on APFS, so a large file costs no space.
fn copy_one(from: &Path, to: &Path) -> io::Result<()> {
    if let Some(parent) = to.parent() {
        fs::create_dir_all(parent)?;
    }
    let meta = from.symlink_metadata()?;
    if meta.file_type().is_symlink() {
        let target = fs::read_link(from)?;
        let target = match from.parent() {
            Some(parent) if target.is_relative() => parent.join(target),
            _ => target,
        };
        std::os::unix::fs::symlink(target, to)
    } else {
        fs::copy(from, to).map(|_| ())
    }
}

/// Runs the project's setup script in the new worktree, in the background. It never blocks or
/// fails New Session: the outcome goes to Activity, and a `worktree-setup` event says when it is
/// done. The script is per project only, since one command rarely suits every repo.
pub(crate) async fn spawn_setup(app: &AppState, source: &str, worktree: &Path, branch: &str) {
    let Some(command) = project_field(app, Path::new(source), |project| &project.worktree_setup).await else {
        return;
    };
    let app = app.clone();
    let source = source.to_owned();
    let worktree = worktree.to_string_lossy().into_owned();
    let branch = branch.to_owned();
    tokio::spawn(async move {
        app.publish(crate::Event::WorktreeSetup { worktree: worktree.clone(), state: "running", error: String::new() });
        let shell = std::env::var("SHELL")
            .ok()
            .filter(|v| v.starts_with('/'))
            .unwrap_or_else(|| "/bin/zsh".into());
        let result = cli::run_in_env(
            &shell,
            ["-lc", command.as_str()],
            SETUP_TIMEOUT,
            Some(Path::new(&worktree)),
            &[
                ("CASCADE_ROOT_PATH", source.as_str()),
                ("CASCADE_WORKTREE_PATH", worktree.as_str()),
                ("CASCADE_BRANCH", branch.as_str()),
            ],
        )
        .await;
        let (state, level, kind, detail) = match &result {
            Ok(_) => ("ready", "info", "worktree_setup_finished", String::new()),
            Err(error) => ("failed", "error", "worktree_setup_failed", tail(&error.to_string())),
        };
        let _ = app.db.add_log(
            "worktree",
            level,
            kind,
            &json!({"worktree":worktree,"command":command,"error":detail}),
        ).await;
        app.publish(crate::Event::WorktreeSetup { worktree: worktree.clone(), state, error: detail });
    });
}

fn tail(text: &str) -> String {
    let text = text.trim();
    let start = text.len().saturating_sub(OUTPUT_TAIL);
    let start = (start..text.len()).find(|&i| text.is_char_boundary(i)).unwrap_or(text.len());
    text[start..].to_owned()
}

/// Refreshes `origin/<base>` before a new branch is cut from it, when Settings asks for that.
/// Off by default: worktree creation otherwise never waits on the network. A fetch that fails or
/// runs out of time is not an error, since the branch is then cut from the tip the checkout has.
pub(crate) async fn fetch_base(app: &AppState, dir: &str, base: &str) {
    if !matches!(config(app, FETCH).await.as_deref(), Some("true" | "1")) {
        return;
    }
    if let Err(reason) = fetch(dir, Some(base), false, FETCH_TIMEOUT).await {
        let _ = app.db.add_log(
            "worktree",
            "info",
            "worktree_fetch_skipped",
            &json!({"base":base,"reason":reason}),
        ).await;
    }
}

/// The one way the app fetches from origin: one branch or all of them, with or without pruning
/// what origin no longer has, never tags, within `timeout`. A failure is the line git gave.
pub(crate) async fn fetch(
    dir: &str,
    branch: Option<&str>,
    prune: bool,
    timeout: Duration,
) -> Result<(), String> {
    let mut args = vec!["-C", dir, "fetch", "--no-tags"];
    if prune {
        args.push("--prune");
    }
    args.push("origin");
    if let Some(branch) = branch {
        args.extend(["--", branch]);
    }
    cli::run("git", args, timeout)
        .await
        .map(|_| ())
        .map_err(|e| crate::local::error_line(&e.to_string()))
}

/// What a picker's fetch of origin came to.
#[derive(Debug, PartialEq)]
pub(crate) enum Fetched {
    /// Origin was fetched now.
    Fresh,
    /// A fetch within the interval stands; nothing was run.
    Recent,
    /// The fetch failed for this reason; what the checkout has stands.
    Failed(String),
}

/// The pickers' fetches of origin, paced and run one at a time per checkout, so two composers on
/// one checkout share one fetch and the app keeps no timer of its own. Only pickers go through
/// here: a worktree being added never waits on a picker's fetch (git's own ref locks keep the
/// two apart, and a fetch that loses to one is a failed fetch, tried again after the interval).
#[derive(Default)]
pub struct Fetches {
    checkouts: Mutex<HashMap<String, Arc<tokio::sync::Mutex<Option<Instant>>>>>,
}

impl Fetches {
    fn checkout(&self, dir: &str) -> Arc<tokio::sync::Mutex<Option<Instant>>> {
        Arc::clone(
            self.checkouts
                .lock()
                .unwrap()
                .entry(dir.to_owned())
                .or_default(),
        )
    }

    /// Fetches origin for a picker opened on `dir`, unless one was tried within the interval. A
    /// failure counts as tried: an origin that is unreachable, missing or too big for the timeout
    /// is not asked again on every open.
    pub(crate) async fn origin(&self, dir: &str) -> Fetched {
        let checkout = self.checkout(dir);
        let mut last = checkout.lock().await;
        if last.is_some_and(|at| at.elapsed() < PICKER_FETCH_INTERVAL) {
            return Fetched::Recent;
        }
        let result = fetch(dir, None, true, PICKER_FETCH_TIMEOUT).await;
        *last = Some(Instant::now());
        match result {
            Ok(()) => Fetched::Fresh,
            Err(reason) => Fetched::Failed(reason),
        }
    }
}

/// Deletes a removed worktree's Xcode derived data in the background: a large build takes a
/// while to delete, and the removal it follows has already succeeded. Not a setting: the folders
/// are named after a path that no longer exists, so nothing can reuse them, and not tied to the
/// project's IDE, since a terminal `xcodebuild` or an agent's build fills them just the same.
pub(crate) fn spawn_derived_data_removal(app: &AppState, worktree: &str, folders: Vec<PathBuf>) {
    if folders.is_empty() {
        return;
    }
    let app = app.clone();
    let worktree = worktree.to_owned();
    tokio::spawn(async move {
        let outcome = tokio::task::spawn_blocking(move || {
            folders
                .into_iter()
                .map(|folder| (fs::remove_dir_all(&folder).err().map(|e| e.to_string()), folder))
                .collect::<Vec<_>>()
        })
        .await
        .unwrap_or_default();
        let deleted: Vec<_> = outcome.iter().filter(|(e, _)| e.is_none()).map(|(_, f)| f).collect();
        let failed: Vec<_> = outcome
            .iter()
            .filter_map(|(e, f)| e.as_ref().map(|e| format!("{}: {e}", f.display())))
            .collect();
        let _ = app.db.add_log(
            "worktree",
            if failed.is_empty() { "info" } else { "error" },
            if failed.is_empty() { "worktree_derived_data_deleted" } else { "worktree_derived_data_failed" },
            &json!({"worktree":worktree,"deleted":deleted,"failed":failed}),
        ).await;
    });
}

/// The mark a branch Cascade made carries in the repository's own config. Git drops the branch's
/// section, mark and all, when the branch is deleted, so a later branch of the same name the person
/// makes is never taken for Cascade's.
fn created_key(branch: &str) -> String {
    format!("branch.{branch}.cascadeCreated")
}

/// Marks `branch`, which `git worktree add -b` just made, as Cascade's to delete with its worktree.
/// A mark that could not be written only keeps the branch when the worktree goes, so it is logged,
/// not failed.
pub(crate) async fn mark_created(dir: &str, branch: &str) {
    if let Err(error) = cli::run("git", ["-C", dir, "config", &created_key(branch), "true"], Duration::from_secs(15)).await {
        tracing::warn!(branch, error = %crate::local::error_line(&error.to_string()), "worktree: the branch was not marked as Cascade's");
    }
}

/// Removing a worktree removes its branch with it when Cascade made that branch for it, by
/// `branch -d`, never `-D`: git refuses a branch that is not merged into its upstream or HEAD, and
/// that refusal is the point. A branch merged into its upstream (often the base it was cut from) or
/// HEAD goes; one holding work merged nowhere stays, pushed or not, and so does any branch a
/// session only adopted (`develop`, a pull request's), whatever it holds.
pub(crate) async fn remove_branch(app: &AppState, dir: &str, branch: &str) -> bool {
    let made = cli::run("git", ["-C", dir, "config", "--bool", &created_key(branch)], Duration::from_secs(15))
        .await
        .is_ok_and(|value| value.trim() == "true");
    if !made {
        return false;
    }
    let result = cli::run(
        "git",
        ["-C", dir, "branch", "-d", "--", branch],
        Duration::from_secs(20),
    )
    .await;
    let deleted = result.is_ok();
    let _ = app.db.add_log(
        "worktree",
        "info",
        if deleted { "worktree_branch_deleted" } else { "worktree_branch_kept" },
        &json!({"branch":branch,"reason":result.err().map(|e| crate::local::error_line(&e.to_string()))}),
    ).await;
    deleted
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn only_a_clean_install_starts_with_cascades_folder() {
        let clean = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::db::Database::open(clean.path()).unwrap(), None);
        settle_location(&app).await;
        assert_eq!(config(&app, LOCATION).await.as_deref(), Some("cascade"));
        // Settled for good: projects added later change nothing.
        app.db.add_project(json!({"name": "App", "workspace": "/code/app"}).as_object().unwrap()).await.unwrap();
        settle_location(&app).await;
        assert_eq!(config(&app, LOCATION).await.as_deref(), Some("cascade"));

        let used = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::db::Database::open(used.path()).unwrap(), None);
        app.db.add_project(json!({"name": "App", "workspace": "/code/app"}).as_object().unwrap()).await.unwrap();
        settle_location(&app).await;
        assert_eq!(location(&app).await, Location::Sibling);

        // A choice already saved is never touched.
        let chosen = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::db::Database::open(chosen.path()).unwrap(), None);
        app.db.set_config(json!({ LOCATION: "inside" }).as_object().unwrap()).await.unwrap();
        settle_location(&app).await;
        assert_eq!(location(&app).await, Location::Inside);
    }

    #[tokio::test]
    async fn the_location_stored_decides_and_nothing_stored_stays_beside_the_checkout() {
        let data = tempfile::tempdir().unwrap();
        let app = AppState::new(crate::db::Database::open(data.path()).unwrap(), None);
        let shared = Location::Custom(default_root());
        // Nothing stored is the safe side: where worktrees always went.
        assert_eq!(location(&app).await, Location::Sibling);
        app.db.set_config(json!({ LOCATION: "cascade" }).as_object().unwrap()).await.unwrap();
        assert_eq!(location(&app).await, shared);
        // A custom location whose folder was never chosen lands there too.
        let half_made = json!({ LOCATION: "custom", ROOT: " " });
        app.db.set_config(half_made.as_object().unwrap()).await.unwrap();
        assert_eq!(location(&app).await, shared);
        let sibling = json!({ LOCATION: "sibling" });
        app.db.set_config(sibling.as_object().unwrap()).await.unwrap();
        assert_eq!(location(&app).await, Location::Sibling);
    }

    #[test]
    fn roots_follow_the_location() {
        assert_eq!(root("/code/app/", &Location::Sibling), PathBuf::from("/code/app.worktrees"));
        assert_eq!(root("/code/app", &Location::Inside), PathBuf::from("/code/app/.worktrees"));
        let custom = Location::Custom("/wt".into());
        let work = root("/work/app", &custom);
        assert!(work.starts_with("/wt") && work.file_name().unwrap().to_str().unwrap().starts_with("app-"));
        // Same folder name, different checkout: never the same root.
        assert_ne!(work, root("/oss/app", &custom));
        assert_eq!(work, root("/work/app/", &custom));
    }

    #[test]
    fn only_the_folders_cascade_names_count_as_its_own() {
        let made = root("/work/my-app", &Location::Custom("/wt".into()));
        assert!(is_project_folder(made.file_name().unwrap().to_str().unwrap()));
        for other in ["app.worktrees", "notes", "my-app", "app-1234567", "app-ABCDEF12", "-1234abcd"] {
            assert!(!is_project_folder(other), "{other}");
        }
    }

    #[tokio::test]
    async fn listing_tells_nothing_ignored_apart_from_git_failing() {
        let dir = tempfile::tempdir().unwrap();
        let patterns = vec!["*.env".to_owned()];
        // Not a checkout: git fails, and that must not read as "nothing to copy".
        assert!(included_files(dir.path(), &patterns).await.is_err());
        cli::run("git", ["-C", dir.path().to_str().unwrap(), "init", "-q"], Duration::from_secs(20))
            .await
            .unwrap();
        // Matches the pattern but no .gitignore names it: check-ignore exits 1, an empty answer.
        fs::write(dir.path().join("notes.env"), "").unwrap();
        assert_eq!(included_files(dir.path(), &patterns).await.unwrap(), Vec::<PathBuf>::new());
    }

    #[test]
    fn copied_symlinks_keep_pointing_at_the_original_target() {
        let dir = tempfile::tempdir().unwrap();
        let (source, destination) = (dir.path().join("app"), dir.path().join("tree"));
        fs::create_dir_all(source.join("config")).unwrap();
        fs::create_dir_all(dir.path().join("secrets")).unwrap();
        fs::write(dir.path().join("secrets/env"), "secret").unwrap();
        std::os::unix::fs::symlink("../../secrets/env", source.join("config/.env")).unwrap();
        let copied = copy_files(&source, &destination, &["config/.env".into()]);
        assert_eq!(copied.copied, 1);
        assert_eq!(fs::read_to_string(destination.join("config/.env")).unwrap(), "secret");
    }

    #[test]
    fn patterns_drop_comments_and_blank_lines_but_keep_negation() {
        assert_eq!(
            parse_patterns("# env\n.env*\n\n!.env.example\n  \nconfig/*.local  \n"),
            vec![".env*", "!.env.example", "config/*.local"]
        );
    }

    #[test]
    fn tail_keeps_the_end_on_a_char_boundary() {
        let text = format!("{}é{}", "a".repeat(10), "b".repeat(OUTPUT_TAIL - 1));
        let kept = tail(&text);
        assert!(kept.len() <= OUTPUT_TAIL);
        assert!(kept.ends_with('b'));
    }
}

#[cfg(test)]
mod fetch_tests {
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };

    use super::{Fetched, Fetches};
    use crate::cli;

    /// A picker's fetch runs once for a checkout and stands for the interval, failed or not. The
    /// arguments are the one fetch shape: no tags, pruned, all of origin.
    #[tokio::test]
    async fn a_pickers_fetch_is_paced_per_checkout_and_retried_after_a_failure() {
        let runs = Arc::new(AtomicUsize::new(0));
        let counted = Arc::clone(&runs);
        let runner = Arc::new(cli::ScriptedRunner::new().on("git", move |args| {
            let args = args.iter().map(|a| a.to_string_lossy().into_owned()).collect::<Vec<_>>();
            assert_eq!(&args[2..], ["fetch", "--no-tags", "--prune", "origin"], "{args:?}");
            let run = counted.fetch_add(1, Ordering::SeqCst);
            // The first fetch of `/down` is the second run (`/up`'s second open runs none); it fails.
            Some(if args[1] == "/down" && run == 1 { Err("fatal: unable to access origin".to_string().into()) } else { Ok(Vec::new()) })
        }));
        let fetches = Fetches::default();
        cli::scoped(runner, async {
            assert_eq!(fetches.origin("/up").await, Fetched::Fresh);
            assert_eq!(fetches.origin("/up").await, Fetched::Recent);
            assert_eq!(fetches.origin("/down").await, Fetched::Failed("fatal: unable to access origin".into()));
            assert_eq!(fetches.origin("/down").await, Fetched::Recent, "A failure is not tried again on every open");
        })
        .await;
        assert_eq!(runs.load(Ordering::SeqCst), 2, "one for /up, one for /down");
    }
}
