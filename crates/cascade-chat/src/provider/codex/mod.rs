//! Codex, driven as `codex app-server` over JSON-RPC on stdio.

pub mod adapter;
pub mod app_server_manager;
pub mod transport;
pub mod turn_input;

pub use adapter::CodexAdapter;
