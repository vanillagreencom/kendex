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
pub mod marker;
pub mod ops;
pub mod policy;
pub mod proof;
pub mod protocol;
pub mod repo;
pub mod schedule;
pub mod send;
pub mod settings;
pub mod state;
pub mod turnend;
pub mod validate;
pub mod verify;
pub mod watch;

pub use error::{Error, Result};

/// `text` as the executable `path`, written by a child shell: a write
/// descriptor open in this process leaks into any sibling test's child
/// between its fork and exec, and an exec of the file meanwhile fails with
/// ETXTBSY.
#[cfg(test)]
#[allow(
    clippy::disallowed_methods,
    reason = "the lib tests' one writer of an executable they run: a child shell, so the test process never holds the file open for writing"
)]
pub(crate) fn write_executable(path: &std::path::Path, text: impl AsRef<str>) {
    let written = std::process::Command::new("sh")
        .args(["-c", "printf '%s' \"$2\" > \"$1\" && chmod 755 \"$1\"", "_"])
        .arg(path)
        .arg(text.as_ref())
        .status()
        .unwrap();
    assert!(written.success(), "write-executable {}", path.display());
}
