//! Shared agent execution: launch, observe, deliver to and stop one
//! coding-harness session, with every identity held exactly.
//!
//! The crate is the one owner of process and native-session identity,
//! launch and adoption, observation, supported delivery and the exact stop.
//! It knows no tracker, review, report or fleet policy: a caller supplies
//! its intent and policy inputs and consumes typed results.

pub mod clock;
pub mod context;
pub mod controller;
pub mod error;
pub mod harness;
pub mod host;
pub mod intent;
pub mod launch;
pub mod observe;
pub mod process;
pub mod protocol;
pub mod reading;
pub mod record;
pub mod rows;
pub mod session;
pub mod settings;
pub mod trust;

pub use error::{Error, Result};
pub use harness::Harness;
