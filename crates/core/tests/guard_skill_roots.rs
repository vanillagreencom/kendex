//! The guard's search roots are the directories kendex actually installs
//! skills into.
//!
//! Derived from the harness adapters rather than transcribed from them. The
//! list had `.cursor/rules`, which is not a skills directory at all, and was
//! missing `.gemini/skills` and `.github/skills` — so a `method = copy`
//! install into any of those three produced a package the guard verbs could
//! not find, and a repository armed from it read as having no package.
//!
//! There is a second copy of this list in the package's `install-git-hooks`,
//! and `guard_hooks::the_search_roots_match_the_installers_own_list` pins
//! them to each other. That pin cannot catch this: two duplicates agreeing
//! is no evidence that either is right. This one asks the adapters.

use std::collections::BTreeSet;
use std::path::Path;

use kendex_core::env::{Env, FakeOs};
use kendex_core::harness::{Surface, all_adapters};
use kendex_core::model::ItemKind;

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
            roots.insert(relative.to_string_lossy().into_owned());
        }
    }
    roots
}

#[test]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn a_root_for_every_harness_skills_surface() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&project).unwrap();
    let env = Env::fake(home, FakeOs::Linux);

    let declared = adapter_skill_roots(&project, &env);
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
