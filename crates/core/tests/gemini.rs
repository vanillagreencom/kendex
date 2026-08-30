//! Gemini CLI as a managed tool: an agent, a skill, a command, a hook and
//! an MCP server each install in the shape Gemini reads, switch on and off
//! without losing anything, and come off disk on request — leaving the keys
//! around ours in its settings file untouched.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::{EngineReport, audit, ops};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;
use serde_json::Value;

const AGENT: &str = "---\nname: rust\ndescription: Rust engineer\nmodel: opus\nrole: engineer\n---\nUse the Grep tool.\n";

const AUDIT_HOOK: &str = "#!/usr/bin/env bash\n# ---\n# name: audit\n# event: PreToolUse\n# matcher: Bash\n# description: log shell commands\n# timeout: 10\n# ---\nexit 0\n";

/// Gemini has no event that means "the turn ended".
const DONE_HOOK: &str = "#!/usr/bin/env bash\n# ---\n# name: done\n# event: TaskCompleted\n# description: check the work\n# ---\nexit 0\n";

const GH_MCP: &str = "command = \"gh-mcp\"\nargs = [\"--stdio\"]\n";

const COMMAND: &str =
    "---\ndescription: Ship the branch\n---\n\nRun the release checklist for {{args}}.\n";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
}

/// A gemini-only project whose catalog carries one of everything;
/// `declarations` is appended to the manifest verbatim.
#[allow(clippy::unwrap_used)]
fn fixture(declarations: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".gemini")).unwrap();

    let source = home.join("catalog");
    for dir in ["agents", "hooks", "mcp", "commands", "skills/deploy"] {
        fs::create_dir_all(source.join(dir)).unwrap();
    }
    fs::write(
        source.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: Ship it\n---\n\nSteps.\n",
    )
    .unwrap();
    fs::write(source.join("agents/rust.md"), AGENT).unwrap();
    fs::write(source.join("hooks/audit.sh"), AUDIT_HOOK).unwrap();
    fs::write(source.join("hooks/done.sh"), DONE_HOOK).unwrap();
    fs::write(source.join("mcp/gh.toml"), GH_MCP).unwrap();
    fs::write(source.join("commands/ship.md"), COMMAND).unwrap();
    // Executable kinds install only from a catalog that declares kendex's layout.
    fs::write(source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();

    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"gemini\"]\nmethod = \"symlink\"\n\n{declarations}",
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

fn settings(f: &Fixture) -> PathBuf {
    f.project.join(".gemini/settings.json")
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_agent_installs_in_geminis_own_format_and_toggles_by_rename() {
    let f = fixture("[agents.rust]\nsource = \"cat\"\n");
    apply_now(&f);

    let file = f.project.join(".gemini/agents/rust.md");
    let text = fs::read_to_string(&file).unwrap();
    assert!(text.starts_with("---\nname: rust\ndescription: \"Rust engineer\"\nkind: local\n"));
    assert!(text.contains("model: gemini-3-pro-preview\n"));
    assert!(text.contains("Use the grep_search tool."), "{text}");
    assert!(is_clean(&f));

    toggle(&f, "rust", false);
    assert!(!file.exists());
    let parked = f.project.join(".gemini/agents/rust.md.disabled");
    assert_eq!(fs::read_to_string(&parked).unwrap(), text);
    assert!(is_clean(&f));

    toggle(&f, "rust", true);
    assert!(file.is_file() && !parked.exists());

    remove(&f, "rust");
    assert!(!file.exists() && !parked.exists());
}

/// Gemini reads the project's shared `.agents/skills` tree, so a skill goes
/// there rather than into a second copy under `.gemini`.
#[test]
#[allow(clippy::unwrap_used)]
fn a_skill_installs_into_the_shared_tree_gemini_reads() {
    let f = fixture("[skills.deploy]\nsource = \"cat\"\n");
    apply_now(&f);

    let marker = f.project.join(".agents/skills/deploy/SKILL.md");
    assert!(fs::read_to_string(&marker).unwrap().contains("Steps."));
    assert!(!f.project.join(".gemini/skills").exists());
    assert!(is_clean(&f));

    toggle(&f, "deploy", false);
    assert!(!marker.exists());
    assert!(
        f.project
            .join(".agents/skills/deploy/SKILL.md.disabled")
            .exists()
    );
    assert!(is_clean(&f));

    remove(&f, "deploy");
    assert!(!f.project.join(".agents/skills/deploy").exists());
}

/// A copy delivery is a tree only this tool reads, so it goes in Gemini's
/// own directory — the escape hatch for a Gemini too old to read the
/// shared one.
#[test]
#[allow(clippy::unwrap_used)]
fn a_copy_delivery_writes_geminis_own_skills_directory() {
    let f = fixture("[skills.deploy]\nsource = \"cat\"\nmethod = \"copy\"\n");
    apply_now(&f);

    let marker = f.project.join(".gemini/skills/deploy/SKILL.md");
    assert!(fs::read_to_string(&marker).unwrap().contains("Steps."));
    assert!(is_clean(&f));
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_command_installs_as_a_toml_table_and_toggles_by_rename() {
    let f = fixture("[commands.ship]\nsource = \"cat\"\n");
    apply_now(&f);

    let file = f.project.join(".gemini/commands/ship.toml");
    let text = fs::read_to_string(&file).unwrap();
    let table: toml::Table = text.parse().unwrap();
    assert_eq!(table["description"].as_str(), Some("Ship the branch"));
    assert_eq!(
        table["prompt"].as_str(),
        Some("Run the release checklist for {{args}}.\n")
    );
    assert!(text.starts_with("# Generated by kendex"));
    assert!(is_clean(&f));

    // Gemini loads nothing but `.toml` from that directory, which is what
    // makes parking the file a real switch.
    toggle(&f, "ship", false);
    assert!(!file.exists());
    let parked = f.project.join(".gemini/commands/ship.toml.disabled");
    assert_eq!(fs::read_to_string(&parked).unwrap(), text);
    assert!(is_clean(&f));

    remove(&f, "ship");
    assert!(!parked.exists() && !file.exists());
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_registers_under_geminis_event_name_in_milliseconds() {
    let f = fixture("[hooks.audit]\nsource = \"cat\"\n");
    fs::write(settings(&f), "{\n  \"ui\": {\"theme\": \"Dark\"}\n}\n").unwrap();
    apply_now(&f);

    let script = f.project.join(".gemini/hooks/audit.sh");
    assert!(script.is_file());
    let registered = json(&settings(&f));
    assert_eq!(registered["ui"]["theme"], "Dark");
    let group = &registered["hooks"]["BeforeTool"][0];
    // The source matches on `Bash`, Claude's name for the shell. Gemini
    // matches its own name or nothing at all.
    assert_eq!(group["matcher"], "run_shell_command");
    assert_eq!(
        group["hooks"][0]["command"],
        "bash \"$(git rev-parse --show-toplevel)/.gemini/hooks/audit.sh\""
    );
    // The source declares ten seconds; Gemini reads the field as milliseconds.
    assert_eq!(group["hooks"][0]["timeout"], 10000);
    assert!(is_clean(&f));

    toggle(&f, "audit", false);
    let disabled = json(&settings(&f));
    assert_eq!(disabled["ui"]["theme"], "Dark");
    assert!(disabled.get("hooks").is_none());
    assert!(f.project.join(".gemini/hooks/audit.sh.disabled").is_file());
    assert!(is_clean(&f));

    toggle(&f, "audit", true);
    assert_eq!(json(&settings(&f)), registered);

    remove(&f, "audit");
    let removed = json(&settings(&f));
    assert_eq!(removed["ui"]["theme"], "Dark");
    assert!(removed.get("hooks").is_none());
    assert!(!script.exists());
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_project_server_is_declared_in_the_projects_settings_and_left_alone_otherwise() {
    let f = fixture("[mcp-servers.gh]\nsource = \"cat\"\n\n[mcp-servers.docs]\nsource = \"cat\"\n");
    fs::write(
        f._tmp.path().join("catalog/mcp/docs.toml"),
        "transport = \"http\"\nurl = \"https://docs.example\"\n",
    )
    .unwrap();
    fs::write(
        settings(&f),
        "{\n  \"mcpServers\": {\n    \"other\": {\"command\": \"x\"}\n  },\n  \"ui\": {}\n}\n",
    )
    .unwrap();
    apply_now(&f);

    let installed = json(&settings(&f));
    assert_eq!(installed["mcpServers"]["other"]["command"], "x");
    assert_eq!(installed["mcpServers"]["gh"]["command"], "gh-mcp");
    assert_eq!(installed["mcpServers"]["gh"]["args"][0], "--stdio");
    // Gemini tells a streamable-HTTP endpoint from an SSE one by which key
    // carries it, not by a `type` beside it.
    assert_eq!(
        installed["mcpServers"]["docs"]["httpUrl"],
        "https://docs.example"
    );
    assert!(installed["mcpServers"]["docs"].get("type").is_none());
    assert!(is_clean(&f));

    remove(&f, "gh");
    let after = json(&settings(&f));
    assert!(after["mcpServers"].get("gh").is_none());
    assert_eq!(after["mcpServers"]["other"]["command"], "x");
    assert!(is_clean(&f));
}

/// Whether a server is on is recorded in one file for the whole machine, so
/// a project can declare one but not switch it off in place.
#[test]
#[allow(clippy::unwrap_used)]
fn a_project_scope_server_says_so_instead_of_switching_off() {
    let f = fixture("[mcp-servers.gh]\nsource = \"cat\"\nenabled = false\n");
    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        report.notes.iter().any(|note| note
            .contains("a project can declare one but not switch it off — remove it here instead")),
        "{:?}",
        report.notes
    );
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(!settings(&f).exists());
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_global_server_switches_off_in_the_file_gemini_keeps_that_state_in() {
    let f = fixture("");
    let manifest = f.env.global_manifest_file();
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    let declare = |enabled: bool| {
        fs::write(
            &manifest,
            format!(
                "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"gemini\"]\n\n[mcp-servers.gh]\nsource = \"cat\"\nenabled = {enabled}\n",
                source_path(&f._tmp.path().join("catalog"))
            ),
        )
        .unwrap();
    };
    let global = Scope::Global;
    let apply_global = || {
        let report = audit(&f.env, &global).unwrap();
        apply::execute(&f.env, &report.plan).unwrap();
    };

    declare(true);
    apply_global();
    let settings = f.env.home.join(".gemini/settings.json");
    let enablement = f.env.home.join(".gemini/mcp-server-enablement.json");
    assert_eq!(json(&settings)["mcpServers"]["gh"]["command"], "gh-mcp");
    assert!(
        !enablement.exists(),
        "an on server needs no record saying so"
    );

    // Off keeps the declaration and records the state, which is what makes
    // the switch reversible.
    declare(false);
    apply_global();
    assert_eq!(json(&settings)["mcpServers"]["gh"]["command"], "gh-mcp");
    assert_eq!(json(&enablement)["gh"]["enabled"], false);
    assert!(audit(&f.env, &global).unwrap().drift.is_empty());

    declare(true);
    apply_global();
    assert!(
        json(&enablement).get("gh").is_none(),
        "back on means Gemini's own default applies again"
    );

    let report = ops::remove(&f.env, &global, &["gh".to_owned()], None, false).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(json(&settings)["mcpServers"].get("gh").is_none());
}
