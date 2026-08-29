//! Where a fork's original came from: the source it was declared on, and
//! the commit its bytes were installed at. Recorded on the fork so the
//! Library can say what it replaced, and read by the capture so it takes
//! the published file at the commit the edits were made against.

use crate::env::Env;
use crate::error::Result;
use crate::manifest::{self, ForkProvenance};
use crate::model::{HarnessId, ItemKind, Scope};

/// Where the original came from, recorded on the fork so the Library can
/// say what it replaced and which commit the edits were made on. The
/// commit is the captured harness's own lock record — installations can
/// sit at different commits mid-refresh, and the edits live in the one
/// rendering being kept. A harness with no record yet falls back to any
/// installation's commit: an approximate base beats none.
pub(super) fn provenance(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
    manifest: &manifest::Manifest,
    decl: &manifest::ItemDecl,
) -> Result<ForkProvenance> {
    let commit = installed_commit(env, scope, kind, name, harness, decl)?;
    Ok(ForkProvenance {
        repo: manifest
            .sources
            .get(&decl.source)
            .and_then(|s| s.repo.clone()),
        source: decl.source.clone(),
        commit,
        forked_at: crate::clock::timestamp(),
    })
}

/// The commit this installation's bytes came from: the captured harness's
/// own lock record, then any other tool's, then the declaration's own pin.
/// Installations can sit at different commits mid-refresh and the edits
/// live in the one rendering being kept, so the captured tool answers
/// first. `None` where nothing recorded one, which reads as the source's
/// head — an approximate base beats none.
pub(super) fn installed_commit(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
    decl: &manifest::ItemDecl,
) -> Result<Option<String>> {
    let lock = crate::lock::load(&crate::lock::lock_path(env, scope))?;
    let mut recorded = lock
        .entries
        .values()
        .filter(|entry| entry.kind == kind && entry.name == name)
        .filter(|entry| entry.source_commit.is_some());
    Ok(recorded
        .clone()
        .find(|entry| entry.harness == harness)
        .or_else(|| recorded.next())
        .and_then(|entry| entry.source_commit.clone())
        .or_else(|| decl.rev.clone()))
}
