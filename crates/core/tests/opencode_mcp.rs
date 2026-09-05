//! OpenCode as a managed tool for MCP servers: a declared server lands under
//! `mcp.<name>` in the scope's config file in OpenCode's own shape, switches
//! off on the entry itself, comes out on request, and leaves every other key
//! in the file as it found it. A transport OpenCode does not speak is refused
//! before anything is written.
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
use serde_json::{Value, json};

const GH_MCP: &str =
    "command = \"gh-mcp\"\nargs = [\"--stdio\"]\n[env]\nGITHUB_TOKEN = \"$GH_TOKEN\"\n";
const DOCS_MCP: &str = "transport = \"http\"\nurl = \"https://mcp.example/docs\"\n";
const LEGACY_MCP: &str = "transport = \"sse\"\nurl = \"https://mcp.example/sse\"\n";

/// What somebody else already keeps in the project's config: OpenCode's own
/// schema line, an instruction row, and a server of their own.
const THEIRS: &str = "{\n  \"$schema\": \"https://opencode.ai/config.json\",\n  \"instructions\": [\"docs/style.md\"],\n  \"mcp\": {\n    \"other\": {\"type\": \"local\", \"command\": [\"x\"]}\n  }\n}\n";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
    source: PathBuf,
}

/// An OpenCode-only project whose catalog carries three servers, one per
/// transport; `declarations` is appended to the manifest verbatim.
#[allow(clippy::unwrap_used)]
fn fixture(declarations: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".opencode")).unwrap();
    fs::create_dir_all(home.join(".config/opencode")).unwrap();

    let source = home.join("catalog");
    fs::create_dir_all(source.join("mcp")).unwrap();
    fs::write(source.join("mcp/gh.toml"), GH_MCP).unwrap();
    fs::write(source.join("mcp/docs.toml"), DOCS_MCP).unwrap();
    fs::write(source.join("mcp/legacy.toml"), LEGACY_MCP).unwrap();
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
fn json(path: &Path) -> Value {
    serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
}

#[allow(clippy::unwrap_used)]
fn is_clean(f: &Fixture) -> bool {
    audit(&f.env, &f.scope).unwrap().drift.is_empty()
}

/// The server names OpenCode's scan reports for a scope, with their switch.
fn scanned(f: &Fixture, scope: &Scope) -> Vec<(String, Option<bool>)> {
    let scanned = kendex_core::scan::scan_scopes(
        &f.env,
        &std::collections::BTreeMap::new(),
        std::slice::from_ref(scope),
    );
    let mut rows: Vec<_> = scanned
        .items
        .iter()
        .filter(|item| item.harness == HarnessId::Opencode && item.kind == ItemKind::McpServer)
        .map(|item| (item.name.clone(), item.enabled))
        .collect();
    rows.sort();
    rows
}

/// A command server is one `local` argv with its environment spelled the way
/// OpenCode substitutes it, a url server is `remote`; both sit beside the
/// keys the file already held and carry `enabled` explicitly, since a
/// missing key would inherit another layer's `false`. Switching off writes
/// `enabled: false`, so the declaration never leaves the file until removal.
#[test]
#[allow(clippy::unwrap_used)]
fn a_server_is_declared_under_mcp_in_opencodes_shape_and_toggles_on_the_entry() {
    let f = fixture("[mcp-servers.gh]\nsource = \"cat\"\n\n[mcp-servers.docs]\nsource = \"cat\"\n");
    let config = f.project.join("opencode.json");
    fs::write(&config, THEIRS).unwrap();
    let report = apply_now(&f);
    assert_eq!(report.warnings, Vec::new());

    let installed = json(&config);
    assert_eq!(installed["$schema"], "https://opencode.ai/config.json");
    assert_eq!(installed["instructions"][0], "docs/style.md");
    assert_eq!(installed["mcp"]["other"]["command"][0], "x");
    assert_eq!(
        installed["mcp"]["gh"],
        json!({"type": "local", "command": ["gh-mcp", "--stdio"], "environment": {"GITHUB_TOKEN": "{env:GH_TOKEN}"}, "enabled": true})
    );
    assert_eq!(
        installed["mcp"]["docs"],
        json!({"type": "remote", "url": "https://mcp.example/docs", "enabled": true})
    );
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
    let off = json(&config);
    assert_eq!(off["mcp"]["gh"]["enabled"], false);
    assert_eq!(off["mcp"]["gh"]["command"][0], "gh-mcp");
    assert_eq!(off["mcp"]["other"]["command"][0], "x");
    assert!(is_clean(&f));
    assert_eq!(scanned(&f, &f.scope)[1], ("gh".to_owned(), Some(false)));

    toggle(&f, "gh", true);
    assert_eq!(json(&config), installed);

    remove(&f, "gh");
    let after = json(&config);
    assert!(after["mcp"].get("gh").is_none(), "{after}");
    assert_eq!(after["mcp"]["docs"]["type"], "remote");
    assert_eq!(after["mcp"]["other"]["command"][0], "x");
    assert_eq!(after["instructions"][0], "docs/style.md");
    assert!(is_clean(&f));
}

/// The global scope writes the config file under OpenCode's own root, and a
/// file kendex creates carries the `$schema` line OpenCode would add itself.
#[test]
#[allow(clippy::unwrap_used)]
fn a_global_server_lands_in_the_global_config_with_the_schema_line() {
    let f = fixture("");
    let manifest = f.env.global_manifest_file();
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    fs::write(
        &manifest,
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"opencode\"]\nmethod = \"symlink\"\n\n[mcp-servers.gh]\nsource = \"cat\"\n",
            source_path(&f.source)
        ),
    )
    .unwrap();

    let report = audit(&f.env, &Scope::Global).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();

    let config = f.env.home.join(".config/opencode/opencode.json");
    let installed = json(&config);
    assert_eq!(installed["$schema"], "https://opencode.ai/config.json");
    assert_eq!(installed["mcp"]["gh"]["type"], "local");
    assert!(audit(&f.env, &Scope::Global).unwrap().drift.is_empty());
    assert_eq!(scanned(&f, &Scope::Global), [("gh".to_owned(), Some(true))]);
}

/// OpenCode's servers are `local` or `remote` and never SSE, so an SSE
/// declaration is refused for this harness with that reason and nothing is
/// written for it.
#[test]
#[allow(clippy::unwrap_used)]
fn an_sse_server_is_refused_for_opencode_with_the_reason() {
    let f = fixture("[mcp-servers.legacy]\nsource = \"cat\"\n");
    let report = apply_now(&f);
    assert!(
        report.drift.iter().any(|row| row.name == "legacy"
            && row
                .detail
                .contains("OpenCode speaks stdio and streamable HTTP and not SSE")),
        "{:?}",
        report.drift
    );
    assert!(!f.project.join("opencode.json").exists());
}
