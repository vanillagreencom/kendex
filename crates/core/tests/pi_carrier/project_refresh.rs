//! A project-only refresh leaves the global carrier enabled and supplies the
//! install location to its two guards, even on the 0.19.2 spawn contract.

use super::{World, carrier_runner, register_carrier, scope, source_path, world};
use crate::test_util;
use kendex_core::engine::{PlanOptions, plan_apply};
use kendex_core::harness::Enforcement;
use kendex_core::pi_ext::carrier;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;

const GUARDS: [&str; 3] = ["command-safety", "lane-mail-check", "lane-mail-halt"];

#[allow(clippy::unwrap_used)]
fn executable(path: &Path, text: &str) {
    fs::write(path, text).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

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

#[allow(clippy::unwrap_used)]
fn catalog_skills(catalog: &Path, repo: &Path) {
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
    executable(
        &catalog.join("skills/mailbox/scripts/lane-mail"),
        "#!/bin/sh\nexit 1\n",
    );
    // The orch suite covers its mailbox decision. Here its installed launcher
    // verifies the transport, so passing without locating it or wiring up
    // its halt arm cannot satisfy the carrier contract.
    executable(
        &catalog.join("skills/orch/scripts/orch-runtime"),
        r#"#!/bin/bash
set -eu
# orch-runtime: hook-entry-no-build
if [[ "$#" = 4 && "$1:$2:$4" = turn-end:--hook-dir:halt &&
      "${KENDEX_HOOK_SCOPE:-}" = project && "${KENDEX_HOOK_ROOT:-}" = "$FIXTURE_PROJECT" &&
      "$3" = "$FIXTURE_PROJECT/.pi/kendex/hooks" && -f "$FIXTURE_PROJECT/halt" ]]; then
  printf 'lane-mail-check: halt=fixture\n' >&2
  exit 2
fi
"#,
    );
}

#[allow(clippy::unwrap_used)]
fn refresh_project(world: &World, catalog: &Path, repo: &Path, refreshed: bool) {
    catalog_guards(catalog, repo, refreshed);
    let report = plan_apply(
        &world.env,
        &scope(world),
        &PlanOptions {
            recover_version_10: true,
            ..PlanOptions::current()
        },
    )
    .unwrap();
    kendex_core::apply::execute(&world.env, &report.plan).unwrap();
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_project_refresh_keeps_both_pi_guards_enforced_with_or_without_carrier_metadata() {
    let Some(bun) = carrier_runner() else { return };
    let w = world();
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let catalog = w.home.join("cat");
    fs::create_dir_all(catalog.join("hooks")).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    catalog_skills(&catalog, &repo);

    let global = w.home.join(".pi/agent");
    register_carrier(&global);
    let settings = fs::read(global.join("settings.json")).unwrap();
    assert_eq!(
        carrier::enforcement(&w.env, &scope(&w)),
        Enforcement::Enforced
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
    refresh_project(&w, &catalog, &repo, false);
    refresh_project(&w, &catalog, &repo, true);
    assert_eq!(fs::read(global.join("settings.json")).unwrap(), settings);

    // pi-hooks 0.19.2 runs the same registry-anchored Bash command without
    // adding either variable. Drop them at the subprocess boundary to keep
    // this regression offline and preserve the rest of the production path.
    let shim = w.home.join("shim");
    fs::create_dir(&shim).unwrap();
    executable(
        &shim.join("bash"),
        "#!/bin/sh\nunset KENDEX_HOOK_SCOPE KENDEX_HOOK_ROOT\nexec /bin/bash \"$@\"\n",
    );
    let path = std::env::var_os("PATH").unwrap();
    let old_spawn =
        std::env::join_paths(std::iter::once(shim).chain(std::env::split_paths(&path))).unwrap();
    let driver = w.home.join("drive.ts");
    fs::write(&driver, include_str!("../fixtures/pi-hook-refresh.ts")).unwrap();
    let entry = repo.join("pi-extensions/pi-hooks/extensions/hooks.ts");
    for (mode, path) in [
        ("published 0.19.2 spawn environment", old_spawn),
        ("carrier metadata", path),
    ] {
        let run = Command::new(&bun)
            .args(["run", "--no-install"])
            .arg(&driver)
            .arg(&entry)
            .arg(&nested)
            .current_dir(&w.home)
            .env_clear()
            .envs(test_util::fixture_env(&w.home))
            .env("XDG_STATE_HOME", w.home.join(".local/state"))
            .env("PI_CODING_AGENT_DIR", &global)
            .env("FIXTURE_PROJECT", &w.project)
            .env("PATH", path)
            .output()
            .unwrap();
        assert!(
            run.status.success(),
            "{mode}: {}",
            String::from_utf8_lossy(&run.stderr)
        );
    }
}
