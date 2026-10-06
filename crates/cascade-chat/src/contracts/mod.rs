//! Wire types, ported from Synara `packages/contracts/src`. Field names serialize exactly as
//! Synara's do (camelCase, the same literals), so the chat page reads them with Synara's own
//! client code.

pub mod base;
pub mod model;
pub mod orchestration;
pub mod provider;
pub mod provider_runtime;
