//! Cursor as a managed tool for MCP servers: a declared server lands under
//! `mcpServers.<name>` in the scope's `mcp.json` in the shape Cursor reads,
//! comes out when switched off and goes back when switched on, comes out on
//! request, and leaves every other entry in the file as it found it.
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
const DOCS_MCP: &str = "transport = \"sse\"\nurl = \"https://mcp.example/sse\"\n";

/// What somebody else already keeps in the project's file.
const THEIRS: &str =
    "{\n  \"mcpServers\": {\n    \"other\": {\"command\": \"x\", \"envFile\": \".env\"}\n  }\n}\n";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
    source: PathBuf,
}

/// A Cursor-only project whose catalog carries a command server and an SSE
/// server; `declarations` is appended to the manifest verbatim.
#[allow(clippy::unwrap_used)]
fn fixture(declarations: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".cursor")).unwrap();
    fs::create_dir_all(home.join(".cursor")).unwrap();

    let source = home.join("catalog");
    fs::create_dir_all(source.join("mcp")).unwrap();
    fs::write(source.join("mcp/gh.toml"), GH_MCP).unwrap();
    fs::write(source.join("mcp/docs.toml"), DOCS_MCP).unwrap();
    fs::write(source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();

    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"cursor\"]\nmethod = \"symlink\"\n\n{declarations}",
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

/// The server names Cursor's scan reports for a scope.
fn scanned(f: &Fixture, scope: &Scope) -> Vec<String> {
    let scanned = kendex_core::scan::scan_scopes(
        &f.env,
        &std::collections::BTreeMap::new(),
        std::slice::from_ref(scope),
    );
    let mut rows: Vec<_> = scanned
        .items
        .iter()
        .filter(|item| item.harness == HarnessId::Cursor && item.kind == ItemKind::McpServer)
        .map(|item| item.name.clone())
        .collect();
    rows.sort();
    rows
}

/// A command server keeps `command` and `args` and spells its `env`
/// references the way Cursor's resolver reads them; a url server keeps
/// `url` and loses the `type` Cursor never reads. Off takes the entry out
/// and on puts it back, because the file has no switch of its own.
#[test]
#[allow(clippy::unwrap_used)]
fn a_server_is_declared_in_the_projects_mcp_json_and_toggles_by_presence() {
    let f = fixture("[mcp-servers.gh]\nsource = \"cat\"\n\n[mcp-servers.docs]\nsource = \"cat\"\n");
    let config = f.project.join(".cursor/mcp.json");
    fs::write(&config, THEIRS).unwrap();
    let report = apply_now(&f);
    assert_eq!(report.warnings, Vec::new());

    let installed = json(&config);
    assert_eq!(installed["mcpServers"]["other"]["envFile"], ".env");
    assert_eq!(
        installed["mcpServers"]["gh"],
        json!({"command": "gh-mcp", "args": ["--stdio"], "env": {"GITHUB_TOKEN": "${env:GH_TOKEN}"}})
    );
    assert_eq!(
        installed["mcpServers"]["docs"],
        json!({"url": "https://mcp.example/sse"})
    );
    assert!(is_clean(&f));
    assert_eq!(scanned(&f, &f.scope), ["docs", "gh", "other"]);

    toggle(&f, "gh", false);
    let off = json(&config);
    assert!(off["mcpServers"].get("gh").is_none(), "{off}");
    assert_eq!(off["mcpServers"]["other"]["command"], "x");
    assert!(is_clean(&f));
    assert_eq!(scanned(&f, &f.scope), ["docs", "other"]);

    toggle(&f, "gh", true);
    assert_eq!(json(&config), installed);

    remove(&f, "gh");
    let after = json(&config);
    assert!(after["mcpServers"].get("gh").is_none(), "{after}");
    assert_eq!(
        after["mcpServers"]["docs"]["url"],
        "https://mcp.example/sse"
    );
    assert_eq!(after["mcpServers"]["other"]["command"], "x");
    assert!(is_clean(&f));
}

/// The global scope writes `~/.cursor/mcp.json`, the file Cursor merges
/// under every workspace.
#[test]
#[allow(clippy::unwrap_used)]
fn a_global_server_lands_in_the_users_mcp_json() {
    let f = fixture("");
    let manifest = f.env.global_manifest_file();
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    fs::write(
        &manifest,
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"cursor\"]\nmethod = \"symlink\"\n\n[mcp-servers.gh]\nsource = \"cat\"\n",
            source_path(&f.source)
        ),
    )
    .unwrap();

    let report = audit(&f.env, &Scope::Global).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();

    let config = f.env.home.join(".cursor/mcp.json");
    assert_eq!(json(&config)["mcpServers"]["gh"]["command"], "gh-mcp");
    assert!(audit(&f.env, &Scope::Global).unwrap().drift.is_empty());
    assert_eq!(scanned(&f, &Scope::Global), ["gh"]);
}
