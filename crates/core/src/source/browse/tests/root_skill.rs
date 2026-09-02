//! A skill that is its whole repository: what the preview lists, and the
//! file read opens, is the skill's tree — never the repository around it.

use std::fs;

use super::super::{Catalog, package_file, package_preview};
use super::repo::{commit, git};
use crate::env::{Env, FakeOs};
use crate::error::CoreError;
use crate::model::ItemKind;

/// A repository that is one skill at its root, carrying the directories a
/// repository has and a skill does not.
fn root_skill_fixture() -> (tempfile::TempDir, Env, Catalog) {
    let tmp = tempfile::tempdir().unwrap();
    let upstream = tmp.path().join("base/owner/rootskill");
    fs::create_dir_all(upstream.join("node_modules/dep")).unwrap();
    fs::create_dir_all(upstream.join("target")).unwrap();
    fs::write(
        upstream.join("SKILL.md"),
        "---\nname: root\ndescription: lives at the root\n---\nbody\n",
    )
    .unwrap();
    fs::write(upstream.join("notes.md"), "kept\n").unwrap();
    fs::write(
        upstream.join("node_modules/dep/index.js"),
        "module.exports = 1\n",
    )
    .unwrap();
    fs::write(upstream.join("target/out.txt"), "built\n").unwrap();
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    commit(&upstream, "one");
    let base = format!("file://{}", tmp.path().join("base").display());
    let env = Env::fake(tmp.path(), FakeOs::Linux).with_var("KENDEX_GIT_BASE", &base);
    let catalog = Catalog::Repo {
        repo: "owner/rootskill".to_owned(),
    };
    (tmp, env, catalog)
}

#[test]
fn a_repo_root_skill_lists_and_reads_only_its_own_tree() {
    let (_tmp, env, catalog) = root_skill_fixture();
    let preview = package_preview(&env, &catalog, ItemKind::Skill, "root", None).unwrap();
    let listed: Vec<&str> = preview.files.iter().map(|f| f.path.as_str()).collect();
    assert!(listed.contains(&"notes.md"), "{listed:?}");
    assert!(
        listed
            .iter()
            .all(|p| !p.starts_with("node_modules/") && !p.starts_with("target/")),
        "{listed:?}"
    );

    assert_eq!(
        package_file(&env, &catalog, ItemKind::Skill, "root", "notes.md")
            .unwrap()
            .content,
        "kept\n"
    );
    for hidden in ["node_modules/dep/index.js", "target/out.txt", ".git/config"] {
        let refused = package_file(&env, &catalog, ItemKind::Skill, "root", hidden).unwrap_err();
        assert!(
            matches!(refused, CoreError::SourceEscape { .. }),
            "{hidden}: {refused}"
        );
    }
}
