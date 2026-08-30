//! What kendex tells the user about a Gemini setup it cannot fully act on:
//! an event Gemini has no counterpart for, subagents switched off, a
//! settings file older than the schema kendex writes, and a machine-wide
//! settings layer that outranks the project.
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
    // Gemini is installed on this machine, which is what makes it a reader
    // of the directories other tools own.
    fs::create_dir_all(home.join(".gemini")).unwrap();

    let source = home.join("catalog");
    for dir in ["agents", "hooks", "mcp", "skills/deploy"] {
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
fn json(path: &Path) -> Value {
    serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
}

fn settings(f: &Fixture) -> PathBuf {
    f.project.join(".gemini/settings.json")
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_event_gemini_does_not_have_is_reported_never_faked() {
    let f = fixture("[hooks.done]\nsource = \"cat\"\n");
    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("event TaskCompleted has no Gemini counterpart")),
        "{:?}",
        report.notes
    );
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(!f.project.join(".gemini/hooks").exists());
}

/// Gemini's own default for the subagent flag is on, so only an explicit
/// `false` means a correctly installed agent will sit there doing nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn an_agent_installed_while_the_feature_is_off_is_reported_inert() {
    let f = fixture("[agents.rust]\nsource = \"cat\"\n");
    fs::write(
        settings(&f),
        "{\"experimental\": {\"enableAgents\": false}}",
    )
    .unwrap();
    let report = apply_now(&f);
    assert!(
        report
            .warnings
            .iter()
            .any(|w| w.message.contains("installs but stays inert")),
        "{:?}",
        report.warnings
    );
    assert!(f.project.join(".gemini/agents/rust.md").is_file());

    fs::write(settings(&f), "{\"experimental\": {\"enableAgents\": true}}").unwrap();
    let quiet = audit(&f.env, &f.scope).unwrap();
    assert!(
        !quiet
            .warnings
            .iter()
            .any(|w| w.message.contains("stays inert")),
        "{:?}",
        quiet.warnings
    );
}

/// A settings file that never met the nested schema belongs to a CLI that
/// would not read what kendex writes into it, so the settings-backed kinds
/// report that instead of writing anyway.
#[test]
#[allow(clippy::unwrap_used)]
fn an_un_upgraded_settings_file_blocks_the_kinds_that_live_in_it() {
    let f = fixture(
        "[hooks.audit]\nsource = \"cat\"\n\n[mcp-servers.gh]\nsource = \"cat\"\n\n[agents.rust]\nsource = \"cat\"\n",
    );
    let legacy = "{\n  \"contextFileName\": \"GEMINI.md\",\n  \"theme\": \"Dark\"\n}\n";
    fs::write(settings(&f), legacy).unwrap();

    let report = apply_now(&f);
    let said = |text: &str| report.notes.iter().any(|note| note.contains(text));
    assert!(
        said("nothing was registered for Gemini"),
        "{:?}",
        report.notes
    );
    assert!(
        said("nothing was declared for Gemini"),
        "{:?}",
        report.notes
    );
    assert_eq!(fs::read_to_string(settings(&f)).unwrap(), legacy);
    assert!(!f.project.join(".gemini/hooks").exists());
    // The agent is a file of its own, so nothing about the settings file
    // stops it landing.
    assert!(f.project.join(".gemini/agents/rust.md").is_file());
}

/// The system settings layer outranks both the user's file and the
/// project's, so what kendex writes can be overridden there.
#[test]
#[allow(clippy::unwrap_used)]
fn a_system_wide_override_is_named_rather_than_argued_with() {
    let mut f = fixture("[hooks.audit]\nsource = \"cat\"\n");
    let system = f._tmp.path().join("etc/gemini-cli/settings.json");
    fs::create_dir_all(system.parent().unwrap()).unwrap();
    fs::write(&system, "{\"hooks\": {\"BeforeTool\": []}}").unwrap();
    f.env = f
        .env
        .clone()
        .with_var("GEMINI_CLI_SYSTEM_SETTINGS_PATH", &system.to_string_lossy());

    let report = apply_now(&f);
    assert!(
        report.warnings.iter().any(|w| w
            .message
            .contains("system-wide Gemini settings also set `hooks`")),
        "{:?}",
        report.warnings
    );
    // Said, not obeyed: the registration still lands where Gemini reads it.
    assert!(json(&settings(&f))["hooks"]["BeforeTool"][0]["matcher"] == "run_shell_command");
}

/// Whether a server is on is recorded once for the whole machine. A project
/// declaring one holds the project lock and nothing else, so that record is
/// read and reported — never rewritten from here.
#[test]
#[allow(clippy::unwrap_used)]
fn a_project_declaration_leaves_the_machine_wide_record_exactly_as_it_was() {
    let f = fixture("[mcp-servers.gh]\nsource = \"cat\"\n");
    let record = f.env.home.join(".gemini/mcp-server-enablement.json");
    let held_off = "{\n  \"gh\": {\"enabled\": false}\n}\n";
    fs::write(&record, held_off).unwrap();

    let report = apply_now(&f);
    assert_eq!(json(&settings(&f))["mcpServers"]["gh"]["command"], "gh-mcp");
    assert_eq!(fs::read_to_string(&record).unwrap(), held_off);
    assert!(
        report
            .warnings
            .iter()
            .any(|w| w.message.contains("stays inert")),
        "{:?}",
        report.warnings
    );

    // Removing the declaration takes the project's entry out and still
    // leaves the machine's own switch where the user set it.
    let removal = ops::remove(&f.env, &f.scope, &["gh".to_owned()], None, false).unwrap();
    apply::execute(&f.env, &removal.plan).unwrap();
    assert!(json(&settings(&f))["mcpServers"].get("gh").is_none());
    assert_eq!(fs::read_to_string(&record).unwrap(), held_off);
}

/// Gemini's settings can gate which servers load at all, whatever a scope
/// declares.
#[test]
#[allow(clippy::unwrap_used)]
fn a_server_gemini_gates_out_of_its_list_is_reported_inert() {
    let f = fixture("[mcp-servers.gh]\nsource = \"cat\"\n");
    fs::write(settings(&f), "{\"mcp\": {\"excluded\": [\"gh\"]}}").unwrap();

    let report = apply_now(&f);
    assert!(
        report
            .warnings
            .iter()
            .any(|w| w.message.contains("gate which servers load")),
        "{:?}",
        report.warnings
    );
    assert_eq!(json(&settings(&f))["mcpServers"]["gh"]["command"], "gh-mcp");
}

/// One tree, two readers. Gemini sees a skill installed for Claude Code
/// through `.agents/skills`, and saying so must never turn one installation
/// into two.
#[test]
#[allow(clippy::unwrap_used)]
fn a_skill_installed_for_another_tool_is_noted_as_visible_to_gemini() {
    let f = fixture("[skills.deploy]\nsource = \"cat\"\nharnesses = [\"claude\"]\n");
    let report = apply_now(&f);
    assert!(
        report.notes.iter().any(|note| note.contains("Gemini CLI")
            && note.contains("read `.agents/skills` too")
            && note.contains("one definition, counted once")),
        "{:?}",
        report.notes
    );
    assert!(f.project.join(".agents/skills/deploy/SKILL.md").is_file());
    assert!(!f.project.join(".gemini/skills").exists());
    assert!(
        !report
            .drift
            .iter()
            .any(|row| row.harness == kendex_core::model::HarnessId::Gemini)
    );
}
