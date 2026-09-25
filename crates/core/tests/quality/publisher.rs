//! Whose item an accepted finding is honoured for, on every path that
//! scores: the preview of a catalog, the plan, and the audit over what is
//! installed. One kendex package with an accepted finding, served from
//! kendex's own repository and from a fork holding the same bytes.

use crate::test_util;
use test_util::rooted;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::{audit, observed_rows};
use kendex_core::env::{Env, FakeOs};
use kendex_core::manifest;
use kendex_core::model::{ItemKind, Scope};
use kendex_core::process::Hardened;
use kendex_core::quality::Finding;
use kendex_core::remote;
use kendex_core::source::browse::{Catalog, package_safety};

/// The kendex package with one accepted finding whose only required
/// companion is one package, so a stub of that companion completes the
/// closure the plan installs.
const PACKAGE: &str = "harness-ci";
const COMPANION: &str = "orch";
const ACCEPTED_AT: &str = "references/wiring.md";

const KENDEX: &str = kendex_core::manifest::DEFAULT_SOURCE_REPO;
const FORK: &str = "someone/kendex";

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    home: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let output = Hardened::git(args, Some(dir)).run().unwrap();
    assert!(output.status.success(), "git {args:?}");
}

#[allow(clippy::unwrap_used)]
fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        match entry.file_type().unwrap().is_dir() {
            true => copy_tree(&entry.path(), &target),
            false => {
                fs::copy(entry.path(), &target).unwrap();
            }
        }
    }
}

/// A repository at `repo` under the fake git base, holding this
/// repository's own copy of the package and a stub of its companion.
#[allow(clippy::unwrap_used)]
fn publish(home: &Path, repo: &str) {
    let upstream = home.join("git").join(repo);
    let shipped = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../skills");
    copy_tree(
        &shipped.join(PACKAGE),
        &upstream.join("skills").join(PACKAGE),
    );
    let companion = upstream.join("skills").join(COMPANION);
    fs::create_dir_all(&companion).unwrap();
    fs::write(
        companion.join("SKILL.md"),
        format!("---\nname: {COMPANION}\ndescription: stands in for {COMPANION}\n---\n\nA stub.\n"),
    )
    .unwrap();
    fs::write(upstream.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    git(&upstream, &["add", "-A"]);
    git(
        &upstream,
        &[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "--quiet",
            "-m",
            "one",
        ],
    );
}

/// A home whose fake git base serves the package from kendex's own
/// repository and from a fork, byte for byte the same.
#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    publish(&home, KENDEX);
    publish(&home, FORK);
    fs::create_dir_all(home.join(".claude")).unwrap();
    let base = format!("file://{}", home.join("git").display());
    World {
        env: Env::fake(&home, FakeOs::Linux).with_var("KENDEX_GIT_BASE", &base),
        home,
        _tmp: tmp,
    }
}

/// A project declaring the package from `repo`, synced.
#[allow(clippy::unwrap_used)]
fn project(w: &World, dir: &str, repo: &str) -> Scope {
    let root = w.home.join(dir);
    fs::create_dir_all(root.join(".claude")).unwrap();
    fs::write(
        root.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{repo}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.{PACKAGE}]\nsource = \"cat\"\n"
        ),
    )
    .unwrap();
    let scope = Scope::Project { root };
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();
    scope
}

fn at_accepted(findings: &[Finding]) -> Vec<&str> {
    findings
        .iter()
        .filter(|finding| finding.location.ends_with(ACCEPTED_AT))
        .map(|finding| finding.rule.as_str())
        .collect()
}

/// Where the package's one accepted finding stands in a result: the rules
/// that fired on it among the findings, and among the accepted.
type Standing<'a> = (Vec<&'a str>, Vec<&'a str>);

fn standing(advisory: &kendex_core::quality::AuditResult) -> Standing<'_> {
    (
        at_accepted(&advisory.findings),
        at_accepted(&advisory.accepted),
    )
}

/// The preview, the plan and the installed audit all set the finding
/// aside for kendex's own copy, and all keep it for the fork's: the bytes
/// are the same, and the table is honoured by source, never by content.
#[test]
#[allow(clippy::unwrap_used)]
fn every_path_honours_the_table_for_kendex_and_for_nobody_else() {
    let w = world();
    let rows: [(&str, &str, Standing<'_>); 2] = [
        ("kendex", KENDEX, (vec![], vec!["rce"])),
        ("fork", FORK, (vec!["rce"], vec![])),
    ];
    for (dir, repo, expected) in rows {
        let scope = project(&w, dir, repo);
        let preview = package_safety(
            &w.env,
            &Catalog::Subscription {
                scope: scope.clone(),
                source: "cat".to_owned(),
            },
            ItemKind::Skill,
            PACKAGE,
            None,
        )
        .unwrap();
        assert_eq!(standing(&preview.advisory), expected, "{dir}: preview");

        let report = audit(&w.env, &scope).unwrap();
        let planned = report
            .safety
            .iter()
            .find(|row| row.name == PACKAGE)
            .unwrap_or_else(|| panic!("{dir}: no plan row for {PACKAGE}: {:#?}", report.notes));
        assert_eq!(standing(&planned.advisory), expected, "{dir}: plan");

        apply::execute(&w.env, &report.plan).unwrap();
        let installed = observed_rows(&w.env, &scope).unwrap();
        let row = installed.iter().find(|row| row.name == PACKAGE).unwrap();
        assert_eq!(standing(&row.advisory), expected, "{dir}: installed");
    }
}

/// A copy nothing declared is nobody's: the same tree kendex's install
/// wrote, placed by hand in a project with no record, keeps its finding.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hand_placed_copy_of_kendexs_own_install_keeps_its_finding() {
    let w = world();
    let scope = project(&w, "app", KENDEX);
    let report = audit(&w.env, &scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
    let Scope::Project { root } = &scope else {
        unreachable!("a project scope");
    };
    let installed = root.join(".claude/skills").join(PACKAGE);
    assert!(
        installed.join("SKILL.md").exists(),
        "{}",
        installed.display()
    );

    let elsewhere = w.home.join("elsewhere");
    copy_tree(&installed, &elsewhere.join(".claude/skills").join(PACKAGE));
    let rows = observed_rows(
        &w.env,
        &Scope::Project {
            root: elsewhere.clone(),
        },
    )
    .unwrap();
    let row = rows
        .iter()
        .find(|row| row.name == PACKAGE)
        .unwrap_or_else(|| panic!("no row for the copy: {rows:#?}"));
    assert_eq!(
        standing(&row.advisory),
        (vec!["rce"], vec![]),
        "{:#?}",
        row.advisory
    );
}
