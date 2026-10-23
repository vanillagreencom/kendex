//! Whole-file lock inventories and older entries without that inventory.
//! Each matrix row has its own tests so a dropped writer field or required
//! reader field turns every affected row red, not only the first row.
use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::attest::{self, Floor};
use kendex_core::engine::{audit, installed_paths, ops, registered_in};
use kendex_core::env::{Env, FakeOs};
use kendex_core::lock::{self, Lock, entry_key};
use kendex_core::model::{HarnessId, ItemKind, Scope};

use crate::test_util::{rooted, source_path};

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    root: PathBuf,
}

#[allow(clippy::unwrap_used, reason = "fixture setup")]
fn fixture(kind: ItemKind, harness: HarnessId, enabled: bool) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("project");
    fs::create_dir_all(&project).unwrap();
    fs::create_dir_all(project.join(".pi")).unwrap();
    fs::write(
        project.join(".pi/settings.json"),
        "{\"packages\":[\"npm:pi-hooks\"]}\n",
    )
    .unwrap();
    let catalog = home.join("catalog");
    for dir in ["agents", "commands", "hooks", "mcp"] {
        fs::create_dir_all(catalog.join(dir)).unwrap();
    }
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        catalog.join("agents/helper.md"),
        "---\nname: helper\ndescription: Review code\n---\n\nReview the code.\n",
    )
    .unwrap();
    fs::write(
        catalog.join("commands/helper.md"),
        "---\ndescription: Review code\n---\n\nReview the code.\n",
    )
    .unwrap();
    // PreToolUse reaches Codex as well as the other hook harnesses. Naming every
    // harness also reaches Antigravity's explicit opt-in delivery.
    fs::write(
        catalog.join("hooks/helper.sh"),
        "#!/usr/bin/env bash\n# ---\n# name: helper\n# event: PreToolUse\n# description: Review code\n# safety: Review the code before running a tool.\n# harnesses: [claude, codex, opencode, cursor, pi, gemini, copilot, antigravity]\n# ---\nexit 0\n",
    )
    .unwrap();
    fs::write(
        catalog.join("mcp/helper.toml"),
        "command = \"helper-mcp\"\n",
    )
    .unwrap();
    let scope = if harness == HarnessId::Antigravity && kind == ItemKind::Agent {
        Scope::Global
    } else {
        Scope::Project {
            root: project.clone(),
        }
    };
    let manifest = match &scope {
        Scope::Global => env.global_manifest_file(),
        Scope::Project { root } => root.join("kendex.toml"),
    };
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    let section = match kind {
        ItemKind::Agent => "agents",
        ItemKind::Command => "commands",
        ItemKind::Hook => "hooks",
        ItemKind::McpServer => "mcp-servers",
        ItemKind::Skill | ItemKind::Plugin | ItemKind::PiExtension | ItemKind::OutputStyle => {
            panic!("fixture requires an agent, command, hook or server")
        }
    };
    fs::write(
        manifest,
        format!(
            "schema = 7\n[sources.cat]\n{}\n[install]\nharnesses = [\"{}\"]\nmethod = \"copy\"\n[{section}.helper]\nsource = \"cat\"\nenabled = {enabled}\n",
            source_path(&catalog), harness.name(),
        ),
    )
    .unwrap();
    Fixture {
        _tmp: tmp,
        env,
        scope,
        root: project,
    }
}

#[allow(clippy::unwrap_used, reason = "fixture apply and inspection")]
fn apply_now(f: &Fixture) -> Lock {
    let report = audit(&f.env, &f.scope).unwrap();
    assert!(report.refused.is_empty(), "{:#?}", report.refused);
    apply::execute(&f.env, &report.plan).unwrap();
    lock::load(&lock::lock_path(&f.env, &f.scope)).unwrap()
}

#[allow(clippy::unwrap_used, reason = "fixture inspection")]
fn records(kind: ItemKind, harness: HarnessId, relative: &str) {
    for enabled in [true, false] {
        let f = fixture(kind, harness, enabled);
        let lock = apply_now(&f);
        let key = entry_key(kind, "helper", harness);
        let entry = &lock.entries[&key];
        let emitted = entry
            .emitted
            .as_ref()
            .unwrap_or_else(|| panic!("{key}: file writer records emitted"));
        let base = match &f.scope {
            Scope::Project { root } => root.clone(),
            Scope::Global => kendex_core::harness::adapter(harness).default_global_root(&f.env),
        };
        let path = if enabled || (kind == ItemKind::Command && harness == HarnessId::Codex) {
            base.join(relative)
        } else {
            base.join(format!("{relative}.disabled"))
        };
        assert_eq!(emitted.paths, vec![path.clone()], "{key}: written location");
        assert_eq!(
            installed_paths(&f.env, &f.scope, entry),
            emitted.paths,
            "{key}: installed uses writer data"
        );
        assert_eq!(
            emitted.kind,
            if kind == ItemKind::Command && harness == HarnessId::Codex {
                ItemKind::Skill
            } else {
                kind
            }
        );
        assert_eq!(emitted.name, "helper");
        let registries = registered_in(&f.env, &f.scope, entry).unwrap();
        let expected_registry = if kind == ItemKind::Hook {
            match harness {
                HarnessId::Claude => Some(".claude/settings.json"),
                HarnessId::Codex => Some(".codex/hooks.json"),
                HarnessId::Opencode => Some("opencode.json"),
                HarnessId::Cursor => None,
                HarnessId::Pi => Some(".pi/kendex/hooks.json"),
                HarnessId::Gemini => Some(".gemini/settings.json"),
                HarnessId::Copilot => Some(".github/hooks/helper.json"),
                HarnessId::Antigravity => Some(".agents/hooks.json"),
            }
        } else {
            None
        };
        assert_eq!(
            registries,
            expected_registry
                .into_iter()
                .map(|path| base.join(path))
                .collect::<Vec<_>>(),
            "{key}: registered_in retains registry ownership beside whole files"
        );
        for registry in &registries {
            assert!(
                !emitted.paths.contains(registry),
                "{key}: shared keys are not whole files"
            );
        }
        if matches!(f.scope, Scope::Project { .. }) {
            let text = fs::read_to_string(lock::lock_path(&f.env, &f.scope)).unwrap();
            let wire: serde_json::Value = serde_json::from_str(&text).unwrap();
            let expected = if enabled || (kind == ItemKind::Command && harness == HarnessId::Codex)
            {
                relative.to_owned()
            } else {
                format!("{relative}.disabled")
            };
            assert_eq!(
                wire["entries"][&key]["emitted"]["paths"],
                serde_json::json!([expected])
            );
        }
        assert!(path.exists(), "{key}: artifact exists");
        // New recorded hook paths must not bypass reversal of registry edits.
        let report =
            ops::remove(&f.env, &f.scope, &["helper".to_owned()], Some(kind), false).unwrap();
        apply::execute(&f.env, &report.plan).unwrap();
        assert!(!path.exists(), "{key}: removal uses recorded location");
        if kind == ItemKind::Hook {
            for registry in registries {
                if registry.exists() {
                    let text = fs::read_to_string(registry).unwrap();
                    assert!(
                        !text.contains("helper.sh") && !text.contains("kendex-hook-helper.md"),
                        "{key}: registration leaves with its file: {text}"
                    );
                }
            }
        }
        assert!(
            lock::load(&lock::lock_path(&f.env, &f.scope))
                .unwrap()
                .entries
                .is_empty()
        );
    }
}

#[allow(clippy::unwrap_used, reason = "fixture record and inspection")]
fn legacy(kind: ItemKind, harness: HarnessId) {
    let f = fixture(kind, harness, true);
    let mut recorded = apply_now(&f);
    let key = entry_key(kind, "helper", harness);
    recorded.entries.get_mut(&key).unwrap().emitted = None;
    let path = lock::lock_path(&f.env, &f.scope);
    lock::save(&path, &recorded).unwrap();
    let loaded = lock::load(&path)
        .unwrap_or_else(|error| panic!("{key}: old entry without emitted loads: {error}"));
    assert!(loaded.entries[&key].emitted.is_none());
    let report = audit(&f.env, &f.scope)
        .unwrap_or_else(|error| panic!("{key}: old entry without emitted plans: {error}"));
    assert!(report.drift.is_empty(), "{key}: {:#?}", report.drift);
    assert!(report.refused.is_empty(), "{key}: {:#?}", report.refused);
    let standing = attest::record(&f.env, &f.scope, &loaded, &report, &Floor::Open)
        .unwrap()
        .unwrap();
    assert!(
        standing.problems.is_empty(),
        "{key}: {:#?}",
        standing.problems
    );
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(
        lock::load(&path).unwrap().entries[&key].emitted.is_some(),
        "{key}: next apply records paths"
    );
}

macro_rules! rows {
    ($(($id:ident, $kind:ident, $harness:ident, $path:literal)),+ $(,)?) => {
        $(mod $id {
            use super::*;
            #[test]
            fn records_whole_files() { records(ItemKind::$kind, HarnessId::$harness, $path); }
            #[test]
            fn loads_and_plans_without_emitted() { legacy(ItemKind::$kind, HarnessId::$harness); }
        })+
    };
}

rows!(
    (agent_claude, Agent, Claude, ".claude/agents/helper.md"),
    (agent_codex, Agent, Codex, ".codex/agents/helper.toml"),
    (
        agent_opencode,
        Agent,
        Opencode,
        ".opencode/agents/helper.md"
    ),
    (agent_cursor, Agent, Cursor, ".cursor/rules/helper.mdc"),
    (agent_pi, Agent, Pi, ".pi/agents/helper.md"),
    (agent_gemini, Agent, Gemini, ".gemini/agents/helper.md"),
    (
        agent_copilot,
        Agent,
        Copilot,
        ".github/agents/helper.agent.md"
    ),
    (agent_antigravity, Agent, Antigravity, "agents/helper.md"),
    (
        command_claude,
        Command,
        Claude,
        ".claude/commands/helper.md"
    ),
    (command_codex, Command, Codex, ".agents/skills/helper"),
    (
        command_opencode,
        Command,
        Opencode,
        ".opencode/commands/helper.md"
    ),
    (command_pi, Command, Pi, ".pi/prompts/helper.md"),
    (
        command_gemini,
        Command,
        Gemini,
        ".gemini/commands/helper.toml"
    ),
    (hook_claude, Hook, Claude, ".claude/hooks/helper.sh"),
    (hook_codex, Hook, Codex, ".codex/hooks/helper.sh"),
    (
        hook_opencode,
        Hook,
        Opencode,
        ".opencode/instructions/kendex-hook-helper.md"
    ),
    (hook_cursor, Hook, Cursor, ".cursor/rules/safety-helper.mdc"),
    (hook_pi, Hook, Pi, ".pi/kendex/hooks/helper.sh"),
    (hook_gemini, Hook, Gemini, ".gemini/hooks/helper.sh"),
    (hook_copilot, Hook, Copilot, ".github/hooks/helper.sh"),
    (
        hook_antigravity,
        Hook,
        Antigravity,
        ".agents/hooks/helper.sh"
    ),
);

#[allow(clippy::unwrap_used, reason = "fixture setup and inspection")]
fn registration_only(kind: ItemKind, harness: HarnessId) {
    let f = fixture(ItemKind::McpServer, harness, true);
    match kind {
        ItemKind::Hook => {
            fs::write(
                f.root.join("kendex.toml"),
                format!("schema = 7\n[install]\nharnesses = [\"{}\"]\n[[custom-hooks]]\nname = \"helper\"\nevent = \"PreToolUse\"\ncommand = \"./scripts/helper.sh\"\nagents = \"all\"\nharnesses = [\"{}\"]\n", harness.name(), harness.name()),
            ).unwrap();
        }
        ItemKind::McpServer => {}
        ItemKind::Plugin => {
            fs::write(
                f.root.join("kendex.toml"),
                format!(
                    "schema = 7\n[plugins.helper]\nenabled = true\nharness = \"{}\"\n",
                    harness.name()
                ),
            )
            .unwrap();
        }
        ItemKind::Agent
        | ItemKind::Command
        | ItemKind::Skill
        | ItemKind::PiExtension
        | ItemKind::OutputStyle => {
            panic!("registration-only fixture requires a hook, server or plugin")
        }
    }
    let lock = apply_now(&f);
    let key = entry_key(kind, "helper", harness);
    assert!(lock.entries[&key].emitted.is_none(), "{key}: no whole file");
    assert!(installed_paths(&f.env, &f.scope, &lock.entries[&key]).is_empty());
}

macro_rules! registrations {
    ($(($id:ident, $kind:ident, $harness:ident)),+ $(,)?) => {
        $(#[test]
        fn $id() { registration_only(ItemKind::$kind, HarnessId::$harness); })+
    };
}

registrations!(
    (scriptless_claude, Hook, Claude),
    (scriptless_codex, Hook, Codex),
    (scriptless_pi, Hook, Pi),
    (scriptless_gemini, Hook, Gemini),
    (scriptless_copilot, Hook, Copilot),
    (scriptless_antigravity, Hook, Antigravity),
    (server_claude, McpServer, Claude),
    (server_codex, McpServer, Codex),
    (server_opencode, McpServer, Opencode),
    (server_cursor, McpServer, Cursor),
    (server_gemini, McpServer, Gemini),
    (server_copilot, McpServer, Copilot),
    (server_antigravity, McpServer, Antigravity),
    (plugin_claude, Plugin, Claude),
    (plugin_copilot, Plugin, Copilot),
);
