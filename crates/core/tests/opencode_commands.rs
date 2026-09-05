//! OpenCode as a managed tool for commands: a declared command installs as
//! the markdown OpenCode reads, byte for byte, at either scope; switches off
//! by the rename its `.md`-only glob makes safe; comes off disk on request;
//! is read back from the same directory; and the name is the filename, with
//! no rule of the loader's to answer to.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::engine::{EngineReport, audit, ops};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{HarnessId, ItemKind, Scope};

const SHIP: &str = "---\ndescription: Ship the branch\nagent: build\n---\n\nRelease $1 with $ARGUMENTS.\n\n!`git status --short`\n";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
    source: PathBuf,
}

/// An OpenCode-only project whose catalog carries the `ship` command under
/// two spellings; `declarations` is appended to the manifest verbatim.
#[allow(clippy::unwrap_used)]
fn fixture(declarations: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".opencode")).unwrap();
    fs::create_dir_all(home.join(".config/opencode")).unwrap();

    let source = home.join("catalog");
    fs::create_dir_all(source.join("commands")).unwrap();
    fs::write(source.join("commands/ship.md"), SHIP).unwrap();
    fs::write(source.join("commands/Ship_It.md"), SHIP).unwrap();
    fs::write(source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();

    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"opencode\"]\nmethod = \"symlink\"\n\n{declarations}",
            source_path(&source)
        ),
    )
    .unwrap();

    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        source,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn apply_now(f: &Fixture) -> EngineReport {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    report
}

#[allow(clippy::unwrap_used)]
fn toggle(f: &Fixture, name: &str, enabled: bool) {
    let report = ops::toggle(&f.env, &f.scope, &[name.to_owned()], None, enabled).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
}

#[allow(clippy::unwrap_used)]
fn remove(f: &Fixture, name: &str) {
    let report = ops::remove(&f.env, &f.scope, &[name.to_owned()], None, false).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
}

#[allow(clippy::unwrap_used)]
fn is_clean(f: &Fixture) -> bool {
    audit(&f.env, &f.scope).unwrap().drift.is_empty()
}

/// The command names OpenCode's scan reports for a scope, with their switch.
fn scanned(f: &Fixture, scope: &Scope) -> Vec<(String, Option<bool>)> {
    let scanned = kendex_core::scan::scan_scopes(
        &f.env,
        &std::collections::BTreeMap::new(),
        std::slice::from_ref(scope),
    );
    scanned
        .items
        .iter()
        .filter(|item| item.harness == HarnessId::Opencode && item.kind == ItemKind::Command)
        .map(|item| (item.name.clone(), item.enabled))
        .collect()
}

/// OpenCode reads the author's frontmatter and expands the same placeholders
/// Claude does, so the file installs untouched; only `*.md` matches its glob,
/// so parking it under `.disabled` is the switch.
#[test]
#[allow(clippy::unwrap_used)]
fn a_command_installs_into_the_projects_commands_dir_and_toggles_by_rename() {
    let f = fixture("[commands.ship]\nsource = \"cat\"\n");
    let report = apply_now(&f);
    assert_eq!(report.warnings, Vec::new(), "nothing to warn about in SHIP");

    let file = f.project.join(".opencode/commands/ship.md");
    assert_eq!(fs::read_to_string(&file).unwrap(), SHIP);
    assert!(is_clean(&f));
    assert_eq!(scanned(&f, &f.scope), [("ship".to_owned(), Some(true))]);

    toggle(&f, "ship", false);
    assert!(!file.exists());
    let parked = f.project.join(".opencode/commands/ship.md.disabled");
    assert_eq!(fs::read_to_string(&parked).unwrap(), SHIP);
    assert!(is_clean(&f));
    assert_eq!(scanned(&f, &f.scope), [("ship".to_owned(), Some(false))]);

    toggle(&f, "ship", true);
    assert!(file.is_file() && !parked.exists());

    remove(&f, "ship");
    assert!(!file.exists() && !parked.exists());
    assert!(is_clean(&f));
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_command_installs_under_the_global_root_too() {
    let f = fixture("");
    let manifest = f.env.global_manifest_file();
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    fs::write(
        &manifest,
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"opencode\"]\nmethod = \"symlink\"\n\n[commands.ship]\nsource = \"cat\"\n",
            source_path(&f.source)
        ),
    )
    .unwrap();

    let report = audit(&f.env, &Scope::Global).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();

    let file = f.env.home.join(".config/opencode/commands/ship.md");
    assert_eq!(fs::read_to_string(&file).unwrap(), SHIP);
    assert!(audit(&f.env, &Scope::Global).unwrap().drift.is_empty());
    assert_eq!(
        scanned(&f, &Scope::Global),
        [("ship".to_owned(), Some(true))]
    );
}

/// OpenCode's command loader keys on the filename alone, with no case or
/// character rule, so a name the skill rule would refuse installs as it is.
#[test]
#[allow(clippy::unwrap_used)]
fn a_name_outside_the_skill_rule_still_installs_as_the_loader_reads_it() {
    let f = fixture("[commands.Ship_It]\nsource = \"cat\"\n");
    let report = apply_now(&f);
    assert_eq!(report.warnings, Vec::new());
    assert_eq!(
        fs::read_to_string(f.project.join(".opencode/commands/Ship_It.md")).unwrap(),
        SHIP
    );
    assert!(is_clean(&f));
    assert_eq!(scanned(&f, &f.scope), [("Ship_It".to_owned(), Some(true))]);
}
