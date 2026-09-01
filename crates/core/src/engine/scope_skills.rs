//! Skill names offered by the current checkout of each source in a scope.
//!
//! An agent's declared assignment is made across sources, not inside the
//! one catalog the agent came from, and a fork rebound to `local` keeps
//! reading it. Item-level pinned revisions do not widen this inventory, so
//! a skill found only at such a pin is unavailable to assignment and fork
//! resolution even when the plan installs it.
//!
//! Each source's current checkout contributes everything it offers,
//! installed or not. An assignment naming one of those skills is answered
//! by declaring it, and what a source adds to an agent's assignment merges
//! into the manifest and arrives declared on the next pass.

use crate::env::Env;
use crate::error::Result;
use crate::manifest::{INPLACE_SOURCE_NAME, LOCAL_SOURCE_NAME, Manifest};
use crate::model::{ItemKind, Scope};
use crate::source::{SourceState, list_items, resolve, source_config_for};
use crate::source_read::SealedSource;

/// Every skill name the scope's current source checkouts offer, sorted and
/// deduplicated.
///
/// Every constructor reads the whole scope. Nothing can hand a narrower set
/// to a resolution that has to see all of it, and two readings of one scope
/// cannot disagree.
pub struct ScopeSkills(Vec<String>);

impl ScopeSkills {
    /// What the scope's current source checkouts offer.
    pub fn of(env: &Env, scope: &Scope, manifest: &Manifest) -> Result<ScopeSkills> {
        ScopeSkills::after(env, scope, manifest, &[])
    }

    /// What the manifest's current source checkouts offer, plus names the
    /// operation is about to place in the local source and has not written
    /// yet. An operation that removes a source and reasons from its output
    /// manifest therefore drops that source from the inventory.
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
