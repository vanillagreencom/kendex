//! Keeping a user's edits beside the source's version: the edited
//! installation becomes a local fork under a new name, and the original
//! declaration stays on its source. The follow-up apply renders both — the
//! source's content under the name it always had, the edits under the name
//! the user chose.

use super::{Capture, capture, capture_ops, edited_rendering, provenance, vacant_name};
use crate::apply::{Op, Plan, PlannedOp, Pre};
use crate::engine::ops::manifest_for_mutation;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{self, LOCAL_SOURCE_NAME};
use crate::model::{HarnessId, ItemKind, Scope};

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
    let mut manifest = manifest_for_mutation(env, scope)?;
    let Some(decl) = manifest.declared(kind).get(name).cloned() else {
        return Err(CoreError::NotDeclared {
            kind,
            name: name.to_owned(),
        });
    };
    vacant_name(env, scope, &manifest, kind, &decl, new_name)?;
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
    let captured = named(capture(kind, &edited)?, new_name)?;
    let mut ops = capture_ops(env, scope, kind, new_name, &edited, captured)?;
    let provenance = provenance(env, scope, kind, name, harness, &manifest, &decl)?;

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

    let manifest_path = manifest::manifest_path(env, scope);
    ops.push(PlannedOp {
        description: format!("record the fork of {name} as {new_name} in kendex.toml"),
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

/// The captured bytes answering to `new_name`. A tool knows a skill or an
/// agent by the name its frontmatter gives, and discovery treats a
/// directory and its frontmatter disagreeing as a finding — so a copy under
/// a new name says that name, or it would shadow the original it sits
/// beside. A frontmatter without a name gets one, exactly as rendering
/// would give it one; bytes whose name no single scalar can carry refuse
/// the fork rather than land a copy that still answers to the old one.
fn named(captured: Capture, new_name: &str) -> Result<Capture> {
    let rename = |bytes: Vec<u8>| -> Result<Vec<u8>> {
        let refused = |problem: String| CoreError::ForkNameUnusable {
            name: crate::names::shown(new_name),
            problem,
        };
        let text =
            std::str::from_utf8(&bytes).map_err(|_| refused("the file is not text".to_owned()))?;
        crate::render::skill::with_name(text, new_name)
            .map(String::into_bytes)
            .map_err(|problem| refused(problem.to_string()))
    };
    Ok(match captured {
        Capture::Tree(files) => Capture::Tree(
            files
                .into_iter()
                .map(|(rel, bytes)| match rel.to_str() {
                    Some("SKILL.md") => rename(bytes).map(|bytes| (rel, bytes)),
                    _ => Ok((rel, bytes)),
                })
                .collect::<Result<Vec<_>>>()?,
        ),
        Capture::File(bytes) => Capture::File(rename(bytes)?),
    })
}
