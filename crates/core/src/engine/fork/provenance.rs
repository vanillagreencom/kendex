//! Where a fork's original came from: the source it was declared on, and
//! the commit its bytes were installed at. Recorded on the fork so the
//! Library can say what it replaced; an agent's capture also reads its
//! published file at that commit.

use crate::env::Env;
use crate::error::Result;
use crate::manifest::{self, ForkProvenance};
use crate::model::{HarnessId, ItemKind, Scope};

/// Where the original came from, recorded on the fork so the Library can
/// say what it replaced and which commit the edits were made on: the
/// commit the capture read the publisher's file at, so the record and the
/// keys the fork took back name one revision.
pub(super) fn provenance(
    manifest: &manifest::Manifest,
    decl: &manifest::ItemDecl,
    commit: Option<String>,
) -> ForkProvenance {
    ForkProvenance {
        repo: manifest
            .sources
            .get(&decl.source)
            .and_then(|s| s.repo.clone()),
        source: decl.source.clone(),
        commit,
        forked_at: crate::clock::timestamp(),
    }
}

/// The commit an agent's installed bytes came from: the captured
/// harness's own lock record, then any other tool's, then the
/// declaration's own pin. Installations can sit at different commits
/// mid-refresh and the edits live in the one rendering being kept, so the
/// captured tool answers first. `None` where nothing recorded one, which
/// reads as the source's head — an approximate base beats none. A skill's
/// capture takes its copy's own record instead
/// ([`crate::source::header::published_text`]), which refuses rather than
/// guess.
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
