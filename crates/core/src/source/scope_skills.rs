//! Every skill name a scope can supply, read across all of its sources.
//!
//! An agent's declared assignment is made across sources, not inside the
//! one catalog the agent came from, and a fork rebound to `local` keeps
//! reading it. So the set it resolves against is scope-wide, and getting
//! that set wrong in either direction is a defect with teeth: too narrow
//! refuses a fork over a skill that is right there, too wide renders one
//! pointing at instructions nothing can load.

use crate::env::Env;
use crate::error::Result;
use crate::manifest::{INPLACE_SOURCE_NAME, LOCAL_SOURCE_NAME, Manifest};
use crate::model::{ItemKind, Scope};

use super::bundles::BundleMember;
use super::{
    SourceConfig, SourceState, bundles, find_item, list_items, resolve, resolve_at,
    source_config_for,
};
use crate::source_read::SealedSource;

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
            skills.extend(root.supplies(&sealed, &config, manifest));
        }
        skills.sort();
        skills.dedup();
        Ok(ScopeSkills(skills))
    }

    pub fn names(&self) -> &[String] {
        &self.0
    }
}

/// One checkout this scope reads, and what may come out of it.
enum Root<'a> {
    /// A source at its own revision. Everything it offers is reachable,
    /// because every declaration reading that source reads it here.
    Source(&'a str),
    /// A source at a revision one declaration pins it to. Only what that
    /// declaration reaches comes out — nothing else in the scope reads
    /// this checkout, and an older revision is full of packages nothing
    /// installs. Offering those would let a fork keep a `## Required
    /// Skills` row pointing at a file no plan ever writes.
    Pinned {
        source: &'a str,
        rev: &'a str,
        reaches: Reaches<'a>,
    },
}

/// What a pinned declaration reaches at its own revision: the skill it
/// declares by name, or the skills the set it installs carries. Those are
/// the two doors the planner opens for a pinned declaration — its
/// `declared` walk and its set expansion — and what a set carries is
/// [`super::bundles::find`]'s answer here as it is there.
enum Reaches<'a> {
    Skill(&'a str),
    Bundle(&'a str),
}

impl Root<'_> {
    fn resolve(&self, env: &Env, scope: &Scope, manifest: &Manifest) -> Result<SourceState> {
        match self {
            Root::Source(name) => resolve(env, scope, name, manifest),
            Root::Pinned { source, rev, .. } => resolve_at(env, scope, source, manifest, Some(rev)),
        }
    }

    /// The skills this checkout supplies, once it is open.
    fn supplies(
        &self,
        sealed: &SealedSource,
        config: &SourceConfig,
        manifest: &Manifest,
    ) -> Vec<String> {
        match self {
            Root::Source(_) => list_items(sealed, config, ItemKind::Skill),
            Root::Pinned {
                reaches: Reaches::Skill(name),
                ..
            } => find_item(sealed, config, ItemKind::Skill, name)
                .map(|_| vec![(*name).to_owned()])
                .unwrap_or_default(),
            Root::Pinned {
                reaches: Reaches::Bundle(name),
                ..
            } => bundles::find(sealed, config, name)
                .ok()
                .flatten()
                .map(|set| {
                    set.members
                        .into_iter()
                        .filter(|member| member.kind == ItemKind::Skill)
                        .filter(|member| installs(sealed, config, manifest, member))
                        .map(|member| member.name)
                        .collect()
                })
                .unwrap_or_default(),
        }
    }
}

/// Whether a set's member is one this scope can install: the person has
/// not taken it away, and the catalog carries it. Both are the checks
/// `engine::bundles::installable` applies to every member as it expands a
/// set, spelled here rather than called because that function sits inside
/// the planner and takes the planner's own types.
///
/// Two spellings of one question is what the reading below is: KEN-821
/// replaces it with the planner's closure, which answers what a pinned
/// revision installs once. Until then, offering a member that is held back
/// or that the catalog does not carry answers an agent's assignment with a
/// skill no plan will ever write.
fn installs(
    sealed: &SealedSource,
    config: &SourceConfig,
    manifest: &Manifest,
    member: &BundleMember,
) -> bool {
    !manifest.is_held_back(member.kind, &member.name)
        && find_item(sealed, config, member.kind, &member.name).is_some()
}

/// Every checkout the scope reads: each declared source plus both reserved
/// ones — `local` for adopted content, `in-place` for content whose record
/// of truth is the shared `.agents` tree — and every revision a skill or a
/// set is pinned to. A pin on any other kind reads no skill out of its
/// revision, so it is not a checkout this scope reads skills from.
fn roots(manifest: &Manifest) -> Vec<Root<'_>> {
    let mut roots: Vec<Root<'_>> = manifest
        .sources
        .keys()
        .map(String::as_str)
        .chain([LOCAL_SOURCE_NAME, INPLACE_SOURCE_NAME])
        .map(Root::Source)
        .collect();
    let pinned = manifest
        .skills
        .iter()
        .map(|(name, decl)| (decl, Reaches::Skill(name.as_str())))
        .chain(
            manifest
                .bundles
                .iter()
                .map(|(name, decl)| (decl, Reaches::Bundle(name.as_str()))),
        );
    for (decl, reaches) in pinned {
        if let Some(rev) = decl.rev.as_deref() {
            roots.push(Root::Pinned {
                source: decl.source.as_str(),
                rev,
                reaches,
            });
        }
    }
    roots
}
