//! What a plan changes about the installed set, as opposed to what it
//! regenerates. Regenerating an installation that stays is safe to do
//! unasked — generated content is replaceable by construction — while
//! adding or dropping one is a decision, so it is previewed and confirmed.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::lock::{Lock, LockEntry, Reason};
use crate::model::{HarnessId, ItemKind};

use super::desired::Retirement;

/// What the orphan pass says, by entry key, of each record a withholding
/// or a missing companion takes (`removal::orphans`).
pub(super) type Said = BTreeMap<String, &'static str>;

/// The items a pass met retired (`DesiredState::retired`).
pub(super) type Retired = BTreeMap<(ItemKind, String), Retirement>;

/// Whether a plan brings an installation into being or takes one away.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum SetDirection {
    Add,
    Remove,
}

/// One installation a plan adds or drops, as opposed to regenerating one
/// that stays. Regeneration is safe to do unasked — the content is
/// replaceable by construction — while changing *what is installed* is a
/// decision, so it is previewed and confirmed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SetChange {
    pub kind: ItemKind,
    pub name: String,
    pub harness: HarnessId,
    pub direction: SetDirection,
    /// Why, in the words a preview shows.
    pub reason: String,
}

impl SetChange {
    pub(super) fn added(entry: &LockEntry) -> SetChange {
        SetChange {
            reason: why_wanted(&entry.reasons),
            direction: SetDirection::Add,
            kind: entry.kind,
            name: entry.name.clone(),
            harness: entry.harness,
        }
    }

    /// `said` is what the orphan pass says of a withholding or a missing
    /// companion that takes the copy ([`Said`]): the reason says so and
    /// points at the hook's warning, since a hook still declared is not
    /// dropped for want of a declaration. `retired` is every item this pass
    /// met retired: one nothing withholds goes for its retirement, whatever
    /// brought it in.
    pub(super) fn dropped(
        entry: &LockEntry,
        said: Option<&'static str>,
        retired: &Retired,
    ) -> SetChange {
        let retirement = retired.get(&(entry.kind, entry.name.clone()));
        let requested = entry.reasons.contains(&Reason::Requested);
        let reason = match (said, retirement, requested) {
            (Some(said), _, _) => format!("{said} — see the warning on {}", entry.name),
            (None, Some(retirement), _) => retirement.by.to_string(),
            (None, None, true) => "no longer declared here".to_owned(),
            (None, None, false) => format!(
                "nothing needs it anymore — it was {}",
                why_wanted(&entry.reasons)
            ),
        };
        SetChange {
            reason,
            direction: SetDirection::Remove,
            kind: entry.kind,
            name: entry.name.clone(),
            harness: entry.harness,
        }
    }
}

/// One installation a removal leaves in place, and what still accounts for
/// it. Uninstalling a bundle says both halves out loud: the members that go,
/// and the ones that stay because something else wants them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct KeptInstall {
    pub kind: ItemKind,
    pub name: String,
    pub harness: HarnessId,
    /// Why it stays, in the words a preview shows.
    pub reason: String,
}

/// The reasons an installation exists, said once, in the words a preview
/// uses. Every reason in a lock was recorded by a pass over the scope that
/// lock belongs to, so there is no other scope for one of them to name.
fn why_wanted(reasons: &BTreeSet<Reason>) -> String {
    let mut said: Vec<String> = Vec::new();
    for reason in reasons {
        said.push(match reason {
            Reason::Requested => "asked for".to_owned(),
            Reason::RequiredBy { by } => {
                format!("required by the {} {}", by.kind.name(), by.name)
            }
            Reason::MemberOf { bundle } => format!("part of the {} bundle", bundle.name),
        });
    }
    said.join(", and ")
}

/// The installed set before against the installed set after — every
/// installation this plan brings into being or takes away, whatever the
/// reason. Regeneration of an installation that stays is not in here.
pub(super) fn set_changes(
    before: &Lock,
    after: &Lock,
    said: &Said,
    retired: &Retired,
) -> Vec<SetChange> {
    let mut changes: Vec<SetChange> = after
        .entries
        .iter()
        .filter(|(key, _)| !before.entries.contains_key(*key))
        .map(|(_, entry)| SetChange::added(entry))
        .collect();
    changes.extend(
        before
            .entries
            .iter()
            .filter(|(key, _)| !after.entries.contains_key(*key))
            .map(|(key, entry)| SetChange::dropped(entry, said.get(key).copied(), retired)),
    );
    changes
}

/// What an uninstalled bundle's members turned out to be held by. Only the
/// members that survive are here — the ones that went are already in the set
/// changes — and each reads back with the reasons it has left, which is
/// exactly what the user needs to see to believe the split.
pub(super) fn kept_members(before: &Lock, after: &Lock, bundles: &[String]) -> Vec<KeptInstall> {
    if bundles.is_empty() {
        return Vec::new();
    }
    before
        .entries
        .iter()
        .filter(|(_, entry)| {
            entry.reasons.iter().any(|reason| match reason {
                Reason::MemberOf { bundle } => bundles.contains(&bundle.name),
                Reason::Requested | Reason::RequiredBy { .. } => false,
            })
        })
        .filter_map(|(key, _)| after.entries.get(key))
        .map(|entry| KeptInstall {
            kind: entry.kind,
            name: entry.name.clone(),
            harness: entry.harness,
            reason: why_wanted(&entry.reasons),
        })
        .collect()
}
