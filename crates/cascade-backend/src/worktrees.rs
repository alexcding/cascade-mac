//! What Settings → Worktrees changes about a session's worktree: where a new one lands, which
//! ignored files follow it from the main checkout, the command that prepares it, and whether its
//! branch goes with it when it is removed. Every option is read from `config` at the moment it is
//! used, so a change applies to the next worktree without a restart.

use std::{
    fs, io,
    os::unix::ffi::OsStringExt,
    path::{Path, PathBuf},
    time::Duration,
};

use serde_json::json;
use sha2::{Digest, Sha256};

use crate::{cli, local::resolve_path, AppState};

pub(crate) const LOCATION: &str = "worktree_location";
pub(crate) const ROOT: &str = "worktree_root";
pub(crate) const INCLUDE: &str = "worktree_include";
/// The project fields (as the project JSON names them) for its own patterns and setup script.
const PROJECT_INCLUDE: &str = "worktreeInclude";
const PROJECT_SETUP: &str = "worktreeSetup";
pub(crate) const DELETE_BRANCH: &str = "worktree_delete_branch";
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
/// The part of a failed setup's output worth keeping in Activity.
const OUTPUT_TAIL: usize = 2000;

#[derive(Debug, PartialEq)]
pub(crate) enum Location {
    /// `<workspace>.worktrees/<leaf>`, beside the checkout: the default, and what every worktree
    /// made before this setting existed already uses.
    Sibling,
    /// `<workspace>/.worktrees/<leaf>`, hidden from git through `info/exclude`.
    Inside,
    /// `<folder>/<repo folder>/<leaf>`, so one folder can hold every project's worktrees.
    Custom(PathBuf),
}

fn config(app: &AppState, key: &str) -> Option<String> {
    app.db.config_value(key).ok().flatten()
}

pub(crate) fn location(app: &AppState) -> Location {
    match config(app, LOCATION).as_deref() {
        Some("inside") => Location::Inside,
        Some("custom") => match config(app, ROOT).filter(|v| !v.trim().is_empty()) {
            Some(root) => Location::Custom(resolve_path(root.trim())),
            // A custom location with no folder yet is a setting half made, not a reason to fail
            // New Session: keep landing where worktrees always have.
            None => Location::Sibling,
        },
        _ => Location::Sibling,
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
fn project_field(app: &AppState, dir: &Path, field: &str) -> Option<String> {
    let dir = resolve_path(&dir.to_string_lossy());
    app.db
        .projects()
        .ok()?
        .into_iter()
        .find(|project| {
            project["workspace"]
                .as_str()
                .is_some_and(|workspace| !workspace.is_empty() && resolve_path(workspace.trim_end_matches('/')) == dir)
        })
        .and_then(|project| project[field].as_str().map(str::to_owned))
        .filter(|value| !value.trim().is_empty())
}

/// Include patterns in gitignore syntax, from the first of: the repo's `.worktreeinclude`, the
/// project's own patterns, the default in Settings, `.env*`. Comments and blank lines are dropped
/// here, since each pattern goes to git as its own `-x`.
fn include_patterns(app: &AppState, source: &Path) -> Vec<String> {
    let text = fs::read_to_string(source.join(INCLUDE_FILE))
        .ok()
        .or_else(|| project_field(app, source, PROJECT_INCLUDE))
        .or_else(|| config(app, INCLUDE))
        .unwrap_or_else(|| DEFAULT_INCLUDE.to_owned());
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
    let patterns = include_patterns(app, source);
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

fn copy_files(source: &Path, destination: &Path, files: &[PathBuf]) -> Copied {
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
pub(crate) fn spawn_setup(app: &AppState, source: &str, worktree: &Path, branch: &str) {
    let Some(command) = project_field(app, Path::new(source), PROJECT_SETUP) else {
        return;
    };
    let app = app.clone();
    let source = source.to_owned();
    let worktree = worktree.to_string_lossy().into_owned();
    let branch = branch.to_owned();
    tokio::spawn(async move {
        app.broadcast(json!({"type":"worktree-setup","worktree":worktree,"state":"running"}));
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
                // Setup scripts written while the app was Craft.
                ("CRAFT_ROOT_PATH", source.as_str()),
                ("CRAFT_WORKTREE_PATH", worktree.as_str()),
                ("CRAFT_BRANCH", branch.as_str()),
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
        );
        app.broadcast(
            json!({"type":"worktree-setup","worktree":worktree,"state":state,"error":detail}),
        );
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
    if !matches!(config(app, FETCH).as_deref(), Some("true" | "1")) {
        return;
    }
    if let Err(error) = cli::run(
        "git",
        ["-C", dir, "fetch", "--no-tags", "origin", "--", base],
        FETCH_TIMEOUT,
    )
    .await
    {
        let _ = app.db.add_log(
            "worktree",
            "info",
            "worktree_fetch_skipped",
            &json!({"base":base,"reason":crate::local::error_line(&error.to_string())}),
        );
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
        );
    });
}

/// Whether removing a session's worktree also removes its branch.
pub(crate) fn delete_branch(app: &AppState) -> bool {
    matches!(config(app, DELETE_BRANCH).as_deref(), Some("true" | "1"))
}

/// `branch -d`, never `-D`: git refuses a branch that is not merged into its upstream or HEAD,
/// and that refusal is the point. Work that was never merged is not deleted by a cleanup.
pub(crate) async fn remove_branch(app: &AppState, dir: &str, branch: &str) -> bool {
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
    );
    deleted
}

#[cfg(test)]
mod tests {
    use super::*;

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
