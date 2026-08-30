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

use crate::env::Env;
use crate::error::Result;
use crate::model::{ItemKind, Scope};
use crate::repo_effects::{Declaration, DeclaredEffects, declaration, declared};

use super::desired::{Artifact, DesiredState, read_dirs, skill_canonical};
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

/// Every declared effect this plan takes out of the scope, once per
/// package — the other direction of [`run`].
///
/// A package leaves when no harness's copy of it survives in the lock this
/// pass writes. That is the package-level question, the same one the add
/// side asks: a copy dropped for one tool while another keeps it is a
/// package still installed, and its effect still wanted.
///
/// Read off the tree on disk, not off the desired state, because the
/// desired state no longer has the item — that is what leaving means. The
/// tree is still there while this plan is only planned, which is the whole
/// window the CLI has to run the uninstaller in: once the plan executes the
/// scripts are gone, and shims that exec a script that is not there fail
/// every commit closed. A tree already missing declares nothing here, and
/// nothing reports what it left armed: the shims are the package's to
/// describe, and the package is gone. A tree that is there and
/// cannot be read is neither, and neither is one whose declaration will not
/// parse: either error stops the plan with the package still installed,
/// rather than reporting a declaration of nothing and letting the removal
/// take the scripts out from under armed shims.
///
/// Empty outside a project. An effect is a change to a repository, and the
/// global scope is not one; `run_script` refuses it.
pub(super) fn leaving(
    env: &Env,
    scope: &Scope,
    before: &crate::lock::Lock,
    after: &crate::lock::Lock,
) -> Result<Vec<DeclaredEffects>> {
    if !matches!(scope, Scope::Project { .. }) {
        return Ok(Vec::new());
    }
    let staying = skill_names(after);
    let mut found: BTreeMap<String, DeclaredEffects> = BTreeMap::new();
    for name in skill_names(before).difference(&staying) {
        let Some(installed) = installed_tree(env, scope, before, name)? else {
            continue;
        };
        let effects = match declaration(&installed.text) {
            Declaration::Effects(effects) => effects,
            // A package that declares nothing has nothing to undo.
            Declaration::Absent => continue,
            Declaration::Unreadable => return Err(unreadable(&installed.declaration)),
        };
        found.insert(
            (*name).to_owned(),
            DeclaredEffects {
                name: (*name).to_owned(),
                root: installed.root,
                effects,
            },
        );
    }
    Ok(found.into_values().collect())
}

/// The packages a lock carries, by name: the package, not any tool's copy
/// of it. A lock row is per harness, and an effect belongs to the package —
/// so both directions ask whether the NAME is in the scope, never whether
/// one tool's row is.
fn skill_names(lock: &crate::lock::Lock) -> BTreeSet<&str> {
    lock.entries
        .values()
        .filter(|entry| entry.kind == ItemKind::Skill)
        .map(|entry| entry.name.as_str())
        .collect()
}

/// The two names an installed skill's declaration can sit under: the
/// second is what a switched-off installation keeps its content as.
const DECLARATION_NAMES: [&str; 2] = ["SKILL.md", "SKILL.md.disabled"];

/// A departing package's installed tree, and the declaration file read out
/// of it — a path rather than the two names, because it is what an error
/// about the declaration has to name for anyone to go and fix it.
#[derive(Debug)]
struct Installed {
    root: std::path::PathBuf,
    declaration: std::path::PathBuf,
    text: String,
}

/// A declaration that will not read stops the plan with the package still
/// installed, the same as a file that will not read at all. Calling it a
/// package that declares nothing is what leaves hook shims delegating to
/// scripts the removal has taken away, and the plan that does it previews
/// as an ordinary removal.
fn unreadable(at: &std::path::Path) -> crate::error::CoreError {
    crate::repo_effects::err(format!(
        "{}: this package's repo-effects declaration will not read, so kendex cannot tell whether it has an uninstaller to run — repair the frontmatter, then remove the package",
        at.display()
    ))
}

/// Where a departing package's tree sits on disk, and its declaration.
///
/// The shared tree first, then every directory the departing rows' own
/// tools read skills from: a copy delivery writes the package into the
/// tool's own directory and the shared tree may not exist at all, so
/// reading only `.agents/skills` found no declaration for exactly the
/// install whose scripts were about to be trashed. The first copy that
/// carries a declaration is the one whose scripts run.
///
/// Both spellings, because switching an installation off renames its
/// `SKILL.md` to `SKILL.md.disabled` and nothing disarms on that switch:
/// probing the enabled name alone read a package that was installed,
/// armed, then disabled as a package that declares nothing, and the
/// removal took its scripts out from under shims still delegating to
/// them. A tree carrying both names never installs — `desired_skill`
/// refuses it — so which one is read is not a question here.
///
/// A candidate with neither name is skipped; a candidate whose
/// declaration will not read is an error, because the alternative is to
/// call a package that declares an uninstaller a package that declares
/// nothing.
fn installed_tree(
    env: &Env,
    scope: &Scope,
    before: &crate::lock::Lock,
    name: &str,
) -> Result<Option<Installed>> {
    let mut candidates = vec![skill_canonical(env, scope, name)];
    for entry in before
        .entries
        .values()
        .filter(|entry| entry.kind == ItemKind::Skill && entry.name == name)
    {
        // The name a harness's own directory holds is that harness's, not
        // the shared tree's: `rendered_name` joins a namespaced name with
        // the separator this tool will load, which is a hyphen wherever
        // names must be lower-kebab. Probing every directory under the
        // canonical spelling found nothing for exactly those installs.
        let rendered = crate::harness::rendered_name(entry.harness, name);
        for dir in read_dirs(env, scope, entry.harness, ItemKind::Skill) {
            candidates.push(dir.join(&rendered));
        }
    }
    for root in candidates {
        for file in DECLARATION_NAMES {
            let declaration = root.join(file);
            if let Some(text) = crate::fs::read_if_exists(&declaration)? {
                return Ok(Some(Installed {
                    root,
                    declaration,
                    text,
                }));
            }
        }
    }
    Ok(None)
}

#[cfg(all(test, unix))]
mod tests;
