//! Renaming a fork: the declaration, its provenance record, and its files in
//! the local source move to the new name together.

use std::path::{Path, PathBuf};

use super::{SKILL_NAME_FILES, forkable_kind, local_item, named_bytes, vacant_name};
use crate::apply::{Op, Plan, PlannedOp, Pre};
use crate::engine::agent_carry::{OldName, rekey_agent_tables};
use crate::engine::ops::manifest_for_mutation;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest;
use crate::model::{ItemKind, Scope};

/// Rename a fork. Only a fork nothing depends on may change its installed
/// name: dependents and bundles refer to the old one, and a rename that
/// breaks them is not a rename, it is a removal wearing one's clothes.
pub fn rename_fork(env: &Env, scope: &Scope, kind: ItemKind, old: &str, new: &str) -> Result<Plan> {
    // A fork entry does not prove the kind: detach writes one for every
    // kind it converts, and the manifest's own table takes any of them, so
    // a rename has no capture step behind it to refuse an unsupported kind
    // later. It is refused here, before the table is read.
    forkable_kind(kind, old)?;
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
    vacant_name(env, scope, &manifest, kind, &decl, old, new)?;
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
            findings: vec![manifest::Finding {
                location: format!("{}.{old}", kind.name()),
                problem: "other items depend on this name".to_owned(),
                fix: "rename what depends on it first, or keep the name".to_owned(),
            }],
        });
    }

    let (from, to) = (
        local_item(env, scope, kind, old),
        local_item(env, scope, kind, new),
    );
    // `vacant_name` proved the destination reachable; the slot being left
    // has to be too. A link anywhere below the local source's root and the
    // fork's files makes the move dishonest: the rename carries the link
    // rather than the tree, and every op bound to what stands past it —
    // the name-stamping write below first of all — then acts on the far
    // end, outside what this scope manages. Refused here, before a single
    // op is planned, in the sealed reader's own words: it names the
    // component it stopped at, which is the thing to go and look at.
    if let Some(escape) = crate::source::slot_escapes(env, scope, &from)? {
        return Err(escape);
    }
    let mut ops = Vec::new();
    if from.exists() {
        let stamped = stamp_name(kind, &from, &to, new)?;
        ops.push(PlannedOp {
            description: format!("rename the fork's files to {new}").into(),
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
        ops.extend(stamped);
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
    // An agent's configuration goes with it. Nothing reads the old name
    // after this, so leaving it behind would render the fork without the
    // project's tool denies, without its instructions, and outside its own
    // hooks.
    rekey_agent_tables(&mut manifest, kind, old, new, OldName::Gone);
    let manifest_path = manifest::manifest_path(env, scope);
    ops.push(PlannedOp {
        description: format!("record the rename to {new} in kendex.toml").into(),
        op: Op::WriteManifest {
            pre: Pre::observed(&manifest_path)?,
            path: manifest_path,
            manifest: Box::new(manifest),
        },
    });
    Plan::landed(scope.clone(), ops)
}

/// The writes that leave the renamed fork answering to `new`. Moving the
/// directory and the declaration is not the whole rename: every tool knows
/// a skill or an agent by the name its frontmatter gives, and the loader
/// validators refuse a rendering whose file calls it something other than
/// the name it installs under — so a rename that left the name behind
/// would hand the person a package refused at the next apply.
///
/// Each write binds to the bytes the rename just carried, at the path it
/// carried them to. Ops run in order and each proves its own precondition
/// immediately before it writes, so what stands at the new path when the
/// write runs is exactly the file hashed here at the old one; binding to
/// the old path would prove nothing, the rename having emptied it. The
/// binding is the plain-file one because kendex does not write a skill's
/// or an agent's document through a link — a link arriving in the moved
/// tree's place refuses the write rather than landing these bytes at the
/// other end of it.
///
/// A name no single scalar can carry refuses the rename here, before
/// anything is written: renaming around it is how the fork ends up
/// declared under one name and answering to another.
fn stamp_name(kind: ItemKind, from: &Path, to: &Path, new: &str) -> Result<Vec<PlannedOp>> {
    let moved: Vec<(PathBuf, PathBuf)> = match kind {
        ItemKind::Skill => SKILL_NAME_FILES
            .iter()
            .map(|rel| (from.join(rel), to.join(rel)))
            .collect(),
        // Every other kind the local source keeps is one file, and the
        // file is what moved.
        _ => vec![(from.to_path_buf(), to.to_path_buf())],
    };
    let mut ops = Vec::new();
    for (old, new_path) in moved {
        // Absent here is also "there, but not a plain file": a link or a
        // directory wearing the name carries nothing this can stamp, and
        // a rendering reading it is refused for that on its own.
        let pre = Pre::plain_observed(&old)?;
        if pre.binds_nothing() {
            continue;
        }
        let bytes = std::fs::read(&old).map_err(|e| CoreError::io(&old, e))?;
        ops.push(PlannedOp {
            description: format!("give the renamed {} its new name, {new}", kind.name()).into(),
            op: Op::WriteFile {
                pre,
                bytes: named_bytes(bytes, new)?,
                path: new_path,
            },
        });
    }
    Ok(ops)
}
