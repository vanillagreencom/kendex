//! Antigravity as a managed tool: an agent, a skill and a hook each install
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
    fs::create_dir_all(project.join(".agents/agents")).unwrap();
    fs::create_dir_all(home.join(".gemini/config")).unwrap();

    let source = home.join("catalog");
    for dir in ["agents", "hooks", "commands", "skills/deploy"] {
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

#[test]
#[allow(clippy::unwrap_used)]
fn an_agent_installs_in_the_loaders_tier_and_toggles_by_rename() {
    let f = fixture("[agents.rust]\nsource = \"cat\"\n");
    apply_now(&f);

    let file = f.project.join(".agents/agents/rust.md");
    let text = fs::read_to_string(&file).unwrap();
    assert!(
        text.starts_with(
            "---\nname: rust\ndescription: \"Rust engineer\"\nmodel: pro\nsubagent: true\n---\n"
        ),
        "{text}"
    );
    assert!(text.contains("Use the grep_search tool."), "{text}");
    assert!(is_clean(&f));

    toggle(&f, "rust", false);
    assert!(!file.exists());
    let parked = f.project.join(".agents/agents/rust.md.disabled");
    assert_eq!(fs::read_to_string(&parked).unwrap(), text);
    assert!(is_clean(&f));

    toggle(&f, "rust", true);
    assert!(file.is_file() && !parked.exists());

    remove(&f, "rust");
    assert!(!file.exists() && !parked.exists());
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
    assert_eq!(
        entry["command"],
        "bash \"$(git rev-parse --show-toplevel)/.agents/hooks/audit.sh\""
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

/// A remote server in `mcp_config.json` names its endpoint `serverUrl`, and
/// the read-only list shows that endpoint rather than a bare name.
#[test]
#[allow(clippy::unwrap_used)]
fn a_remote_server_is_listed_by_its_endpoint() {
    let f = fixture("");
    fs::write(
        f.project.join(".agents/mcp_config.json"),
        r#"{"mcpServers": {"docs": {"serverUrl": "https://docs.example/sse"}, "gh": {"command": "gh-mcp"}}}"#,
    )
    .unwrap();
    let scanned = kendex_core::scan::scan_scopes(
        &f.env,
        &std::collections::BTreeMap::new(),
        std::slice::from_ref(&f.scope),
    );
    let servers: Vec<_> = scanned
        .items
        .iter()
        .filter(|item| item.kind == kendex_core::model::ItemKind::McpServer)
        .map(|item| (item.name.as_str(), item.description.as_deref()))
        .collect();
    assert_eq!(
        servers,
        [
            ("docs", Some("https://docs.example/sse")),
            ("gh", Some("gh-mcp")),
        ]
    );
}
