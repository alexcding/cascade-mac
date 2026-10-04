//! The backend's own types: what crosses a module boundary instead of `serde_json::Value`, with
//! serde names that are the JSON the app already reads. Nothing here touches a process, a file
//! or a database.

mod fault;
mod project;
mod session;
mod snapshot;

pub use fault::Fault;
pub use project::Project;
pub use session::{folder, Session};
pub use snapshot::PrSnapshot;
