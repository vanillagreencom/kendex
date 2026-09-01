//! Keeping a user's edits beside the source's version: the edited
//! installation becomes a local fork under a new name, and the original
//! declaration stays on its source. The follow-up apply renders both — the
//! source's content under the name it always had, the edits under the name
//! the user chose.

use super::{
    Capture, Captured, ForkOf, capture, capture_ops, edited_rendering, forkable_kind, named_bytes,
    provenance, vacant_name,
};
use crate::apply::{Op, Plan, PlannedOp, Pre};
use crate::engine::agent_carry::{OldName, rekey_agent_tables};
use crate::engine::ops::manifest_for_mutation;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{self, LOCAL_SOURCE_NAME};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::render::skill::carries_name;

/// Turn one edited installation into a local fork under `new_name`,
/// leaving `name` declared from its source. `rev` — anything the
/// repository can name — moves the original's hold to that commit, so the
/// source version that lands is the newest rather than the one the edits
/// were made on; `None` leaves the hold as it is. Everything is proven
/// before anything is written (invariant 11): the new name is vacant and
/// every target loader takes it, the source still carries the original at
/// the target revision, and the edited bytes can carry the new name in
/// their frontmatter.
///
/// The plan: capture the edited bytes into the local source under the
/// new name, trash the edited artifact so the follow-up apply re-renders
/// the original from its source, and write the manifest — the new name
/// declared `local` with the original's provenance recorded on it.
pub fn fork_beside(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
    new_name: &str,
    rev: Option<&str>,
) -> Result<Plan> {
    // Before the name is judged: every question below is asked in terms of
    // how this kind renders, and the capture refuses an unsupported one
    // several statements later, by which point the name has already been
    // answered for in a vocabulary that does not fit it.
    forkable_kind(kind, name)?;
    let mut manifest = manifest_for_mutation(env, scope)?;
    let Some(decl) = manifest.declared(kind).get(name).cloned() else {
        return Err(CoreError::NotDeclared {
            kind,
            name: name.to_owned(),
        });
    };
    vacant_name(env, scope, &manifest, kind, &decl, name, new_name)?;
    let hold = match rev {
        Some(selector) => Some(crate::package::resolve_hold(
            env, &manifest, kind, name, selector,
        )?),
        None => {
            crate::package::prove_present(env, scope, &manifest, kind, name)?;
            None
        }
    };
    let edited = edited_rendering(env, scope, kind, name, harness)?;
    let captured = capture(
        &ForkOf {
            env,
            scope,
            manifest: &manifest,
            decl: &decl,
            kind,
            name,
            installed_as: new_name,
            harness,
        },
        &edited,
    )?;
    let Captured {
        files,
        carry,
        read_at,
    } = captured;
    let mut ops = capture_ops(env, scope, kind, new_name, &edited, named(files, new_name)?)?;
    let provenance = provenance(env, scope, kind, name, harness, &manifest, &decl)?;
    // An agent's configuration is keyed by its installed name, so a copy
    // under a new one reads none of it: it would render without the
    // project's tool denies, without its instructions, and outside its own
    // hooks. The original keeps its own — it stays declared from its source
    // and goes on rendering under the name it always had.
    rekey_agent_tables(&mut manifest, kind, name, new_name, OldName::Kept);
    if let Some(carry) = carry {
        carry.apply(&mut manifest, new_name);
    }

    let mut own = decl;
    own.source = LOCAL_SOURCE_NAME.to_owned();
    own.rev = None;
    manifest.declared_mut(kind).insert(new_name.to_owned(), own);
    manifest
        .forks
        .entry(kind)
        .or_default()
        .insert(new_name.to_owned(), provenance);
    if let Some(commit) = hold {
        manifest
            .declared_mut(kind)
            .get_mut(name)
            .unwrap_or_else(|| unreachable!("declared above"))
            .rev = Some(commit);
    }

    // One capture, read at one revision, is what every harness renders from
    // once the fork lands, so every harness it answers for has to be at
    // that revision now. Proven before any of it reaches disk.
    if kind == ItemKind::Agent {
        let declared = manifest
            .declared(kind)
            .get(new_name)
            .unwrap_or_else(|| unreachable!("declared above"));
        super::revision::one_revision(env, scope, &manifest, declared, name, read_at.as_deref())?;
    }

    let manifest_path = manifest::manifest_path(env, scope);
    ops.push(PlannedOp {
        description: format!("record the fork of {name} as {new_name} in kendex.toml").into(),
        op: Op::WriteManifest {
            pre: Pre::observed(&manifest_path)?,
            path: manifest_path,
            manifest: Box::new(manifest),
        },
    });
    Plan::landed(scope.clone(), ops)
}

/// The captured bytes answering to `new_name` — [`named_bytes`] over the
/// files that carry the name. A copy under a new name says that name, or
/// it would shadow the original it sits beside: discovery treats a
/// directory and its frontmatter disagreeing as a finding.
fn named(captured: Capture, new_name: &str) -> Result<Capture> {
    Ok(match captured {
        Capture::Tree(files) => Capture::Tree(
            files
                .into_iter()
                .map(|(rel, bytes)| match carries_name(&rel) {
                    true => named_bytes(bytes, new_name).map(|bytes| (rel, bytes)),
                    false => Ok((rel, bytes)),
                })
                .collect::<Result<Vec<_>>>()?,
        ),
        Capture::File(bytes) => Capture::File(named_bytes(bytes, new_name)?),
    })
}
