//! A project-only refresh under an enabled global carrier keeps the command
//! check and the mailbox hold tied to the project install, whether the
//! carrier names the registration (pi-hooks 0.19.3 and later) or not
//! (0.19.2 and earlier). Both shipped guards read the registration. When
//! both scopes share a registry, the render refuses calls from older
//! carriers because it cannot recover the registration.

use super::{World, carrier_runner, register_carrier, scope, source_path, world};
use crate::test_util;
use kendex_core::engine::{PlanOptions, plan_apply};
use kendex_core::harness::Enforcement;
use kendex_core::pi_ext::carrier;
use serde_json::Value;
use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::Command;

const GUARDS: [&str; 3] = ["command-safety", "lane-mail-check", "lane-mail-halt"];

#[derive(Clone, Copy, Debug)]
enum Layout {
    /// `<project>/.pi` is a directory of its own.
    Ordinary,
    /// `<project>/.pi` links to a directory elsewhere in the project.
    Linked,
    /// The global root is elsewhere in the project, and the project's hook
    /// directory links into the global one: one directory of scripts, two
    /// registries, the hooks registered in the project's alone.
    LinkedHooks,
    /// The global root is `<project>/.pi`, so both registries are one file
    /// and every hook script is both scopes' install.
    Overlap,
    /// Rendered as `Ordinary`, then Pi is pointed at the checkout's `.pi`:
    /// the overlap of a checkout whose files were written before.
    Retargeted,
}

#[allow(clippy::unwrap_used)]
fn executable(path: &Path, text: &str) {
    fs::write(path, text).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

/// The catalog's three guards, as the repository ships them, or with a body
/// that passes everything, the hooks a refresh replaces.
#[allow(clippy::unwrap_used)]
fn catalog_guards(catalog: &Path, refreshed: bool) {
    let hooks = test_util::checkout_root().join("hooks");
    for guard in GUARDS {
        let text = fs::read_to_string(hooks.join(format!("{guard}.sh"))).unwrap();
        let (header, body) = text.split_once("\n# ---\n\n").unwrap();
        let header = if guard == "lane-mail-check" {
            // The other companion listeners are outside this tool_call case.
            header
                .lines()
                .filter(|line| !line.starts_with("# requires:"))
                .collect::<Vec<_>>()
                .join("\n")
        } else {
            header.to_owned()
        };
        let body = if refreshed { body } else { "exit 0\n" };
        fs::write(
            catalog.join(format!("hooks/{guard}.sh")),
            format!("{header}\n# ---\n\n{body}"),
        )
        .unwrap();
    }
}

/// The skills the guards read. Each fixture reader requires the project's
/// registration even where both scopes can reach the same files.
#[allow(clippy::unwrap_used)]
fn catalog_skills(catalog: &Path) {
    for skill in ["commit-guards", "mailbox", "orch", "agent-runtime"] {
        let dir = catalog.join("skills").join(skill);
        fs::create_dir_all(dir.join("scripts")).unwrap();
        fs::write(
            dir.join("SKILL.md"),
            format!("---\nname: {skill}\ndescription: Test skill\n---\n"),
        )
        .unwrap();
    }
    let libraries = catalog.join("skills/commit-guards/scripts/lib");
    fs::create_dir(&libraries).unwrap();
    for file in
        fs::read_dir(test_util::checkout_root().join("skills/commit-guards/scripts/lib")).unwrap()
    {
        let file = file.unwrap();
        fs::copy(file.path(), libraries.join(file.file_name())).unwrap();
    }
    let settings = libraries.join("settings.sh");
    let loader = fs::read_to_string(&settings).unwrap();
    fs::write(
        settings,
        format!(
            r#"[[ "${{KENDEX_HOOK_SCOPE:-}}" = project &&
      "${{KENDEX_HOOK_ROOT:-}}" = "$FIXTURE_PROJECT" ]] || return 1
{loader}"#
        ),
    )
    .unwrap();
    executable(
        &catalog.join("skills/mailbox/scripts/lane-mail"),
        "#!/bin/sh\nexit 1\n",
    );
    // The orch suite covers the mailbox decision. Here the installed runtime
    // holds the turn only for the project's hook directory, with the
    // fixture's halt standing.
    executable(
        &catalog.join("skills/orch/scripts/orch-runtime"),
        r#"#!/bin/bash
set -eu
# orch-runtime: hook-entry-no-build
if [[ "$#" = 4 && "$1:$2:$4" = turn-end:--hook-dir:halt &&
      "${KENDEX_HOOK_SCOPE:-}" = project && "${KENDEX_HOOK_ROOT:-}" = "$FIXTURE_PROJECT" &&
      "$3" -ef "$FIXTURE_PROJECT/.pi/kendex/hooks" && -f "$FIXTURE_PROJECT/halt" ]]; then
  printf 'lane-mail-check: halt=fixture\n' >&2
  exit 2
fi
"#,
    );
}

#[allow(clippy::unwrap_used)]
fn refresh_project(world: &World, env: &kendex_core::env::Env, catalog: &Path, refreshed: bool) {
    catalog_guards(catalog, refreshed);
    let report = plan_apply(env, &scope(world), &PlanOptions::current()).unwrap();
    kendex_core::apply::execute(env, &report.plan).unwrap();
}

#[test]
fn a_project_refresh_keeps_both_pi_guards_on_the_project_install_under_either_carrier() {
    let Some(bun) = carrier_runner() else { return };
    for layout in [
        Layout::Ordinary,
        Layout::Linked,
        Layout::LinkedHooks,
        Layout::Overlap,
        Layout::Retargeted,
    ] {
        assert_project_refresh(&bun, layout);
    }
}

#[allow(clippy::unwrap_used)]
fn assert_project_refresh(bun: &Path, layout: Layout) {
    let w = world();
    let global = match layout {
        Layout::Ordinary | Layout::Retargeted => w.home.join(".pi/agent"),
        Layout::Linked => {
            let pi = w.project.join(".pi");
            let shared = w.project.join("shared-pi");
            fs::rename(&pi, &shared).unwrap();
            symlink(&shared, &pi).unwrap();
            w.home.join(".pi/agent")
        }
        Layout::LinkedHooks => {
            let global = w.project.join("global-pi");
            fs::create_dir_all(global.join("kendex/hooks")).unwrap();
            fs::create_dir_all(w.project.join(".pi/kendex")).unwrap();
            symlink(
                global.join("kendex/hooks"),
                w.project.join(".pi/kendex/hooks"),
            )
            .unwrap();
            global
        }
        Layout::Overlap => w.project.join(".pi"),
    };
    let env = w
        .env
        .clone()
        .with_var("PI_CODING_AGENT_DIR", &global.to_string_lossy());
    let catalog = w.home.join("cat");
    fs::create_dir_all(catalog.join("hooks")).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    catalog_skills(&catalog);

    register_carrier(&global);
    assert_eq!(
        carrier::enforcement(&env, &scope(&w)),
        Enforcement::Enforced,
        "{layout:?}"
    );
    let nested = w.project.join("nested");
    fs::create_dir(&nested).unwrap();
    test_util::git(&w.project, &["init", "-q"]);
    fs::write(
        w.project.join("kendex.toml"),
        format!(
            "schema = 8\n[sources.cat]\n{}\n[install]\nharnesses = [\"pi\"]\n[hooks.command-safety]\nsource = 'cat'\n[hooks.lane-mail-halt]\nsource = 'cat'\n",
            source_path(&catalog)
        ),
    )
    .unwrap();
    fs::write(
        w.project.join("kendex.settings.toml"),
        "[env]\nCOMMAND_SAFETY_DENY_PATTERN = '^echo configured-policy$'\n",
    )
    .unwrap();
    refresh_project(&w, &env, &catalog, false);
    let settings = fs::read(global.join("settings.json")).unwrap();
    refresh_project(&w, &env, &catalog, true);
    assert_eq!(
        fs::read(global.join("settings.json")).unwrap(),
        settings,
        "{layout:?}: the project refresh rewrote the global carrier's settings"
    );
    // The global root a session reads from from here on.
    let global = match layout {
        Layout::Retargeted => w.project.join(".pi"),
        _ => global,
    };

    let guarded = vec![
        None,
        None,
        Some("command-safety: refused=policy".to_owned()),
        Some("lane-mail-check: halt=fixture".to_owned()),
    ];
    let metadata = drive(bun, &w, &nested, &global, Carrier::Metadata);
    assert_eq!(metadata, guarded, "{layout:?}, carrier metadata");
    let legacy = drive(bun, &w, &nested, &global, Carrier::Legacy);
    match layout {
        Layout::Ordinary | Layout::Linked | Layout::LinkedHooks => {
            assert_eq!(legacy, guarded, "{layout:?}, pi-hooks 0.19.2 spawn");
        }
        Layout::Overlap | Layout::Retargeted => {
            let refused = [
                "command-safety",
                "lane-mail-check",
                "command-safety",
                "lane-mail-check",
            ]
            .map(|hook| {
                Some(format!(
                    "kendex-hook-scope-overlap: hook={hook} carrier=pi-hooks>=0.19.3"
                ))
            });
            assert_eq!(legacy, refused, "{layout:?}, pi-hooks 0.19.2 spawn");
        }
    }
}

/// How the carrier starts a hook.
#[derive(Clone, Copy)]
enum Carrier {
    /// The carrier under test, which names the registration.
    Metadata,
    /// pi-hooks 0.19.2, which starts the same registry-anchored script with
    /// neither variable. The variables are dropped at the subprocess
    /// boundary, so the run stays offline and the rest of the path is the
    /// production one.
    Legacy,
}

/// The first line of each refusal the driver's calls met, `None` for a call
/// that passed.
#[allow(clippy::unwrap_used)]
fn drive(
    bun: &Path,
    w: &World,
    cwd: &Path,
    global: &Path,
    carrier: Carrier,
) -> Vec<Option<String>> {
    let path = std::env::var_os("PATH").unwrap();
    let path = match carrier {
        Carrier::Metadata => path,
        Carrier::Legacy => {
            let shim = w.home.join("shim");
            if !shim.exists() {
                fs::create_dir(&shim).unwrap();
                executable(
                    &shim.join("bash"),
                    "#!/bin/sh\nunset KENDEX_HOOK_SCOPE KENDEX_HOOK_ROOT\nexec /bin/bash \"$@\"\n",
                );
            }
            let dirs: Vec<PathBuf> = std::iter::once(shim)
                .chain(std::env::split_paths(&path))
                .collect();
            std::env::join_paths(dirs).unwrap()
        }
    };
    let driver = w.home.join("drive.ts");
    fs::write(&driver, include_str!("../fixtures/pi-hook-refresh.ts")).unwrap();
    let run = Command::new(bun)
        .args(["run", "--no-install"])
        .arg(&driver)
        .arg(
            test_util::checkout_root()
                .join("pi-extensions/pi-hooks")
                .join("extensions/hooks.ts"),
        )
        .arg(cwd)
        .current_dir(&w.home)
        .env_clear()
        .envs(test_util::fixture_env(&w.home))
        .env("XDG_STATE_HOME", w.home.join(".local/state"))
        .env("PI_CODING_AGENT_DIR", global)
        .env("FIXTURE_PROJECT", &w.project)
        .env("PATH", path)
        .output()
        .unwrap();
    assert!(
        run.status.success(),
        "carrier run failed: {}",
        String::from_utf8_lossy(&run.stderr)
    );
    let lines: Vec<Value> = serde_json::from_slice(&run.stdout).unwrap();
    lines
        .into_iter()
        .map(|line| line.as_str().map(str::to_owned))
        .collect()
}
