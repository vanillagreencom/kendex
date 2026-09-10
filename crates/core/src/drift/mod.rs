//! The drift report agents wake up to.
//!
//! Session start reads a snapshot; the background job earns it. The check
//! ([`report`]) reads the lock, the manifest, the per-scope drift snapshot
//! ([`snapshot`]) and the per-mirror fetch stamps ([`stamps`]) — nothing
//! else: it materializes no source trees, hashes no catalogs, and fans out
//! no per-package subprocesses. The deep work runs where time is free —
//! `updates`, `refresh`, `apply`, and the detached background fetch all
//! re-derive the snapshot — and the check renders snapshot plus age. A
//! mirror that moved since its last evaluation reads as unevaluated, the
//! honest "maybe", never a guessed verdict.

pub mod hook;
pub mod refresh;
pub mod report;
pub mod setup;
pub mod snapshot;
pub mod stamps;
