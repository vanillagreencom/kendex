//! What a person reads about a package, wherever it is named.
//!
//! One line — the author's `summary`, else the `description` they wrote
//! instead — reaches the catalog row, the directory index, the installed
//! row and the package page. A hook and an MCP server keep no prose in the
//! file a tool registers them in, so the words come from the script the
//! install wrote and from the declaration the records name; the command
//! and the endpoint stay where execution is inspected and never stand in
//! for words nobody wrote.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{ItemKind, ObservedItem, Scope};
use kendex_core::source::browse;
use kendex_core::source_read::SealedSource;

/// A hook whose author wrote both lines: the constraint for the agent, and
/// the sentence for the person.
const GUARD: &str = "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: Refuse a command matching the deny pattern.\n# summary: Stops shell commands your project has ruled out.\n# ---\nexit 0\n";

/// A hook with a description and no summary: the description is shown.
const PLAIN: &str = "#!/usr/bin/env bash\n# ---\n# name: plain\n# event: Stop\n# description: Says nothing at all.\n# ---\nexit 0\n";

/// A script with no header kendex can read. Nothing authored is reachable,
/// and nothing is invented from the file around it.
const NOISE: &str = "#!/usr/bin/env bash\necho summary: not a header\nexit 0\n";

const DB_MCP: &str = "command = \"db-mcp\"\nsummary = \"Reads and writes the project database.\"\n";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
    catalog: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn fixture(declarations: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();

    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("hooks")).unwrap();
    fs::create_dir_all(catalog.join("mcp")).unwrap();
    fs::write(catalog.join("hooks/guard.sh"), GUARD).unwrap();
    fs::write(catalog.join("hooks/plain.sh"), PLAIN).unwrap();
    fs::write(catalog.join("hooks/noise.sh"), NOISE).unwrap();
    fs::write(catalog.join("mcp/db.toml"), DB_MCP).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n{declarations}",
            source_path(&catalog)
        ),
    )
    .unwrap();

    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        catalog,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn apply_now(f: &Fixture) {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
}

#[allow(clippy::unwrap_used)]
fn scanned(f: &Fixture, kind: ItemKind) -> Vec<ObservedItem> {
    let result = kendex_core::scan::scan_scopes(
        &f.env,
        &std::collections::BTreeMap::new(),
        std::slice::from_ref(&f.scope),
    );
    let mut items: Vec<ObservedItem> = result
        .items
        .into_iter()
        .filter(|item| item.kind == kind)
        .collect();
    items.sort_by(|a, b| a.name.cmp(&b.name));
    items
}

/// One more entry in a tool's hooks file, as a person adds one of their
/// own beside whatever kendex put there.
#[allow(clippy::unwrap_used)]
fn add_registration(settings: &Path, command: &str) {
    let mut value: serde_json::Value = match fs::read_to_string(settings) {
        Ok(text) => serde_json::from_str(&text).unwrap(),
        Err(_) => serde_json::json!({}),
    };
    let groups = value
        .as_object_mut()
        .unwrap()
        .entry("hooks")
        .or_insert_with(|| serde_json::json!({}))
        .as_object_mut()
        .unwrap()
        .entry("PreToolUse")
        .or_insert_with(|| serde_json::json!([]));
    groups.as_array_mut().unwrap().push(serde_json::json!({
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": command}],
    }));
    fs::write(settings, serde_json::to_string(&value).unwrap()).unwrap();
}

/// The Packages table and the directory index read one header, so a
/// catalog row and the row a directory publishes for it cannot say
/// different things about one version.
#[test]
#[allow(clippy::unwrap_used)]
fn a_catalog_reads_a_hooks_own_words_and_invents_none() {
    let f = fixture("");
    let rows = browse::packages(
        &f.env,
        &browse::Catalog::Subscription {
            scope: f.scope.clone(),
            source: "cat".to_owned(),
        },
    )
    .unwrap();
    let of = |name: &str| {
        rows.iter()
            .find(|row| row.kind == ItemKind::Hook && row.name == name)
            .unwrap_or_else(|| panic!("{name} not offered"))
    };
    // A summary is the person's line; the description stays the agent's,
    // so writing one never rewrites the other.
    assert_eq!(
        of("guard").summary.as_deref(),
        Some("Stops shell commands your project has ruled out.")
    );
    assert_eq!(
        of("guard").description.as_deref(),
        Some("Refuse a command matching the deny pattern.")
    );
    assert_eq!(
        of("plain").summary.as_deref(),
        Some("Says nothing at all."),
        "a hook with no summary is shown its description"
    );
    assert_eq!(
        of("noise").summary,
        None,
        "no header to read is a blank row, never a line built from the script"
    );

    let index =
        kendex_core::source::index::index(&SealedSource::open(&f.catalog).unwrap(), "catalog")
            .unwrap();
    let indexed = |name: &str| {
        index
            .packages
            .iter()
            .find(|row| row.kind == "hook" && row.name == name)
            .unwrap_or_else(|| panic!("{name} not indexed"))
    };
    assert_eq!(indexed("guard").summary, of("guard").summary);
    assert_eq!(indexed("plain").summary, of("plain").summary);
    assert_eq!(indexed("noise").summary, None);
}

/// An installed hook is a command in the tool's settings file. Its words
/// come from the script that command runs, and the command itself stays on
/// the row as what it is.
#[test]
#[allow(clippy::unwrap_used)]
fn an_installed_hooks_words_come_from_its_script() {
    let f = fixture("[hooks.guard]\nsource = \"cat\"\n");
    apply_now(&f);

    let hooks = scanned(&f, ItemKind::Hook);
    let row = hooks.first().expect("the registration was scanned");
    assert_eq!(
        row.summary.as_deref(),
        Some("Stops shell commands your project has ruled out.")
    );
    let command = row.action.clone().expect("the registration runs something");
    assert!(
        command.contains("guard.sh"),
        "the command a person inspects stays on the row: {command}"
    );
    assert_ne!(
        row.summary.as_deref(),
        Some(command.as_str()),
        "a command is never promoted into a description"
    );
}

/// A registration kendex did not write says nothing about a package,
/// however close its command looks.
///
/// A registration is named by the stem of the command it runs, and two
/// commands share a stem the moment one names the other's script: a
/// person's own `sh .claude/hooks/guard.sh --theirs` reduces to `guard`,
/// the name of an installed hook standing right beside it. Only the whole
/// command kendex would have registered claims that script's words; a
/// stem alone claims nothing, and neither does a command naming a file
/// that is not there.
#[test]
#[allow(clippy::unwrap_used)]
fn a_registration_kendex_did_not_write_says_nothing() {
    let f = fixture("[hooks.guard]\nsource = \"cat\"\n");
    apply_now(&f);
    let ours = scanned(&f, ItemKind::Hook)
        .first()
        .and_then(|row| row.action.clone())
        .expect("the install registered something");
    // Their own entry, in the same file, running the script kendex wrote —
    // under a command kendex would never have written.
    let theirs = format!("sh {ours} --theirs");
    add_registration(&f.project.join(".claude/settings.json"), &theirs);
    add_registration(
        &f.project.join(".claude/settings.json"),
        "bash /elsewhere/theirs.sh",
    );

    let rows = scanned(&f, ItemKind::Hook);
    assert_eq!(rows.len(), 3, "every entry in the file was scanned");
    let of = |command: &str| {
        rows.iter()
            .find(|row| row.action.as_deref() == Some(command))
            .unwrap_or_else(|| panic!("{command} was not scanned"))
            .summary
            .as_deref()
    };
    assert!(
        of(&ours).is_some(),
        "kendex's own registration keeps its words"
    );
    assert_eq!(
        of(&theirs),
        None,
        "a command kendex did not write claims no package's words"
    );
    assert_eq!(of("bash /elsewhere/theirs.sh"), None);
}

/// An MCP server's entry records how to reach it and nothing else. The
/// words come from the declaration's own source, at the version installed
/// here, through the records that say which package the entry is.
#[test]
#[allow(clippy::unwrap_used)]
fn an_mcp_servers_words_come_from_its_declaration() {
    let f = fixture("[mcp-servers.db]\nsource = \"cat\"\n");
    apply_now(&f);

    let servers = scanned(&f, ItemKind::McpServer);
    let observed = servers.first().expect("the server was scanned");
    assert_eq!(
        observed.summary, None,
        "a tool's config file holds no words about the package"
    );
    assert_eq!(observed.action.as_deref(), Some("db-mcp"));

    let rows = kendex_core::library::provenance(&f.env, std::slice::from_ref(&f.scope)).unwrap();
    let row = rows
        .iter()
        .find(|row| row.kind == ItemKind::McpServer && row.name == "db")
        .expect("the server has a provenance row");
    assert_eq!(
        row.summary.as_deref(),
        Some("Reads and writes the project database.")
    );
}
