//! The guard's search roots are the directories kendex actually installs
//! skills into.
//!
//! Derived from the harness adapters rather than transcribed from them. The
//! list had `.cursor/rules`, which is not a skills directory at all, and was
//! missing `.gemini/skills` and `.github/skills` — so a `method = copy`
//! install into any of those three produced a package the guard verbs could
//! not find, and a repository armed from it read as having no package.
//!
//! The package has its own copy, in `scripts/lib/skill-roots.sh`, which the
//! installer bakes into the helper it writes into `.git/hooks`. Both lists
//! are pinned here, and both to the adapters rather than only to each
//! other: two copies agreeing is no evidence either is right, and for three
//! rounds they agreed on a wrong list.
//!
//! Order as well as membership, which is why the shell list is compared as
//! tokens and not as a set. `guard::Installed::resolve` takes the first
//! root whose script is executable and the baked helper takes its own
//! first; a repository where the two pick different copies runs one gate
//! and reports on another.

use std::collections::BTreeSet;
use std::path::Path;

use kendex_core::env::{Env, FakeOs};
use kendex_core::harness::{Surface, all_adapters};
use kendex_core::model::ItemKind;

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

/// Every project-scope skills directory any harness declares, relative to
/// the project root.
#[allow(clippy::expect_used)]
fn adapter_skill_roots(project: &Path, env: &Env) -> BTreeSet<String> {
    let mut roots = BTreeSet::new();
    for adapter in all_adapters() {
        for surface in adapter.project_surfaces(ItemKind::Skill, project, env) {
            let Surface::SubdirPerItem { dir, .. } = surface else {
                continue;
            };
            let relative = dir
                .strip_prefix(project)
                .expect("a project surface is under the project root");
            roots.insert(kendex_core::paths::slashed(relative));
        }
    }
    roots
}

/// The adapter-derived set, over a throwaway project.
#[allow(clippy::unwrap_used)]
fn declared_roots() -> BTreeSet<String> {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let env = Env::fake(home, FakeOs::Linux);
    adapter_skill_roots(&project, &env)
}

#[test]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn a_root_for_every_harness_skills_surface() {
    let declared = declared_roots();
    let searched: BTreeSet<String> = kendex_core::guard::SEARCH_ROOTS
        .iter()
        .map(|root| (*root).to_owned())
        .collect();

    let unsearched: Vec<&String> = declared.difference(&searched).collect();
    assert!(
        unsearched.is_empty(),
        "harnesses install skills into {unsearched:?}, which the guard verbs never look in — \
         a package installed there is one they cannot find"
    );

    // The other direction is a warning, not a rule: `skills` is kendex's own
    // source layout and belongs to no adapter, so only the dotted roots have
    // to be accounted for.
    let unexplained: Vec<&String> = searched
        .difference(&declared)
        .filter(|root| root.starts_with('.'))
        .collect();
    assert!(
        unexplained.is_empty(),
        "the guard verbs search {unexplained:?}, which no harness installs skills into"
    );
}

/// The shell list and the Rust list are the same roots in the same order.
///
/// `Installed::resolve` walks the Rust list on every guard verb, and the
/// commit-hook verdict `kendex check` prints is whatever the copy it finds
/// there says — while the helper git actually runs at commit time searches
/// the shell list. A root in one and not the other, or the same roots in a
/// different order, is a repository gated by one copy and described by
/// another.
///
/// Token equality, not a parse. The shell list is one space-separated
/// string by construction, and comparing them as sets would pass a pair
/// that searched the same places in a different order.
#[test]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn the_packages_own_list_is_the_same_roots_in_the_same_order() {
    let ours: Vec<String> = kendex_core::guard::SEARCH_ROOTS
        .iter()
        .map(|root| (*root).to_owned())
        .collect();
    let theirs = package_skill_roots();
    assert_eq!(
        theirs, ours,
        "the package searches {theirs:?} and kendex searches {ours:?}"
    );
}

/// And the package's list accounts for every harness skills directory too.
///
/// The pin above would pass on two identical wrong lists. This is the same
/// question `a_root_for_every_harness_skills_surface` asks of the Rust
/// copy, asked of the shell one, so neither is only ever compared to its
/// twin.
#[test]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn the_packages_own_list_covers_every_harness_skills_surface() {
    let theirs: BTreeSet<String> = package_skill_roots()
        .into_iter()
        .map(String::from)
        .collect();
    let declared = declared_roots();
    let unsearched: Vec<&String> = declared.difference(&theirs).collect();
    assert!(
        unsearched.is_empty(),
        "harnesses install skills into {unsearched:?}, which the package's own \
         search never looks in — a package installed there is one the commit \
         hook cannot find"
    );
}

/// `GG_SKILL_ROOTS` out of the package's single definition of it.
#[allow(clippy::expect_used, clippy::unwrap_used)]
fn package_skill_roots() -> Vec<String> {
    let definition = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../skills/growth-guards/scripts/lib/skill-roots.sh")
        .canonicalize()
        .unwrap();
    let text = std::fs::read_to_string(&definition).unwrap();
    text.lines()
        .find_map(|line| line.strip_prefix("GG_SKILL_ROOTS=\""))
        .and_then(|rest| rest.strip_suffix('"'))
        .expect("the package declares GG_SKILL_ROOTS as one quoted string")
        .split_whitespace()
        .map(str::to_owned)
        .collect()
}
