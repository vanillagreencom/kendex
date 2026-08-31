//! Unsubscribing: what leaves with a marketplace, and removing or keeping it.
//!
//! The closure of a source is **derived by re-expansion, not read off
//! declarations**: expand the installed set with the source present and again
//! with its declarations gone, and diff. A derived dependency never names the
//! source in the manifest, so only the difference between the two expansions
//! tells the truth about what its going takes with it. When the source bytes
//! that expansion needs are unreachable, the closure refuses rather than infer.

use std::path::PathBuf;

use crate::apply::{Op, Plan, PlannedOp, Pre};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{ForkProvenance, ItemDecl, LOCAL_SOURCE_NAME, Manifest};
use crate::model::{ItemKind, Scope};
use crate::source::local_source_root;

use super::EngineReport;
use super::agent_carry::AgentCarry;
use super::planned::planned_declarations;

mod capture;

use capture::{capture_to_local, source_form};

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
        removal_filter: Some(
            closure
                .items
                .iter()
                .map(|i| (Some(i.kind), i.name.clone()))
                .collect(),
        ),
        sweep_unneeded: true,
        overwrite_edited: discard_edits,
        ..super::PlanOptions::default()
    };
    let mut report = super::plan_scope(env, &scope, &without, &lock, &options)?;
    if !super::persists_manifest(&report.plan.ops) {
        crate::engine::ops::insert_manifest_save(env, &scope, &mut report.plan, without)?;
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
/// can lose bytes for. The engine's own check answers it: skills, agents,
/// commands and hooks alike hold wherever the record cannot prove the bytes
/// on disk are what apply wrote, which is the same line an automatic removal
/// draws. Detach carried a second arm of its own while an anchor-less hook
/// record held nothing there; it holds now, so the arm said nothing the
/// engine's check had not already said.
/// (An MCP server is a config entry with no standalone file — its edits are not
/// detected here, the one gap that remains.)
fn install_edited(env: &Env, scope: &Scope, entry: &crate::lock::LockEntry) -> bool {
    super::removal::edit_holds(env, scope, entry)
}

/// The names an "edited packages" refusal lists — kind and name, so an edited
/// skill and an unchanged command of the same name are never confused.
fn edited_labels(edited: &[(ItemKind, String)]) -> Vec<String> {
    edited
        .iter()
        .map(|(kind, name)| format!("{} {name}", kind.name()))
        .collect()
}

// Keeping a marketplace's packages: copying each installation's source-form
// bytes into the scope's local source so the package stays after the source
// is gone. The byte copy, its local-target preflight, and the plan that
// flips each declaration to local and removes the source.

/// The commit one item's bytes are copied from: the commit its lock entries
/// agree on, or its own declared pin when it was never applied. Per-harness
/// lock entries pinning different commits are a refusal naming both — local
/// storage has one path per identity, so there is one right set of bytes.
fn effective_commit(lock: &crate::lock::Lock, item: &ClosureItem) -> Result<Option<String>> {
    let commits: std::collections::BTreeSet<Option<String>> = lock
        .entries
        .values()
        .filter(|e| e.kind == item.kind && e.name == item.name)
        .map(|e| e.source_commit.clone())
        .collect();
    match commits.len() {
        0 => Ok(item.decl.rev.clone()),
        1 => Ok(commits.into_iter().next().unwrap_or_default()),
        _ => Err(CoreError::DetachCommitConflict {
            name: item.name.clone(),
        }),
    }
}

/// The path in the local source one detached item's source-form bytes are
/// written to, or why they may not be. A `plugin/item` name nests one
/// directory level, the shape the local reader lists back. A symlink among
/// the components below the local source's root puts the write outside the
/// scope, where no later read of this source finds the kept package.
fn local_target(env: &Env, scope: &Scope, kind: ItemKind, name: &str) -> Result<PathBuf> {
    if matches!(kind, ItemKind::Plugin | ItemKind::PiExtension) {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: format!("detach does not support {} yet", kind.name()),
        });
    }
    let target = crate::source::local_slot(&local_source_root(env, scope), kind, name);
    if let Some(escape) = crate::source::slot_escapes(env, scope, &target)? {
        return Err(escape);
    }
    Ok(target)
}

/// Unsubscribe but keep the packages: convert each installation to a local one
/// and remove the source. This copies each item's **source-form** bytes from
/// the catalog at the exact commit it was installed from into the scope's local
/// source, flips its declaration to `local`, and records the conversion as a
/// fork whose bytes did not change. The local writes are ordered before the
/// declaration flip in one plan, so a failure mid-apply rolls the whole
/// conversion back (invariant 11).
///
/// An installation the user has edited is not converted from source form — that
/// would silently drop the edit — so detach refuses while any package is
/// edited, naming them: fork or discard each first. (Routing an edited package
/// through fork capture inside the same plan is the remaining half.)
pub fn source(env: &Env, scope: &Scope, source_name: &str) -> Result<Plan> {
    let scope = scope.canonical();
    let manifest = crate::engine::ops::manifest_for_mutation(env, &scope)?;
    let closure = closure(env, &scope, source_name, &manifest)?;
    let lock = crate::lock::load(&crate::lock::lock_path(env, &scope))?;

    // An edited installation cannot be recovered from source form; name every
    // one and refuse rather than lose the edit.
    let edited = edited_items(env, &scope, &closure, &lock);
    if !edited.is_empty() {
        return Err(CoreError::DetachEdited {
            names: edited_labels(&edited),
        });
    }

    // What a kept agent's assignment has to resolve against is the scope
    // this conversion leaves behind, not the one it starts in: the source
    // is going, and the packages it carried arrive under `local`. Read
    // once, because per agent it reopens every catalog again.
    let mut converted = converted_manifest(&manifest, &closure, source_name, &lock)?;
    let arriving: Vec<String> = closure
        .items
        .iter()
        .filter(|item| item.kind == ItemKind::Skill)
        .map(|item| item.name.clone())
        .collect();
    let skills = crate::engine::ScopeSkills::after(env, &scope, &converted, &arriving)?;
    let mut ops = Vec::new();
    let mut carried: Vec<(String, AgentCarry)> = Vec::new();
    for item in &closure.items {
        // Read this item's source-form bytes at the exact commit it installed
        // from — not the source head, which may have moved. A declared item
        // that was never applied has no lock entry; its own pin is the commit.
        let commit = effective_commit(&lock, item)?;
        let (files, carry) = source_form(env, &scope, &manifest, item, commit.as_deref(), &skills)?;
        carried.extend(carry.map(|carry| (item.name.clone(), carry)));
        let target = local_target(env, &scope, item.kind, &item.name)?;
        ops.extend(capture_to_local(item.kind, &item.name, &target, files)?);
    }
    // The catalog's own mapping tables shaped every rendering — skills the
    // catalog attached, frontmatter defaults it set. The local source has
    // no such tables, so the effective values move into the manifest here
    // or the very next apply would silently re-render every kept agent
    // differently.
    for (name, carry) in carried {
        carry.apply(&mut converted, &name);
    }

    let manifest_path = crate::manifest::manifest_path(env, &scope);
    ops.push(PlannedOp {
        description: format!("keep {source_name}'s packages as your own in kendex.toml").into(),
        op: Op::WriteManifest {
            pre: Pre::observed(&manifest_path)?,
            path: manifest_path,
            manifest: Box::new(converted),
        },
    });
    Plan::landed(scope.clone(), ops)
}

/// The manifest this conversion writes: every kept package reading `local`
/// and recorded as a fork, and the source it came from gone. Derived before
/// anything is read, because it is the scope a kept agent's assignment has
/// to resolve against — reasoning from the manifest on disk plans against a
/// catalog the same plan removes.
fn converted_manifest(
    manifest: &Manifest,
    closure: &Closure,
    source_name: &str,
    lock: &crate::lock::Lock,
) -> Result<Manifest> {
    let mut converted = manifest.clone();
    for item in &closure.items {
        let provenance = ForkProvenance {
            repo: manifest
                .sources
                .get(&item.decl.source)
                .and_then(|s| s.repo.clone()),
            source: item.decl.source.clone(),
            commit: effective_commit(lock, item)?,
            forked_at: crate::clock::timestamp(),
        };
        // A derived member or dependency becomes a plain declaration; a
        // declared item flips in place. Either way it now reads `local`, holds
        // nothing, and its bundle/dependency membership is a request of its own.
        let decl = converted
            .declared_mut(item.kind)
            .entry(item.name.clone())
            .or_insert_with(|| ItemDecl::from_source(LOCAL_SOURCE_NAME));
        decl.source = LOCAL_SOURCE_NAME.to_owned();
        decl.rev = None;
        converted
            .forks
            .entry(item.kind)
            .or_default()
            .insert(item.name.clone(), provenance);
    }
    converted
        .bundles
        .retain(|_, decl| decl.source != source_name);
    converted.sources.remove(source_name);
    Ok(converted)
}
