//! The authoring check reads the catalog the way subscribing reads it: one
//! `source_config`/discovery result behind `check --catalog`, browsing and
//! the index, so a repo can never pass its own check and then install
//! differently.

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::check_catalog::check;
use kendex_core::model::ItemKind;
use kendex_core::source::index::index;
use kendex_core::source_read::SealedSource;

#[allow(clippy::unwrap_used)]
fn repo() -> (tempfile::TempDir, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("repo");
    fs::create_dir_all(&root).unwrap();
    (tmp, root)
}

#[allow(clippy::unwrap_used)]
fn skill_at(root: &Path, dir: &str, name: &str) {
    let dir = root.join(dir).join(name);
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: about {name}\n---\nBody.\n"),
    )
    .unwrap();
}

/// A skills.sh-style repo — skills under `.claude/skills`, nothing under
/// kendex's own `skills/` dir — is checked exactly as discovery offers it.
/// Before the check consumed discovery this repo checked clean and empty.
#[test]
#[allow(clippy::unwrap_used)]
fn a_discovered_repo_is_checked_the_way_it_installs() {
    let (_tmp, root) = repo();
    skill_at(&root, ".claude/skills", "review");
    let sealed = SealedSource::open(&root).unwrap();
    let report = check(&sealed, "repo").unwrap();
    let names: Vec<&str> = report.items.iter().map(|item| item.name.as_str()).collect();
    assert_eq!(names, ["review"]);
    assert_eq!(report.items[0].kind, ItemKind::Skill);
}

/// A one-skill repo (root SKILL.md) offers exactly one skill, and the check
/// sees it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_one_skill_repo_is_one_checked_item() {
    let (_tmp, root) = repo();
    fs::write(
        root.join("SKILL.md"),
        "---\nname: repo\ndescription: the one skill\n---\nBody.\n",
    )
    .unwrap();
    let sealed = SealedSource::open(&root).unwrap();
    let report = check(&sealed, "repo").unwrap();
    assert_eq!(report.items.len(), 1);
    assert_eq!(report.items[0].name, "repo");
}

/// A control file that exists but does not parse makes the whole catalog a
/// breakage finding — never an empty, passing report.
#[test]
#[allow(clippy::unwrap_used)]
fn a_broken_control_file_is_breakage_not_an_empty_pass() {
    let (_tmp, root) = repo();
    skill_at(&root, "skills", "review");
    fs::write(root.join("kendex.toml"), "not [valid toml").unwrap();
    let sealed = SealedSource::open(&root).unwrap();
    let report = check(&sealed, "repo").unwrap();
    assert!(report.items.is_empty());
    assert!(report.tally().breakage >= 1);
    assert!(report.failing(false) >= 1);
    let finding = &report.catalog[0];
    assert_eq!(finding.severity, "error");
    assert!(finding.message.contains("not readable TOML"));
}

/// An undeclared `hooks/` folder is repository tooling: browsing refuses to
/// offer it and the check refuses to score it — the same silence.
#[test]
#[allow(clippy::unwrap_used)]
fn an_undeclared_hooks_dir_is_not_checked() {
    let (_tmp, root) = repo();
    skill_at(&root, "skills", "review");
    fs::create_dir_all(root.join("hooks")).unwrap();
    fs::write(root.join("hooks/deploy.sh"), "#!/bin/sh\n").unwrap();
    let sealed = SealedSource::open(&root).unwrap();
    let report = check(&sealed, "repo").unwrap();
    assert!(
        report.items.iter().all(|item| item.kind != ItemKind::Hook),
        "a hook was checked out of a repo that never declared kendex's layout"
    );
}

/// The check and the index pronounce on the same item set with the same
/// verdicts — the pin that keeps "what the site says" and "what the author
/// checked" one answer.
#[test]
#[allow(clippy::unwrap_used)]
fn check_and_index_agree_on_the_offered_set() {
    let (_tmp, root) = repo();
    skill_at(&root, "skills", "review");
    skill_at(&root, ".claude/skills", "deploy");
    fs::create_dir_all(root.join("agents")).unwrap();
    fs::write(
        root.join("agents/scout.md"),
        "---\nname: scout\ndescription: finds things\n---\nBody.\n",
    )
    .unwrap();
    fs::write(root.join("kendex.toml"), "[marketplace]\nname = \"demo\"\n").unwrap();
    let sealed = SealedSource::open(&root).unwrap();
    let report = check(&sealed, "repo").unwrap();
    let summary = index(&sealed, "repo").unwrap();
    let mut checked: Vec<(String, String)> = report
        .items
        .iter()
        .map(|item| (item.kind.name().to_owned(), item.name.clone()))
        .collect();
    let mut indexed: Vec<(String, String)> = summary
        .packages
        .iter()
        .map(|package| (package.kind.to_owned(), package.name.clone()))
        .collect();
    checked.sort();
    indexed.sort();
    assert_eq!(checked, indexed);
    for item in &report.items {
        let package = summary
            .packages
            .iter()
            .find(|package| package.name == item.name && package.kind == item.kind.name())
            .unwrap();
        assert_eq!(package.safety.score, item.advisory.safety.score);
    }
}

/// A kind dir's support directories (tests, fixtures) hold suites about the
/// items, not items — the check must not list them as installable names.
#[test]
#[allow(clippy::unwrap_used)]
fn hook_test_suites_are_not_catalog_items() {
    let (_tmp, root) = repo();
    fs::create_dir_all(root.join("hooks/tests")).unwrap();
    fs::write(root.join("hooks/guard.sh"), "#!/bin/sh\n").unwrap();
    fs::write(root.join("hooks/tests/guard.test.sh"), "#!/bin/sh\n").unwrap();
    fs::write(root.join("kendex.toml"), "[marketplace]\nname = \"demo\"\n").unwrap();
    let sealed = SealedSource::open(&root).unwrap();
    let report = check(&sealed, "repo").unwrap();
    let names: Vec<&str> = report.items.iter().map(|item| item.name.as_str()).collect();
    assert!(names.contains(&"guard"));
    assert!(
        !names.iter().any(|name| name.contains("test")),
        "suite files must not be listed as items: {names:?}"
    );
}

/// The repo-root exclusions hold under either spelling of the root: a
/// caller reaching a repo-root skill through the spelling it opened
/// (macOS's /var symlink, a linked project folder) must not collect VCS
/// internals.
#[test]
#[cfg(unix)]
#[allow(clippy::unwrap_used)]
fn repo_root_exclusions_hold_under_the_given_spelling() {
    let tmp = tempfile::tempdir().unwrap();
    let real = tmp.path().canonicalize().unwrap().join("repo");
    fs::create_dir_all(real.join(".git")).unwrap();
    fs::write(real.join(".git/config"), "secret").unwrap();
    fs::write(
        real.join("SKILL.md"),
        "---\nname: repo\ndescription: about repo\n---\nBody.\n",
    )
    .unwrap();
    let alias = tmp.path().canonicalize().unwrap().join("alias");
    std::os::unix::fs::symlink(&real, &alias).unwrap();

    let sealed = SealedSource::open(&alias).unwrap();
    let files = sealed.collect_skill_tree(&alias).unwrap();
    assert!(
        files.iter().all(|(p, _)| !p.starts_with(".git")),
        "{:?}",
        files.iter().map(|(p, _)| p).collect::<Vec<_>>()
    );
}

/// A safety finding is reported and counted, and fails nothing — not even
/// under `--strict`. The score is advisory in a catalog's own CI too.
#[test]
#[allow(clippy::unwrap_used)]
fn a_safety_finding_is_reported_and_fails_nothing() {
    let (_tmp, root) = repo();
    let dir = root.join("skills").join("risky");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("SKILL.md"),
        "---\nname: risky\ndescription: about risky\n---\n\n```sh\ngit commit --no-verify\n```\n",
    )
    .unwrap();
    let sealed = SealedSource::open(&root).unwrap();
    let report = check(&sealed, "repo").unwrap();
    let found = report
        .findings()
        .filter(|finding| finding.rule.is_some())
        .count();
    assert!(found > 0);
    assert_eq!(report.tally().findings, found);
    assert_eq!(report.failing(false), 0);
    assert_eq!(report.failing(true), 0, "advisory under --strict too");
}

/// A `[bundles.<name>]` body key no reader reads is a set that carries
/// nothing, and the check says so: kendex's own four sets were written with
/// a `members = [...]` list, installed nothing, and every check ran green.
#[test]
#[allow(clippy::unwrap_used)]
fn a_bundle_key_no_reader_reads_is_breakage() {
    let (_tmp, root) = repo();
    skill_at(&root, "skills", "gh");
    fs::write(
        root.join("kendex.toml"),
        "[bundles.starter]\ndescription = \"the basics\"\nmembers = [\"skill/gh\"]\n",
    )
    .unwrap();
    let sealed = SealedSource::open(&root).unwrap();
    let report = check(&sealed, "repo").unwrap();
    assert!(report.tally().breakage >= 1);
    assert!(report.failing(false) >= 1, "it fails without --strict too");
    let finding = &report.catalog[0];
    assert_eq!(finding.severity, "error");
    assert!(finding.message.contains("members"), "{}", finding.message);
    assert!(
        finding.message.contains("[bundles.starter]"),
        "{}",
        finding.message
    );
    for list in ["agents", "skills", "commands", "hooks", "mcp-servers"] {
        assert!(finding.fix.contains(list), "{}: {}", list, finding.fix);
    }
}

/// The same catalog with its members under a list the reader reads: no
/// finding, and the set carries the skill. Without this the assertion above
/// would hold just as well for a check that called every catalog broken.
#[test]
#[allow(clippy::unwrap_used)]
fn a_bundle_written_in_the_shape_the_reader_reads_is_clean() {
    let (_tmp, root) = repo();
    skill_at(&root, "skills", "gh");
    fs::write(
        root.join("kendex.toml"),
        "[bundles.starter]\ndescription = \"the basics\"\nskills = [\"gh\"]\n",
    )
    .unwrap();
    let sealed = SealedSource::open(&root).unwrap();
    let report = check(&sealed, "repo").unwrap();
    assert_eq!(report.tally().breakage, 0);
    assert_eq!(report.failing(true), 0);
    let config = kendex_core::source::source_config(&sealed, "repo").unwrap();
    let sets = kendex_core::source::bundles::offered(&sealed, &config).unwrap();
    let members: Vec<&str> = sets[0]
        .members
        .iter()
        .map(|member| member.name.as_str())
        .collect();
    assert_eq!(members, ["gh"]);
}

/// One file is both when a project offers what it installs: `[bundles.<name>]
/// source = "…"` in a project's own kendex.toml records an installed set, and
/// reading it as a malformed catalog set would make the project unreadable as
/// a source of its own skills.
#[test]
#[allow(clippy::unwrap_used)]
fn an_installed_set_recorded_beside_the_catalog_is_not_a_malformed_set() {
    let (_tmp, root) = repo();
    skill_at(&root, "skills", "gh");
    fs::write(
        root.join("kendex.toml"),
        "schema = 6\n\n[bundles.starter]\nsource = \"cat\"\n",
    )
    .unwrap();
    let sealed = SealedSource::open(&root).unwrap();
    let report = check(&sealed, "repo").unwrap();
    assert_eq!(report.tally().breakage, 0, "{:?}", report.catalog);
    let names: Vec<&str> = report.items.iter().map(|item| item.name.as_str()).collect();
    assert_eq!(names, ["gh"], "the catalog still offers its own skills");
}
