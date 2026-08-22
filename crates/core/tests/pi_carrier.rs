//! Pi hooks, enforced through the carrier: events map onto the listeners
//! Pi actually fires (unmappable ones stay honestly unsupported), labels
//! read carrier reality at both scopes — a project-installed hook with a
//! global carrier is enforced, the v1 #1407 lesson — and everything
//! renders through the ordinary plan.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::harness::{Enforcement, pi_listener};
use kendex_core::model::Scope;
use kendex_core::pi_ext::carrier;

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    home: PathBuf,
    project: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().canonicalize().unwrap();
    let project = home.join("app");
    fs::create_dir_all(project.join(".pi")).unwrap();
    World {
        env: Env::fake(&home, FakeOs::Linux),
        home,
        project,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn register_carrier(settings_dir: &Path) {
    fs::create_dir_all(settings_dir).unwrap();
    fs::write(
        settings_dir.join("settings.json"),
        r#"{ "packages": ["./packages/pi-hooks"] }"#,
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn declare_hook(world: &World, event: &str) {
    let catalog = world.home.join("cat");
    fs::create_dir_all(catalog.join("hooks")).unwrap();
    // Hooks install only from a catalog that declares kendex's layout.
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        catalog.join("hooks/guard.sh"),
        format!(
            "#!/bin/sh\n# ---\n# name: guard\n# event: {event}\n# description: a guard\n# harnesses: [pi]\n# ---\nexit 0\n"
        ),
    )
    .unwrap();
    fs::write(
        world.project.join("kendex.toml"),
        format!(
            "schema = 5\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"pi\"]\nmethod = \"symlink\"\n\n[hooks.guard]\nsource = \"cat\"\n",
            catalog.display()
        ),
    )
    .unwrap();
}

fn scope(world: &World) -> Scope {
    Scope::Project {
        root: world.project.clone(),
    }
}

#[test]
fn events_map_onto_the_listeners_pi_actually_fires() {
    assert_eq!(pi_listener("PreToolUse"), Some("tool_call"));
    assert_eq!(pi_listener("PostToolUse"), Some("tool_result"));
    assert_eq!(pi_listener("Stop"), Some("turn_end"));
    assert_eq!(pi_listener("TaskCompleted"), Some("turn_end"));
    assert_eq!(pi_listener("SessionStart"), Some("session_start"));
    assert_eq!(
        pi_listener("PostCompact"),
        None,
        "pi fires no such listener"
    );
    assert_eq!(pi_listener("UserPromptSubmit"), None);
}

#[test]
#[allow(clippy::unwrap_used)]
fn carrier_presence_is_read_per_settings_layer_and_either_scope_enforces() {
    let w = world();
    let project_scope = scope(&w);
    assert!(!carrier::presence(&w.env, &project_scope).anywhere());
    assert_eq!(
        carrier::enforcement(&w.env, &project_scope),
        Enforcement::Advisory,
        "no carrier anywhere: a rendered registry is prose"
    );

    // The #1407 case: the hook installs in the project, the carrier is
    // registered only globally — Pi loads both settings layers, so the
    // hook is enforced.
    register_carrier(&w.home.join(".pi/agent"));
    let presence = carrier::presence(&w.env, &project_scope);
    assert!(presence.global && !presence.project);
    assert_eq!(
        carrier::enforcement(&w.env, &project_scope),
        Enforcement::Enforced
    );

    // And the mirror case: a project carrier alone also enforces.
    fs::remove_file(w.home.join(".pi/agent/settings.json")).unwrap();
    register_carrier(&w.project.join(".pi"));
    let presence = carrier::presence(&w.env, &project_scope);
    assert!(!presence.global && presence.project);
    assert_eq!(
        carrier::enforcement(&w.env, &project_scope),
        Enforcement::Enforced
    );

    // The global scope reads only the layers Pi loads globally.
    assert_eq!(
        carrier::enforcement(&w.env, &Scope::Global),
        Enforcement::Advisory
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_mappable_event_renders_the_registry_in_pi_listener_names() {
    let w = world();
    register_carrier(&w.project.join(".pi"));
    declare_hook(&w, "PreToolUse");

    let report = audit(&w.env, &scope(&w)).unwrap();
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();

    let script = w.project.join(".pi/kendex/hooks/guard.sh");
    assert!(
        script.is_file(),
        "the hook script lands beside the registry"
    );
    let registry = fs::read_to_string(w.project.join(".pi/kendex/hooks.json")).unwrap();
    assert!(
        registry.contains("tool_call"),
        "the registry speaks pi's listener names: {registry}"
    );
    assert!(
        !registry.contains("PreToolUse"),
        "the harness event name never reaches pi: {registry}"
    );

    // No downgrade warning while the carrier is registered.
    let report = audit(&w.env, &scope(&w)).unwrap();
    assert!(
        !report
            .warnings
            .iter()
            .any(|warning| warning.message.contains("carrier")),
        "{:?}",
        report.warnings
    );
    assert!(report.drift.is_empty(), "{:?}", report.drift);
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_unmappable_event_installs_nothing_on_pi() {
    let w = world();
    register_carrier(&w.project.join(".pi"));
    declare_hook(&w, "PostCompact");

    let report = audit(&w.env, &scope(&w)).unwrap();
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("unsupported on pi")),
        "{:?}",
        report.notes
    );
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();
    assert!(
        !w.project.join(".pi/kendex/hooks/guard.sh").exists(),
        "no stale advisory artifact for an event pi cannot fire"
    );
    assert!(!w.project.join(".pi/kendex/hooks.json").exists());
}

#[test]
#[allow(clippy::unwrap_used)]
fn labels_downgrade_per_item_when_the_carrier_is_missing() {
    let w = world();
    declare_hook(&w, "PreToolUse");

    let report = audit(&w.env, &scope(&w)).unwrap();
    let warning = report
        .warnings
        .iter()
        .find(|warning| warning.message.contains("carrier"))
        .unwrap_or_else(|| panic!("no carrier warning: {:?}", report.warnings));
    assert!(
        warning
            .remediation
            .as_deref()
            .is_some_and(|fix| fix.contains("pi-hooks")),
        "{warning:?}"
    );
}

/// Pi warns about a `hooks/` beside a root it loads on the name alone —
/// so the name is one kendex never writes.
#[test]
#[allow(clippy::unwrap_used)]
fn nothing_lands_in_the_directory_names_pi_reserved() {
    let w = world();
    register_carrier(&w.project.join(".pi"));
    declare_hook(&w, "PreToolUse");

    let report = audit(&w.env, &scope(&w)).unwrap();
    kendex_core::apply::execute(&w.env, &report.plan, None).unwrap();

    assert!(
        !w.project.join(".pi/hooks").exists(),
        "the reserved directory name makes pi warn at every start"
    );
}
