//! A `[[custom-hooks]]` entry is command-bodied: it writes no script and
//! exists under the reserved name only as a registry entry, whose command
//! is the person's own and which the lock recorded verbatim. Synthesizing
//! the command instead of reading it back would match nothing, and the old
//! registry would sit there being warned about forever.

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

const DECLARATION: &str = "[[custom-hooks]]\nname = \"mine\"\nevent = \"PreToolUse\"\nmatcher = \"Bash\"\ncommand = \"./scripts/mine.sh\"\nagents = \"all\"\n";

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
    fs::write(
        project.join(".pi/settings.json"),
        r#"{ "packages": ["./packages/pi-hooks"] }"#,
    )
    .unwrap();
    fs::create_dir_all(home.join(".pi/agent")).unwrap();
    fs::write(
        home.join(".pi/agent/settings.json"),
        r#"{ "packages": ["./packages/pi-hooks"] }"#,
    )
    .unwrap();
    World {
        env: Env::fake(&home, FakeOs::Linux),
        home,
        project,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn apply(env: &Env, scope: &Scope) {
    let report = audit(env, scope).unwrap();
    kendex_core::apply::execute(env, &report.plan, None).unwrap();
}

/// The registry an earlier kendex wrote: the same document, at the name
/// pi reserved. A custom hook's command is the person's own, so the move
/// changes nothing inside it — only where it lives.
#[allow(clippy::unwrap_used)]
fn regress(root: &Path) {
    let registry = fs::read_to_string(root.join("kendex/hooks.json")).unwrap();
    fs::write(root.join("hooks.json"), registry).unwrap();
    fs::remove_dir_all(root.join("kendex")).unwrap();
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_command_bodied_hook_leaves_the_reserved_registry_behind() {
    let w = world();
    let scope = Scope::Project {
        root: w.project.clone(),
    };
    fs::write(
        w.project.join("kendex.toml"),
        format!("schema = 5\n\n[install]\nharnesses = [\"pi\"]\n\n{DECLARATION}"),
    )
    .unwrap();
    apply(&w.env, &scope);
    let dot = w.project.join(".pi");
    assert!(
        fs::read_to_string(dot.join("kendex/hooks.json"))
            .unwrap()
            .contains("./scripts/mine.sh"),
        "the person's own command is what is registered"
    );
    regress(&dot);

    apply(&w.env, &scope);

    assert!(
        !dot.join("hooks.json").exists(),
        "the registry under the reserved name is retired by the command the lock recorded"
    );
    assert!(
        fs::read_to_string(dot.join("kendex/hooks.json"))
            .unwrap()
            .contains("./scripts/mine.sh"),
        "and the person's command still runs from the new one"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_command_bodied_global_hook_leaves_the_reserved_registry_behind() {
    let w = world();
    let manifest = w.env.global_manifest_file();
    fs::create_dir_all(manifest.parent().unwrap()).unwrap();
    fs::write(
        &manifest,
        format!("schema = 5\n\n[install]\nharnesses = [\"pi\"]\n\n{DECLARATION}"),
    )
    .unwrap();
    apply(&w.env, &Scope::Global);
    let agent = w.home.join(".pi/agent");
    regress(&agent);

    apply(&w.env, &Scope::Global);

    assert!(!agent.join("hooks.json").exists());
    assert!(
        fs::read_to_string(agent.join("kendex/hooks.json"))
            .unwrap()
            .contains("./scripts/mine.sh")
    );
}

/// A custom hook is declared in its own table, so the retirement decision
/// has to see it there: read as undeclared it would be retired the moment
/// anything held its rendering back.
#[test]
#[allow(clippy::unwrap_used)]
fn a_declared_custom_hook_is_not_read_as_one_nobody_declares() {
    let w = world();
    let scope = Scope::Project {
        root: w.project.clone(),
    };
    fs::write(
        w.project.join("kendex.toml"),
        format!("schema = 5\n\n[install]\nharnesses = [\"pi\"]\n\n{DECLARATION}"),
    )
    .unwrap();
    apply(&w.env, &scope);
    let dot = w.project.join(".pi");
    regress(&dot);
    // The new registry cannot be written, so nothing proves the move.
    fs::create_dir_all(dot.join("kendex")).unwrap();
    fs::write(dot.join("kendex/hooks.json"), "{ not json").unwrap();

    apply(&w.env, &scope);

    assert!(
        fs::read_to_string(dot.join("hooks.json"))
            .unwrap()
            .contains("./scripts/mine.sh"),
        "a declaration that could not be rendered keeps the hook it is running"
    );
}
