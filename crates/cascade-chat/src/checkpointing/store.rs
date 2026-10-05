//! Ported from Synara `apps/server/src/checkpointing/Layers/CheckpointStore.ts` (capture, copy,
//! diff, restore, delete) and the ref names of `checkpointing/Utils.ts`.
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

    async fn resolve_head_commit(&self, cwd: &Path) -> Result<Option<String>> {
        let output = self.git(cwd, &["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], &[]).await?;
        Ok(output.success().then(|| output.stdout.trim().to_owned()).filter(|c| !c.is_empty()))
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
        let working_index = self.seed_checkpoint_index(cwd, &temp_index).await?;
        if working_index.is_none() && self.has_head_commit(cwd).await? {
            self.git_ok(cwd, &["read-tree", "HEAD"], &env).await?;
        }
        if let Some(metadata) = &working_index {
            // Really-refresh makes git verify racily clean entries of the copied index.
            self.git(cwd, &["update-index", "--really-refresh"], &env).await?;
            // Copying advanced the index's timestamp; put the original back so a rapid
            // same-size rewrite still looks newer than the snapshot and is hashed.
            if let Ok(modified) = metadata.modified() {
                if let Ok(file) = std::fs::File::options().write(true).open(&temp_index) {
                    let _ = file.set_modified(modified);
                }
            }
        }
        self.git_ok(cwd, &["add", "-A", "--", "."], &env).await?;
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
        let from_commit = self.resolve_checkpoint_commit(cwd, from).await?;
        let to_commit = self.resolve_checkpoint_commit(cwd, to).await?;
        let (Some(from_commit), Some(to_commit)) = (from_commit, to_commit) else {
            return Err(anyhow!("Checkpoint ref is unavailable for diff operation."));
        };
        let output = self
            .git_ok(
                cwd,
                &["diff", "--patch", "--minimal", "--no-color", "--no-ext-diff", "--no-textconv", &from_commit, &to_commit],
                &[],
            )
            .await?;
        if output.stdout.len() > CHECKPOINT_DIFF_MAX_OUTPUT_BYTES {
            bail!("The turn diff is larger than {CHECKPOINT_DIFF_MAX_OUTPUT_BYTES} bytes.");
        }
        Ok(output.stdout)
    }

    /// Synara `restoreCheckpoint`: put the workspace back as `reference` has it. `false` when the
    /// checkpoint (and, with `fallback_to_head`, HEAD) is unavailable.
    pub async fn restore_checkpoint(&self, cwd: &Path, reference: &CheckpointRef, fallback_to_head: bool) -> Result<bool> {
        let mut commit = self.resolve_checkpoint_commit(cwd, reference).await?;
        if commit.is_none() && fallback_to_head {
            commit = self.resolve_head_commit(cwd).await?;
        }
        let Some(commit) = commit else {
            return Ok(false);
        };
        self.git_ok(cwd, &["restore", "--source", &commit, "--worktree", "--staged", "--", "."], &[]).await?;
        self.git_ok(cwd, &["clean", "-fd", "--", "."], &[]).await?;
        if self.has_head_commit(cwd).await? {
            self.git_ok(cwd, &["reset", "--quiet", "--", "."], &[]).await?;
        }
        Ok(true)
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
