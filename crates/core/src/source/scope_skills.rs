//! Every skill name a scope can supply, read across all of its sources.
//!
//! An agent's declared assignment is made across sources, not inside the
//! one catalog the agent came from, and a fork rebound to `local` keeps
//! reading it. So the set it resolves against is scope-wide, and getting
//! that set wrong in either direction is a defect with teeth: too narrow
//! refuses a fork over a skill that is right there, too wide renders one
//! pointing at instructions nothing can load.

use std::collections::BTreeSet;

use crate::env::Env;
use crate::error::Result;
use crate::manifest::{INPLACE_SOURCE_NAME, LOCAL_SOURCE_NAME, Manifest};
use crate::model::{ItemKind, Scope};

use super::{SourceState, list_items, resolve, resolve_at, source_config_for};

/// Every skill name this scope can supply, sorted and deduplicated.
///
/// [`ScopeSkills::of`] and [`ScopeSkills::after`] are the only ways to
/// obtain one, and both read the whole scope. Nothing can hand a narrower
/// set to a resolution that has to see all of it, and two readings of one
/// scope cannot disagree.
pub struct ScopeSkills(Vec<String>);

impl ScopeSkills {
    /// The scope as it stands.
    pub fn of(env: &Env, scope: &Scope, manifest: &Manifest) -> Result<ScopeSkills> {
        ScopeSkills::after(env, scope, manifest, &[])
    }

    /// The scope as an operation will leave it: read from the manifest it
    /// will write, plus names it is about to place in the local source and
    /// has not written yet. An operation that removes a source and reasons
    /// from the scope it started in plans an assignment against a catalog
    /// it is taking away. `arriving` can only widen the set, never narrow
    /// it, so it cannot be used to hide a skill from the resolution.
    pub fn after(
        env: &Env,
        scope: &Scope,
        manifest: &Manifest,
        arriving: &[String],
    ) -> Result<ScopeSkills> {
        let mut skills: Vec<String> = arriving.to_vec();
        for root in roots(manifest) {
            // Every way of not reading a root is one answer: it supplies
            // no skills. Pending, disabled, missing, unopenable and
            // unreadable already read that way, and a resolution that
            // errors outright — a cache that cannot be rebuilt — must
            // too. This scan is incidental to most of the work that
            // triggers it, so it must never be able to fail that work; a
            // skill it therefore cannot see is refused by name later,
            // which is loud, not silent.
            let Ok(SourceState::Ready(ready)) = root.resolve(env, scope, manifest) else {
                continue;
            };
            let Ok(sealed) = crate::source_read::SealedSource::open(&ready.root) else {
                continue;
            };
            let Ok(config) = source_config_for(&sealed, &ready.provenance) else {
                continue;
            };
            skills.extend(list_items(&sealed, &config, ItemKind::Skill));
        }
        skills.sort();
        skills.dedup();
        Ok(ScopeSkills(skills))
    }

    pub fn names(&self) -> &[String] {
        &self.0
    }
}

/// One checkout this scope reads: a source at its own revision, or a
/// source at the revision one declaration pinned it to. Both are planned
/// and installable, so both supply skills — reading only the first calls a
/// pinned skill absent while the planner reads it perfectly well.
enum Root<'a> {
    Source(&'a str),
    Pinned(&'a str, &'a str),
}

impl Root<'_> {
    fn resolve(&self, env: &Env, scope: &Scope, manifest: &Manifest) -> Result<SourceState> {
        match self {
            Root::Source(name) => resolve(env, scope, name, manifest),
            Root::Pinned(name, rev) => resolve_at(env, scope, name, manifest, Some(rev)),
        }
    }
}

/// Every checkout the scope reads: each declared source plus both reserved
/// ones — `local` for adopted content, `in-place` for content whose record
/// of truth is the shared `.agents` tree — and every revision a
/// declaration pins a source to, deduplicated.
fn roots(manifest: &Manifest) -> Vec<Root<'_>> {
    let mut roots: Vec<Root<'_>> = manifest
        .sources
        .keys()
        .map(String::as_str)
        .chain([LOCAL_SOURCE_NAME, INPLACE_SOURCE_NAME])
        .map(Root::Source)
        .collect();
    let declared = ItemKind::ALL
        .iter()
        .flat_map(|kind| manifest.declared(*kind).values())
        .chain(manifest.bundles.values());
    let mut pinned: BTreeSet<(&str, &str)> = BTreeSet::new();
    for decl in declared {
        if let Some(rev) = decl.rev.as_deref() {
            pinned.insert((decl.source.as_str(), rev));
        }
    }
    roots.extend(
        pinned
            .into_iter()
            .map(|(name, rev)| Root::Pinned(name, rev)),
    );
    roots
}
