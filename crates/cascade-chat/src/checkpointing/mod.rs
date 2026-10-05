//! Filesystem checkpoints: a snapshot of a thread's workspace before and after each turn, kept as
//! hidden git refs, and the turn's diff between them. Ported from Synara
//! `apps/server/src/checkpointing/` (`Utils.ts` for the ref names, `Layers/CheckpointStore.ts`
//! for the git operations); the reactor that decides when to capture lives in the engine.

pub mod git;
pub mod store;

pub use git::{GitOutput, GitRunner, ProcessGit};
pub use store::CheckpointStore;
