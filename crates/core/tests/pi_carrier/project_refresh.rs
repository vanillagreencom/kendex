//! A project-only refresh under an enabled global carrier keeps the command
//! check and the mailbox hold tied to the project install, whether the
//! carrier names the registration (pi-hooks 0.19.3 and later) or not
//! (0.19.2 and earlier), and a file that is both scopes' install is refused
//! under a carrier that cannot say which registration started it.
//!
//! The guards run as the repository ships them, over two sets of the skills
//! they read: the shipped readers, which take the install from the path the
//! guard hands them, and readers that demand the project registration, the
//! readers KEN-5647 moves the guards onto.

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

/// The skills the guards read their install through.
#[derive(Clone, Copy, Debug)]
enum Readers {
    /// The repository's settings loader, and a turn-end runtime that holds
    /// for the hook directory the guard hands it.
    Shipped,
    /// Both of those, answering only for the project registration.
    Registration,
}

#[allow(clippy::unwrap_used)]
fn executable(path: &Path, text: &str) {
    fs::write(path, text).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

/// The catalog's three guards, as the repository ships them, or with a body
/// that passes everything, the hooks a refresh replaces.
#[allow(clippy::unwrap_used)]
fn catalog_guards(catalog: &Path, repo: &Path, refreshed: bool) {
    for guard in GUARDS {
        let text = fs::read_to_string(repo.join(format!("hooks/{guard}.sh"))).unwrap();
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

/// The skills the guards read. Under `Readers::Registration` each reader the
/// guards reach demands the project install's registration, so a guard that
/// lost it, or took the global one, loses its verdict.
#[allow(clippy::unwrap_used)]
fn catalog_skills(catalog: &Path, repo: &Path, readers: Readers) {
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
    for file in fs::read_dir(repo.join("skills/commit-guards/scripts/lib")).unwrap() {
        let file = file.unwrap();
        fs::copy(file.path(), libraries.join(file.file_name())).unwrap();
    }
    let registration = match readers {
        Readers::Shipped => "",
        Readers::Registration => {
            r#"&& "${KENDEX_HOOK_SCOPE:-}" = project && "${KENDEX_HOOK_ROOT:-}" = "$FIXTURE_PROJECT""#
        }
    };
    if let Readers::Registration = readers {
        // The real settings loader still reads the configured command policy;
        // it answers only for the project registration.
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
    }
    executable(
        &catalog.join("skills/mailbox/scripts/lane-mail"),
        "#!/bin/sh\nexit 1\n",
    );
    // The orch suite covers the mailbox decision. Here the installed runtime
    // holds the turn only for the project's hook directory, with the
    // fixture's halt standing.
    executable(
        &catalog.join("skills/orch/scripts/orch-runtime"),
        &format!(
            r#"#!/bin/bash
set -eu
# orch-runtime: hook-entry-no-build
if [[ "$#" = 4 && "$1:$2:$4" = turn-end:--hook-dir:halt {registration} &&
      "$3" -ef "$FIXTURE_PROJECT/.pi/kendex/hooks" && -f "$FIXTURE_PROJECT/halt" ]]; then
  printf 'lane-mail-check: halt=fixture\n' >&2
  exit 2
fi
"#
        ),
    );
}

#[allow(clippy::unwrap_used)]
fn refresh_project(
    world: &World,
    env: &kendex_core::env::Env,
    catalog: &Path,
    repo: &Path,
    refreshed: bool,
) {
    catalog_guards(catalog, repo, refreshed);
    let report = plan_apply(env, &scope(world), &PlanOptions::current()).unwrap();
    kendex_core::apply::execute(env, &report.plan).unwrap();
}

#[test]
fn a_project_refresh_keeps_both_pi_guards_on_the_project_install_under_either_carrier() {
    let Some(bun) = carrier_runner() else { return };
    for readers in [Readers::Shipped, Readers::Registration] {
        for layout in [
            Layout::Ordinary,
            Layout::Linked,
            Layout::LinkedHooks,
            Layout::Overlap,
            Layout::Retargeted,
        ] {
            assert_project_refresh(&bun, layout, readers);
        }
    }
}

#[allow(clippy::unwrap_used)]
fn assert_project_refresh(bun: &Path, layout: Layout, readers: Readers) {
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
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let catalog = w.home.join("cat");
    fs::create_dir_all(catalog.join("hooks")).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    catalog_skills(&catalog, &repo, readers);

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
    refresh_project(&w, &env, &catalog, &repo, false);
    let settings = fs::read(global.join("settings.json")).unwrap();
    refresh_project(&w, &env, &catalog, &repo, true);
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
    let metadata = drive(bun, &w, &repo, &nested, &global, Carrier::Metadata);
    let legacy = drive(bun, &w, &repo, &nested, &global, Carrier::Legacy);
    let case = format!("{layout:?}, {readers:?} readers");
    match (layout, readers) {
        (Layout::LinkedHooks, _) => {
            // The command check on main takes its install from its physical
            // directory, here the global root's, and reads no project
            // policy under either carrier; KEN-5647 moves it onto the
            // registration. The old carrier still runs what the new one does.
            assert_eq!(metadata[3], guarded[3], "{case}, carrier metadata");
            assert_eq!(legacy, metadata, "{case}, pi-hooks 0.19.2 spawn");
        }
        (Layout::Ordinary | Layout::Linked, _) => {
            assert_eq!(metadata, guarded, "{case}, carrier metadata");
            assert_eq!(legacy, guarded, "{case}, pi-hooks 0.19.2 spawn");
        }
        (Layout::Overlap | Layout::Retargeted, _) => {
            // The carrier's registration reaches the mailbox hold. The
            // command check on main still classifies this layout from its own
            // path, a global root, and reads no project policy; KEN-5647 moves
            // it onto the registration.
            assert_eq!(metadata[3], guarded[3], "{case}, carrier metadata");
            assert!(
                !metadata
                    .iter()
                    .flatten()
                    .any(|line| overlap_refusal(line).is_some()),
                "{case}, carrier metadata: {metadata:?}"
            );
            for line in &legacy {
                assert!(
                    matches!(line.as_deref().and_then(overlap_refusal), Some((hook, "carrier=pi-hooks>=0.19.3")) if GUARDS.contains(&hook)),
                    "{case}, pi-hooks 0.19.2 spawn: {legacy:?}"
                );
            }
        }
    }
}

/// The hook and the carrier floor an overlap refusal's key line names.
fn overlap_refusal(line: &str) -> Option<(&str, &str)> {
    line.strip_prefix("kendex-hook-scope-overlap: hook=")?
        .split_once(' ')
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
    repo: &Path,
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
        .arg(repo.join("pi-extensions/pi-hooks/extensions/hooks.ts"))
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
