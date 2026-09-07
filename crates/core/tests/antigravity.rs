//! Antigravity as a managed tool: an agent, a skill, a hook and an MCP server each install
//! in the shape its loader reads, switch on and off without losing
//! anything, and come off disk on request — leaving the keys around ours in
//! its registry untouched.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::{EngineReport, audit, ops};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;
use serde_json::Value;

const AGENT: &str = "---\nname: rust\ndescription: Rust engineer\nmodel: opus\nrole: engineer\n---\nUse the Grep tool.\n";

const AUDIT_HOOK: &str = "#!/usr/bin/env bash\n# ---\n# name: audit\n# event: PreToolUse\n# matcher: Bash\n# description: log shell commands\n# timeout: 10\n# harnesses: [antigravity]\n# ---\nexit 0\n";

/// The same hook with no `harnesses` line: written for the payload every
/// other tool sends, which Antigravity does not.
const UNNAMED_HOOK: &str = "#!/usr/bin/env bash\n# ---\n# name: audit\n# event: PreToolUse\n# matcher: Bash\n# description: log shell commands\n# timeout: 10\n# ---\nexit 0\n";

const COMMAND: &str = "---\ndescription: Ship the branch\n---\n\nRun the checklist.\n";

const GH_MCP: &str = "command = \"gh-mcp\"\nargs = [\"--stdio\"]\n";

const DOCS_MCP: &str = "transport = \"http\"\nurl = \"https://mcp.example/docs\"\n";

const ENV_MCP: &str = "command = \"gh-mcp\"\n[env]\nGH_TOKEN = \"$GH_TOKEN\"\n";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
}

/// An antigravity-only project whose catalog carries one of everything;
/// `declarations` is appended to the manifest verbatim.
#[allow(clippy::unwrap_used)]
fn fixture(declarations: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".agents")).unwrap();
    fs::create_dir_all(home.join(".gemini/config")).unwrap();

    let source = home.join("catalog");
    for dir in ["agents", "hooks", "commands", "mcp", "skills/deploy"] {
        fs::create_dir_all(source.join(dir)).unwrap();
    }
    fs::write(
        source.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: Ship it\n---\n\nSteps.\n",
    )
    .unwrap();
    fs::write(source.join("agents/rust.md"), AGENT).unwrap();
    fs::write(source.join("hooks/audit.sh"), AUDIT_HOOK).unwrap();
    fs::write(source.join("commands/ship.md"), COMMAND).unwrap();
    fs::write(source.join("mcp/gh.toml"), GH_MCP).unwrap();
    fs::write(source.join("mcp/docs.toml"), DOCS_MCP).unwrap();
    fs::write(source.join("mcp/tokened.toml"), ENV_MCP).unwrap();
    fs::write(source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();

    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"antigravity\"]\nmethod = \"symlink\"\n\n{declarations}",
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

/// The same catalog declared at the global scope: Antigravity's global
/// customization root is the one `agy` scans at startup.
#[allow(clippy::unwrap_used)]
fn declare_globally(f: &Fixture, declarations: &str) {
    let manifest = f.env.global_manifest_file();
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    let source = f.env.home.join("catalog");
    fs::write(
        &manifest,
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"antigravity\"]\nmethod = \"symlink\"\n\n{declarations}",
            source_path(&source)
        ),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn apply_globally(f: &Fixture) -> EngineReport {
    let report = audit(&f.env, &Scope::Global).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    report
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

/// The drift rows by name and state — what a pass over a registry holding
/// somebody else's entry reports.
#[allow(clippy::unwrap_used)]
fn drift(f: &Fixture) -> Vec<(String, kendex_core::engine::DriftState)> {
    audit(&f.env, &f.scope)
        .unwrap()
        .drift
        .into_iter()
        .map(|row| (row.name, row.state))
        .collect()
}

/// `agy` lists an agent from `~/.gemini/config/agents/` and from nowhere
/// else, so the global root is the whole of the agent surface.
#[test]
#[allow(clippy::unwrap_used)]
fn an_agent_installs_under_the_global_root_and_toggles_by_rename() {
    let f = fixture("");
    declare_globally(&f, "[agents.rust]\nsource = \"cat\"\n");
    apply_globally(&f);

    let file = f.env.home.join(".gemini/config/agents/rust.md");
    let text = fs::read_to_string(&file).unwrap();
    assert!(
        text.starts_with(
            "---\nname: rust\ndescription: \"Rust engineer\"\nmodel: pro\nsubagent: true\n---\n"
        ),
        "{text}"
    );
    assert!(text.contains("Use the grep_search tool."), "{text}");
    assert!(audit(&f.env, &Scope::Global).unwrap().drift.is_empty());

    let names = ["rust".to_owned()];
    let report = ops::toggle(&f.env, &Scope::Global, &names, None, false).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(!file.exists());
    let parked = f.env.home.join(".gemini/config/agents/rust.md.disabled");
    assert_eq!(fs::read_to_string(&parked).unwrap(), text);
    assert!(audit(&f.env, &Scope::Global).unwrap().drift.is_empty());

    let report = ops::toggle(&f.env, &Scope::Global, &names, None, true).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(file.is_file() && !parked.exists());

    let report = ops::remove(&f.env, &Scope::Global, &names, None, false).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(!file.exists() && !parked.exists());
}

/// The same declaration in a project installs nothing, and says so: `agy`
/// 1.1.27 reads no workspace `agents/` directory, so a render there would
/// report an install the tool never acts on.
#[test]
#[allow(clippy::unwrap_used)]
fn a_project_agent_installs_nothing_and_the_report_says_why() {
    let f = fixture("[agents.rust]\nsource = \"cat\"\n");
    let report = apply_now(&f);
    assert!(
        report.notes.iter().any(|note| note
            == "agent rust: Antigravity cannot hold one at this scope — nothing was installed"),
        "{:?}",
        report.notes
    );
    assert!(!f.project.join(".agents/agents/rust.md").exists());
}

/// The project's `.agents/skills` is the one tree Antigravity, Codex and
/// Pi all read, so a skill goes there and nowhere else.
#[test]
#[allow(clippy::unwrap_used)]
fn a_skill_installs_into_the_shared_tree() {
    let f = fixture("[skills.deploy]\nsource = \"cat\"\n");
    apply_now(&f);

    let marker = f.project.join(".agents/skills/deploy/SKILL.md");
    assert!(fs::read_to_string(&marker).unwrap().contains("Steps."));
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

/// The registry is one file keyed by hook name, so the entry goes under
/// ours, in Antigravity's tool names, and comes out with the name when it
/// is the last thing under it. Somebody else's name in the same file is
/// theirs: reported as unmanaged, never touched.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_registers_under_its_name_in_the_roots_hooks_json() {
    let f = fixture("[hooks.audit]\nsource = \"cat\"\n");
    let registry = f.project.join(".agents/hooks.json");
    fs::write(
        &registry,
        "{\n  \"lint\": {\"PostToolUse\": [{\"matcher\": \"run_command\", \"hooks\": [{\"command\": \"./lint.sh\"}]}]}\n}\n",
    )
    .unwrap();
    apply_now(&f);

    let script = f.project.join(".agents/hooks/audit.sh");
    assert!(script.is_file());
    let registered = json(&registry);
    let group = &registered["audit"]["PreToolUse"][0];
    // The same `Bash` the source declares, said in Antigravity's tool
    // names — a regex of Claude's spelling would match nothing.
    assert_eq!(group["matcher"], "run_command");
    let entry = &group["hooks"][0];
    assert_eq!(entry["type"], "command");
    // The command finds the script when it runs and names no directory of
    // this machine's, so a repository can commit the registry it is in.
    let command = entry["command"].as_str().unwrap();
    assert!(command.contains("p='.agents/hooks/audit.sh'"), "{command}");
    assert!(
        !command.contains(&*f.project.to_string_lossy()),
        "{command}"
    );
    assert_eq!(entry["timeout"], 10);
    assert_eq!(
        registered["lint"]["PostToolUse"][0]["hooks"][0]["command"],
        "./lint.sh"
    );
    let theirs = vec![(
        "PostToolUse:run_command:lint".to_owned(),
        kendex_core::engine::DriftState::Unmanaged,
    )];
    assert_eq!(drift(&f), theirs);

    toggle(&f, "audit", false);
    let off = json(&registry);
    assert!(off.get("audit").is_none(), "{off}");
    assert_eq!(off["lint"]["PostToolUse"][0]["matcher"], "run_command");
    assert!(f.project.join(".agents/hooks/audit.sh.disabled").is_file());
    assert_eq!(drift(&f), theirs);

    toggle(&f, "audit", true);
    assert_eq!(json(&registry), registered);

    remove(&f, "audit");
    assert!(!script.exists());
    let after = json(&registry);
    assert!(after.get("audit").is_none(), "{after}");
    assert_eq!(after["lint"]["PostToolUse"][0]["matcher"], "run_command");
}

/// A hook that names no harness is written for the `tool_input` payload;
/// Antigravity sends `toolCall.args`, so the hook would run and read
/// nothing. It installs nowhere on Antigravity and the plan says why.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_naming_no_harness_stays_out_of_antigravity() {
    let f = fixture("[hooks.audit]\nsource = \"cat\"\n");
    fs::write(f.env.home.join("catalog/hooks/audit.sh"), UNNAMED_HOOK).unwrap();
    let report = apply_now(&f);

    assert!(!f.project.join(".agents/hooks.json").exists());
    assert!(!f.project.join(".agents/hooks/audit.sh").exists());
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.starts_with("hook audit: skips antigravity")),
        "{:?}",
        report.notes
    );
}

/// What kendex writes is what kendex reads back: the scan finds the entry
/// under the hook's name in the one registry the loader reads.
#[test]
#[allow(clippy::unwrap_used)]
fn a_registered_hook_is_read_back_from_the_registry() {
    let f = fixture("[hooks.audit]\nsource = \"cat\"\n");
    apply_now(&f);

    let scanned = kendex_core::scan::scan_scopes(
        &f.env,
        &std::collections::BTreeMap::new(),
        std::slice::from_ref(&f.scope),
    );
    assert_eq!(scanned.warnings, Vec::<String>::new());
    let hooks: Vec<_> = scanned
        .items
        .iter()
        .filter(|item| {
            item.harness == kendex_core::model::HarnessId::Antigravity
                && item.kind == kendex_core::model::ItemKind::Hook
        })
        .map(|item| (item.name.as_str(), item.enabled))
        .collect();
    assert_eq!(hooks, [("PreToolUse:run_command:audit", Some(true))]);
}

/// A skill is Antigravity's slash command, so a command declared for it
/// produces nothing at all rather than a dead file.
#[test]
#[allow(clippy::unwrap_used)]
fn a_command_declared_for_antigravity_writes_nothing() {
    let f = fixture("[commands.ship]\nsource = \"cat\"\n");
    apply_now(&f);
    assert!(!f.project.join(".agents/commands").exists());
    assert!(is_clean(&f));
}

/// A command server is written as declared and a url server under
/// `serverUrl`, beside the entry somebody else keeps in the file. Off writes
/// `disabled: true` on the entry and on takes the key away, so the
/// declaration stays until removal; the scan lists each by its endpoint.
#[test]
#[allow(clippy::unwrap_used)]
fn a_server_is_declared_in_mcp_config_json_and_toggles_on_the_entry() {
    let f = fixture("[mcp-servers.gh]\nsource = \"cat\"\n\n[mcp-servers.docs]\nsource = \"cat\"\n");
    let config = f.project.join(".agents/mcp_config.json");
    fs::write(
        &config,
        r#"{"mcpServers": {"other": {"serverUrl": "https://docs.example/sse", "disabled": true}}}"#,
    )
    .unwrap();
    let report = apply_now(&f);
    assert_eq!(report.warnings, Vec::new());

    let installed = json(&config);
    assert_eq!(
        installed["mcpServers"]["other"],
        serde_json::json!({"serverUrl": "https://docs.example/sse", "disabled": true})
    );
    assert_eq!(
        installed["mcpServers"]["gh"],
        serde_json::json!({"command": "gh-mcp", "args": ["--stdio"]})
    );
    assert_eq!(
        installed["mcpServers"]["docs"],
        serde_json::json!({"serverUrl": "https://mcp.example/docs"})
    );
    assert!(is_clean(&f));

    let scanned = kendex_core::scan::scan_scopes(
        &f.env,
        &std::collections::BTreeMap::new(),
        std::slice::from_ref(&f.scope),
    );
    let mut servers: Vec<_> = scanned
        .items
        .iter()
        .filter(|item| item.kind == kendex_core::model::ItemKind::McpServer)
        .map(|item| (item.name.as_str(), item.description.as_deref()))
        .collect();
    servers.sort();
    assert_eq!(
        servers,
        [
            ("docs", Some("https://mcp.example/docs")),
            ("gh", Some("gh-mcp")),
            ("other", Some("https://docs.example/sse")),
        ]
    );

    toggle(&f, "gh", false);
    let off = json(&config);
    assert_eq!(off["mcpServers"]["gh"]["disabled"], true);
    assert_eq!(off["mcpServers"]["gh"]["command"], "gh-mcp");
    assert_eq!(off["mcpServers"]["other"]["disabled"], true);
    assert!(is_clean(&f));
    let scanned = kendex_core::scan::scan_scopes(
        &f.env,
        &std::collections::BTreeMap::new(),
        std::slice::from_ref(&f.scope),
    );
    let mut switches: Vec<_> = scanned
        .items
        .iter()
        .filter(|item| item.kind == kendex_core::model::ItemKind::McpServer)
        .map(|item| (item.name.as_str(), item.enabled))
        .collect();
    switches.sort();
    assert_eq!(
        switches,
        [("docs", None), ("gh", Some(false)), ("other", Some(false)),]
    );

    toggle(&f, "gh", true);
    assert_eq!(json(&config), installed);

    remove(&f, "gh");
    let after = json(&config);
    assert!(after["mcpServers"].get("gh").is_none(), "{after}");
    assert_eq!(
        after["mcpServers"]["docs"]["serverUrl"],
        "https://mcp.example/docs"
    );
    assert_eq!(after["mcpServers"]["other"]["disabled"], true);
    assert!(is_clean(&f));
}

/// The global scope writes `mcp_config.json` under the customization root
/// Antigravity shares with its IDE, the file `agy mcp list` reads.
#[test]
#[allow(clippy::unwrap_used)]
fn a_global_server_lands_under_the_customization_root() {
    let f = fixture("");
    declare_globally(&f, "[mcp-servers.gh]\nsource = \"cat\"\n");
    apply_globally(&f);

    let config = f.env.home.join(".gemini/config/mcp_config.json");
    assert_eq!(json(&config)["mcpServers"]["gh"]["command"], "gh-mcp");
    assert!(audit(&f.env, &Scope::Global).unwrap().drift.is_empty());
}

/// Nothing in Antigravity's documentation substitutes a reference in an
/// `env` value, so a server carrying one is refused with the reason rather
/// than handed a literal to run with.
#[test]
#[allow(clippy::unwrap_used)]
fn a_server_with_env_references_is_refused_with_the_reason() {
    let f = fixture("[mcp-servers.tokened]\nsource = \"cat\"\n");
    let report = apply_now(&f);
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.name == "tokened" && row.detail.contains("documents no substitution")),
        "{:?}",
        report.drift
    );
    assert!(!f.project.join(".agents/mcp_config.json").exists());
}
