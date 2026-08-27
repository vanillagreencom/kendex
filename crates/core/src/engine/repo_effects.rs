//! Collecting the repository effects a plan would set in motion.
//!
//! Read off the same rendered bytes the plan is about to write, beside the
//! safety scoring and for the same reason: an item that is not installed
//! yet has nothing on disk to read, and the declaration has to reach the
//! preview before anything is written.
//!
//! Only for packages this plan actually settles. The declaration is read
//! from the bytes kendex would write; the script an effect runs is read
//! from the tree on disk afterwards. Where the plan refuses to write —
//! content kendex did not put there is at the canonical target — those are
//! two different files, and the one that would run belongs to whoever left
//! it there.

use std::collections::{BTreeMap, BTreeSet};

use crate::model::ItemKind;
use crate::repo_effects::{DeclaredEffects, declared};

use super::desired::{Artifact, DesiredState};
use super::report_types::{DriftCause, DriftRow};
use super::set_change::{SetChange, SetDirection};

/// Every declared effect this plan would bring, once per package.
///
/// A skill fans out to several tools and produces one desired row each,
/// while the effect belongs to the package rather than to any tool's copy
/// of it — so rows collapse by name, and the canonical tree every copy
/// links back to is the root its scripts resolve against.
///
/// The set is what this plan ADDS to the installed set, minus anything it
/// holds back. That is the engine's own answer to "what did this invocation
/// install", and it is the fifth thing tried, so it is worth saying what the
/// other four got wrong and why this one cannot.
///
/// The desired state is the whole scope, so reading it offered every
/// declaring package installed here on every add — `add deploy` armed a
/// growth-guards whose effect was declined a week earlier. Which trees the
/// plan WROTE missed a package whose bytes were already correct, which is
/// routine for a committed render or a cache already at the commit asked
/// for. The caller's requested-member list disclosed a member the plan held
/// back and skipped every dependency the engine pulled in behind it.
///
/// The lock diff has none of those seams. A package appears there when this
/// pass adds it to what the scope carries, whether its bytes changed or not
/// and whether it was named on the command line or required by something
/// that was; a package already installed does not appear, because the scope
/// already carried it; and a package the plan refuses to write never
/// reaches the new lock at all. `blocked` stays as a second gate, because a
/// disclosure for a tree kendex did not write is the one that runs somebody
/// else's script.
pub(super) fn run(
    state: &DesiredState,
    drift: &[DriftRow],
    added: &[SetChange],
    before: &crate::lock::Lock,
) -> Vec<DeclaredEffects> {
    // A lock row is per harness, so a package the scope already carried
    // produced an Add the day a new tool was detected and its copy fanned
    // out — and an unrelated `add` then armed a package whose effect had
    // been declined. The effect belongs to the package, so the question is
    // about the package: was this name anywhere in the scope before.
    let already_here = crate::lock::skill_names(before);
    let installed: BTreeSet<&str> = added
        .iter()
        .filter(|change| {
            change.direction == SetDirection::Add
                && change.kind == ItemKind::Skill
                && !already_here.contains(change.name.as_str())
        })
        .map(|change| change.name.as_str())
        .collect();
    let mut found: BTreeMap<String, DeclaredEffects> = BTreeMap::new();
    for item in &state.items {
        if item.kind != ItemKind::Skill || !item.enabled {
            continue;
        }
        if !installed.contains(item.name.as_str()) {
            continue;
        }
        if blocked(drift, &item.name) {
            continue;
        }
        let Artifact::Tree {
            canonical, files, ..
        } = &item.artifact
        else {
            continue;
        };
        if found.contains_key(&item.name) {
            continue;
        }
        // The declaration at the package root, by its whole relative path.
        // Matching the basename took whichever `SKILL.md` sorted first, so a
        // nested one — a package that carries an example, a bundled skill —
        // decided what this install disclosed: the root's effect dropped
        // silently, or somebody authorized a different package's summary
        // while the root's own installer is what would run.
        let Some(text) = files.iter().find_map(|(path, bytes)| {
            (path == std::path::Path::new("SKILL.md")).then(|| String::from_utf8_lossy(bytes))
        }) else {
            continue;
        };
        let Some(effects) = declared(&text) else {
            continue;
        };
        found.insert(
            item.name.clone(),
            DeclaredEffects {
                name: item.name.clone(),
                root: canonical.clone(),
                effects,
            },
        );
    }
    found.into_values().collect()
}

/// Whether this plan leaves the package's tree as it found it.
///
/// Every cause that holds the write counts, not only the ones about files
/// kendex did not put there. A tree somebody edited is held back the same
/// way, and it matters for the same reason and more: the effect would
/// disclose the catalog's bytes and then run the edited script sitting on
/// disk. Asking the cause whether it holds the write, rather than listing
/// the causes that do, is what keeps this from having to be revisited each
/// time a cause is added.
///
/// Whatever the reason, the directory an effect would run its script out of
/// is whatever was already there — so the effect is not disclosed and not
/// offered. A package that did not install has nothing to authorize.
fn blocked(drift: &[DriftRow], name: &str) -> bool {
    drift
        .iter()
        .filter(|row| row.kind == ItemKind::Skill && row.name == name)
        .any(|row| row.dead_stop() || row.cause.is_some_and(DriftCause::holds_the_write))
}
