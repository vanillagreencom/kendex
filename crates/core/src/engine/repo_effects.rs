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
use crate::repo_effects::{DeclaredEffects, declared};

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
/// every commit closed. A tree already missing declares nothing here; what
/// it left armed is `guard::stranded`'s to report. A tree that is there and
/// cannot be read is neither: the error stops the plan with the package
/// still installed, rather than reporting a declaration of nothing and
/// letting the removal take the scripts out from under armed shims.
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
        let Some((root, text)) = installed_tree(env, scope, before, name)? else {
            continue;
        };
        let Some(effects) = declared(&text) else {
            continue;
        };
        found.insert(
            (*name).to_owned(),
            DeclaredEffects {
                name: (*name).to_owned(),
                root,
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

/// Where a departing package's tree sits on disk, and its `SKILL.md`.
///
/// The shared tree first, then every directory the departing rows' own
/// tools read skills from: a copy delivery writes the package into the
/// tool's own directory and the shared tree may not exist at all, so
/// reading only `.agents/skills` found no declaration for exactly the
/// install whose scripts were about to be trashed. The first copy that
/// carries a `SKILL.md` is the one whose scripts run.
///
/// A candidate with no `SKILL.md` is skipped; a candidate whose `SKILL.md`
/// will not read is an error, because the alternative is to call a package
/// that declares an uninstaller a package that declares nothing.
fn installed_tree(
    env: &Env,
    scope: &Scope,
    before: &crate::lock::Lock,
    name: &str,
) -> Result<Option<(std::path::PathBuf, String)>> {
    let canonical = crate::harness::canonical_name(name);
    let mut candidates = vec![skill_canonical(env, scope, name)];
    for entry in before
        .entries
        .values()
        .filter(|entry| entry.kind == ItemKind::Skill && entry.name == name)
    {
        for dir in read_dirs(env, scope, entry.harness, ItemKind::Skill) {
            candidates.push(dir.join(&canonical));
        }
    }
    for root in candidates {
        if let Some(text) = crate::fs::read_if_exists(&root.join("SKILL.md"))? {
            return Ok(Some((root, text)));
        }
    }
    Ok(None)
}

#[cfg(all(test, unix))]
mod tests {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    use super::*;
    use crate::env::FakeOs;

    /// A candidate with no `SKILL.md` is a candidate to move past; a
    /// candidate whose `SKILL.md` will not read is the end of the search.
    ///
    /// Swallowing the read spelled the second case as the first, and the
    /// caller reads that as "this package declares nothing" — which is how
    /// a removal takes a package's scripts away with its hook shims still
    /// delegating to them. The lock is empty, so the canonical tree is the
    /// only candidate and the answer is about the read, nothing else.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn an_unreadable_declaration_is_an_error_not_an_absent_one() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().to_path_buf();
        let env = Env::fake(&home, FakeOs::Linux);
        let root = home.join("dev/app");
        let scope = Scope::Project { root: root.clone() };
        let lock = crate::lock::Lock::default();

        assert!(
            installed_tree(&env, &scope, &lock, "armer")
                .unwrap()
                .is_none(),
            "a tree that is not there declares nothing"
        );

        let tree = root.join(".agents/skills/armer");
        fs::create_dir_all(&tree).unwrap();
        let declaration = tree.join("SKILL.md");
        fs::write(&declaration, "---\nname: armer\n---\nBody.\n").unwrap();
        let readable = installed_tree(&env, &scope, &lock, "armer").unwrap();
        assert_eq!(readable.map(|(at, _)| at), Some(tree));

        fs::set_permissions(&declaration, fs::Permissions::from_mode(0o000)).unwrap();
        // Root reads a mode-000 file, so there is no unreadable file to make.
        if fs::read_to_string(&declaration).is_ok() {
            return;
        }
        let err = installed_tree(&env, &scope, &lock, "armer").unwrap_err();
        assert!(
            err.to_string().contains("SKILL.md"),
            "the error did not name the file it could not read: {err}"
        );
    }
}
