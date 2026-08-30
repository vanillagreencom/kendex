//! Bringing installed packages current: one package, or every one a
//! place's `Update all` selected. Each is a whole-scope reconcile that
//! holds every follower it was not asked about, so the difference between
//! them is what a pass costs, never what it moves.

use crate::engine::EngineReport;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::Manifest;
use crate::model::{ItemKind, Scope};

use super::resolve_hold;

/// Bring one package current and leave the rest of the scope where it is:
/// the plan resolves this package — and, for a derived one, the
/// declarations that carry it, since the owner is what holds its revision —
/// at the source's tip, while every other follower reads the commit its
/// lock entries record — bar one the lock cannot place, which resolves
/// fresh as a whole-scope apply would give it anyway. A hold still holds:
/// a package pinned by its own
/// `rev`, its source, or a parent moves only when that hold moves. The
/// whole-scope apply and `refresh` are unchanged and bring every follower
/// current at once.
pub fn update_one(env: &Env, scope: &Scope, kind: ItemKind, name: &str) -> Result<EngineReport> {
    update_many(
        env,
        scope,
        std::slice::from_ref(&UpdateTarget {
            kind,
            name: name.to_owned(),
            hold: None,
        }),
    )
}

/// One package a batched update names, and where its hold goes.
///
/// `hold` is the commit a held place's Update moves its hold to. A
/// following place carries `None`, which leaves its declaration exactly as
/// it is — never confused with the `None` [`super::set_rev`] takes to mean "stop
/// holding this", because that instruction is not one an Update ever
/// gives.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct UpdateTarget {
    pub kind: ItemKind,
    pub name: String,
    pub hold: Option<String>,
}

/// [`update_one`] over the packages one place's `Update all` selected:
/// they all come current in one reconcile, one journalled apply and one
/// lock write, while every other follower stays where it is. Running the
/// single-package verb per row costs the scope a whole plan each time and
/// reaches the same end.
///
/// The targets that move a hold are written into the manifest first, so
/// the plan reads the revisions they are moving to rather than restoring
/// the ones they came from. Every selector resolves before the first of
/// them is written (invariant 11): one target the source cannot place
/// leaves the manifest exactly as it was.
pub fn update_many(env: &Env, scope: &Scope, targets: &[UpdateTarget]) -> Result<EngineReport> {
    let manifest = plannable_manifest(env, scope)?;
    let installed = installed_names(env, scope, targets)?;
    for target in targets {
        // Derived packages (bundle members, dependencies) have no
        // declaration of their own — their lock entries are what names
        // them here. With no manifest at all neither reading stands: this
        // scope declares nothing, so nothing it records is an installation
        // of anything it still asks for.
        let known = manifest.as_ref().is_some_and(|manifest| {
            manifest.declared(target.kind).contains_key(&target.name)
                || installed.contains(&(target.kind, target.name.clone()))
        });
        if !known {
            return Err(CoreError::NotDeclared {
                kind: target.kind,
                name: target.name.clone(),
            });
        }
    }
    let options = crate::engine::PlanOptions::for_packages(
        targets
            .iter()
            .map(|target| (target.kind, target.name.clone())),
    );
    let holds: Vec<(&UpdateTarget, &str)> = targets
        .iter()
        .filter_map(|target| Some((target, target.hold.as_deref()?)))
        .collect();
    if holds.is_empty() {
        return crate::engine::plan_apply(env, scope, &options);
    }
    let mut manifest = crate::engine::ops::manifest_for_mutation(env, scope)?;
    // Resolved against the manifest as it stands, all of them, before any
    // one of them is written: a selector reads a declaration's source, and
    // nothing here changes one.
    let resolved: Vec<(ItemKind, String, String)> = holds
        .iter()
        .map(|(target, selector)| {
            let commit = resolve_hold(env, &manifest, target.kind, &target.name, selector)?;
            Ok((target.kind, target.name.clone(), commit))
        })
        .collect::<Result<_>>()?;
    for (kind, name, commit) in resolved {
        let Some(decl) = manifest.declared_mut(kind).get_mut(&name) else {
            return Err(CoreError::NotDeclared { kind, name });
        };
        decl.rev = Some(commit);
    }
    crate::source_ops::persist_and_plan_with(env, scope, manifest, &options)
}

/// The manifest a targeted update plans against, `None` where the scope
/// has none. A file this build cannot read is refused by the load itself.
fn plannable_manifest(env: &Env, scope: &Scope) -> Result<Option<Manifest>> {
    let path = crate::manifest::manifest_path(env, scope);
    match crate::manifest::load(&path)? {
        crate::manifest::ManifestFile::Current(manifest) => Ok(Some(*manifest)),
        crate::manifest::ManifestFile::Absent => Ok(None),
    }
}

/// Which of these packages the lock records an installation of.
fn installed_names(
    env: &Env,
    scope: &Scope,
    targets: &[UpdateTarget],
) -> Result<std::collections::BTreeSet<(ItemKind, String)>> {
    let lock_path = crate::lock::lock_path(env, scope);
    match crate::lock::load_file(&lock_path)? {
        crate::lock::LockFile::Current(lock) => Ok(lock
            .entries
            .values()
            .filter(|entry| {
                targets
                    .iter()
                    .any(|target| target.kind == entry.kind && target.name == entry.name)
            })
            .map(|entry| (entry.kind, entry.name.clone()))
            .collect()),
        // Nothing recorded yet — a declared package still plans.
        crate::lock::LockFile::Absent => Ok(std::collections::BTreeSet::new()),
    }
}
