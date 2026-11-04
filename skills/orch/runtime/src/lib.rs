//! The repository orchestration runtime: one repository's admitted work and
//! its workflow state, as documents with typed read views and the domain
//! operations over them, plus the standing scheduler that decides when each
//! duty is due.
//!
//! The crate owns the item and fleet state files in the shape the
//! `workflow-state` script writes, every transition over them, and the write
//! check (the content comparison under the file's lock). It writes a record
//! as a patch on the document it read, so a field it does not transition
//! keeps its value and position, and it refuses only what the script's
//! readers refuse on the same file. It does not own process or
//! native-session identity, launch, observation, delivery or the exact stop:
//! those are `agent-runtime`'s, and an operation that needs one persists its
//! intent here, runs the effect through that crate (`effects`) and records
//! the outcome it observed. `settings` is the one reader of the project's
//! `kendex.settings.toml` keys the runtime acts on; the keys and their
//! defaults are its constants. `verify` reads GitHub for a published head
//! through agent-runtime's one process runner and records the verdict.
//! `send` records a directive send to a cloud session lane before the
//! mailbox program makes it and stamps the receipt after. `watch` is the
//! standing scheduler: the one long-lived runner per fleet state, its
//! claim, its event log and its baseline, driving the duties on
//! `schedule`'s due times.

pub mod archive;
pub mod effects;
pub mod error;
pub mod mailbox;
pub mod ops;
pub mod proof;
pub mod protocol;
pub mod schedule;
pub mod send;
pub mod settings;
pub mod state;
pub mod validate;
pub mod verify;
pub mod watch;

pub use error::{Error, Result};
