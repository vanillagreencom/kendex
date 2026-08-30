//! The invariants as they apply to kinds that live inside shared harness
//! config: hooks, MCP servers, and plugins. Declaring, toggling, or removing
//! one edits a file the user also owns, so every test here asserts that the
//! keys around ours came through untouched.
#![cfg(unix)]

#[path = "../../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::{audit, ops};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;
use serde_json::Value;

mod config_files;

const GUARD_HOOK: &str = "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: block dangerous commands\n# timeout: 10\n# harnesses: [claude-code]\n# ---\nexit 0\n";

/// No `harnesses` line: this one goes everywhere hooks are supported.
const AUDIT_HOOK: &str = "#!/usr/bin/env bash\n# ---\n# name: audit\n# event: PreToolUse\n# matcher: Bash\n# description: log shell commands\n# safety: Shell commands are logged.\n# ---\nexit 0\n";

/// codex has no TaskCompleted event to hang a hook on.
const DONE_HOOK: &str = "#!/usr/bin/env bash\n# ---\n# name: done\n# event: TaskCompleted\n# description: check the work\n# harnesses: [codex]\n# ---\nexit 0\n";

const GH_MCP: &str =
    "command = \"gh-mcp\"\nargs = [\"--stdio\"]\n\n[env]\nGITHUB_TOKEN = \"$GH_TOKEN\"\n";

pub struct Fixture {
    _tmp: tempfile::TempDir,
    pub env: Env,
    pub scope: Scope,
    pub project: PathBuf,
}

/// A claude-only project whose catalog carries a hook and an MCP server;
/// `declarations` is appended to the manifest verbatim.
#[allow(clippy::unwrap_used)]
pub fn fixture(declarations: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();

    let source = home.join("catalog");
    fs::create_dir_all(source.join("hooks")).unwrap();
    fs::write(source.join("hooks/guard.sh"), GUARD_HOOK).unwrap();
    fs::write(source.join("hooks/audit.sh"), AUDIT_HOOK).unwrap();
    fs::write(source.join("hooks/done.sh"), DONE_HOOK).unwrap();
    fs::create_dir_all(source.join("mcp")).unwrap();
    fs::write(source.join("mcp/gh.toml"), GH_MCP).unwrap();
    fs::create_dir_all(source.join("commands")).unwrap();
    fs::write(source.join("commands/ship.md"), "Ship the branch.\n").unwrap();
    // Executable kinds install only from a catalog that declares kendex's layout.
    fs::write(source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();

    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n{declarations}",
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
pub fn apply_now(f: &Fixture) {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
}

#[allow(clippy::unwrap_used)]
fn toggle(f: &Fixture, name: &str, enabled: bool) {
    let report = ops::toggle(&f.env, &f.scope, &[name.to_owned()], None, enabled).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
}

#[allow(clippy::unwrap_used)]
pub fn json(path: &Path) -> Value {
    serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
}

#[allow(clippy::unwrap_used)]
pub fn is_clean(f: &Fixture) -> bool {
    audit(&f.env, &f.scope).unwrap().drift.is_empty()
}

pub fn settings(f: &Fixture) -> PathBuf {
    f.project.join(".claude/settings.json")
}

#[test]
fn hook_registration_round_trips_and_spares_unrelated_settings() {
    let f = fixture("[hooks.guard]\nsource = \"cat\"\n");
    fs::write(settings(&f), "{\n  \"model\": \"opus\"\n}\n").unwrap();
    apply_now(&f);

    let script = f.project.join(".claude/hooks/guard.sh");
    assert!(script.is_file());
    let registered = json(&settings(&f));
    assert_eq!(registered["model"], "opus");
    let group = &registered["hooks"]["PreToolUse"][0];
    assert_eq!(group["matcher"], "Bash");
    assert_eq!(
        group["hooks"][0]["command"],
        "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh\""
    );
    assert_eq!(group["hooks"][0]["timeout"], 10);
    assert!(is_clean(&f), "a fresh registration is not drift");

    toggle(&f, "guard", false);
    let disabled = json(&settings(&f));
    assert_eq!(disabled["model"], "opus");
    assert!(disabled.get("hooks").is_none());
    assert!(!script.exists());
    assert!(f.project.join(".claude/hooks/guard.sh.disabled").is_file());
    assert!(is_clean(&f), "disabled is a state, not drift");

    toggle(&f, "guard", true);
    assert_eq!(json(&settings(&f)), registered);
    assert!(script.is_file());
    assert!(!f.project.join(".claude/hooks/guard.sh.disabled").exists());
}

#[test]
fn one_hook_reaches_each_harness_in_its_own_native_form() {
    let f = fixture(
        "[hooks.audit]\nsource = \"cat\"\nharnesses = [\"claude\", \"codex\", \"opencode\", \"cursor\", \"pi\"]\n",
    );
    apply_now(&f);
    let at = |rel: &str| f.project.join(rel);

    assert!(at(".claude/hooks/audit.sh").is_file());
    assert!(
        json(&settings(&f))["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
            .as_str()
            .is_some_and(|c| c.contains("CLAUDE_PROJECT_DIR"))
    );

    assert!(at(".codex/hooks/audit.sh").is_file());
    assert_eq!(
        json(&at(".codex/hooks.json"))["hooks"]["PreToolUse"][0]["hooks"][0]["command"],
        "bash \"$(git rev-parse --show-toplevel)/.codex/hooks/audit.sh\""
    );
    assert!(
        fs::read_to_string(at(".codex/config.toml"))
            .unwrap()
            .contains("[features]\nhooks = true")
    );

    let instruction = at(".opencode/instructions/kendex-hook-audit.md");
    assert!(
        fs::read_to_string(&instruction)
            .unwrap()
            .contains("# Safety: audit")
    );
    let opencode = json(&at("opencode.json"));
    assert_eq!(
        opencode["instructions"][0],
        ".opencode/instructions/kendex-hook-audit.md"
    );
    assert_eq!(opencode["permission"]["bash"]["*"], "ask");

    let rule = fs::read_to_string(at(".cursor/rules/safety-audit.mdc")).unwrap();
    assert!(rule.contains("alwaysApply: true") && rule.contains("log shell commands"));

    // Pi rides the pi-hooks carrier: the script lands beside a registry
    // spoken in pi's own listener names.
    assert!(at(".pi/kendex/hooks/audit.sh").is_file());
    assert_eq!(
        json(&at(".pi/kendex/hooks.json"))["hooks"]["tool_call"][0]["hooks"][0]["command"],
        "bash \"$(git rev-parse --show-toplevel)/.pi/kendex/hooks/audit.sh\""
    );
    assert!(is_clean(&f));
}

#[test]
fn a_hook_declared_disabled_writes_no_config_file_at_all() {
    let f = fixture("[hooks.guard]\nsource = \"cat\"\nenabled = false\n");
    apply_now(&f);
    assert!(
        f.project.join(".claude/hooks/guard.sh.disabled").is_file(),
        "the script is parked, not lost"
    );
    assert!(
        !settings(&f).exists(),
        "recording an absence is no reason to create a settings file"
    );
    assert!(is_clean(&f));
}

#[test]
fn an_event_codex_cannot_run_is_reported_never_faked() {
    let f = fixture("[hooks.done]\nsource = \"cat\"\nharnesses = [\"codex\"]\n");
    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("hook done: event TaskCompleted unsupported on codex")),
        "{:?}",
        report.notes
    );
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(!f.project.join(".codex").exists());
}

#[test]
fn mcp_declare_apply_remove_keeps_the_servers_we_never_declared() {
    let f = fixture("[mcp-servers.gh]\nsource = \"cat\"\n");
    let file = f.project.join(".mcp.json");
    fs::write(
        &file,
        "{\n  \"mcpServers\": {\n    \"other\": {\"command\": \"x\"}\n  }\n}\n",
    )
    .unwrap();
    apply_now(&f);

    let installed = json(&file);
    assert_eq!(installed["mcpServers"]["other"]["command"], "x");
    assert_eq!(installed["mcpServers"]["gh"]["command"], "gh-mcp");
    assert_eq!(installed["mcpServers"]["gh"]["args"][0], "--stdio");
    assert_eq!(
        installed["mcpServers"]["gh"]["env"]["GITHUB_TOKEN"],
        "$GH_TOKEN"
    );
    assert!(is_clean(&f));

    let report = ops::remove(&f.env, &f.scope, &["gh".to_owned()], None, false).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    let after = json(&file);
    assert!(after["mcpServers"].get("gh").is_none());
    assert_eq!(after["mcpServers"]["other"]["command"], "x");
    assert!(is_clean(&f));
}

/// Two structured edits to one config file compose into a single mutation
/// with a single precondition — before this, the second edit's precondition
/// bound to the original bytes and the whole apply rolled back.
#[test]
#[allow(clippy::unwrap_used)]
fn two_mcp_servers_install_into_one_settings_file_in_one_apply() {
    let f = fixture("[mcp-servers.gh]\nsource = \"cat\"\n\n[mcp-servers.lin]\nsource = \"cat\"\n");
    let source_mcp = f._tmp.path().join("catalog/mcp");
    fs::write(
        source_mcp.join("lin.toml"),
        "command = \"lin-mcp\"\nargs = [\"--stdio\"]\n",
    )
    .unwrap();
    apply_now(&f);

    let file = f.project.join(".mcp.json");
    let installed = json(&file);
    assert_eq!(installed["mcpServers"]["gh"]["command"], "gh-mcp");
    assert_eq!(installed["mcpServers"]["lin"]["command"], "lin-mcp");
    assert!(is_clean(&f));

    // Removals against the same settings file coalesce too: both servers
    // come out in one mutation.
    let report = ops::remove(
        &f.env,
        &f.scope,
        &["gh".to_owned(), "lin".to_owned()],
        None,
        false,
    )
    .unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    let after = json(&file);
    assert!(after["mcpServers"].is_null() || after["mcpServers"].get("gh").is_none());
    assert!(is_clean(&f));
}

#[test]
fn a_secret_in_an_mcp_env_value_is_refused_not_installed() {
    let f = fixture("[mcp-servers.gh]\nsource = \"cat\"\n");
    let source = f
        .project
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("catalog");
    fs::write(
        source.join("mcp/gh.toml"),
        "command = \"gh-mcp\"\n\n[env]\nGITHUB_TOKEN = \"ghp_literal\"\n",
    )
    .unwrap();

    let report = audit(&f.env, &f.scope).unwrap();
    assert!(report.plan.ops.is_empty());
    assert!(
        report.notes.iter().any(|note| note
            == "mcp gh: env value for GITHUB_TOKEN must be a $REFERENCE, never a secret"),
        "{:?}",
        report.notes
    );
    assert!(!f.project.join(".mcp.json").exists());
}

#[test]
fn a_command_is_a_plain_file_that_toggles_by_rename() {
    let f = fixture("[commands.ship]\nsource = \"cat\"\n");
    apply_now(&f);
    let file = f.project.join(".claude/commands/ship.md");
    assert_eq!(fs::read_to_string(&file).unwrap(), "Ship the branch.\n");
    assert!(is_clean(&f));

    toggle(&f, "ship", false);
    assert!(!file.exists());
    let parked = f.project.join(".claude/commands/ship.md.disabled");
    assert_eq!(fs::read_to_string(&parked).unwrap(), "Ship the branch.\n");
    assert!(is_clean(&f));

    let report = ops::remove(&f.env, &f.scope, &["ship".to_owned()], None, false).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(!parked.exists() && !file.exists());
}

#[test]
fn a_plugin_toggle_writes_only_its_own_settings_key() {
    let f = fixture("[plugins.\"fmt@main\"]\nenabled = true\n");
    fs::write(settings(&f), "{\n  \"model\": \"opus\"\n}\n").unwrap();
    apply_now(&f);

    let enabled = json(&settings(&f));
    assert_eq!(enabled["enabledPlugins"]["fmt@main"], true);
    assert_eq!(enabled["model"], "opus");
    assert!(enabled.get("hooks").is_none());
    assert!(is_clean(&f));

    toggle(&f, "fmt@main", false);
    let disabled = json(&settings(&f));
    assert_eq!(disabled["enabledPlugins"]["fmt@main"], false);
    assert_eq!(disabled["model"], "opus");
    assert!(is_clean(&f));

    let report = ops::remove(&f.env, &f.scope, &["fmt@main".to_owned()], None, false).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    let removed = json(&settings(&f));
    assert!(removed.get("enabledPlugins").is_none());
    assert_eq!(removed["model"], "opus");
}
