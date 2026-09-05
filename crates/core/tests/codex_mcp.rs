//! Codex as a managed tool for MCP servers: a declared server lands as its
//! own `[mcp_servers.<name>]` table in the scope's `config.toml`, the user's
//! comments and other tables kept as they were; switches off on the table
//! itself; comes out on request; and a transport Codex does not speak is
//! refused before anything is written.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::{EngineReport, audit, ops};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{HarnessId, ItemKind, Scope};

const GH_MCP: &str =
    "command = \"gh-mcp\"\nargs = [\"--stdio\"]\n[env]\nGH_TOKEN = \"$GH_TOKEN\"\n";
const RENAMED_MCP: &str = "command = \"gh-mcp\"\n[env]\nGITHUB_TOKEN = \"$GH_TOKEN\"\n";
const DOCS_MCP: &str = "transport = \"http\"\nurl = \"https://mcp.example/docs\"\n";
const LEGACY_MCP: &str = "transport = \"sse\"\nurl = \"https://mcp.example/sse\"\n";

/// What the user already keeps in the project's file: a comment, a model, a
/// feature flag with a trailing comment, and a server of their own.
const THEIRS: &str = "# the user's file\nmodel = \"gpt-6-astra\"\n\n[features]\nhooks = true # keep\n\n[mcp_servers.other]\ncommand = \"x\"\n";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
    source: PathBuf,
}

/// A Codex-only project whose catalog carries three servers, one per
/// transport; `declarations` is appended to the manifest verbatim.
#[allow(clippy::unwrap_used)]
fn fixture(declarations: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".codex")).unwrap();
    fs::create_dir_all(home.join(".codex")).unwrap();

    let source = home.join("catalog");
    fs::create_dir_all(source.join("mcp")).unwrap();
    fs::write(source.join("mcp/gh.toml"), GH_MCP).unwrap();
    fs::write(source.join("mcp/docs.toml"), DOCS_MCP).unwrap();
    fs::write(source.join("mcp/legacy.toml"), LEGACY_MCP).unwrap();
    fs::write(source.join("mcp/renamed.toml"), RENAMED_MCP).unwrap();
    fs::write(source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();

    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"codex\"]\nmethod = \"symlink\"\n\n{declarations}",
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
fn table(path: &Path) -> toml::Table {
    fs::read_to_string(path).unwrap().parse().unwrap()
}

#[allow(clippy::unwrap_used)]
fn is_clean(f: &Fixture) -> bool {
    audit(&f.env, &f.scope).unwrap().drift.is_empty()
}

/// The server names Codex's scan reports for a scope, with their switch.
fn scanned(f: &Fixture, scope: &Scope) -> Vec<(String, Option<bool>)> {
    let scanned = kendex_core::scan::scan_scopes(
        &f.env,
        &std::collections::BTreeMap::new(),
        std::slice::from_ref(scope),
    );
    let mut rows: Vec<_> = scanned
        .items
        .iter()
        .filter(|item| item.harness == HarnessId::Codex && item.kind == ItemKind::McpServer)
        .map(|item| (item.name.clone(), item.enabled))
        .collect();
    rows.sort();
    rows
}

/// A stdio server is a table whose `env` references become `env_vars`, a url server a table
/// holding `url` and no `type`; the user's comment, model, feature flag and
/// own server survive byte for byte. Off writes `enabled = false` on the
/// table and on takes it away, so the declaration stays until removal.
#[test]
#[allow(clippy::unwrap_used)]
fn a_server_is_its_own_table_beside_the_users_and_toggles_on_the_table() {
    let f = fixture("[mcp-servers.gh]\nsource = \"cat\"\n\n[mcp-servers.docs]\nsource = \"cat\"\n");
    let config = f.project.join(".codex/config.toml");
    fs::write(&config, THEIRS).unwrap();
    let report = apply_now(&f);
    assert_eq!(report.warnings, Vec::new());

    let text = fs::read_to_string(&config).unwrap();
    assert!(text.starts_with(THEIRS), "{text}");
    let installed = table(&config);
    let gh = &installed["mcp_servers"]["gh"];
    assert_eq!(gh["command"].as_str(), Some("gh-mcp"));
    assert_eq!(gh["args"][0].as_str(), Some("--stdio"));
    assert_eq!(gh["env_vars"][0].as_str(), Some("GH_TOKEN"));
    assert!(gh.get("env").is_none());
    assert!(gh.get("enabled").is_none());
    let docs = &installed["mcp_servers"]["docs"];
    assert_eq!(docs["url"].as_str(), Some("https://mcp.example/docs"));
    assert!(docs.get("type").is_none());
    assert_eq!(installed["features"]["hooks"].as_bool(), Some(true));
    assert!(is_clean(&f));
    assert_eq!(
        scanned(&f, &f.scope),
        [
            ("docs".to_owned(), Some(true)),
            ("gh".to_owned(), Some(true)),
            ("other".to_owned(), Some(true)),
        ]
    );

    toggle(&f, "gh", false);
    let off = table(&config);
    assert_eq!(off["mcp_servers"]["gh"]["enabled"].as_bool(), Some(false));
    assert_eq!(off["mcp_servers"]["gh"]["command"].as_str(), Some("gh-mcp"));
    assert_eq!(off["mcp_servers"]["other"]["command"].as_str(), Some("x"));
    assert!(is_clean(&f));
    assert_eq!(scanned(&f, &f.scope)[1], ("gh".to_owned(), Some(false)));

    toggle(&f, "gh", true);
    assert_eq!(fs::read_to_string(&config).unwrap(), text);

    remove(&f, "gh");
    let after = fs::read_to_string(&config).unwrap();
    assert!(after.starts_with(THEIRS), "{after}");
    let after = table(&config);
    assert!(after["mcp_servers"].get("gh").is_none(), "{after}");
    assert_eq!(
        after["mcp_servers"]["docs"]["url"].as_str(),
        Some("https://mcp.example/docs")
    );
    assert!(is_clean(&f));
}

/// The global scope writes `config.toml` under Codex's own root, the file
/// `codex mcp add` writes too.
#[test]
#[allow(clippy::unwrap_used)]
fn a_global_server_lands_in_the_users_config_toml() {
    let f = fixture("");
    let manifest = f.env.global_manifest_file();
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    fs::write(
        &manifest,
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"codex\"]\nmethod = \"symlink\"\n\n[mcp-servers.gh]\nsource = \"cat\"\n",
            source_path(&f.source)
        ),
    )
    .unwrap();

    let report = audit(&f.env, &Scope::Global).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();

    let config = f.env.home.join(".codex/config.toml");
    assert_eq!(
        table(&config)["mcp_servers"]["gh"]["command"].as_str(),
        Some("gh-mcp")
    );
    assert!(audit(&f.env, &Scope::Global).unwrap().drift.is_empty());
    assert_eq!(scanned(&f, &Scope::Global), [("gh".to_owned(), Some(true))]);
}

/// Codex speaks stdio and streamable HTTP and never SSE, so an SSE
/// declaration is refused for this harness with that reason and nothing is
/// written for it.
#[test]
#[allow(clippy::unwrap_used)]
fn an_sse_server_is_refused_for_codex_with_the_reason() {
    let f = fixture("[mcp-servers.legacy]\nsource = \"cat\"\n");
    let report = apply_now(&f);
    assert!(
        report.drift.iter().any(|row| row.name == "legacy"
            && row
                .detail
                .contains("Codex speaks stdio and streamable HTTP and not SSE")),
        "{:?}",
        report.drift
    );
    assert!(!f.project.join(".codex/config.toml").exists());
}

/// Codex passes a variable through under its own name only, so a reference
/// that would land under another key is refused with the fix rather than
/// written as a literal the process would read.
#[test]
#[allow(clippy::unwrap_used)]
fn a_renamed_env_reference_is_refused_for_codex_with_the_fix() {
    let f = fixture("[mcp-servers.renamed]\nsource = \"cat\"\n");
    let report = apply_now(&f);
    assert!(
        report.drift.iter().any(|row| row.name == "renamed"
            && row.detail.contains("under its own name only")
            && row.detail.contains("name the variable GH_TOKEN")),
        "{:?}",
        report.drift
    );
    assert!(!f.project.join(".codex/config.toml").exists());
}

/// A declaration switched off before Codex's file exists still writes the
/// whole table with its switch, so the file says what the manifest says.
#[test]
#[allow(clippy::unwrap_used)]
fn a_server_declared_off_writes_its_table_into_a_fresh_file() {
    let f = fixture("[mcp-servers.gh]\nsource = \"cat\"\nenabled = false\n");
    apply_now(&f);
    let config = f.project.join(".codex/config.toml");
    let installed = table(&config);
    assert_eq!(
        installed["mcp_servers"]["gh"]["command"].as_str(),
        Some("gh-mcp")
    );
    assert_eq!(
        installed["mcp_servers"]["gh"]["enabled"].as_bool(),
        Some(false)
    );
    assert!(is_clean(&f));
    assert_eq!(scanned(&f, &f.scope), [("gh".to_owned(), Some(false))]);
}
