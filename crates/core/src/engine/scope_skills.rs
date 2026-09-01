//! Every skill name a scope can supply, read across all of its sources.
//!
//! An agent's declared assignment is made across sources, not inside the
//! one catalog the agent came from, and a fork rebound to `local` keeps
//! reading it. So the set it resolves against is scope-wide, and getting
//! that set wrong in either direction is a defect with teeth: too narrow
//! refuses a fork over a skill that is right there, too wide renders one
//! pointing at instructions nothing can load.
//!
//! What a source offers is what it can supply. Every declaration reading
//! that source reads it here, an assignment naming one of its skills is
//! answered by declaring it, and what a source adds to an agent's
//! assignment merges into the manifest and arrives declared on the next
//! pass.

use crate::env::Env;
use crate::error::Result;
use crate::manifest::{INPLACE_SOURCE_NAME, LOCAL_SOURCE_NAME, Manifest};
use crate::model::{ItemKind, Scope};
use crate::source::{SourceState, list_items, resolve, source_config_for};
use crate::source_read::SealedSource;

/// Every skill name this scope can supply, sorted and deduplicated.
///
/// Every constructor reads the whole scope. Nothing can hand a narrower set
/// to a resolution that has to see all of it, and two readings of one scope
/// cannot disagree.
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
        skills.extend(offered(env, scope, manifest));
        skills.sort();
        skills.dedup();
        Ok(ScopeSkills(skills))
    }

    pub fn names(&self) -> &[String] {
        &self.0
    }
}

/// Everything the scope's own checkouts offer: each declared source plus
/// both reserved ones — `local` for adopted content, `in-place` for content
/// whose record of truth is the shared `.agents` tree.
fn offered(env: &Env, scope: &Scope, manifest: &Manifest) -> Vec<String> {
    let mut skills = Vec::new();
    for name in manifest
        .sources
        .keys()
        .map(String::as_str)
        .chain([LOCAL_SOURCE_NAME, INPLACE_SOURCE_NAME])
    {
        // Every way of not reading a source is one answer: it supplies no
        // skills. Pending, disabled, missing, unopenable and unreadable
        // already read that way, and a resolution that errors outright — a
        // cache that cannot be rebuilt — must too. This scan is incidental
        // to most of the work that triggers it, so it must never be able to
        // fail that work; a skill it therefore cannot see is refused by name
        // later, which is loud, not silent.
        let Ok(SourceState::Ready(ready)) = resolve(env, scope, name, manifest) else {
            continue;
        };
        let Ok(sealed) = SealedSource::open(&ready.root) else {
            continue;
        };
        let Ok(config) = source_config_for(&sealed, &ready.provenance) else {
            continue;
        };
        skills.extend(list_items(&sealed, &config, ItemKind::Skill));
    }
    skills
}
