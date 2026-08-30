//! The install seam: every supported kind declarable through `add`, Pi
//! extensions carrier-only, bare names found by searching every
//! subscription, and install-all folding in the members it accounts for.
#![cfg(unix)]

#[path = "../../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::ops;
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::manifest::{self, ManifestFile};
use kendex_core::model::Scope;

mod bundles;
mod naming;

pub struct Fixture {
    pub _tmp: tempfile::TempDir,
    pub env: Env,
    pub scope: Scope,
    pub project: PathBuf,
    pub home: PathBuf,
}

#[allow(clippy::unwrap_used)]
pub fn world() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        home,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
pub fn write(root: &Path, rel: &str, text: &str) {
    let path = root.join(rel);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

pub fn skill(catalog: &Path, name: &str) {
    write(
        catalog,
        &format!("skills/{name}/SKILL.md"),
        &format!("---\nname: {name}\ndescription: the {name} skill\n---\nBody.\n"),
    );
}

pub fn agent(catalog: &Path, name: &str) {
    write(
        catalog,
        &format!("agents/{name}.md"),
        &format!("---\nname: {name}\ndescription: does {name} things\n---\n\nGo.\n"),
    );
}

/// A project manifest subscribed to these path catalogs, claude-only.
pub fn manifest_with(f: &Fixture, sources: &[(&str, &Path)], declarations: &str) {
    let subscriptions: String = sources
        .iter()
        .map(|(alias, path)| format!("[sources.{alias}]\n{}\n\n", source_path(&path)))
        .collect();
    write(
        &f.project,
        "kendex.toml",
        &format!(
            "schema = 6\n\n{subscriptions}[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n{declarations}"
        ),
    );
}

#[allow(clippy::unwrap_used)]
pub fn manifest_of(f: &Fixture) -> kendex_core::manifest::Manifest {
    match manifest::load(&manifest::manifest_path(&f.env, &f.scope)).unwrap() {
        ManifestFile::Current(manifest) => *manifest,
        other => panic!("expected a current manifest, got {other:?}"),
    }
}

#[allow(clippy::unwrap_used)]
pub fn add_and_apply(f: &Fixture, request: &ops::AddRequest) -> kendex_core::engine::EngineReport {
    let report = ops::add(&f.env, &f.scope, request).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    report
}

/// A catalog carrying one item of every fixed-dir kind.
pub fn full_catalog(f: &Fixture, name: &str) -> PathBuf {
    let catalog = f.home.join(name);
    skill(&catalog, "gh");
    agent(&catalog, "writer");
    write(
        &catalog,
        "hooks/guard.sh",
        "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: block dangerous commands\n# ---\nexit 0\n",
    );
    write(&catalog, "commands/ship.md", "Ship the branch.\n");
    write(
        &catalog,
        "mcp/gh.toml",
        "command = \"gh-mcp\"\nargs = [\"--stdio\"]\n",
    );
    // Executable kinds install only from a catalog that declares kendex's layout.
    write(&catalog, "kendex.toml", "is_source_catalog = true\n");
    catalog
}

/// The whole matrix through one declaration path: a hook, a command and an
/// MCP server each declare from a named catalog through `add`, install,
/// and come back off with `remove` — no kind needs a hand-written
/// manifest edit anymore.
#[test]
#[allow(clippy::unwrap_used)]
fn hook_command_and_mcp_server_round_trip_through_add_and_remove() {
    let f = world();
    let catalog = full_catalog(&f, "catalog");
    manifest_with(&f, &[("cat", &catalog)], "");

    add_and_apply(
        &f,
        &ops::AddRequest {
            source: Some("cat".to_owned()),
            hooks: vec!["guard".into()],
            commands: vec!["ship".into()],
            mcp_servers: vec!["gh".into()],
            ..ops::AddRequest::default()
        },
    );

    let manifest = manifest_of(&f);
    assert_eq!(manifest.hooks["guard"].source, "cat");
    assert_eq!(manifest.commands["ship"].source, "cat");
    assert_eq!(manifest.mcp_servers["gh"].source, "cat");
    assert!(f.project.join(".claude/hooks/guard.sh").is_file());
    assert!(f.project.join(".claude/commands/ship.md").exists());
    let mcp = fs::read_to_string(f.project.join(".mcp.json")).unwrap();
    assert!(mcp.contains("gh-mcp"), "{mcp}");

    let report = ops::remove(
        &f.env,
        &f.scope,
        &["guard".to_owned(), "ship".to_owned(), "gh".to_owned()],
        None,
        false,
    )
    .unwrap();
    apply::execute(&f.env, &report.plan).unwrap();

    let manifest = manifest_of(&f);
    assert!(manifest.hooks.is_empty() && manifest.commands.is_empty());
    assert!(manifest.mcp_servers.is_empty());
    assert!(!f.project.join(".claude/hooks/guard.sh").exists());
    assert!(!f.project.join(".claude/commands/ship.md").exists());
    let mcp = fs::read_to_string(f.project.join(".mcp.json")).unwrap_or_default();
    assert!(!mcp.contains("gh-mcp"), "{mcp}");
}

/// Pi extensions are carrier-only: asking for one directly is refused with
/// the carrier explanation, and nothing is written.
#[test]
#[allow(clippy::unwrap_used)]
fn a_direct_pi_extension_add_refuses_naming_the_carrier() {
    let f = world();
    let catalog = full_catalog(&f, "catalog");
    manifest_with(&f, &[("cat", &catalog)], "");
    let before = fs::read_to_string(f.project.join("kendex.toml")).unwrap();

    let error = ops::add(
        &f.env,
        &f.scope,
        &ops::AddRequest {
            source: Some("cat".to_owned()),
            pi_extensions: vec!["@vanillagreen/pi-hooks".into()],
            ..ops::AddRequest::default()
        },
    )
    .unwrap_err();

    assert!(
        matches!(error, CoreError::PiExtensionDirect { ref name } if name == "@vanillagreen/pi-hooks"),
        "expected the carrier refusal, got {error}"
    );
    assert!(
        error.to_string().contains("not installable on its own"),
        "{error}"
    );
    assert_eq!(
        fs::read_to_string(f.project.join("kendex.toml")).unwrap(),
        before,
        "a refusal writes nothing"
    );
}
