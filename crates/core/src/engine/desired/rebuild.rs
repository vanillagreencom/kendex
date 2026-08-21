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

use super::super::expansion::Pins;
use super::{Desired, desired_state_at};

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
            desired_state_at(env, scope, manifest, lock, &pinned_to(&installed, pass))?
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

/// What this pass rebuilds from: every installation at the `pass`th
/// revision it is recorded at, and left alone where it has no `pass`th one.
///
/// Keyed by the installation, never by a declaration. A bundle member and a
/// dependency are installed under a declaration written for something else
/// — the bundle, the parent — and are not in `declared` under their own
/// names at all, so pinning declarations rebuilt every derived installation
/// from wherever its source has moved to. A member still installed at the
/// commit its publisher reviewed then read as content that catalog does not
/// publish, which is the whole failure this rebuild exists to prevent,
/// coming back for anything a bundle brought in.
fn pinned_to(installed: &Installed, pass: usize) -> Pins {
    installed
        .iter()
        .filter_map(|(item, revisions)| Some((item.clone(), revisions.keys().nth(pass)?.clone())))
        .collect()
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
