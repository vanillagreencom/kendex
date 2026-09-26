//! Every project path kendex's harness adapters read, and the role each
//! harness reads it in: root, catalog, registry or instruction.
//!
//! The document is for a classifier deciding which changed paths a harness
//! acts on, so the adapters in `kendex_core::harness` stay the one owner of
//! which paths those are. The document depends on no project, no install
//! record and nothing under the caller's home, so every caller gets the
//! same rows, in a checkout that has installed nothing too. The process
//! still does what every run of the binary does at startup, such as
//! recording where the command is installed.

use kendex_core::env::Env;
use kendex_core::harness::PathsDocument;

use super::{CliResult, answer};

pub fn run(env: &Env) -> CliResult {
    answer(&serde_json::to_string_pretty(&PathsDocument::new(env))?);
    Ok(())
}
