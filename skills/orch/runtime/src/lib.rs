//! The repository orchestration runtime: one repository's admitted work and
//! its workflow state, as documents with typed read views and the domain
//! operations over them, plus the standing scheduler that decides when each
//! duty is due.
//!
//! The crate owns the item and fleet state files as the legacy
//! `workflow-state` script shaped them, every transition over them, and the
//! two write checks (content on an unstamped file, revision on a stamped
//! one). It writes a record as a patch on the document it read, so a field
//! it does not transition keeps its value and position, and it refuses only
//! what a legacy reader refuses on the same file. It does not own process or
//! native-session identity, launch, observation, delivery or the exact stop:
//! those are `agent-runtime`'s, and an operation that needs one persists its
//! intent here and calls across.

pub mod error;
pub mod ops;
pub mod protocol;
pub mod schedule;
pub mod state;

pub use error::{Error, Result};
