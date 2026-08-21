//! Writing down that a move is over.
//!
//! A finished move is a fact about the past, and the lock is where facts
//! about the past live. Deriving it from the present is what let an edit
//! to the new copy, or a catalog changing a hook's event, re-open a move
//! that had ended.

use std::collections::BTreeSet;

use super::super::desired::DesiredState;
use super::Sink;
use crate::lock::LockEntry;
use crate::model::{HarnessId, ItemKind};

/// A finished move goes into the record this plan writes, so no later
/// pass has to work it out again from bytes and registrations that have
/// every right to change afterwards. It rides the same plan as the
/// removals it describes: an apply that fails rolls both back.
pub(super) fn record_finished(finished: BTreeSet<String>, sink: &mut Sink) {
    for name in finished {
        let key = crate::lock::entry_key(ItemKind::Hook, &name, HarnessId::Pi);
        if let Some(entry) = sink.new_lock.entries.get_mut(&key) {
            entry.left_pi_reserved_name = true;
        }
    }
}

/// Every pi hook this scope knows about, installed or being installed —
/// what a plan that finds nothing at all under the reserved name may call
/// finished.
pub(super) fn every_pi_hook(entries: &[&LockEntry], state: &DesiredState) -> BTreeSet<String> {
    entries
        .iter()
        .map(|entry| entry.name.clone())
        .chain(desired_pi_hooks(state))
        .collect()
}

/// The pi hooks this pass installs that no lock entry names: the ones
/// with no history under the reserved name to have anything left in.
pub(super) fn newly_installed(entries: &[&LockEntry], state: &DesiredState) -> BTreeSet<String> {
    desired_pi_hooks(state)
        .filter(|name| !entries.iter().any(|entry| &entry.name == name))
        .collect()
}

fn desired_pi_hooks(state: &DesiredState) -> impl Iterator<Item = String> + '_ {
    state
        .items
        .iter()
        .filter(|item| item.kind == ItemKind::Hook && item.harness == HarnessId::Pi)
        .map(|item| item.name.clone())
}
