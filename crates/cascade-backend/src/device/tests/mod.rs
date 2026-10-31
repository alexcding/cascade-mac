//! Tests for the device layer, one file per module, ported from Synara's tests where they test
//! logic (`apps/server/src/device/*.test.ts`, `packages/shared/src/*.test.ts`).

mod boot_ownership;
mod cache;
mod capabilities;
mod catalogue;
mod fake;
mod frame;
mod helper;
mod ios_parsing;
mod ios_simulator;
mod live;
mod logs;
mod manager;
mod routes;
mod sandbox;
mod tools;
mod tree_targeting;
mod ui_snapshot;
mod ui_targeting;
mod vendor;
