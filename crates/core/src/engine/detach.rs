//! Unsubscribing: what leaves with a marketplace, and removing it.
//!
//! The closure of a source is **derived by re-expansion, not read off
//! declarations**: expand the installed set with the source present and again
//! with its declarations gone, and diff. A derived dependency never names the
//! source in the manifest, so only the difference between the two expansions
//! tells the truth about what its going takes with it. When the source bytes
//! that expansion needs are unreachable, the closure refuses rather than infer.

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{ItemDecl, Manifest};
use crate::model::{ItemKind, Scope};

use super::EngineReport;
use super::planned::planned_declarations;

/// One item that leaves with the source: its kind and name, the declaration it
/// installs under, and whether it was derived (a bundle member or a dependency)
/// rather than declared by name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClosureItem {
    pub kind: ItemKind,
    pub name: String,
    pub decl: ItemDecl,
    pub derived: bool,
}

/// Everything a source's going removes: the items (declared and derived) and
/// the curated sets declared from it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Closure {
    pub items: Vec<ClosureItem>,
    pub bundles: Vec<String>,
}

/// What unsubscribing shows before it acts: the packages that leave, split into
/// the ones a plain removal or a from-source keep can handle and the ones the
/// user has edited (which must be forked or discarded first), and the curated
/// sets that go with the source.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Preview {
    pub removable: Vec<(ItemKind, String)>,
    pub edited: Vec<(ItemKind, String)>,
    pub bundles: Vec<String>,
}

/// The partition an unsubscribe dialog reads. Refuses, like the closure, while
/// the source itself cannot be reached — the fix is to refresh first.
pub fn preview(env: &Env, scope: &Scope, source_name: &str) -> Result<Preview> {
    let scope = scope.canonical();
    let manifest = super::ops::manifest_for_mutation(env, &scope)?;
    let closure = closure(env, &scope, source_name, &manifest)?;
    let lock = crate::lock::load(&crate::lock::lock_path(env, &scope))?;
    let edited: std::collections::BTreeSet<(ItemKind, String)> =
        edited_items(env, &scope, &closure, &lock)
            .into_iter()
            .collect();
    let (mut edited_out, mut removable) = (Vec::new(), Vec::new());
    for item in &closure.items {
        let row = (item.kind, item.name.clone());
        if edited.contains(&row) {
            edited_out.push(row);
        } else {
            removable.push(row);
        }
    }
    Ok(Preview {
        removable,
        edited: edited_out,
        bundles: closure.bundles,
    })
}

/// The closure of a subscription, by re-expansion. Refuses when the source is
/// not readable at the commit its installations were expanded from — a closure
/// inferred from an unreachable catalog could strand a derived dependency or
/// sweep one that another parent still keeps.
pub fn closure(
    env: &Env,
    scope: &Scope,
    source_name: &str,
    manifest: &Manifest,
) -> Result<Closure> {
    let scope = scope.canonical();
    if !manifest.sources.contains_key(source_name) {
        return Err(CoreError::UnknownSource {
            name: source_name.to_owned(),
        });
    }
    // The expansion reads the source's bundles and dependencies; if it cannot
    // be reached, refuse and name the fix rather than compute a wrong closure.
    match crate::source::resolve(env, &scope, source_name, manifest)? {
        crate::source::SourceState::Ready(_) => {}
        crate::source::SourceState::Pending { .. } => {
            return Err(CoreError::SourcePending {
                name: source_name.to_owned(),
            });
        }
        crate::source::SourceState::Disabled { .. } => {
            return Err(CoreError::SourceDisabled {
                name: source_name.to_owned(),
            });
        }
        crate::source::SourceState::Missing { path, .. } => {
            return Err(CoreError::SourceMissing {
                name: source_name.to_owned(),
                path,
            });
        }
    }

    let before = planned_declarations(env, &scope, manifest);
    let without = without_source(manifest, source_name);
    let after = planned_declarations(env, &scope, &without);

    let kept: std::collections::BTreeSet<(ItemKind, String)> = after
        .iter()
        .map(|item| (item.kind, item.name.clone()))
        .collect();
    let items = before
        .into_iter()
        .filter(|item| !kept.contains(&(item.kind, item.name.clone())))
        .map(|item| ClosureItem {
            kind: item.kind,
            name: item.name,
            decl: item.decl,
            derived: item.derived,
        })
        .collect();
    let bundles = manifest
        .bundles
        .iter()
        .filter(|(_, decl)| decl.source == source_name)
        .map(|(name, _)| name.clone())
        .collect();
    Ok(Closure { items, bundles })
}

/// The manifest with every declaration that names the source dropped — items,
/// bundles, and the source itself — the post-mutation half of the diff.
fn without_source(manifest: &Manifest, source_name: &str) -> Manifest {
    let mut out = manifest.clone();
    for kind in super::expansion::PLANNED_KINDS {
        out.declared_mut(kind)
            .retain(|_, decl| decl.source != source_name);
    }
    out.bundles.retain(|_, decl| decl.source != source_name);
    out.sources.remove(source_name);
    // An optional-dependency choice whose parent skill is gone is gone too.
    out.optional_dependencies
        .retain(|parent, _| out.skills.contains_key(parent));
    out
}

/// Unsubscribe and uninstall: remove every declaration the source's closure
/// covers, then let the plan sweep the installations and any dependency whose
/// only parents left with it. Members another marketplace's bundle still
/// carries stay, by the same edge rules an ordinary removal follows. An edited
/// installation is never swept without a decision — remove refuses while any
/// package is edited unless `discard_edits` says to take the edits too.
pub fn remove(
    env: &Env,
    scope: &Scope,
    source_name: &str,
    discard_edits: bool,
) -> Result<EngineReport> {
    let scope = scope.canonical();
    let manifest = super::ops::manifest_for_mutation(env, &scope)?;
    // Validate reachability the same way the closure does, so remove and its
    // preview never disagree about whether the source can be read.
    let closure = closure(env, &scope, source_name, &manifest)?;
    let lock = crate::lock::load(&crate::lock::lock_path(env, &scope))?;
    if !discard_edits {
        let edited = edited_items(env, &scope, &closure, &lock);
        if !edited.is_empty() {
            return Err(CoreError::DetachEdited {
                names: edited_labels(&edited),
            });
        }
    }
    let without = without_source(&manifest, source_name);
    // Dropping the declarations orphans their installations; remove takes those
    // off disk. The filter is the closure's own names, so orphan removal is
    // scoped to what left with this source — a derived dependency is named so
    // it is not kept as "unaccountable" now that its origin is gone — and no
    // unrelated pre-existing orphan is swept along.
    let options = super::PlanOptions {
        remove_orphans: true,
        removal_filter_typed: Some(
            closure
                .items
                .iter()
                .map(|i| (i.kind, i.name.clone()))
                .collect(),
        ),
        sweep_unneeded: true,
        overwrite_edited: discard_edits,
        ..super::PlanOptions::default()
    };
    let mut report = super::plan_scope(env, &scope, &without, &lock, &options)?;
    if !super::persists_manifest(&report.plan.ops) {
        crate::rename::insert_manifest_save(env, &scope, &mut report.plan, without)?;
    }
    Ok(report)
}

/// The closure items whose installation the user has edited by hand.
fn edited_items(
    env: &Env,
    scope: &Scope,
    closure: &Closure,
    lock: &crate::lock::Lock,
) -> Vec<(ItemKind, String)> {
    closure
        .items
        .iter()
        .filter(|item| {
            lock.entries
                .values()
                .filter(|e| e.kind == item.kind && e.name == item.name)
                .any(|e| install_edited(env, scope, e))
        })
        .map(|item| (item.kind, item.name.clone()))
        .collect()
}

/// Whether the user has edited this installation's bytes, for the kinds detach
/// can lose bytes for. The engine's own check covers skills, agents, commands
/// and anchored hooks; an anchor-less non-pi hook record holds nothing there,
/// so the sweep can still clean it up — but detach can lose bytes, so here any
/// present file of such a record's holds.
/// (An MCP server is a config entry with no standalone file — its edits are not
/// detected here, the one gap that remains.)
fn install_edited(env: &Env, scope: &Scope, entry: &crate::lock::LockEntry) -> bool {
    if super::removal::edit_holds(env, scope, entry) {
        return true;
    }
    if entry.kind != ItemKind::Hook {
        return false;
    }
    let owned = super::owned::installed(env, scope, entry);
    let present: Vec<_> = owned
        .files
        .iter()
        .filter(|path| !path.is_symlink() && path.exists())
        .collect();
    match &entry.rendered_hash {
        None => !present.is_empty(),
        Some(rendered) => present.iter().any(|path| {
            crate::hash::hash_tree(path)
                .map(|disk| &disk != rendered)
                .unwrap_or(true)
        }),
    }
}

/// The names an "edited packages" refusal lists — kind and name, so an edited
/// skill and an unchanged command of the same name are never confused.
fn edited_labels(edited: &[(ItemKind, String)]) -> Vec<String> {
    edited
        .iter()
        .map(|(kind, name)| format!("{} {name}", kind.name()))
        .collect()
}

mod keep;
pub use keep::source;
