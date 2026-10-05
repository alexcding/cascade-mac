//! Ported from Synara `apps/server/src/checkpointing/Layers/CheckpointStore.ts` (capture, copy,
//! diff, reverse, delete; Synara's whole-folder `restoreCheckpoint` is not ported) and the ref names of `checkpointing/Utils.ts`.
//!
//! A checkpoint is a parentless commit of the whole workspace, written through a throwaway index
//! and kept under a hidden ref: it never touches HEAD, the user's index or a branch. A workspace
//! that is not a git repository has no checkpoints; every operation there is skipped.

use std::{
    path::{Path, PathBuf},
    sync::Arc,
};

use anyhow::{anyhow, bail, Context, Result};

use crate::contracts::base::{CheckpointRef, MessageId, ThreadId, TurnId};

use super::git::{GitOutput, GitRunner};

/// Synara `CHECKPOINT_REFS_PREFIX` (Utils.ts:11), in Cascade's own namespace. Synara's managed-ref
/// pattern accepts any `refs/<namespace>/checkpoints/...`.
pub const CHECKPOINT_REFS_PREFIX: &str = "refs/cascade/checkpoints";

/// Synara `CHECKPOINT_DIFF_MAX_OUTPUT_BYTES` (CheckpointStore.ts:22)
pub const CHECKPOINT_DIFF_MAX_OUTPUT_BYTES: usize = 10_000_000;

const CHECKPOINT_AUTHOR_NAME: &str = "Cascade";
const CHECKPOINT_AUTHOR_EMAIL: &str = "cascade@localhost";

/// Effect `Encoding.encodeBase64Url`: URL-safe alphabet, no padding.
pub fn encode_base64_url(value: &str) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let bytes = value.as_bytes();
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
        let symbols = chunk.len() + 1;
        for index in 0..symbols {
            out.push(ALPHABET[((n >> (18 - 6 * index)) & 63) as usize] as char);
        }
    }
    out
}

/// Synara `checkpointRefForThreadTurn` (Utils.ts:49): the workspace after turn `turn_count`;
/// turn 0 is the baseline before the first turn.
pub fn checkpoint_ref_for_thread_turn(thread: &ThreadId, turn_count: u64) -> CheckpointRef {
    CheckpointRef::new(format!("{CHECKPOINT_REFS_PREFIX}/{}/turn/{turn_count}", encode_base64_url(thread.as_str())))
}

/// Synara `checkpointRefForThreadMessageStart` (Utils.ts:62)
pub fn checkpoint_ref_for_message_start(thread: &ThreadId, message: &MessageId) -> CheckpointRef {
    CheckpointRef::new(format!(
        "{CHECKPOINT_REFS_PREFIX}/{}/message-start/{}",
        encode_base64_url(thread.as_str()),
        encode_base64_url(message.as_str())
    ))
}

/// Synara `checkpointRefForThreadTurnStart` (Utils.ts:71)
pub fn checkpoint_ref_for_turn_start(thread: &ThreadId, turn: &TurnId) -> CheckpointRef {
    CheckpointRef::new(format!(
        "{CHECKPOINT_REFS_PREFIX}/{}/turn-start/{}",
        encode_base64_url(thread.as_str()),
        encode_base64_url(turn.as_str())
    ))
}

/// Synara `revertRescueCheckpointRef` (Utils.ts): the workspace just before a revert, kept until
/// the revert commits.
pub fn revert_rescue_checkpoint_ref(thread: &ThreadId, token: &str) -> CheckpointRef {
    CheckpointRef::new(format!(
        "{CHECKPOINT_REFS_PREFIX}/{}/revert-rescue/{}",
        encode_base64_url(thread.as_str()),
        encode_base64_url(token)
    ))
}

/// Synara `parseManagedCheckpointRef` (Utils.ts:24), as a yes or no: a ref this layer wrote, as
/// opposed to a provider-diff placeholder.
pub fn is_managed_checkpoint_ref(value: &str) -> bool {
    let parts: Vec<&str> = value.split('/').collect();
    let token = |s: &str| !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-');
    parts.len() == 6
        && parts[0] == "refs"
        && !parts[1].is_empty()
        && parts[1].chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        && parts[2] == "checkpoints"
        && token(parts[3])
        && matches!(parts[4], "turn" | "message-start" | "turn-start" | "turn-live" | "revert-rescue")
        && token(parts[5])
        && (parts[4] != "turn" || parts[5].chars().all(|c| c.is_ascii_digit()))
}

/// Synara `ManagedCheckpointRefParts` (Utils.ts:17), the parts the diff query reads.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ManagedCheckpointRefParts {
    pub thread_token: String,
    pub family_prefix: String,
}

/// Synara `parseManagedCheckpointRef` (Utils.ts:24)
pub fn parse_managed_checkpoint_ref(value: &str) -> Option<ManagedCheckpointRefParts> {
    if !is_managed_checkpoint_ref(value) {
        return None;
    }
    let parts: Vec<&str> = value.split('/').collect();
    Some(ManagedCheckpointRefParts {
        thread_token: parts[3].to_owned(),
        family_prefix: format!("refs/{}/checkpoints/{}", parts[1], parts[3]),
    })
}

/// Synara `isManagedCheckpointRefForThread` (Utils.ts): a ref this layer wrote for `thread`.
pub fn is_managed_checkpoint_ref_for_thread(value: &str, thread: &ThreadId) -> bool {
    parse_managed_checkpoint_ref(value).is_some_and(|parts| parts.thread_token == encode_base64_url(thread.as_str()))
}

/// Synara `checkpointRefForThreadTurnInManagedFamily` (Utils.ts:51): turn `turn_count` of the
/// ref family `managed_ref` belongs to, when that family is this thread's.
pub fn checkpoint_ref_for_thread_turn_in_managed_family(
    managed_ref: &str,
    thread: &ThreadId,
    turn_count: u64,
) -> Option<CheckpointRef> {
    let parsed = parse_managed_checkpoint_ref(managed_ref)?;
    (parsed.thread_token == encode_base64_url(thread.as_str()))
        .then(|| CheckpointRef::new(format!("{}/turn/{turn_count}", parsed.family_prefix)))
}

/// Synara `checkpointRefForThreadTurnStartInManagedFamily` (Utils.ts:76)
pub fn checkpoint_ref_for_turn_start_in_managed_family(
    managed_ref: &str,
    thread: &ThreadId,
    turn: &TurnId,
) -> Option<CheckpointRef> {
    let parsed = parse_managed_checkpoint_ref(managed_ref)?;
    (parsed.thread_token == encode_base64_url(thread.as_str())).then(|| {
        CheckpointRef::new(format!("{}/turn-start/{}", parsed.family_prefix, encode_base64_url(turn.as_str())))
    })
}

/// An index or tree entry: `(mode, object, path)`.
type Entry = (String, String, String);

fn entry_of<'a>(entries: &'a [Entry], path: &str) -> Option<(&'a str, &'a str)> {
    entries.iter().find(|(_, _, p)| p == path).map(|(mode, object, _)| (mode.as_str(), object.as_str()))
}

/// One turn to take back: its start and end commits and the paths it changed.
struct ReverseStep {
    from: String,
    to: String,
    paths: Vec<String>,
}

/// Paths handed to git are names, not patterns: a file called `a*.txt` is that file alone.
fn literal_pathspecs() -> Vec<(String, String)> {
    vec![("GIT_LITERAL_PATHSPECS".to_owned(), "1".to_owned())]
}

fn make_temp_dir(prefix: &str) -> Result<PathBuf> {
    let dir = std::env::temp_dir().join(format!("{prefix}-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).context("Failed to prepare the checkpoint patch for undo.")?;
    Ok(dir)
}

fn undo_conflict(strict_stderr: &str, merged_stderr: &str) -> String {
    ["Undo could not be applied because the workspace changed since this checkpoint.", strict_stderr.trim(), merged_stderr.trim()]
        .iter()
        .filter(|part| !part.is_empty())
        .copied()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Synara `CheckpointStore`.
pub struct CheckpointStore {
    git: Arc<dyn GitRunner>,
}

impl CheckpointStore {
    pub fn new(git: Arc<dyn GitRunner>) -> Self {
        Self { git }
    }

    async fn git(&self, cwd: &Path, args: &[&str], env: &[(String, String)]) -> Result<GitOutput> {
        let args: Vec<String> = args.iter().map(|a| (*a).to_owned()).collect();
        self.git.run(cwd, &args, env).await.with_context(|| format!("git {}", args.join(" ")))
    }

    async fn git_ok(&self, cwd: &Path, args: &[&str], env: &[(String, String)]) -> Result<GitOutput> {
        let output = self.git(cwd, args, env).await?;
        if !output.success() {
            bail!("git {} failed: {}", args.join(" "), output.stderr.trim());
        }
        Ok(output)
    }

    /// Synara `isGitRepository`
    pub async fn is_git_repository(&self, cwd: &Path) -> bool {
        matches!(
            self.git(cwd, &["rev-parse", "--is-inside-work-tree"], &[]).await,
            Ok(output) if output.success() && output.stdout.trim() == "true"
        )
    }

    async fn has_head_commit(&self, cwd: &Path) -> Result<bool> {
        Ok(self.git(cwd, &["rev-parse", "--verify", "--quiet", "HEAD"], &[]).await?.success())
    }

    /// Synara `resolveCheckpointCommit`
    async fn resolve_checkpoint_commit(&self, cwd: &Path, reference: &CheckpointRef) -> Result<Option<String>> {
        let spec = format!("{}^{{commit}}", reference.as_str());
        let output = self.git(cwd, &["rev-parse", "--verify", "--quiet", &spec], &[]).await?;
        Ok(output.success().then(|| output.stdout.trim().to_owned()).filter(|c| !c.is_empty()))
    }

    /// Synara `hasCheckpointRef`
    pub async fn has_checkpoint_ref(&self, cwd: &Path, reference: &CheckpointRef) -> Result<bool> {
        Ok(self.resolve_checkpoint_commit(cwd, reference).await?.is_some())
    }

    /// Synara `seedCheckpointIndex`: copy the working index so `git add` keeps its stat cache.
    async fn seed_checkpoint_index(&self, cwd: &Path, temp_index: &Path) -> Result<Option<std::fs::Metadata>> {
        let output = self.git(cwd, &["rev-parse", "--git-path", "index"], &[]).await?;
        let raw = output.stdout.trim();
        if !output.success() || raw.is_empty() {
            return Ok(None);
        }
        let index = if Path::new(raw).is_absolute() { PathBuf::from(raw) } else { cwd.join(raw) };
        let Ok(metadata) = std::fs::metadata(&index) else {
            return Ok(None);
        };
        std::fs::copy(&index, temp_index).context("copy the working index")?;
        Ok(Some(metadata))
    }

    /// Fill `index` (named by `GIT_INDEX_FILE` in `env`) with the working tree as it is, seeded
    /// from a copy of the person's index so `git add` hashes only what changed since it was
    /// last refreshed rather than every file.
    async fn mirror_worktree_index(&self, cwd: &Path, index: &Path, env: &[(String, String)]) -> Result<()> {
        let working_index = self.seed_checkpoint_index(cwd, index).await?;
        if working_index.is_none() && self.has_head_commit(cwd).await? {
            self.git_ok(cwd, &["read-tree", "HEAD"], env).await?;
        }
        if let Some(metadata) = &working_index {
            // Really-refresh makes git verify racily clean entries of the copied index.
            self.git(cwd, &["update-index", "--really-refresh"], env).await?;
            // Copying advanced the index's timestamp; put the original back so a rapid
            // same-size rewrite still looks newer than the snapshot and is hashed.
            if let Ok(modified) = metadata.modified() {
                if let Ok(file) = std::fs::File::options().write(true).open(index) {
                    let _ = file.set_modified(modified);
                }
            }
        }
        self.git_ok(cwd, &["add", "-A", "--", "."], env).await?;
        Ok(())
    }

    /// Synara `captureCheckpoint`: snapshot the workspace under `reference`.
    pub async fn capture_checkpoint(&self, cwd: &Path, reference: &CheckpointRef, skip_if_exists: bool) -> Result<()> {
        if skip_if_exists && self.resolve_checkpoint_commit(cwd, reference).await?.is_some() {
            return Ok(());
        }
        let temp_dir = std::env::temp_dir().join(format!("cascade-fs-checkpoint-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&temp_dir).context("create the checkpoint's temporary folder")?;
        let outcome = self.capture_into(cwd, reference, &temp_dir).await;
        let _ = std::fs::remove_dir_all(&temp_dir);
        outcome
    }

    async fn capture_into(&self, cwd: &Path, reference: &CheckpointRef, temp_dir: &Path) -> Result<()> {
        let temp_index = temp_dir.join(format!("index-{}", uuid::Uuid::new_v4()));
        let env = vec![
            ("GIT_INDEX_FILE".to_owned(), temp_index.to_string_lossy().into_owned()),
            ("GIT_AUTHOR_NAME".to_owned(), CHECKPOINT_AUTHOR_NAME.to_owned()),
            ("GIT_AUTHOR_EMAIL".to_owned(), CHECKPOINT_AUTHOR_EMAIL.to_owned()),
            ("GIT_COMMITTER_NAME".to_owned(), CHECKPOINT_AUTHOR_NAME.to_owned()),
            ("GIT_COMMITTER_EMAIL".to_owned(), CHECKPOINT_AUTHOR_EMAIL.to_owned()),
        ];
        self.mirror_worktree_index(cwd, &temp_index, &env).await?;
        let tree = self.git_ok(cwd, &["write-tree"], &env).await?.stdout.trim().to_owned();
        if tree.is_empty() {
            bail!("git write-tree returned an empty tree oid.");
        }
        let message = format!("Cascade checkpoint ref={}", reference.as_str());
        let commit = self.git_ok(cwd, &["commit-tree", &tree, "-m", &message], &env).await?.stdout.trim().to_owned();
        if commit.is_empty() {
            bail!("git commit-tree returned an empty commit oid.");
        }
        self.git_ok(cwd, &["update-ref", reference.as_str(), &commit], &[]).await?;
        Ok(())
    }

    /// Synara `copyCheckpointRef`: `false` when `from` does not exist.
    pub async fn copy_checkpoint_ref(&self, cwd: &Path, from: &CheckpointRef, to: &CheckpointRef) -> Result<bool> {
        let Some(commit) = self.resolve_checkpoint_commit(cwd, from).await? else {
            return Ok(false);
        };
        self.git_ok(cwd, &["update-ref", to.as_str(), &commit], &[]).await?;
        Ok(true)
    }

    /// Synara `diffCheckpoints`: the unified diff from one checkpoint to another.
    pub async fn diff_checkpoints(&self, cwd: &Path, from: &CheckpointRef, to: &CheckpointRef) -> Result<String> {
        self.diff_checkpoints_with(cwd, from, to, false).await
    }

    /// [`Self::diff_checkpoints`] with Synara's `ignoreWhitespace` (`--ignore-all-space`).
    pub async fn diff_checkpoints_with(
        &self,
        cwd: &Path,
        from: &CheckpointRef,
        to: &CheckpointRef,
        ignore_whitespace: bool,
    ) -> Result<String> {
        let from_commit = self.resolve_checkpoint_commit(cwd, from).await?;
        let to_commit = self.resolve_checkpoint_commit(cwd, to).await?;
        let (Some(from_commit), Some(to_commit)) = (from_commit, to_commit) else {
            return Err(anyhow!("Checkpoint ref is unavailable for diff operation."));
        };
        let output = self
            .git_ok(
                cwd,
                &[
                    &["diff", "--patch", "--minimal", "--no-color", "--no-ext-diff", "--no-textconv"][..],
                    if ignore_whitespace { &["--ignore-all-space"][..] } else { &[][..] },
                    &[from_commit.as_str(), to_commit.as_str()][..],
                ]
                .concat(),
                &[],
            )
            .await?;
        if output.stdout.len() > CHECKPOINT_DIFF_MAX_OUTPUT_BYTES {
            bail!("The turn diff is larger than {CHECKPOINT_DIFF_MAX_OUTPUT_BYTES} bytes.");
        }
        Ok(output.stdout)
    }

    /// Synara `reverseCheckpointDiff`: take back, in the workspace, the changes from `from` to
    /// `to`, leaving everything else as it is. `false` when either checkpoint is unavailable. The
    /// patch is written by git to a file of its own, so no byte of it passes through a string and
    /// it has no size cap (Synara's cap is for a diff read into memory).
    pub async fn reverse_checkpoint_diff(&self, cwd: &Path, from: &CheckpointRef, to: &CheckpointRef) -> Result<bool> {
        let Some((from_commit, to_commit)) = self.resolve_range(cwd, from, to).await? else {
            return Ok(false);
        };
        let paths = self.changed_paths(cwd, &from_commit, &to_commit).await?;
        if paths.is_empty() {
            return Ok(true);
        }
        let temp_dir = make_temp_dir("cascade-checkpoint-undo")?;
        let outcome = self.reverse_into(cwd, &from_commit, &to_commit, &paths, &temp_dir).await;
        let _ = std::fs::remove_dir_all(&temp_dir);
        outcome.map(|()| true)
    }

    async fn resolve_range(&self, cwd: &Path, from: &CheckpointRef, to: &CheckpointRef) -> Result<Option<(String, String)>> {
        let from = self.resolve_checkpoint_commit(cwd, from).await?;
        let to = self.resolve_checkpoint_commit(cwd, to).await?;
        Ok(from.zip(to))
    }

    /// The binary patch from `from_commit` to `to_commit`, written by git into `patch_path`;
    /// `false` when it is empty.
    async fn write_patch(&self, cwd: &Path, from_commit: &str, to_commit: &str, patch_path: &Path) -> Result<bool> {
        let output = format!("--output={}", patch_path.to_string_lossy());
        self.git_ok(
            cwd,
            &["diff", "--patch", "--binary", "--full-index", "--no-color", "--no-ext-diff", "--no-textconv", &output, from_commit, to_commit],
            &[],
        )
        .await?;
        Ok(std::fs::metadata(patch_path).map(|m| m.len()).unwrap_or(0) > 0)
    }

    async fn reverse_into(&self, cwd: &Path, from_commit: &str, to_commit: &str, paths: &[String], temp_dir: &Path) -> Result<()> {
        let patch_path = temp_dir.join("turn.patch");
        if !self.write_patch(cwd, from_commit, to_commit, &patch_path).await? {
            return Ok(());
        }
        let patch = patch_path.to_string_lossy().into_owned();
        let affected: Vec<&str> = paths.iter().map(String::as_str).collect();
        let strict = self.git(cwd, &["apply", "--reverse", "--whitespace=nowarn", "--", &patch], &[]).await?;
        if !strict.success() {
            self.apply_reverse_with_three_way_merge(cwd, temp_dir, &patch, &affected, &strict.stderr).await?;
        }
        if let Err(error) = self.take_back_staged(cwd, from_commit, to_commit, paths).await {
            self.git_ok(cwd, &["apply", "--whitespace=nowarn", "--", &patch], &[]).await?;
            return Err(error);
        }
        Ok(())
    }

    /// The index after a turn's changes are taken back. Cascade, where Synara resets each path to
    /// the turn's start (`git reset <start> -- <paths>`, which stages a file nobody staged and
    /// drops the person's partial staging): a path whose entry is as the turn left it (the agent
    /// staged its change, or its deletion of a tracked file) goes back to its entry at the turn's
    /// start; any other entry is the person's and stays, and a path with none stays untracked.
    async fn take_back_staged(&self, cwd: &Path, from_commit: &str, to_commit: &str, paths: &[String]) -> Result<()> {
        let staged = self.index_entries(cwd, paths).await?;
        let at_end = self.tree_entries(cwd, to_commit, paths).await?;
        let at_start = self.tree_entries(cwd, from_commit, paths).await?;
        let in_head = if self.has_head_commit(cwd).await? { self.tree_entries(cwd, "HEAD", paths).await? } else { vec![] };
        for path in paths {
            let as_the_turn_left_it = match (entry_of(&staged, path), entry_of(&at_end, path)) {
                (Some(staged), Some(end)) => staged == end,
                (None, None) => entry_of(&in_head, path).is_some(),
                _ => false,
            };
            if as_the_turn_left_it {
                self.set_index_entry(cwd, path, entry_of(&at_start, path)).await?;
            }
        }
        Ok(())
    }

    async fn set_index_entry(&self, cwd: &Path, path: &str, entry: Option<(&str, &str)>) -> Result<()> {
        match entry {
            Some((mode, object)) => {
                let info = format!("{mode},{object},{path}");
                self.git_ok(cwd, &["update-index", "--add", "--cacheinfo", &info], &literal_pathspecs()).await?;
            }
            None => {
                self.git_ok(cwd, &["update-index", "--force-remove", "--", path], &literal_pathspecs()).await?;
            }
        }
        Ok(())
    }

    /// Synara `applyReverseWithThreeWayMerge`: when the workspace drifted after the checkpoint, a
    /// three-way reverse apply through a throwaway index that mirrors the working tree (the user's
    /// index stays untouched). A conflicted apply is rolled back to the tree it started from.
    async fn apply_reverse_with_three_way_merge(
        &self,
        cwd: &Path,
        temp_dir: &Path,
        patch: &str,
        affected: &[&str],
        strict_stderr: &str,
    ) -> Result<()> {
        let index = temp_dir.join(format!("undo-index-{}", uuid::Uuid::new_v4()));
        let env = vec![("GIT_INDEX_FILE".to_owned(), index.to_string_lossy().into_owned())];
        self.mirror_worktree_index(cwd, &index, &env).await?;
        let pre_attempt_tree = self.git_ok(cwd, &["write-tree"], &env).await?.stdout.trim().to_owned();
        let applied = self
            .git(cwd, &["apply", "--reverse", "--3way", "--whitespace=nowarn", "--", patch], &env)
            .await?;
        if applied.success() {
            return Ok(());
        }
        if !pre_attempt_tree.is_empty() {
            if let Err(error) = self.restore_worktree_paths_from_tree(cwd, &pre_attempt_tree, affected).await {
                tracing::warn!("failed to roll back a conflicted checkpoint undo: {error:#}");
            }
        }
        bail!(undo_conflict(strict_stderr, &applied.stderr))
    }

    /// Cascade, for a revert or an edit that rolls several turns back: take back each turn's own
    /// changes (`ranges`, newest first, each from its start to its end), leaving everything else
    /// in the folder as it is, where Synara restores the whole folder to a checkpoint (which would
    /// also undo what the person, or a terminal agent sharing the folder, did meanwhile). All or
    /// nothing: every reverse is first tried on a throwaway index that mirrors the folder, and
    /// only then is `rescue` taken, a snapshot of the folder; a reverse that still fails for real
    /// puts back the paths the reverses touched from it, with their index entries. `rescue` is
    /// deleted once it is not needed (kept, and named in the error, only when the put-back failed).
    /// `false` when a checkpoint is unavailable; an error, with the folder as it was, when a
    /// reverse conflicts. Ranges with no changes are skipped.
    pub async fn reverse_checkpoint_diffs(
        &self,
        cwd: &Path,
        ranges: &[(CheckpointRef, CheckpointRef)],
        rescue: &CheckpointRef,
    ) -> Result<bool> {
        let Some(steps) = self.plan_reverses(cwd, ranges).await? else {
            return Ok(false);
        };
        if steps.is_empty() {
            return Ok(true);
        }
        self.check_reverses(cwd, &steps).await?;
        self.capture_checkpoint(cwd, rescue, false)
            .await
            .map_err(|error| anyhow!("The workspace snapshot taken before a rollback could not be captured, so nothing was changed: {error:#}"))?;
        let forget_rescue = || async {
            if let Err(error) = self.delete_checkpoint_refs(cwd, std::slice::from_ref(rescue)).await {
                tracing::warn!("failed to delete a rollback's rescue snapshot: {error:#}");
            }
        };
        let mut affected: Vec<String> = Vec::new();
        for step in &steps {
            affected.extend(step.paths.iter().filter(|p| !affected.contains(p)).cloned().collect::<Vec<_>>());
        }
        let saved_index = match self.index_entries(cwd, &affected).await {
            Ok(saved) => saved,
            Err(error) => {
                forget_rescue().await;
                return Err(error);
            }
        };
        let mut touched: Vec<String> = Vec::new();
        for step in &steps {
            touched.extend(step.paths.iter().filter(|p| !touched.contains(p)).cloned().collect::<Vec<_>>());
            let outcome = match make_temp_dir("cascade-checkpoint-undo") {
                Ok(temp_dir) => {
                    let outcome = self.reverse_into(cwd, &step.from, &step.to, &step.paths, &temp_dir).await;
                    let _ = std::fs::remove_dir_all(&temp_dir);
                    outcome
                }
                Err(error) => Err(error),
            };
            if let Err(error) = outcome {
                return Err(match self.put_back_paths(cwd, rescue, &touched, &saved_index).await {
                    Ok(()) => {
                        forget_rescue().await;
                        error
                    }
                    Err(put_back) => {
                        tracing::warn!("failed to put back a partly reversed rollback: {put_back:#}");
                        error.context(format!(
                            "The rollback failed part way and could not be put back ({put_back:#}); the folder as it was is kept at {}.",
                            rescue.as_str()
                        ))
                    }
                });
            }
        }
        forget_rescue().await;
        Ok(true)
    }

    /// Whether [`Self::reverse_checkpoint_diffs`] would apply, tried on a throwaway index that
    /// mirrors the folder: nothing in the folder or the person's index changes. `false` when a
    /// checkpoint is unavailable; an error naming the conflict when a reverse does not apply.
    pub async fn check_reverse_checkpoint_diffs(&self, cwd: &Path, ranges: &[(CheckpointRef, CheckpointRef)]) -> Result<bool> {
        let Some(steps) = self.plan_reverses(cwd, ranges).await? else {
            return Ok(false);
        };
        self.check_reverses(cwd, &steps).await?;
        Ok(true)
    }

    /// Each range's commits and changed paths, the ranges with no changes left out; `None` when a
    /// checkpoint is unavailable.
    async fn plan_reverses(&self, cwd: &Path, ranges: &[(CheckpointRef, CheckpointRef)]) -> Result<Option<Vec<ReverseStep>>> {
        let mut steps = Vec::with_capacity(ranges.len());
        for (from, to) in ranges {
            let Some((from, to)) = self.resolve_range(cwd, from, to).await? else {
                return Ok(None);
            };
            let paths = self.changed_paths(cwd, &from, &to).await?;
            if !paths.is_empty() {
                steps.push(ReverseStep { from, to, paths });
            }
        }
        Ok(Some(steps))
    }

    async fn check_reverses(&self, cwd: &Path, steps: &[ReverseStep]) -> Result<()> {
        if steps.is_empty() {
            return Ok(());
        }
        let temp_dir = make_temp_dir("cascade-checkpoint-check")?;
        let outcome = self.check_into(cwd, steps, &temp_dir).await;
        let _ = std::fs::remove_dir_all(&temp_dir);
        outcome
    }

    async fn check_into(&self, cwd: &Path, steps: &[ReverseStep], temp_dir: &Path) -> Result<()> {
        let index = temp_dir.join("check-index");
        let env = vec![("GIT_INDEX_FILE".to_owned(), index.to_string_lossy().into_owned())];
        self.mirror_worktree_index(cwd, &index, &env).await?;
        for (number, step) in steps.iter().enumerate() {
            let patch_path = temp_dir.join(format!("turn-{number}.patch"));
            if !self.write_patch(cwd, &step.from, &step.to, &patch_path).await? {
                continue;
            }
            let patch = patch_path.to_string_lossy().into_owned();
            let strict = self.git(cwd, &["apply", "--cached", "--reverse", "--whitespace=nowarn", "--", &patch], &env).await?;
            if strict.success() {
                continue;
            }
            let merged = self
                .git(cwd, &["apply", "--cached", "--reverse", "--3way", "--whitespace=nowarn", "--", &patch], &env)
                .await?;
            if !merged.success() {
                bail!(undo_conflict(&strict.stderr, &merged.stderr));
            }
        }
        Ok(())
    }

    async fn changed_paths(&self, cwd: &Path, from_commit: &str, to_commit: &str) -> Result<Vec<String>> {
        let changed = self.git_ok(cwd, &["diff", "--name-only", "--no-renames", "-z", from_commit, to_commit], &[]).await?;
        Ok(changed.stdout.split('\0').filter(|p| !p.is_empty()).map(str::to_owned).collect())
    }

    /// The person's index entries (stage 0) for `paths`: `(mode, object, path)`.
    async fn index_entries(&self, cwd: &Path, paths: &[String]) -> Result<Vec<Entry>> {
        if paths.is_empty() {
            return Ok(vec![]);
        }
        let args: Vec<&str> = [&["ls-files", "-s", "-z", "--"][..], &paths.iter().map(String::as_str).collect::<Vec<_>>()[..]].concat();
        let listed = self.git_ok(cwd, &args, &literal_pathspecs()).await?;
        Ok(listed
            .stdout
            .split('\0')
            .filter_map(|record| {
                let (meta, path) = record.split_once('\t')?;
                let mut parts = meta.split(' ');
                let (mode, object, stage) = (parts.next()?, parts.next()?, parts.next()?);
                (stage == "0").then(|| (mode.to_owned(), object.to_owned(), path.to_owned()))
            })
            .collect())
    }

    /// `tree`'s entries for `paths`: `(mode, object, path)`.
    async fn tree_entries(&self, cwd: &Path, tree: &str, paths: &[String]) -> Result<Vec<Entry>> {
        if paths.is_empty() {
            return Ok(vec![]);
        }
        let args: Vec<&str> = [&["ls-tree", "-r", "-z", tree, "--"][..], &paths.iter().map(String::as_str).collect::<Vec<_>>()[..]].concat();
        let listed = self.git_ok(cwd, &args, &literal_pathspecs()).await?;
        Ok(listed
            .stdout
            .split('\0')
            .filter_map(|record| {
                let (meta, path) = record.split_once('\t')?;
                let mut parts = meta.split(' ');
                let (mode, _kind, object) = (parts.next()?, parts.next()?, parts.next()?);
                Some((mode.to_owned(), object.to_owned(), path.to_owned()))
            })
            .collect())
    }

    /// Put `paths` back as `rescue` has them in the folder, and as `saved` has them in the index.
    async fn put_back_paths(&self, cwd: &Path, rescue: &CheckpointRef, paths: &[String], saved: &[Entry]) -> Result<()> {
        if paths.is_empty() {
            return Ok(());
        }
        let Some(commit) = self.resolve_checkpoint_commit(cwd, rescue).await? else {
            bail!("the pre-revert snapshot is gone");
        };
        let refs: Vec<&str> = paths.iter().map(String::as_str).collect();
        self.restore_worktree_paths_from_tree(cwd, &commit, &refs).await?;
        for path in paths {
            self.set_index_entry(cwd, path, entry_of(saved, path)).await?;
        }
        Ok(())
    }

    /// Synara `restoreWorktreePathsFromTree`: put `paths` back as `tree` has them, without the
    /// index; a path the tree lacks did not exist before, so it is deleted.
    async fn restore_worktree_paths_from_tree(&self, cwd: &Path, tree: &str, paths: &[&str]) -> Result<()> {
        if paths.is_empty() {
            return Ok(());
        }
        let ls_args: Vec<&str> = [&["ls-tree", "-r", "--name-only", "-z", tree, "--"][..], paths].concat();
        let listed = self.git(cwd, &ls_args, &literal_pathspecs()).await?;
        let tracked: Vec<&str> = listed.stdout.split('\0').filter(|p| !p.is_empty()).collect();
        if !tracked.is_empty() {
            let restore_args: Vec<&str> = [&["restore", "--source", tree, "--worktree", "--"][..], &tracked[..]].concat();
            self.git_ok(cwd, &restore_args, &literal_pathspecs()).await?;
        }
        for path in paths.iter().filter(|p| !tracked.contains(p)) {
            let full = cwd.join(path);
            let _ = if full.is_dir() { std::fs::remove_dir_all(&full) } else { std::fs::remove_file(&full) };
        }
        Ok(())
    }

    /// Synara `deleteCheckpointRefs`
    pub async fn delete_checkpoint_refs(&self, cwd: &Path, references: &[CheckpointRef]) -> Result<()> {
        for reference in references {
            self.git(cwd, &["update-ref", "-d", reference.as_str()], &[]).await?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn git(dir: &Path, args: &[&str]) -> String {
        let output = std::process::Command::new("git").args(args).current_dir(dir).output().unwrap();
        assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
        String::from_utf8(output.stdout).unwrap()
    }

    fn rescue_refs(dir: &Path) -> Vec<String> {
        git(dir, &["for-each-ref", "--format=%(refname)"]).lines().filter(|r| r.contains("/revert-rescue/")).map(str::to_owned).collect()
    }

    fn at(name: &str) -> CheckpointRef {
        CheckpointRef::new(format!("{CHECKPOINT_REFS_PREFIX}/dGhyZWFkLTE/turn-start/{name}"))
    }

    fn read(dir: &Path, path: &str) -> String {
        std::fs::read_to_string(dir.join(path)).unwrap()
    }

    /// The real git, except that a reverse apply in the folder fails once `passes` have gone
    /// through, after running `meanwhile` (what the person does while it runs).
    struct FailingApply {
        passes: std::sync::atomic::AtomicUsize,
        meanwhile: Box<dyn Fn() + Send + Sync>,
    }

    impl GitRunner for FailingApply {
        fn run(&self, cwd: &Path, args: &[String], env: &[(String, String)]) -> super::super::git::GitFuture {
            let worktree_reverse = args.first().is_some_and(|a| a == "apply")
                && args.iter().any(|a| a == "--reverse")
                && !args.iter().any(|a| a == "--cached");
            let ordering = std::sync::atomic::Ordering::SeqCst;
            if worktree_reverse && self.passes.fetch_update(ordering, ordering, |n| n.checked_sub(1)).is_err() {
                (self.meanwhile)();
                return Box::pin(async { Ok(GitOutput { code: Some(1), stdout: String::new(), stderr: "injected".to_owned() }) });
            }
            super::super::git::ProcessGit.run(cwd, args, env)
        }
    }

    /// A reverse that fails for real after an earlier one applied (the folder changed after the
    /// check) puts the touched paths back, in the folder and in the index, and deletes the rescue
    /// snapshot it put them back from. Paths are names: putting back `a*.txt` leaves `ab.txt`,
    /// which the person wrote meanwhile, alone.
    #[tokio::test]
    async fn a_failed_multi_turn_reverse_puts_back_what_it_had_taken_back() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path();
        git(cwd, &["init", "-q"]);
        std::fs::write(cwd.join("README.md"), "hello\n").unwrap();
        std::fs::write(cwd.join("ab.txt"), "person\n").unwrap();
        let ab = cwd.join("ab.txt");
        let store = CheckpointStore::new(Arc::new(FailingApply {
            passes: 1.into(),
            meanwhile: Box::new(move || std::fs::write(&ab, "meanwhile\n").unwrap()),
        }));
        let (s1, e1, s2, e2) = (at("s1"), at("e1"), at("s2"), at("e2"));
        store.capture_checkpoint(cwd, &s1, false).await.unwrap();
        std::fs::write(cwd.join("c.txt"), "c\n").unwrap();
        store.capture_checkpoint(cwd, &e1, false).await.unwrap();
        store.capture_checkpoint(cwd, &s2, false).await.unwrap();
        std::fs::write(cwd.join("a*.txt"), "x\n").unwrap();
        store.capture_checkpoint(cwd, &e2, false).await.unwrap();
        git(cwd, &["add", "README.md"]);
        let ranges = [(s2, e2), (s1, e1)];
        let rescue = revert_rescue_checkpoint_ref(&ThreadId::new("thread-1"), "r");

        let failed = store.reverse_checkpoint_diffs(cwd, &ranges, &rescue).await.unwrap_err();
        assert!(format!("{failed:#}").contains("injected"), "{failed:#}");
        assert_eq!(read(cwd, "a*.txt"), "x\n", "turn 2's reverse was put back");
        assert_eq!(read(cwd, "c.txt"), "c\n");
        assert_eq!(read(cwd, "ab.txt"), "meanwhile\n", "a path the pattern `a*.txt` would match is left alone");
        assert_eq!(git(cwd, &["ls-files"]), "README.md\n", "the index is as the person left it");
        assert!(rescue_refs(cwd).is_empty(), "the rescue snapshot is deleted once the paths are back");
    }

    /// A reverse that does not apply is refused before anything changes, and before a rescue
    /// snapshot is taken; once it applies, both turns go and the snapshot is deleted.
    #[tokio::test]
    async fn a_conflicting_multi_turn_reverse_changes_nothing_and_keeps_no_snapshot() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path();
        git(cwd, &["init", "-q"]);
        std::fs::write(cwd.join("README.md"), "hello\n").unwrap();
        let store = CheckpointStore::new(Arc::new(super::super::git::ProcessGit));
        let (s1, e1, s2, e2) = (at("s1"), at("e1"), at("s2"), at("e2"));
        store.capture_checkpoint(cwd, &s1, false).await.unwrap();
        std::fs::write(cwd.join("a.txt"), "a\n").unwrap();
        store.capture_checkpoint(cwd, &e1, false).await.unwrap();
        store.capture_checkpoint(cwd, &s2, false).await.unwrap();
        std::fs::write(cwd.join("b.txt"), "b\n").unwrap();
        store.capture_checkpoint(cwd, &e2, false).await.unwrap();
        // The person rewrites turn 1's file and stages their README.
        std::fs::write(cwd.join("a.txt"), "person\n").unwrap();
        git(cwd, &["add", "README.md"]);
        let ranges = [(s2, e2), (s1, e1)];
        let rescue = revert_rescue_checkpoint_ref(&ThreadId::new("thread-1"), "r");

        let checked = store.check_reverse_checkpoint_diffs(cwd, &ranges).await;
        assert!(format!("{:#}", checked.unwrap_err()).starts_with("Undo could not be applied"));
        let refused = store.reverse_checkpoint_diffs(cwd, &ranges, &rescue).await;
        assert!(format!("{:#}", refused.unwrap_err()).starts_with("Undo could not be applied"));
        assert_eq!(read(cwd, "b.txt"), "b\n");
        assert_eq!(read(cwd, "a.txt"), "person\n");
        assert_eq!(git(cwd, &["ls-files"]), "README.md\n");
        assert!(rescue_refs(cwd).is_empty(), "a refused reverse leaves no rescue snapshot");

        std::fs::write(cwd.join("a.txt"), "a\n").unwrap();
        assert!(store.reverse_checkpoint_diffs(cwd, &ranges, &rescue).await.unwrap());
        assert!(!cwd.join("a.txt").exists() && !cwd.join("b.txt").exists());
        assert_eq!(read(cwd, "README.md"), "hello\n");
        assert!(rescue_refs(cwd).is_empty(), "the rescue snapshot is deleted behind a reverse");
    }

    /// The patch goes to a file, so a turn whose diff is over Synara's in-memory cap reverses.
    #[tokio::test]
    async fn a_turn_whose_patch_is_over_the_diff_cap_reverses() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path();
        git(cwd, &["init", "-q"]);
        std::fs::write(cwd.join("README.md"), "hello\n").unwrap();
        let store = CheckpointStore::new(Arc::new(super::super::git::ProcessGit));
        let (s1, e1) = (at("s1"), at("e1"));
        store.capture_checkpoint(cwd, &s1, false).await.unwrap();
        // Incompressible bytes, so even git's deflated binary patch is over the cap.
        let mut state: u64 = 0x9E37_79B9_7F4A_7C15;
        let bytes: Vec<u8> = (0..CHECKPOINT_DIFF_MAX_OUTPUT_BYTES + 1_000_000)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                state as u8
            })
            .collect();
        std::fs::write(cwd.join("big.bin"), &bytes).unwrap();
        store.capture_checkpoint(cwd, &e1, false).await.unwrap();
        assert!(store.diff_checkpoints(cwd, &s1, &e1).await.is_ok(), "a binary diff without --binary is small");

        let ranges = [(s1, e1)];
        assert!(store.check_reverse_checkpoint_diffs(cwd, &ranges).await.unwrap());
        assert!(store.reverse_checkpoint_diffs(cwd, &ranges, &revert_rescue_checkpoint_ref(&ThreadId::new("t"), "r")).await.unwrap());
        assert!(!cwd.join("big.bin").exists());
        assert_eq!(read(cwd, "README.md"), "hello\n");
    }

    /// Taking a turn back leaves the person's index alone: a file the chat made and nobody staged
    /// stays untracked, and the person's partial staging stays; only what the turn itself staged
    /// goes back.
    #[tokio::test]
    async fn a_reverse_keeps_the_persons_index() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path();
        git(cwd, &["init", "-q"]);
        std::fs::write(cwd.join("README.md"), "hello\n").unwrap();
        git(cwd, &["add", "README.md"]);
        git(cwd, &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"]);
        let store = CheckpointStore::new(Arc::new(super::super::git::ProcessGit));
        let (s1, e1, s2, e2) = (at("s1"), at("e1"), at("s2"), at("e2"));
        store.capture_checkpoint(cwd, &s1, false).await.unwrap();
        std::fs::write(cwd.join("notes.txt"), "one\n").unwrap();
        store.capture_checkpoint(cwd, &e1, false).await.unwrap();
        // The person stages one version of the README and keeps writing another.
        std::fs::write(cwd.join("README.md"), "staged\n").unwrap();
        git(cwd, &["add", "README.md"]);
        std::fs::write(cwd.join("README.md"), "worktree\n").unwrap();
        store.capture_checkpoint(cwd, &s2, false).await.unwrap();
        // Turn 2 edits turn 1's untracked file and the README, and makes and stages a file.
        std::fs::write(cwd.join("notes.txt"), "two\n").unwrap();
        std::fs::write(cwd.join("README.md"), "turn\n").unwrap();
        std::fs::write(cwd.join("new.txt"), "new\n").unwrap();
        git(cwd, &["add", "new.txt"]);
        store.capture_checkpoint(cwd, &e2, false).await.unwrap();

        let ranges = [(s2, e2)];
        assert!(store.reverse_checkpoint_diffs(cwd, &ranges, &revert_rescue_checkpoint_ref(&ThreadId::new("t"), "r")).await.unwrap());
        assert_eq!(read(cwd, "notes.txt"), "one\n");
        assert_eq!(read(cwd, "README.md"), "worktree\n");
        assert!(!cwd.join("new.txt").exists());
        assert_eq!(git(cwd, &["ls-files"]), "README.md\n", "notes.txt stays untracked, new.txt is unstaged");
        assert_eq!(git(cwd, &["show", ":README.md"]), "staged\n", "the person's staging stays");
    }

    #[test]
    fn encodes_base64_url_without_padding() {
        assert_eq!(encode_base64_url("thread-1"), "dGhyZWFkLTE");
        assert_eq!(encode_base64_url("ab"), "YWI");
        assert_eq!(encode_base64_url("???"), "Pz8_");
    }

    #[test]
    fn names_and_recognizes_managed_refs() {
        let thread = ThreadId::new("thread-1");
        let turn = checkpoint_ref_for_thread_turn(&thread, 3);
        assert_eq!(turn.as_str(), "refs/cascade/checkpoints/dGhyZWFkLTE/turn/3");
        assert!(is_managed_checkpoint_ref(turn.as_str()));
        assert!(is_managed_checkpoint_ref(checkpoint_ref_for_turn_start(&thread, &TurnId::new("t")).as_str()));
        assert!(is_managed_checkpoint_ref("refs/synara/checkpoints/abc/turn/0"));
        assert!(!is_managed_checkpoint_ref("provider-diff:event-1"));
        assert!(!is_managed_checkpoint_ref("refs/cascade/checkpoints/abc/turn/x"));
    }
}
