//! Renaming a fork: the declaration, its provenance record, and its files in
//! the local source move to the new name together.

use super::{local_item, vacant_name};
use crate::apply::{Op, Plan, PlannedOp, Pre};
use crate::engine::ops::manifest_for_mutation;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest;
use crate::model::{ItemKind, Scope};

/// Rename a fork. Only a fork nothing depends on may change its installed
/// name: dependents and bundles refer to the old one, and a rename that
/// breaks them is not a rename, it is a removal wearing one's clothes.
pub fn rename_fork(env: &Env, scope: &Scope, kind: ItemKind, old: &str, new: &str) -> Result<Plan> {
    let mut manifest = manifest_for_mutation(env, scope)?;
    if !manifest
        .forks
        .get(&kind)
        .is_some_and(|forks| forks.contains_key(old))
    {
        return Err(CoreError::NotDeclared {
            kind,
            name: old.to_owned(),
        });
    }
    let Some(decl) = manifest.declared(kind).get(old).cloned() else {
        return Err(CoreError::NotDeclared {
            kind,
            name: old.to_owned(),
        });
    };
    vacant_name(env, scope, &manifest, kind, &decl, new)?;
    let lock = crate::lock::load(&crate::lock::lock_path(env, scope))?;
    let depended_on = lock
        .entries
        .values()
        .filter(|entry| entry.kind == kind && entry.name == old)
        .flat_map(|entry| entry.reasons.iter())
        .any(|reason| !matches!(reason, crate::lock::Reason::Requested));
    if depended_on {
        return Err(CoreError::ManifestInvalid {
            path: manifest::manifest_path(env, scope),
            findings: vec![format!(
                "{}.{old}: other items depend on this name — fix: rename what depends on it first, or keep the name",
                kind.name()
            )],
        });
    }

    let (from, to) = (
        local_item(env, scope, kind, old),
        local_item(env, scope, kind, new),
    );
    let mut ops = Vec::new();
    if from.exists() {
        ops.push(PlannedOp {
            description: format!("rename the fork's files to {new}"),
            op: Op::Rename {
                // The fork moves whole, whatever sits in it: a dangling
                // link the person left there is carried along, not a
                // reason to refuse the rename.
                from_pre: Pre::tree_as_is(&from)?,
                from,
                to,
                to_pre: Pre::Absent,
            },
        });
    }
    let Some(decl) = manifest.declared_mut(kind).remove(old) else {
        return Err(CoreError::NotDeclared {
            kind,
            name: old.to_owned(),
        });
    };
    manifest.declared_mut(kind).insert(new.to_owned(), decl);
    if let Some(forks) = manifest.forks.get_mut(&kind)
        && let Some(provenance) = forks.remove(old)
    {
        forks.insert(new.to_owned(), provenance);
    }
    let manifest_path = manifest::manifest_path(env, scope);
    ops.push(PlannedOp {
        description: format!("record the rename to {new} in kendex.toml"),
        op: Op::WriteManifest {
            pre: Pre::observed(&manifest_path)?,
            path: manifest_path,
            manifest: Box::new(manifest),
        },
    });
    Ok(Plan {
        scope: scope.clone(),
        ops,
    })
}
