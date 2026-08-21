//! Rebuilding the plan that produced what is on disk.
//!
//! Split out of `desired.rs`: this is the audit's question rather than an
//! apply's, and it is the one place a lock's word chooses anything — which
//! revision to rebuild from, never what the answer is.

use crate::env::Env;
use crate::error::Result;
use crate::lock::Lock;
use crate::manifest::Manifest;
use crate::model::Scope;

use super::super::expansion::PLANNED_KINDS;
use super::{DesiredState, desired_state};

/// The plan that produced what is on disk: every declaration read at the
/// revision its lock entry came from, rather than at the one it tracks now.
///
/// This is what an audit compares against. Reading the *current* revision
/// would call a clean install unreviewed the moment upstream moved, which
/// is a thing that happens to every following installation between an
/// upstream push and the next refresh. What is wanted is the world the
/// apply built, rebuilt.
///
/// The commit each entry names is the lock's word, and the lock is a file
/// this project commits — but nothing is taken on that word. It chooses
/// which revision to rebuild from, and the rebuild then has to equal the
/// bytes on disk. Naming another commit produces another artifact, which
/// is not what is installed, and the record it carried settles nothing.
///
/// A path source has no revision to name, so it is read as it is now: a
/// local catalog that edits an item has moved the content its records were
/// about, and saying so is the same answer every other edit gets.
pub fn desired_as_installed(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
) -> Result<DesiredState> {
    let mut pinned = manifest.clone();
    for kind in PLANNED_KINDS {
        for (name, decl) in pinned.declared_mut(kind) {
            let key = |harness| crate::lock::entry_key(kind, name, harness);
            decl.rev = crate::model::HarnessId::ALL
                .into_iter()
                .find_map(|harness| lock.entries.get(&key(harness)))
                .and_then(|entry| entry.source_commit.clone())
                .or_else(|| decl.rev.clone());
        }
    }
    desired_state(env, scope, &pinned, lock)
}
