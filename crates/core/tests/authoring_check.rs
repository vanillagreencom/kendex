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

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

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

/// Every `[bundles.<name>]` body shape this reader will not read is that
/// set's breakage: a plain check fails on it, naming the set and the part it
/// could not read, while the set beside it and every item the catalog offers
/// are untouched. kendex's own four sets shipped the unknown-key shape — a
/// `members` list nothing read — and installed nothing with every check
/// green; the member-list shapes shipped fewer members than they were
/// written with, and the non-table body shipped no set at all.
#[test]
#[allow(clippy::unwrap_used)]
fn every_unreadable_set_body_is_reported_and_costs_the_catalog_nothing() {
    // Each row is the broken `starter` body, the substring the finding has to
    // name so the author is sent to the part that will not read, and what
    // the fix has to spell out to be actionable.
    const LISTS: &[&str] = &["agents", "skills", "commands", "hooks", "mcp-servers"];
    const REWRITE: &[&str] = &["array of strings"];
    let rows: [(&str, &str, &[&str]); 6] = [
        (
            "[bundles.starter]\nmembers = [\"skill/gh\"]\n",
            "members",
            LISTS,
        ),
        (
            "[bundles]\nstarter = \"the starter set\"\n",
            "is not a table",
            LISTS,
        ),
        ("[bundles.starter]\nskills = \"gh\"\n", "`skills`", REWRITE),
        (
            "[bundles.starter]\nskills = [[\"gh\"]]\n",
            "`skills`",
            REWRITE,
        ),
        (
            "[bundles.starter]\nskills = { a = \"gh\" }\n",
            "`skills`",
            REWRITE,
        ),
        (
            "[bundles.starter]\nskills = [\"gh\", 3]\n",
            "`skills`",
            REWRITE,
        ),
    ];
    for (body, named, fix_names) in rows {
        let (_tmp, root) = repo();
        skill_at(&root, "skills", "gh");
        fs::write(
            root.join("kendex.toml"),
            format!("{body}\n[bundles.other]\nskills = [\"gh\"]\n"),
        )
        .unwrap();
        let sealed = SealedSource::open(&root).unwrap();
        let report = check(&sealed, "repo").unwrap();
        assert!(report.failing(false) >= 1, "the check passed it: {body}");
        let finding = &report.catalog[0];
        assert_eq!(finding.severity, "error", "{body}: {}", finding.message);
        assert!(
            finding.message.contains(named),
            "{body}: {}",
            finding.message
        );
        assert!(
            finding.message.contains("[bundles.starter]"),
            "{body}: {}",
            finding.message
        );
        for wanted in fix_names {
            assert!(
                finding.fix.contains(wanted),
                "{body}: {wanted}: {}",
                finding.fix
            );
        }
        let names: Vec<&str> = report.items.iter().map(|item| item.name.as_str()).collect();
        assert_eq!(
            names,
            ["gh"],
            "{body}: the catalog stopped offering its item"
        );
        let config = kendex_core::source::source_config(&sealed, "repo").unwrap();
        let sets: Vec<String> = kendex_core::source::bundles::offered(&sealed, &config)
            .unwrap()
            .iter()
            .map(|set| set.name.clone())
            .collect();
        assert_eq!(sets, ["other"], "{body}: the set beside it went too");
    }
}

/// The must-fail counterpart: the same catalog with a table body, known keys
/// and its members under a list of names is clean, under `--strict` too, and
/// offers every member it was written with. Without it the control above
/// would hold for a check that called every catalog broken, and for a reader
/// that answered the malformed shapes by dropping members.
#[test]
#[allow(clippy::unwrap_used)]
fn a_bundle_written_in_the_shape_the_reader_reads_is_clean() {
    let (_tmp, root) = repo();
    skill_at(&root, "skills", "gh");
    skill_at(&root, "skills", "linear");
    fs::write(
        root.join("kendex.toml"),
        "[bundles.starter]\ndescription = \"the basics\"\nskills = [\"gh\", \"linear\"]\n",
    )
    .unwrap();
    let sealed = SealedSource::open(&root).unwrap();
    let report = check(&sealed, "repo").unwrap();
    assert_eq!(report.failing(true), 0, "{:?}", report.catalog);
    let config = kendex_core::source::source_config(&sealed, "repo").unwrap();
    let sets = kendex_core::source::bundles::offered(&sealed, &config).unwrap();
    let members: Vec<&str> = sets[0]
        .members
        .iter()
        .map(|member| member.name.as_str())
        .collect();
    assert_eq!(members, ["gh", "linear"], "a member was dropped");
}

/// Catalog authors can leave renamed or removed items in any member list.
#[test]
#[allow(clippy::unwrap_used)]
fn every_unoffered_bundle_member_is_breakage() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    skill_at(&root, "skills", "gh");
    fs::write(
        root.join("kendex.toml"),
        "[bundles.starter]\nskills = [\"gh\", \"gone-skill\"]\n\
         agents = [\"gone-agent\"]\nhooks = [\"gone-hook\"]\n\
         commands = [\"gone-command\"]\nmcp-servers = [\"gone-mcp\"]\n\
         [bundles.other]\nskills = [\"gh\"]\n",
    )
    .unwrap();
    let sealed = SealedSource::open(&root).unwrap();
    let report = check(&sealed, "repo").unwrap();
    let missing = [
        "gone-agent",
        "gone-skill",
        "gone-command",
        "gone-hook",
        "gone-mcp",
    ];
    assert_eq!(report.catalog.len(), missing.len());
    assert_eq!(report.tally().breakage, missing.len());
    assert_eq!(report.failing(false), missing.len());
    assert_eq!(report.failing(true), missing.len());
    for (finding, member) in report.catalog.iter().zip(missing) {
        assert_eq!(finding.name, "starter");
        assert_eq!(finding.kind, "bundle");
        assert_eq!(finding.pass, "catalog");
        assert_eq!(finding.file, "kendex.toml");
        assert_eq!(finding.severity, "error");
        assert!(finding.rule.is_none());
        assert!(finding.message.contains("starter"), "{finding:?}");
        assert!(finding.message.contains(member), "{finding:?}");
    }
    assert_eq!(report.items.len(), 1);
    assert_eq!(report.items[0].name, "gh");
}

/// A project's own kendex.toml is both manifest and catalog once `kendex
/// init` writes the marker into it, so this reader meets the manifest's own
/// `[bundles.<name>]` records. A record carries whatever `kendex add
/// --bundle <set> --harness <tool>` wrote beside `source` — `harnesses`, and
/// `method`, `rev` or `enabled` when set — and reading those as a set's own
/// breakage would fail the project's check on its own install record and
/// stop that source sweeping orphans, while the set it really offers is
/// untouched.
#[test]
#[allow(clippy::unwrap_used)]
fn a_projects_own_install_record_is_not_its_catalogs_breakage() {
    let (_tmp, root) = repo();
    skill_at(&root, "skills", "gh");
    fs::write(
        root.join("kendex.toml"),
        "is_source_catalog = true\n\n[bundles.offered]\nskills = [\"gh\"]\n\n\
         [bundles.installed]\nsource = \"cat\"\nharnesses = [\"claude\"]\n\
         method = \"copy\"\nrev = \"9f2c\"\nenabled = false\n",
    )
    .unwrap();
    let sealed = SealedSource::open(&root).unwrap();
    let report = check(&sealed, "repo").unwrap();
    assert_eq!(report.failing(false), 0, "{:?}", report.catalog);
    let config = kendex_core::source::source_config(&sealed, "repo").unwrap();
    assert!(
        !config.hides_content(),
        "the project stopped sweeping its own orphans"
    );
    let sets: Vec<String> = kendex_core::source::bundles::offered(&sealed, &config)
        .unwrap()
        .iter()
        .map(|set| set.name.clone())
        .collect();
    assert_eq!(sets, ["offered"], "an install record is not a set on offer");
}

/// The must-fail counterpart: the same record with a member list beside its
/// `source` is a set on offer written wrong, not a record, and the check
/// fails on it. Without this the control above would hold for a reader that
/// waved through every key a manifest record can carry, wherever it sat.
#[test]
#[allow(clippy::unwrap_used)]
fn a_source_beside_a_member_list_is_still_that_sets_breakage() {
    let (_tmp, root) = repo();
    skill_at(&root, "skills", "gh");
    fs::write(
        root.join("kendex.toml"),
        "is_source_catalog = true\n\n[bundles.installed]\nsource = \"cat\"\nskills = [\"gh\"]\n",
    )
    .unwrap();
    let sealed = SealedSource::open(&root).unwrap();
    let report = check(&sealed, "repo").unwrap();
    assert!(report.failing(false) >= 1, "{:?}", report.catalog);
}
