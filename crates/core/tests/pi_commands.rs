//! Pi as a managed tool for commands: a declared command installs as the
//! prompt template Pi reads, byte for byte, at either scope; switches off by
//! the rename Pi's `.md`-only discovery makes safe; comes off disk on
//! request; and is read back from the same directory.
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

const SHIP: &str = "---\ndescription: Ship the branch\nargument-hint: \"<branch>\"\n---\n\nRelease $1 with $ARGUMENTS.\n";

const INLINED: &str = "---\ndescription: Show the diff\n---\n\n- Staged changes: !`git diff --cached`\n\nReview them.\n";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
    source: PathBuf,
}

/// A Pi-only project whose catalog carries two commands; `declarations` is
/// appended to the manifest verbatim.
#[allow(clippy::unwrap_used)]
fn fixture(declarations: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".pi")).unwrap();
    fs::create_dir_all(home.join(".pi/agent")).unwrap();

    let source = home.join("catalog");
    fs::create_dir_all(source.join("commands")).unwrap();
    fs::write(source.join("commands/ship.md"), SHIP).unwrap();
    fs::write(source.join("commands/diff.md"), INLINED).unwrap();
    fs::write(source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();

    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"pi\"]\nmethod = \"symlink\"\n\n{declarations}",
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

/// The command names Pi's scan reports for a scope, with their switch.
fn scanned(f: &Fixture, scope: &Scope) -> Vec<(String, Option<bool>)> {
    let scanned = kendex_core::scan::scan_scopes(
        &f.env,
        &std::collections::BTreeMap::new(),
        std::slice::from_ref(scope),
    );
    scanned
        .items
        .iter()
        .filter(|item| item.harness == HarnessId::Pi && item.kind == ItemKind::Command)
        .map(|item| (item.name.clone(), item.enabled))
        .collect()
}

/// Pi reads the author's frontmatter and placeholders as written, so the
/// file installs untouched; only `.md` loads from `prompts/`, so parking it
/// under `.disabled` is the switch.
#[test]
#[allow(clippy::unwrap_used)]
fn a_command_installs_as_the_projects_prompt_template_and_toggles_by_rename() {
    let f = fixture("[commands.ship]\nsource = \"cat\"\n");
    let report = apply_now(&f);
    assert_eq!(report.warnings, Vec::new(), "nothing to warn about in SHIP");

    let file = f.project.join(".pi/prompts/ship.md");
    assert_eq!(fs::read_to_string(&file).unwrap(), SHIP);
    assert!(is_clean(&f));
    assert_eq!(scanned(&f, &f.scope), [("ship".to_owned(), Some(true))]);

    toggle(&f, "ship", false);
    assert!(!file.exists());
    let parked = f.project.join(".pi/prompts/ship.md.disabled");
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
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"pi\"]\nmethod = \"symlink\"\n\n[commands.ship]\nsource = \"cat\"\n",
            source_path(&f.source)
        ),
    )
    .unwrap();

    let report = audit(&f.env, &Scope::Global).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();

    let file = f.env.home.join(".pi/agent/prompts/ship.md");
    assert_eq!(fs::read_to_string(&file).unwrap(), SHIP);
    assert!(audit(&f.env, &Scope::Global).unwrap().drift.is_empty());
    assert_eq!(
        scanned(&f, &Scope::Global),
        [("ship".to_owned(), Some(true))]
    );
}

/// Pi expands positional placeholders and nothing else, so a Claude-style
/// shell inline installs and is said to reach the model as text.
#[test]
#[allow(clippy::unwrap_used)]
fn a_shell_inline_installs_with_a_warning() {
    let f = fixture("[commands.diff]\nsource = \"cat\"\n");
    let report = apply_now(&f);

    assert_eq!(
        fs::read_to_string(f.project.join(".pi/prompts/diff.md")).unwrap(),
        INLINED
    );
    let warned: Vec<_> = report
        .warnings
        .iter()
        .map(|w| (w.kind, w.name.as_str(), w.harness, w.message.as_str()))
        .collect();
    assert_eq!(
        warned,
        [(
            ItemKind::Command,
            "diff",
            Some(HarnessId::Pi),
            "the command runs a shell inline with !`…`, which Pi does not expand — the model reads the backticked command as text",
        )]
    );
}
