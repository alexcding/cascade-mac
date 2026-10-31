//! The iOS Simulator device layer: Synara's device backend, ported module for module (see
//! `SYNARA.md` beside this file), with Synara's native helper vendored verbatim under
//! `vendor/synara-device-helper`.
//!
//! The lower half is the backend that discovers, boots and drives simulators (`ios_simulator.rs`,
//! behind the `DeviceBackend` trait), the helper client and its frame stream, and the
//! accessibility-tree logic the agent tools read the screen through. On top of it: the device
//! manager (`manager.rs`), which owns who watches which device and the one stream; the agent's
//! `device_*` tools (`tools.rs`); and the Simulator pane's routes and frame sockets (`routes.rs`,
//! `frames.rs`, `transport.rs`). `service.rs` is how `AppState` holds it.

pub mod backend;
pub mod boot_ownership;
pub mod cache;
pub mod capabilities;
pub mod catalogue;
pub mod contracts;
pub mod frame;
pub mod frames;
// The helper's whole method table is named, including methods nothing here calls (`ping`, `list`,
// `stream.stats`, `touch`).
#[allow(dead_code)]
pub mod helper;
pub mod ios_simulator;
pub mod logs;
pub mod manager;
pub mod process;
pub mod routes;
pub mod sandbox;
pub mod service;
pub mod tools;
pub mod transport;
pub mod tree_targeting;
pub mod ui_snapshot;
pub mod ui_targeting;

#[cfg(test)]
mod tests;

/// Milliseconds since the epoch as JavaScript's `toISOString` writes them.
pub(crate) fn iso_from_millis(millis: i64) -> String {
    chrono::DateTime::<chrono::Utc>::from_timestamp_millis(millis)
        .unwrap_or_default()
        .to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

pub(crate) fn now_millis() -> i64 {
    chrono::Utc::now().timestamp_millis()
}
