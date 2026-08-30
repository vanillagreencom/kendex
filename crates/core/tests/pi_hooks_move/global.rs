//! The move at the global scope, where the reserved names sit beside
//! `~/.pi/agent` — the install a person makes once and every project then
//! carries, so the every-start warning bites hardest here.

use crate::test_util::source_path;

use std::fs;
use std::path::PathBuf;

use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

use super::catalog;

struct Global {
    _tmp: tempfile::TempDir,
    env: Env,
    agent: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn global(body: &str) -> Global {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let catalog = catalog(&home);
    let agent = home.join(".pi/agent");
    fs::create_dir_all(&agent).unwrap();
    fs::write(
        agent.join("settings.json"),
        r#"{ "packages": ["./packages/pi-hooks"] }"#,
    )
    .unwrap();
    let env = Env::fake(&home, FakeOs::Linux);
    let manifest = env.global_manifest_file();
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    fs::write(
        &manifest,
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"pi\"]\n\n{body}",
            source_path(&catalog)
        ),
    )
    .unwrap();
    Global {
        env,
        agent,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn apply(g: &Global) {
    let report = audit(&g.env, &Scope::Global).unwrap();
    kendex_core::apply::execute(&g.env, &report.plan).unwrap();
}

/// The layout an earlier kendex wrote at the global scope: the script
/// under the reserved name, the registry spelling the absolute path it
/// then had.
#[allow(clippy::unwrap_used)]
fn regress(g: &Global) {
    super::forget_the_move(&g.env.global_lock_file());
    fs::create_dir_all(g.agent.join("hooks")).unwrap();
    fs::rename(
        g.agent.join("kendex/hooks/guard.sh"),
        g.agent.join("hooks/guard.sh"),
    )
    .unwrap();
    let registry = fs::read_to_string(g.agent.join("kendex/hooks.json")).unwrap();
    fs::write(
        g.agent.join("hooks.json"),
        registry.replace("/kendex/hooks/guard.sh", "/hooks/guard.sh"),
    )
    .unwrap();
    fs::remove_dir_all(g.agent.join("kendex")).unwrap();
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_older_global_install_moves_out_of_the_reserved_directory() {
    let g = global("[hooks.guard]\nsource = \"cat\"\n");
    apply(&g);
    regress(&g);

    apply(&g);

    assert!(
        !g.agent.join("hooks").exists(),
        "the reserved directory beside the global root has to go too"
    );
    assert!(!g.agent.join("hooks.json").exists());
    assert!(g.agent.join("kendex/hooks/guard.sh").is_file());
    let registry = fs::read_to_string(g.agent.join("kendex/hooks.json")).unwrap();
    assert!(
        registry.contains("/kendex/hooks/guard.sh"),
        "the carrier is pointed at the new path: {registry}"
    );
    // A move that happened is a move with nothing left to do.
    let settled = audit(&g.env, &Scope::Global).unwrap();
    assert!(settled.plan.ops.is_empty(), "{:?}", settled.plan.ops);
    assert!(settled.notes.is_empty(), "{:?}", settled.notes);
}

/// The same ownership proof at the global scope: a hook somebody wrote by
/// hand into the global registry keeps its entry and its file.
#[test]
#[allow(clippy::unwrap_used)]
fn a_global_registry_entry_kendex_never_wrote_survives() {
    let g = global("[hooks.guard]\nsource = \"cat\"\n");
    apply(&g);
    regress(&g);
    let registry = g.agent.join("hooks.json");
    let mut value: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&registry).unwrap()).unwrap();
    value["hooks"]["turn_end"] = serde_json::json!([{
        "hooks": [{ "type": "command", "command": "echo theirs" }]
    }]);
    fs::write(&registry, serde_json::to_string_pretty(&value).unwrap()).unwrap();
    fs::write(g.agent.join("hooks/theirs.sh"), "#!/bin/sh\n").unwrap();

    apply(&g);

    assert!(g.agent.join("hooks/theirs.sh").is_file());
    let text = fs::read_to_string(&registry).unwrap();
    assert!(text.contains("echo theirs"), "{text}");
    assert!(
        !text.contains("/hooks/guard.sh"),
        "only kendex's own entry comes out: {text}"
    );
    assert!(g.agent.join("kendex/hooks/guard.sh").is_file());
}

/// The registry ownership gate at the global scope too.
#[test]
#[allow(clippy::unwrap_used)]
fn a_structurally_empty_global_registry_survives() {
    let g = global("[hooks.guard]\nsource = \"cat\"\n");
    apply(&g);
    let shape = "{\"hooks\":{\"tool_call\":[]}}\n";
    fs::write(g.agent.join("hooks.json"), shape).unwrap();

    apply(&g);

    assert_eq!(
        fs::read_to_string(g.agent.join("hooks.json")).unwrap(),
        shape
    );
}
