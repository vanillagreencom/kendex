//! Shared agent execution: launch, observe, deliver to and stop one
//! coding-harness session, with every identity held exactly.
//!
//! The crate is the one owner of process and native-session identity,
//! launch and adoption, observation, supported delivery and the exact stop.
//! It knows no tracker, review, report or fleet policy: a caller supplies
//! its intent and policy inputs and consumes typed results.

pub mod accounts;
pub mod clock;
pub mod context;
pub mod controller;
#[allow(
    clippy::disallowed_methods,
    reason = "the engine is the one owner of every primitive it acts with, its job launcher's files and the owner notice"
)]
pub mod effects;
pub mod error;
pub mod harness;
#[allow(
    clippy::disallowed_methods,
    reason = "the runner and the tmux client define the primitives the fence holds, and call each other"
)]
pub mod host;
pub mod intent;
#[allow(
    clippy::disallowed_methods,
    reason = "the journal's own writes are its commit's callers, and its commit is the store's"
)]
pub mod journal;
pub mod launch;
pub mod observe;
#[allow(
    clippy::disallowed_methods,
    reason = "the process module defines the exact stop the fence holds, and its own rows run it"
)]
pub mod process;
pub mod protocol;
pub mod reading;
#[allow(
    clippy::disallowed_methods,
    reason = "the record module defines the store's write, and its own rows run it"
)]
pub mod record;
pub mod rows;
pub mod session;
pub mod settings;
#[allow(
    clippy::disallowed_methods,
    reason = "the trust module defines the trust write, and its own rows run it"
)]
pub mod trust;

pub use error::{Error, Result};
pub use harness::Harness;
