#![recursion_limit = "256"]
//! Chat sessions that drive agent CLIs (Claude Code, Codex) over their JSON protocols, and fold
//! what they say into chat threads. A port of Synara's provider layer, kept shaped like it so
//! upstream changes can be followed: see `SYNARA.md` for the file map and the pinned commit.
//!
//! The crate depends on nothing in the app's backend. The backend owns one [`ChatEngine`], hands
//! it a place for its database and a callback for its events, and serves its commands and reads.

pub mod checkpointing;
pub mod contracts;
pub mod orchestration;
pub mod persistence;
pub mod provider;

/// The project id of a chat that belongs to no Cascade project (Synara's `ProjectId` must not be
/// empty). A project's chats carry the project's UUID.
pub const STANDALONE_PROJECT_ID: &str = "cascade-standalone";

pub use orchestration::engine::{
    ChatEngine, ChatEngineConfig, ChatEngineEvent, ChatError, DispatchResult, ProviderInfo,
};
