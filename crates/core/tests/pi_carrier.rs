//! Pi hooks, enforced through the carrier: events map onto the listeners
//! Pi actually fires (unmappable ones stay honestly unsupported), labels
//! read carrier reality at both scopes — a project-installed hook with a
//! global carrier is enforced, the v1 #1407 lesson — and everything
//! renders through the ordinary plan.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

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
        r#"{ "packages": ["./packages/@vanillagreen/pi-hooks"] }"#,
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
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"pi\"]\nmethod = \"symlink\"\n\n[hooks.guard]\nsource = \"cat\"\n",
            source_path(&catalog)
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
    kendex_core::apply::execute(&w.env, &report.plan).unwrap();

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
    kendex_core::apply::execute(&w.env, &report.plan).unwrap();
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
    kendex_core::apply::execute(&w.env, &report.plan).unwrap();

    assert!(
        !w.project.join(".pi/hooks").exists(),
        "the reserved directory name makes pi warn at every start"
    );
}

/// A scope carrying the layout an older kendex wrote: script and registry
/// beside the root, nothing under `kendex/`. Everything here reads or
/// writes one level down, so the files beside the root are outside every
/// path this build takes — including removal's. They stay exactly as they
/// are, the refresh renders the hook under `kendex/` on its own, and the
/// pass after it changes nothing.
///
/// Said plainly because `docs/adapters/pi.md` says it: what is beside the
/// root is the person's to deal with by hand. `kendex remove` does not
/// touch it, and nothing in this build does.
#[test]
#[allow(clippy::unwrap_used)]
fn the_older_layout_beside_the_root_is_left_exactly_where_it_is() {
    let w = world();
    register_carrier(&w.project.join(".pi"));
    declare_hook(&w, "PreToolUse");
    let report = audit(&w.env, &scope(&w)).unwrap();
    kendex_core::apply::execute(&w.env, &report.plan).unwrap();

    // Put the installation back where an older kendex kept it: script and
    // registry beside the root, with kendex's own segment gone.
    let home = w.project.join(".pi/kendex");
    let beside_script = w.project.join(".pi/hooks/guard.sh");
    let beside_registry = w.project.join(".pi/hooks.json");
    fs::create_dir_all(beside_script.parent().unwrap()).unwrap();
    fs::rename(home.join("hooks/guard.sh"), &beside_script).unwrap();
    fs::rename(home.join("hooks.json"), &beside_registry).unwrap();
    fs::remove_dir_all(&home).unwrap();
    let left_script = fs::read_to_string(&beside_script).unwrap();
    let left_registry = fs::read_to_string(&beside_registry).unwrap();

    // The refresh renders the hook under `kendex/` and stops there.
    let report = audit(&w.env, &scope(&w)).unwrap();
    kendex_core::apply::execute(&w.env, &report.plan).unwrap();
    assert!(home.join("hooks/guard.sh").is_file());
    assert!(
        fs::read_to_string(home.join("hooks.json"))
            .unwrap()
            .contains("guard.sh")
    );

    // And the pass after it settles.
    let settled = audit(&w.env, &scope(&w)).unwrap();
    assert!(settled.plan.ops.is_empty(), "{:?}", settled.plan.ops);

    // Nothing touched what is beside the root — not the refresh, and not
    // a removal, which derives its paths the same way.
    let removal = kendex_core::engine::ops::remove(
        &w.env,
        &scope(&w),
        std::slice::from_ref(&"guard".to_owned()),
        None,
        false,
    )
    .unwrap();
    kendex_core::apply::execute(&w.env, &removal.plan).unwrap();
    assert!(
        !home.join("hooks/guard.sh").exists(),
        "removal takes what this build wrote"
    );
    assert_eq!(fs::read_to_string(&beside_script).unwrap(), left_script);
    assert_eq!(fs::read_to_string(&beside_registry).unwrap(), left_registry);
}

/// Is `bun` on PATH? The carrier is TypeScript, so the case below runs the
/// real extension the way its own suite does.
fn bun_on_path() -> Option<std::path::PathBuf> {
    std::env::var_os("PATH").and_then(|path| {
        std::env::split_paths(&path)
            .map(|dir| dir.join("bun"))
            .find(|candidate| candidate.is_file())
    })
}

/// The lane that has to prove the case below rather than skip it: CI on
/// Linux, where `.github/workflows/skill-tests.yml`'s `cargo-tests` job
/// installs bun. Without this, deleting that one step turns KEN-941's only
/// end-to-end proof into a permanent silent pass — cargo swallows the
/// `eprintln!` of a passing test. macOS and Windows install no bun and skip.
fn bun_is_required() -> bool {
    cfg!(target_os = "linux")
        && (std::env::var_os("GITHUB_ACTIONS").is_some() || std::env::var_os("CI").is_some())
}

/// End to end, KEN-475: a hook declared in `kendex.toml` fires under Pi.
///
/// A `[[custom-hooks]]` entry is the case that proves it, because a custom
/// hook has no file of its own — kendex registers the person's command
/// verbatim, so it exists nowhere but the rendered registry. The engine
/// renders it here and the `pi-hooks` carrier's own `tool_call` handler runs
/// it, which is the whole chain the `enforced` label claims (KEN-941).
#[test]
#[allow(clippy::unwrap_used)]
fn a_declared_custom_hook_fires_through_the_carrier() {
    let Some(bun) = bun_on_path() else {
        assert!(
            !bun_is_required(),
            "bun is not on PATH: restore the oven-sh/setup-bun step in the cargo-tests job of .github/workflows/skill-tests.yml, or this case proves nothing"
        );
        eprintln!("skipped: bun is not on PATH, so the carrier cannot be run");
        return;
    };
    let w = world();
    register_carrier(&w.project.join(".pi"));
    fs::write(
        w.project.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"pi\"]\n\n[[custom-hooks]]\nname = \"e2e-guard\"\nevent = \"PreToolUse\"\nmatcher = \"Bash\"\ncommand = \"echo ken-941-fired >&2; exit 2\"\nagents = \"all\"\n",
    )
    .unwrap();

    let report = audit(&w.env, &scope(&w)).unwrap();
    kendex_core::apply::execute(&w.env, &report.plan).unwrap();
    let registry = fs::read_to_string(w.project.join(".pi/kendex/hooks.json")).unwrap();
    assert!(
        registry.contains("ken-941-fired"),
        "the person's command rides in the registry: {registry}"
    );

    // The real carrier, driven the way Pi drives it: one bash tool call.
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let carrier = repo.join("pi-extensions/pi-hooks/extensions/hooks.ts");
    let driver = w.home.join("drive.ts");
    fs::write(
        &driver,
        format!(
            "import piHooks from {carrier};\nlet handler;\npiHooks({{ on(event, callback) {{ if (event === \"tool_call\") handler = callback; }} }});\nconst verdict = await handler(\n\t{{ toolName: \"bash\", input: {{ command: \"git push\" }} }},\n\t{{ cwd: {project}, isProjectTrusted: () => true }},\n);\nprocess.stdout.write(JSON.stringify(verdict ?? null));\n",
            carrier = serde_json::to_string(&carrier.to_string_lossy()).unwrap(),
            project = serde_json::to_string(&w.project.to_string_lossy()).unwrap(),
        ),
    )
    .unwrap();

    let run = std::process::Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .current_dir(&w.project)
        // The fixture's global root, so the run reads no Pi install of the
        // developer's; the project root is the walk's own answer from the
        // working directory, which is the project below.
        .env("PI_CODING_AGENT_DIR", w.home.join(".pi/agent"))
        .output()
        .unwrap();
    assert!(
        run.status.success(),
        "carrier run failed: {}",
        String::from_utf8_lossy(&run.stderr)
    );
    let verdict = String::from_utf8_lossy(&run.stdout);
    assert!(
        verdict.contains("\"block\":true") && verdict.contains("ken-941-fired"),
        "the declared hook did not fire: {verdict}"
    );
}
