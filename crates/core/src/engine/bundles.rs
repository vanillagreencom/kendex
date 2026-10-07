//! Which items an installed bundle brings in.
//!
//! A bundle is a curated set a catalog offers under one name. The manifest
//! records that the set is installed and nothing else — what it holds is the
//! catalog's to say, and it derives here on every plan, each member carrying
//! an edge back to the bundle it came in with. That edge is what lets the
//! bundle be uninstalled later without taking anything the user also asked
//! for, and without stranding anything they did not.
//!
//! Members are the catalog's own items, always: a set cannot reach into
//! another source, because a bare name from somewhere else names nothing
//! stable. A member this catalog does not offer is a finding that says which
//! member, and the rest of the set still installs.
//!
//! Two sets can carry one member and ask for it differently. The tools are
//! simply both, and a set that is switched on installs its member switched
//! on — an unrelated set that is switched off must never be the reason an
//! installed set's own member arrives dead. What is left is a genuine
//! disagreement, so it is reported rather than settled by whichever set the
//! manifest happens to name first.

use std::collections::btree_map::Entry;
use std::collections::{BTreeMap, BTreeSet};

use crate::lock::{BundleRef, Reason, entry_key};
use crate::manifest::{ItemDecl, Manifest};
use crate::model::{HarnessId, ItemKind, Scope};

use super::ItemWarning;
use super::desired::hold::HeldPins;
use super::desired::{DesiredState, KeptBundle, target_harnesses};
use super::expansion::{Catalogs, Expansion, Offer, OpenCatalog};

/// One member, as every set that carries it asked for it.
struct Carried {
    decl: ItemDecl,
    /// The set whose answer stands where the sets disagree.
    by: String,
    /// The edge each set adds, against the tools that set installs on.
    edges: Vec<(Reason, Vec<HarnessId>)>,
    /// Decls from other bundles that disagree on the held revision — kept
    /// alongside the winner so the rev-conflict check fires.
    rivals: Vec<ItemDecl>,
}

pub(super) fn expand(
    scope: &Scope,
    manifest: &Manifest,
    held: Option<&HeldPins>,
    expansion: &mut Expansion,
    catalogs: &mut Catalogs,
    state: &mut DesiredState,
) {
    let mut carried: BTreeMap<(ItemKind, String), Carried> = BTreeMap::new();
    for (name, decl) in &manifest.bundles {
        for (kind, member, member_decl, harnesses) in
            installable(name, decl, scope, manifest, held, catalogs, state)
        {
            let edge = (
                Reason::MemberOf {
                    bundle: bundle_ref(name, &decl.source),
                },
                harnesses,
            );
            match carried.entry((kind, member.clone())) {
                Entry::Vacant(slot) => {
                    slot.insert(Carried {
                        decl: member_decl,
                        by: name.clone(),
                        edges: vec![edge],
                        rivals: Vec::new(),
                    });
                }
                Entry::Occupied(mut slot) => {
                    let held = slot.get_mut();
                    if let Some(warning) =
                        disagreement(manifest, kind, &member, held, name, &member_decl)
                    {
                        state.warnings.push(warning);
                    }
                    // A member two bundles hold at different revisions is a
                    // conflict, not a silent first-wins: record the second
                    // decl so the rev-disagreement machinery raises it (one
                    // filesystem identity cannot be both revisions).
                    if held.decl.rev != member_decl.rev {
                        held.rivals.push(member_decl.clone());
                    }
                    held.decl.enabled |= member_decl.enabled;
                    held.edges.push(edge);
                }
            }
        }
    }
    for (
        (kind, name),
        Carried {
            decl,
            edges,
            rivals,
            ..
        },
    ) in carried
    {
        for (reason, harnesses) in edges {
            for harness in &harnesses {
                expansion.add(kind, &name, &decl, *harness, reason.clone());
                // Feed each rival rev on the same tools: two decls at
                // different revs for one item is what the conflict check
                // looks for.
                for rival in &rivals {
                    expansion.add(kind, &name, rival, *harness, reason.clone());
                }
            }
        }
    }
}

/// A member installs the way its bundle does: same source, same tools,
/// same method, same held revision, and off while the bundle is off.
///
/// One definition, because a member has no declaration of its own and every
/// reading that wants one has to arrive at the same answer. A preview that
/// reached for the member's own name found nothing and fell back to the
/// scope's default tools — so a bundle targeting one tool previewed a
/// rendering that tool never gets, and the page and the gate disagreed
/// about the same package.
pub(crate) fn member_decl(bundle: &ItemDecl) -> ItemDecl {
    ItemDecl {
        source: bundle.source.clone(),
        harnesses: bundle.harnesses.clone(),
        method: bundle.method,
        rev: bundle.rev.clone(),
        enabled: bundle.enabled,
        env: None,
    }
}

/// The revision one member reads, where the set is not the only thing that
/// says.
///
/// A set carries one revision to everything in it, and that is the answer
/// wherever the member has nothing else to read. A member the manifest
/// declares reads its own declaration instead, and what the set brings to
/// that reading is the revision the person wrote on the set — never the
/// pin a single-package update invented to hold the set still. Weighed
/// against the pin, one package is wanted at two revisions nobody chose,
/// and a plan that refuses both writes nothing for a package nobody
/// pinned.
///
/// What the declaration brings is the revision the person wrote on it, and
/// [`super::expansion::Planned`] keeps that where the pass pinned the
/// declaration too. Where the two differ the disagreement is real, and it
/// is stated in the revisions they wrote.
fn carried_rev(
    manifest: &Manifest,
    held: Option<&HeldPins>,
    bundle: &str,
    bundle_rev: Option<String>,
    kind: ItemKind,
    member: &str,
) -> Option<String> {
    if !manifest.declared(kind).contains_key(member) {
        return bundle_rev;
    }
    match held.is_some_and(|pins| pins.invented_bundle(bundle)) {
        true => None,
        false => bundle_rev,
    }
}

/// The members of one set this plan can actually install, each with the
/// declaration it installs under and the tools it lands on. Every member left
/// out is accounted for: held back by a removal, not offered by the catalog,
/// or of a kind no tool here holds.
fn installable(
    name: &str,
    decl: &ItemDecl,
    scope: &Scope,
    manifest: &Manifest,
    held: Option<&HeldPins>,
    catalogs: &mut Catalogs,
    state: &mut DesiredState,
) -> Vec<(ItemKind, String, ItemDecl, Vec<HarnessId>)> {
    let Some(catalog) = catalogs.get(&decl.source, decl.rev.as_deref(), state) else {
        state.mark_incomplete();
        return Vec::new();
    };
    let OpenCatalog { sealed, config, .. } = catalog;
    // What the catalog says is wrong with itself, on this path too: a set is
    // reached through here and never through the item pass, so without this
    // a bundle-only manifest is told nothing its catalog reported.
    super::catalog::notes(config, &decl.source, state);
    // `[retired]` answers before the set is looked for, as it does for an
    // item, so a catalog that retired a set and deleted it answers as one
    // still carrying it.
    if let Some(migration) = config.retired_bundle(name) {
        retire(name, &decl.source, migration, state);
        return Vec::new();
    }
    let offered = match crate::source::bundles::find(sealed, config, name) {
        Ok(offered) => offered,
        // The set is installed and this pass cannot say what it holds. The
        // catalog framing belongs to a catalog that would not read; a body
        // that will not read is that set's own breakage, and its error says
        // so. Either way the removal pass keeps what this could not account
        // for.
        Err(problem) => {
            state.mark_incomplete();
            state.notes.push(match &problem {
                crate::error::CoreError::UnreadableBundle { .. } => {
                    format!("bundle {name}: {problem}")
                }
                _ => format!(
                    "bundle {name}: the catalog '{}' could not be read — {problem}",
                    decl.source
                ),
            });
            return Vec::new();
        }
    };
    // Refused as a declared item the catalog does not carry is: a set
    // renamed in its catalog would otherwise uninstall what it brought in
    // from every consumer that declared it, and say so only in passing.
    let Some(bundle) = offered else {
        state.mark_incomplete();
        let offered = crate::source::bundles::names(config);
        let detail = super::desired::not_offered(&decl.source, "bundle", offered);
        state.notes.push(format!("bundle {name}: {detail}"));
        let kept = bundle_ref(name, &decl.source);
        state
            .kept_bundles
            .insert(kept, KeptBundle::NotOffered { detail });
        return Vec::new();
    };
    let mut installable = Vec::new();
    let mut held_back = 0;
    for member in &bundle.members {
        // A member the user took away stays away: the bundle is still
        // installed, and the audit says how much of it is not. A member they
        // declared by name is not held back at all — the declaration
        // outranks the record of the removal.
        if manifest.is_held_back(member.kind, &member.name) {
            held_back += 1;
            continue;
        }
        // A retired member is planned, for the item pass to keep or prune.
        if let Offer::NotOffered | Offer::Silent = catalog.offer(member.kind, &member.name) {
            state.mark_incomplete();
            state.warnings.push(ItemWarning {
                kind: member.kind,
                name: member.name.clone(),
                harness: None,
                message: format!(
                    "the bundle {name} carries {}, which the catalog '{}' does not offer",
                    member.name, decl.source
                ),
                remediation: Some(format!(
                    "add {} to that catalog, or drop it from the bundle {name}",
                    member.name
                )),
            });
            continue;
        }
        let mut member_decl = member_decl(decl);
        member_decl.rev = carried_rev(
            manifest,
            held,
            name,
            member_decl.rev,
            member.kind,
            &member.name,
        );
        let harnesses = target_harnesses(&member_decl, manifest, member.kind, scope);
        if harnesses.is_empty() {
            state.mark_incomplete();
            state.notes.push(format!(
                "bundle {name}: no tool here holds a {}, so {} was not installed",
                member.kind.name(),
                member.name
            ));
            continue;
        }
        installable.push((member.kind, member.name.clone(), member_decl, harnesses));
    }
    if held_back > 0 {
        state.notes.push(format!(
            "bundle {name}: installed, {held_back} member{} held back",
            match held_back {
                1 => "",
                _ => "s",
            }
        ));
    }
    installable
}

/// A declared set its catalog retired. Short of a prune, what it installed
/// stays as recorded, with one notice keyed by the set that ends with the
/// catalog's migration; its command is engine rule 18's exception for a
/// retired bundle's notice. A prune drops the declaration
/// (`desired::settle_retired`), and what only the set carried then goes as
/// any leftover does.
fn retire(name: &str, source: &str, migration: &str, state: &mut DesiredState) {
    if state.prune_retired {
        state.pruned_bundles.insert(name.to_owned());
        return;
    }
    let line =
        format!("bundle {name}: retired by {source}; kept; remove it with kendex refresh --prune");
    let notice = match migration.is_empty() {
        true => line,
        false => format!("{line}; {migration}"),
    };
    state.notes.push(notice.clone());
    let kept = KeptBundle::Retired { notice };
    state.kept_bundles.insert(bundle_ref(name, source), kept);
}

/// The records the sets in `kept` keep, by entry key, each with the edges
/// it was recorded under that tie it to them: what the record says such a
/// set brought in, since this pass cannot read what it holds, and what
/// those records require, until nothing changes. A member keeps its edges
/// to those sets, and a record kept for what it requires its
/// `RequiredBy` edges to records kept here. A record the expansion derives
/// on its tool requires afresh, so a stale reason naming it keeps nothing.
/// A record the person took away (`Manifest::is_held_back`) is not kept,
/// as a set this pass expands does not install it.
pub(super) fn kept_members(
    lock: &crate::lock::Lock,
    manifest: &Manifest,
    kept: &BTreeMap<BundleRef, KeptBundle>,
    expansion: &Expansion,
) -> BTreeMap<String, BTreeSet<Reason>> {
    let mut members: BTreeMap<String, BTreeSet<Reason>> = BTreeMap::new();
    loop {
        let mut changed = false;
        for (key, entry) in &lock.entries {
            if manifest.is_held_back(entry.kind, &entry.name) {
                continue;
            }
            let edges: BTreeSet<Reason> = entry
                .reasons
                .iter()
                .filter(|reason| match reason {
                    Reason::MemberOf { bundle } => kept.contains_key(bundle),
                    Reason::RequiredBy { by } => {
                        members.contains_key(&entry_key(by.kind, &by.name, by.harness))
                            && expansion.reasons(by.kind, &by.name, by.harness).is_empty()
                    }
                    Reason::Requested => false,
                })
                .cloned()
                .collect();
            if !edges.is_empty() && members.get(key) != Some(&edges) {
                members.insert(key.clone(), edges);
                changed = true;
            }
        }
        if !changed {
            return members;
        }
    }
}

fn bundle_ref(name: &str, source: &str) -> BundleRef {
    BundleRef {
        source: source.to_owned(),
        name: name.to_owned(),
    }
}

/// What two sets carrying one member cannot agree on, once the tools and the
/// on/off state have been merged. Where it comes from and how it lands are
/// one answer each, so the first set's stands and the user is told they had
/// a choice to make — declaring the item is how they make it.
fn disagreement(
    manifest: &Manifest,
    kind: ItemKind,
    name: &str,
    held: &Carried,
    second: &str,
    theirs: &ItemDecl,
) -> Option<ItemWarning> {
    let method = |decl: &ItemDecl| super::desired::effective_method(decl, manifest);
    let mut differ = Vec::new();
    if held.decl.source != theirs.source {
        differ.push("which catalog it comes from");
    }
    if method(&held.decl) != method(theirs) {
        differ.push("how it is installed");
    }
    if differ.is_empty() {
        return None;
    }
    Some(ItemWarning {
        kind,
        name: name.to_owned(),
        harness: None,
        message: format!(
            "the bundles {} and {second} both carry {name} and disagree about {} — it installs the way {} asks",
            held.by,
            differ.join(" and "),
            held.by
        ),
        remediation: Some(format!(
            "declare the {} {name} in kendex.toml to say how it should install",
            kind.name()
        )),
    })
}

/// The items the record says came in with any of these bundles. A bundle
/// uninstall names them alongside the bundle itself: taking the set away is
/// what takes its members away, and each one goes only if nothing else
/// accounts for it once the bundle's edge is gone.
pub(super) fn recorded_members(lock: &crate::lock::Lock, bundles: &[String]) -> Vec<String> {
    let mut names: Vec<String> = lock
        .entries
        .values()
        .filter(|entry| {
            entry.reasons.iter().any(|reason| match reason {
                Reason::MemberOf { bundle } => bundles.contains(&bundle.name),
                Reason::Requested | Reason::RequiredBy { .. } => false,
            })
        })
        .map(|entry| entry.name.clone())
        .collect();
    names.sort();
    names.dedup();
    names
}
