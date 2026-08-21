//! Rebuilding the plan that produced what is on disk.
//!
//! Split out of `desired.rs`: this is the audit's question rather than an
//! apply's, and it is the one place a lock's word chooses anything — which
//! revision to rebuild from, never what the answer is.

use std::collections::{BTreeMap, BTreeSet};

use crate::env::Env;
use crate::error::Result;
use crate::lock::Lock;
use crate::manifest::Manifest;
use crate::model::{HarnessId, ItemKind, Scope};

use super::super::expansion::PLANNED_KINDS;
use super::{Desired, desired_state};

/// Which revisions one item is installed at, and which tools sit at each.
type Installed = BTreeMap<(ItemKind, String), BTreeMap<Option<String>, BTreeSet<HarnessId>>>;

/// The plan that produced what is on disk: every installation rebuilt at
/// the revision its own lock entry names, rather than at the one the
/// declaration tracks now.
///
/// This is what an audit compares against. Reading the *current* revision
/// would call a clean install unreviewed the moment upstream moved, which
/// happens to every following installation between an upstream push and the
/// next refresh. What is wanted is the world the apply built, rebuilt.
///
/// Per installation and not per declaration, because the lock legitimately
/// holds one revision per installation: refresh an item installed for
/// several tools and one tool's new rendering can be held back while
/// another's applies, leaving the two at different commits. Pinning the
/// declaration once rebuilds only one of them, and the other reads as
/// content its catalog does not publish — the very symptom this is here to
/// stop. So an item recorded at two revisions is planned twice, and each
/// pass keeps only the installations it was built for. One revision is the
/// ordinary case and costs one pass.
///
/// The commit each entry names is the lock's word, and the lock is a file
/// this project commits — but nothing is taken on that word. It chooses
/// which revision to rebuild from, and the rebuild then has to equal the
/// bytes on disk. Naming another commit produces another artifact, which is
/// not what is installed, and the record it carried settles nothing.
///
/// A path source has no revision to name, so it is read as it is now: a
/// local catalog that edits an item has moved the content its records were
/// about, and saying so is the same answer every other edit gets.
pub fn desired_as_installed(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
) -> Result<Vec<Desired>> {
    let installed = installed_at(lock);
    let passes = installed
        .values()
        .map(BTreeMap::len)
        .max()
        .unwrap_or(1)
        .max(1);
    let mut built = Vec::new();
    for pass in 0..passes {
        built.extend(
            desired_state(env, scope, &pinned_to(manifest, &installed, pass), lock)?
                .items
                .into_iter()
                .filter(|item| built_here(&installed, item, pass)),
        );
    }
    Ok(built)
}

/// Every installation the lock records, grouped by the revision it names.
fn installed_at(lock: &Lock) -> Installed {
    let mut found: Installed = BTreeMap::new();
    for entry in lock.entries.values() {
        found
            .entry((entry.kind, entry.name.clone()))
            .or_default()
            .entry(entry.source_commit.clone())
            .or_default()
            .insert(entry.harness);
    }
    found
}

/// The manifest as this pass reads it: every declaration at the `pass`th
/// revision anything is installed at, and left alone where there is no
/// `pass`th one.
fn pinned_to(manifest: &Manifest, installed: &Installed, pass: usize) -> Manifest {
    let mut pinned = manifest.clone();
    for kind in PLANNED_KINDS {
        for (name, decl) in pinned.declared_mut(kind) {
            if let Some(commit) = installed
                .get(&(kind, name.clone()))
                .and_then(|revisions| revisions.keys().nth(pass))
            {
                decl.rev = commit.clone().or_else(|| decl.rev.clone());
            }
        }
    }
    pinned
}

/// Whether this pass is the one that rebuilt this installation: the tool
/// sits at the revision this pass pinned, or the lock records no revision
/// for it at all and the first pass is the only one that will ever offer it
/// one.
fn built_here(installed: &Installed, item: &Desired, pass: usize) -> bool {
    let Some(revisions) = installed.get(&(item.kind, item.name.clone())) else {
        return pass == 0;
    };
    match revisions.values().nth(pass) {
        Some(tools) => tools.contains(&item.harness),
        None => false,
    }
}
