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
        assert_eq!(package.safety.verdict, item.verdict);
        assert_eq!(package.safety.score, item.score);
    }
}

/// A committed review record settles a finding: the item stops being held
/// back, the finding is still reported (marked dismissed), and editing the
/// item's content makes the record stale so the hold comes back.
#[test]
#[allow(clippy::unwrap_used)]
fn a_committed_dismissal_unblocks_until_the_content_moves() {
    use kendex_core::check_catalog::dismissals;
    use kendex_core::quality::Verdict;

    let (_tmp, root) = repo();
    let dir = root.join("skills/guardy");
    fs::create_dir_all(&dir).unwrap();
    let body = "---\nname: guardy\ndescription: a commit guard\n---\nIf the hook blocks a commit, `git commit --no-verify` is the deliberate bypass.\n";
    fs::write(dir.join("SKILL.md"), body).unwrap();
    fs::write(root.join("kendex.toml"), "[marketplace]\nname = \"demo\"\n").unwrap();

    let sealed = SealedSource::open(&root).unwrap();
    let report = check(&sealed, "repo").unwrap();
    let item = &report.items[0];
    assert_eq!(item.verdict, Verdict::Block);
    let token = item
        .findings
        .iter()
        .find_map(|finding| finding.token.clone())
        .unwrap();
    let (kind, name, fingerprint) = dismissals::parse_token(&token).unwrap();
    assert_eq!(kind, ItemKind::Skill);
    assert_eq!(name, "guardy");

    let hash = dismissals::content_hash(&sealed, &dir).unwrap();
    dismissals::record(
        &sealed,
        kind,
        name,
        &hash,
        &[(
            fingerprint.to_owned(),
            kendex_core::quality::reviews::DismissReason::Intended,
        )],
    )
    .unwrap();

    // Re-open so the reviews file is inside the sealed root's view.
    let sealed = SealedSource::open(&root).unwrap();
    let report = check(&sealed, "repo").unwrap();
    let item = &report.items[0];
    assert_ne!(
        item.verdict,
        Verdict::Block,
        "the reviewed finding no longer holds the item back"
    );
    let settled = item
        .findings
        .iter()
        .find(|finding| finding.token.as_deref() == Some(token.as_str()))
        .unwrap();
    assert!(
        settled.dismissed,
        "the finding is still reported, marked dismissed"
    );

    // The content moves: the snapshot is stale and the hold returns.
    fs::write(dir.join("SKILL.md"), format!("{body}\nOne more line.\n")).unwrap();
    let report = check(&sealed, "repo").unwrap();
    assert_eq!(report.items[0].verdict, Verdict::Block);
}

/// Tokens parse only in their printed shape.
#[test]
fn authoring_tokens_parse_in_their_printed_shape() {
    use kendex_core::check_catalog::dismissals::parse_token;
    assert_eq!(
        parse_token("skill:guardy#abc123"),
        Some((ItemKind::Skill, "guardy", "abc123"))
    );
    assert_eq!(parse_token("skill:guardy"), None);
    assert_eq!(parse_token("skill:#abc"), None);
    assert_eq!(parse_token("nonsense:guardy#abc"), None);
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
