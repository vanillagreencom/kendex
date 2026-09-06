//! Whether a request would land anywhere, and which kinds it would land.
//!
//! Success has to mean bytes reached disk. A selection naming tools that
//! take none of what is being installed plans nothing, applies nothing and
//! reports done — so it is refused here, before the manifest is touched,
//! and the same filter draws the picker so the choice can never be made in
//! the first place.
//!
//! A curated set is the same question asked one step later: what it holds
//! is the catalog's to say, so it is answered where the request's sets have
//! been resolved rather than from the request alone.

use super::AddRequest;
use crate::manifest::Manifest;
use crate::model::{HarnessId, ItemKind, Scope};

/// Why this request would install nothing, or `None` where at least one
/// named tool can take at least one of the kinds asked for.
///
/// Only an explicit selection is answered here. Leaving the tools to the
/// scope's defaults is a different question — what the scope targets is
/// re-read as the pass runs, and an empty answer there is reported per
/// item, where the reader can see which item it was.
pub(super) fn lands_nowhere(request: &AddRequest, scope: &Scope) -> Option<String> {
    let chosen = request.harnesses.as_deref()?;
    if chosen.is_empty() {
        return Some("no tool was chosen to install to".to_owned());
    }
    let kinds = requested_kinds(request);
    if kinds.iter().any(|kind| {
        chosen
            .iter()
            .any(|h| crate::harness::installs_here(*h, *kind, scope))
    }) {
        return None;
    }
    Some(format!(
        "{} {} nothing of this kind at this scope",
        chosen
            .iter()
            .map(|h| h.display_name().to_owned())
            .collect::<Vec<_>>()
            .join(", "),
        match chosen.len() {
            1 => "takes",
            _ => "take",
        }
    ))
}

/// The same question for one curated set, asked once its members are
/// known: `None` where at least one kind the catalog offers for the set
/// reaches a tool this request installs to, and the tools it turned the
/// install down for otherwise.
///
/// A set has to be asked separately because the manifest records only that
/// the set is installed — what it holds derives at plan time, so
/// [`requested_kinds`] can only widen a bundle request to every kind and
/// any tool taking any kind passes it. This reads what the plan itself
/// will read for each member, so the two cannot disagree about whether a
/// declaration puts bytes on disk.
///
/// `harnesses` is the list the set will be declared with, which the caller
/// derives — not the request's own, which answers for a declaration nobody
/// is about to write. `None` falls back to the scope's list, and by here
/// that list has already been brought up to date against the machine, so it
/// is what the plan will read too.
pub(super) fn set_lands_nowhere(
    offered: &[ItemKind],
    harnesses: Option<&[HarnessId]>,
    manifest: &Manifest,
    scope: &Scope,
) -> Option<Vec<HarnessId>> {
    let lands = offered.iter().any(|kind| {
        !crate::engine::desired::harnesses_for(harnesses, manifest, *kind, scope).is_empty()
    });
    match lands {
        true => None,
        false => Some(crate::engine::desired::requested_or_default(
            harnesses, manifest,
        )),
    }
}

/// The kinds this request would declare. A whole-source or bundle install
/// carries whatever the catalog holds, so it is every kind — narrowing it
/// to what happens to be named would refuse a request that is not empty.
/// What a named set actually holds is [`set_lands_nowhere`]'s question,
/// asked where its members have been resolved.
pub fn requested_kinds(request: &AddRequest) -> Vec<ItemKind> {
    if request.all || !request.bundles.is_empty() {
        return ItemKind::ALL.to_vec();
    }
    let named: Vec<(ItemKind, &Vec<String>)> = vec![
        (ItemKind::Agent, &request.agents),
        (ItemKind::Skill, &request.skills),
        (ItemKind::Hook, &request.hooks),
        (ItemKind::Command, &request.commands),
        (ItemKind::McpServer, &request.mcp_servers),
    ];
    let asked: Vec<ItemKind> = named
        .into_iter()
        .filter(|(_, names)| !names.is_empty())
        .map(|(kind, _)| kind)
        .collect();
    match asked.is_empty() {
        // A request naming nothing declares nothing; every kind is still
        // the honest answer to "what could this land", and the emptiness
        // itself is somebody else's refusal.
        true => ItemKind::ALL.to_vec(),
        false => asked,
    }
}

/// The tools that can take at least one of `kinds` at this scope — the
/// picker's rows, and what "every tool" means. Reading the same filter the
/// refusal reads is what keeps a picker from offering a choice the install
/// would turn down.
pub fn targets_for(kinds: &[ItemKind], scope: &Scope) -> Vec<crate::model::HarnessId> {
    crate::model::HarnessId::ALL
        .into_iter()
        .filter(|harness| crate::harness::installable(*harness))
        .filter(|harness| {
            kinds
                .iter()
                .any(|kind| crate::harness::installs_here(*harness, *kind, scope))
        })
        .collect()
}
