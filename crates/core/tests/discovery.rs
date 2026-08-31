//! Any repository holding skills is a marketplace: the closed search table
//! finds them, the About report says what was found where, and a control
//! file that is present but broken makes the source unusable with a finding
//! rather than silently reading as a different kind of repository.

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::model::ItemKind;
use kendex_core::source::{
    CatalogMode, DISCOVERY_VERSION, SourceConfig, about, find_item, list_items, source_config,
};
use kendex_core::source_read::SealedSource;

#[allow(clippy::unwrap_used)]
fn repo() -> (tempfile::TempDir, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("repo");
    fs::create_dir_all(&root).unwrap();
    (tmp, root)
}

#[allow(clippy::unwrap_used)]
fn skill(root: &Path, rel: &str, name: &str) {
    let dir = root.join(rel);
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: about {name}\n---\nBody.\n"),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn read(root: &Path) -> (SealedSource, SourceConfig) {
    let sealed = SealedSource::open(root).unwrap();
    let config = source_config(&sealed, "repo").unwrap();
    (sealed, config)
}

/// A repository with more skills than the cap yields exactly the cap and a
/// finding, and the walk stops rather than reading the rest of a hostile tree.
#[test]
#[allow(clippy::unwrap_used)]
fn a_repo_past_the_cap_yields_the_cap_and_says_so() {
    let (_tmp, root) = repo();
    for n in 0..600 {
        skill(&root, &format!("skills/s{n:04}"), &format!("s{n:04}"));
    }
    let (sealed, config) = read(&root);
    assert_eq!(list_items(&sealed, &config, ItemKind::Skill).len(), 512);
    assert!(
        config
            .findings()
            .any(|f| f.problem.contains("more than 512 skills")),
        "the cap is a finding"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_flat_skills_repo_lists_exactly_its_skills() {
    let (_tmp, root) = repo();
    skill(&root, "skills/gh", "gh");
    skill(&root, "skills/review", "review");
    let (sealed, config) = read(&root);
    assert_eq!(
        list_items(&sealed, &config, ItemKind::Skill),
        ["gh", "review"]
    );
    assert_eq!(
        find_item(&sealed, &config, ItemKind::Skill, "gh"),
        Some(sealed.root().join("skills/gh"))
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn category_nested_skills_are_found_and_named_by_their_leaf_directory() {
    let (_tmp, root) = repo();
    skill(&root, "skills/data/eda", "eda");
    let (sealed, config) = read(&root);
    assert_eq!(list_items(&sealed, &config, ItemKind::Skill), ["eda"]);
    assert_eq!(
        find_item(&sealed, &config, ItemKind::Skill, "eda"),
        Some(sealed.root().join("skills/data/eda"))
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn dot_claude_skills_is_a_recognized_root() {
    let (_tmp, root) = repo();
    skill(&root, ".claude/skills/gh", "gh");
    let (sealed, config) = read(&root);
    assert_eq!(list_items(&sealed, &config, ItemKind::Skill), ["gh"]);
    let report = about(&sealed, &config);
    assert!(
        report.found.iter().any(|row| row.root == ".claude/skills"
            && row.kind == ItemKind::Skill
            && row.count == 1),
        "{report:?}"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_root_skill_md_is_a_one_skill_repo_named_by_its_frontmatter() {
    let (_tmp, root) = repo();
    fs::write(
        root.join("SKILL.md"),
        "---\nname: my-skill\ndescription: d\n---\nBody.\n",
    )
    .unwrap();
    let (sealed, config) = read(&root);
    assert_eq!(list_items(&sealed, &config, ItemKind::Skill), ["my-skill"]);
    // The whole repository is the skill's tree.
    assert_eq!(
        find_item(&sealed, &config, ItemKind::Skill, "my-skill"),
        Some(sealed.root().to_path_buf())
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_root_skill_md_without_a_name_takes_the_display_name_the_caller_passed() {
    let (_tmp, root) = repo();
    fs::write(root.join("SKILL.md"), "No frontmatter at all.\n").unwrap();
    let sealed = SealedSource::open(&root).unwrap();
    // The store directory is a commit id, so the caller says what the
    // repository is called.
    let config = source_config(&sealed, "agent-skills").unwrap();
    assert_eq!(
        list_items(&sealed, &config, ItemKind::Skill),
        ["agent-skills"]
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_plugin_registry_wins_outright_and_root_dirs_are_not_read() {
    let (_tmp, root) = repo();
    skill(&root, "skills/loose", "loose");
    skill(&root, "plugins/kit/skills/eda", "eda");
    fs::create_dir_all(root.join(".claude-plugin")).unwrap();
    fs::write(
        root.join(".claude-plugin/marketplace.json"),
        r#"{"name": "kit", "owner": {"name": "o"},
            "plugins": [{"name": "kit", "source": "./plugins/kit"}]}"#,
    )
    .unwrap();
    let (sealed, config) = read(&root);
    assert_eq!(config.mode, CatalogMode::PluginRegistry);
    assert_eq!(list_items(&sealed, &config, ItemKind::Skill), ["kit/eda"]);
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_frontmatter_name_disagreeing_with_the_directory_is_a_finding() {
    let (_tmp, root) = repo();
    skill(&root, "skills/gh", "github-helper");
    let (sealed, config) = read(&root);
    // The directory name is the identity; the skill still installs.
    assert_eq!(list_items(&sealed, &config, ItemKind::Skill), ["gh"]);
    let finding = config
        .findings()
        .find(|f| f.problem.contains("github-helper"))
        .expect("a finding naming the disagreement");
    assert!(finding.problem.contains("`gh`"), "{finding}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_unparseable_kendex_toml_makes_the_source_unusable_with_a_finding() {
    let (_tmp, root) = repo();
    skill(&root, "skills/gh", "gh");
    fs::write(root.join("kendex.toml"), "[catalog\nskills = broken").unwrap();
    let (sealed, config) = read(&root);
    assert_eq!(config.mode, CatalogMode::Unusable);
    assert!(list_items(&sealed, &config, ItemKind::Skill).is_empty());
    assert_eq!(find_item(&sealed, &config, ItemKind::Skill, "gh"), None);
    assert_eq!(find_item(&sealed, &config, ItemKind::Hook, "x"), None);
    let report = about(&sealed, &config);
    assert!(report.found.is_empty());
    assert!(
        report
            .findings
            .iter()
            .any(|f| f.problem.contains("not readable TOML")),
        "{report:?}"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_wrong_typed_catalog_array_never_falls_through_to_discovery() {
    let (_tmp, root) = repo();
    skill(&root, "skills/gh", "gh");
    fs::write(root.join("kendex.toml"), "[catalog]\nskills = \"skills\"\n").unwrap();
    let (sealed, config) = read(&root);
    assert_eq!(config.mode, CatalogMode::Unusable);
    assert!(list_items(&sealed, &config, ItemKind::Skill).is_empty());
    assert!(
        config
            .findings()
            .any(|f| f.problem.contains("not a list of directory names")),
        "the breakage must be named"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_present_but_broken_registry_offers_nothing_and_says_why() {
    let (_tmp, root) = repo();
    skill(&root, "skills/gh", "gh");
    fs::create_dir_all(root.join(".claude-plugin")).unwrap();
    fs::write(root.join(".claude-plugin/marketplace.json"), "{ not json").unwrap();
    let (sealed, config) = read(&root);
    // Recognized — never read the plain way instead.
    assert_eq!(config.mode, CatalogMode::PluginRegistry);
    assert!(list_items(&sealed, &config, ItemKind::Skill).is_empty());
    assert!(
        config
            .findings()
            .any(|f| f.problem.contains("not readable JSON"))
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn one_directory_reachable_twice_is_one_item() {
    let (_tmp, root) = repo();
    skill(&root, "skills/.curated/gh", "gh");
    let (sealed, config) = read(&root);
    assert_eq!(list_items(&sealed, &config, ItemKind::Skill), ["gh"]);
    assert_eq!(config.discovery.skills.len(), 1);
    assert_eq!(config.discovery.skills[0].root, "skills/.curated");
}

#[test]
#[allow(clippy::unwrap_used)]
fn two_directories_folding_to_one_name_with_different_bytes_both_skip() {
    let (_tmp, root) = repo();
    skill(&root, "skills/gh", "gh");
    skill(&root, ".claude/skills/GH", "GH");
    let (sealed, config) = read(&root);
    // Both are skipped: which the walk reached first must not decide which
    // clashing skill a hostile repo gets to install.
    assert!(list_items(&sealed, &config, ItemKind::Skill).is_empty());
    let finding = config
        .findings()
        .find(|f| f.problem.contains("both are skipped"))
        .expect("the collision is a finding");
    assert!(finding.problem.contains("gh"), "{finding}");
}

/// The same skill served under two recognized roots — one repo offering it to
/// two harness layouts — is one item, deduplicated in silence, not a false
/// case-folding collision. The bytes are identical, so it is plainly one skill.
#[test]
#[allow(clippy::unwrap_used)]
fn one_skill_copied_under_two_roots_is_one_item() {
    let (_tmp, root) = repo();
    skill(&root, "skills/gh", "gh");
    skill(&root, ".claude/skills/gh", "gh");
    let (sealed, config) = read(&root);
    assert_eq!(list_items(&sealed, &config, ItemKind::Skill), ["gh"]);
    assert!(
        config.findings().all(|f| !f.problem.contains("fold")),
        "identical copies are not a collision"
    );
}

#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_symlinked_skill_entry_is_skipped() {
    let (tmp, root) = repo();
    let outside = tmp.path().join("outside");
    fs::create_dir_all(&outside).unwrap();
    fs::write(outside.join("SKILL.md"), "---\nname: out\n---\n").unwrap();
    fs::create_dir_all(root.join("skills")).unwrap();
    std::os::unix::fs::symlink(&outside, root.join("skills/out")).unwrap();
    skill(&root, "skills/real", "real");
    let (sealed, config) = read(&root);
    assert_eq!(list_items(&sealed, &config, ItemKind::Skill), ["real"]);
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_walk_stops_below_a_found_skill() {
    let (_tmp, root) = repo();
    skill(&root, "skills/outer", "outer");
    skill(&root, "skills/outer/fixtures/inner", "inner");
    let (sealed, config) = read(&root);
    assert_eq!(list_items(&sealed, &config, ItemKind::Skill), ["outer"]);
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_skill_nested_past_the_depth_cap_is_not_found() {
    let (_tmp, root) = repo();
    skill(&root, "skills/a/b/c/deep", "deep");
    let (sealed, config) = read(&root);
    assert!(list_items(&sealed, &config, ItemKind::Skill).is_empty());
}

/// Executable content is never discovered into existence: a `hooks/` folder
/// in a repo that declared no kendex layout is repository tooling, and the
/// About report must not offer it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hooks_folder_in_a_skills_repo_is_not_offered() {
    let (_tmp, root) = repo();
    skill(&root, ".claude/skills/gh", "gh");
    fs::create_dir_all(root.join("hooks")).unwrap();
    fs::write(root.join("hooks/deploy.sh"), "#!/bin/sh\n").unwrap();
    let (sealed, config) = read(&root);
    let report = about(&sealed, &config);
    assert!(
        report.found.iter().all(|row| row.kind == ItemKind::Skill),
        "{report:?}"
    );
    // Not listed and not resolvable by name: asking for the hook directly must
    // refuse too, or a discovered repo would still install and run the script.
    assert_eq!(find_item(&sealed, &config, ItemKind::Hook, "deploy"), None);

    // A repo that declares kendex's layout offers the same folder.
    fs::write(root.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    let (sealed, config) = read(&root);
    let report = about(&sealed, &config);
    assert!(
        report
            .found
            .iter()
            .any(|row| row.kind == ItemKind::Hook && row.root == "hooks" && row.count == 1),
        "{report:?}"
    );
    assert!(find_item(&sealed, &config, ItemKind::Hook, "deploy").is_some());
}

#[test]
#[allow(clippy::unwrap_used)]
fn submodule_and_lfs_pointers_under_a_root_are_findings_not_content() {
    let (_tmp, root) = repo();
    skill(&root, "skills/real", "real");
    fs::create_dir_all(root.join("skills/vendored")).unwrap();
    fs::write(
        root.join(".gitmodules"),
        "[submodule \"vendored\"]\n\tpath = skills/vendored\n\turl = https://example.invalid/x\n",
    )
    .unwrap();
    fs::create_dir_all(root.join("skills/heavy")).unwrap();
    fs::write(
        root.join("skills/heavy/SKILL.md"),
        "version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 12\n",
    )
    .unwrap();
    let (sealed, config) = read(&root);
    assert_eq!(list_items(&sealed, &config, ItemKind::Skill), ["real"]);
    assert!(
        config.findings().any(|f| f.problem.contains("submodule")),
        "the submodule is named"
    );
    assert!(
        config.findings().any(|f| f.problem.contains("git-lfs")),
        "the pointer is named"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_about_report_counts_skills_per_root() {
    let (_tmp, root) = repo();
    skill(&root, "skills/a", "a");
    skill(&root, "skills/b", "b");
    skill(&root, ".claude/skills/c", "c");
    let (sealed, config) = read(&root);
    let report = about(&sealed, &config);
    let count = |name: &str| {
        report
            .found
            .iter()
            .find(|row| row.root == name && row.kind == ItemKind::Skill)
            .map(|row| row.count)
    };
    assert_eq!(count("skills"), Some(2));
    assert_eq!(count(".claude/skills"), Some(1));
    // The version travels with the table into the safety-cache key.
    let _versioned: u32 = DISCOVERY_VERSION;
}

/// A listing says what a source offers, and one sibling it cannot read
/// must not take the readable items with it. `skills/locked` is searchable
/// but not listable — POSIX mode 0311, or an ACL — and `skills/gh` beside
/// it is still offered, still resolved, and still counted. The agent arm
/// answers the same way: `agents/locked` costs nothing but its own rows.
///
/// This is the listing's answer, not the disk's. What a write would land on
/// top of is read through `SealedSource::entries`, where a refused read is
/// an error rather than an empty directory.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_sibling_costs_only_its_own_rows() {
    use std::os::unix::fs::PermissionsExt;
    let (_tmp, root) = repo();
    skill(&root, "skills/gh", "gh");
    skill(&root, "skills/locked/hidden", "hidden");
    fs::create_dir_all(root.join("agents")).unwrap();
    fs::write(root.join("agents/rust.md"), "---\nname: rust\n---\nx\n").unwrap();
    fs::create_dir_all(root.join("agents/locked")).unwrap();
    fs::write(
        root.join("kendex.toml"),
        "[catalog]\nskills = [\"skills\"]\nagents = [\"agents\"]\n",
    )
    .unwrap();
    let locked = [root.join("skills/locked"), root.join("agents/locked")];
    for dir in &locked {
        fs::set_permissions(dir, fs::Permissions::from_mode(0o311)).unwrap();
    }
    // Root reads any directory whatever its mode, so there the denial under
    // test does not exist and the nested skill is offered as well.
    let denied = fs::read_dir(&locked[0]).is_err();

    let (sealed, config) = read(&root);
    let skills = list_items(&sealed, &config, ItemKind::Skill);
    let agents = list_items(&sealed, &config, ItemKind::Agent);
    let counted = |name: &str, kind: ItemKind| {
        about(&sealed, &config)
            .found
            .iter()
            .find(|row| row.root == name && row.kind == kind)
            .map(|row| row.count)
    };
    let skill_rows = counted("skills", ItemKind::Skill);
    let agent_rows = counted("agents", ItemKind::Agent);
    for dir in &locked {
        fs::set_permissions(dir, fs::Permissions::from_mode(0o755)).unwrap();
    }

    assert!(skills.contains(&"gh".to_owned()), "{skills:?}");
    assert_eq!(agents, ["rust"]);
    assert_eq!(
        find_item(&sealed, &config, ItemKind::Skill, "gh"),
        Some(sealed.root().join("skills/gh"))
    );
    assert_eq!(agent_rows, Some(1));
    match denied {
        true => {
            assert_eq!(skills, ["gh"]);
            assert_eq!(skill_rows, Some(1));
        }
        false => {
            assert_eq!(skills, ["gh", "locked/hidden"]);
            assert_eq!(skill_rows, Some(2));
        }
    }
}

/// The half that must fail: a kind directory the catalog does not have is
/// an empty listing, not a refusal. Reading every absent directory as an
/// unreadable one would refuse the first add into a fresh source.
#[test]
#[allow(clippy::unwrap_used)]
fn a_kind_directory_that_is_not_there_lists_as_empty() {
    let (_tmp, root) = repo();
    skill(&root, "skills/gh", "gh");
    fs::write(
        root.join("kendex.toml"),
        "[catalog]\nskills = [\"skills\"]\nagents = [\"agents\"]\n",
    )
    .unwrap();
    let (sealed, config) = read(&root);
    assert!(!root.join("agents").exists());
    assert_eq!(list_items(&sealed, &config, ItemKind::Skill), ["gh"]);
    assert!(list_items(&sealed, &config, ItemKind::Agent).is_empty());
}
