//! A Pi hook kendex renders names the install it was rendered for to a
//! carrier that names no registration (pi-hooks 0.19.2 and earlier): the
//! scope from the render, the root from the path the registry spawned.

use super::{World, source_path, world};
use kendex_core::engine::audit;
use kendex_core::model::Scope;
use std::fs;
use std::path::Path;
use std::process::Command;

/// The rendered hook's body: the registration it runs under.
const REPORT: &str =
    "printf '%s|%s' \"${KENDEX_HOOK_SCOPE-unset}\" \"${KENDEX_HOOK_ROOT-unset}\"\n";

/// The project and the global render of one hook, through the ordinary plan.
#[allow(clippy::unwrap_used)]
fn renders(w: &World) -> (Vec<u8>, Vec<u8>) {
    let catalog = w.home.join("cat");
    fs::create_dir_all(catalog.join("hooks")).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        catalog.join("hooks/guard.sh"),
        format!(
            "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# description: a guard\n# harnesses: [pi]\n# ---\n{REPORT}"
        ),
    )
    .unwrap();
    let manifest = format!(
        "schema = 8\n[sources.cat]\n{}\n[install]\nharnesses = [\"pi\"]\n[hooks.guard]\nsource = \"cat\"\n",
        source_path(&catalog)
    );
    let global = w.env.global_manifest_file();
    fs::create_dir_all(global.parent().unwrap()).unwrap();
    fs::write(&global, &manifest).unwrap();
    fs::write(w.project.join("kendex.toml"), &manifest).unwrap();
    let project = Scope::Project {
        root: w.project.clone(),
    };
    for scope in [&project, &Scope::Global] {
        let report = audit(&w.env, scope).unwrap();
        kendex_core::apply::execute(&w.env, &report.plan).unwrap();
    }
    let root = kendex_core::harness::adapter(kendex_core::model::HarnessId::Pi)
        .default_global_root(&w.env);
    (
        fs::read(w.project.join(".pi/kendex/hooks/guard.sh")).unwrap(),
        fs::read(root.join("kendex/hooks/guard.sh")).unwrap(),
    )
}

/// Run `script` saved at `spawned` under `dir` as a carrier starts a
/// rendered hook, `bash <path>`, with only the registration variables
/// `carrier` sets. Its status and stdout.
#[allow(clippy::unwrap_used)]
fn spawn(
    dir: &Path,
    spawned: &str,
    script: &[u8],
    carrier: &[(&str, &str)],
) -> (Option<i32>, String) {
    let path = dir.join(spawned);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, script).unwrap();
    let out = Command::new("bash")
        .arg(spawned)
        .current_dir(dir)
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap())
        .envs(carrier.iter().copied())
        .output()
        .unwrap();
    (
        out.status.code(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
    )
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_rendered_pi_hook_names_its_install_to_a_carrier_that_names_none() {
    let w = world();
    let (project, global) = renders(&w);
    let dir = w.home.join("spawned");
    fs::create_dir(&dir).unwrap();
    let at = |rest: &str| format!("{}/{rest}", dir.display());
    // A Windows carrier spawns with backslashes. A Linux file name may hold
    // them, so each of those spellings runs here as one literal file name.
    let installed = w.project.join(".pi/kendex/hooks/guard.sh");
    for (script, spawned, carrier, expected) in [
        (
            &project,
            installed.display().to_string(),
            &[][..],
            format!("project|{}", w.project.display()),
        ),
        (
            &project,
            at("p/.pi/kendex/hooks/guard.sh"),
            &[],
            format!("project|{}", at("p")),
        ),
        (
            &global,
            at("agent/kendex/hooks/guard.sh"),
            &[],
            format!("global|{}", at("agent")),
        ),
        // A global root moved into a checkout's `.pi` is still the global install.
        (
            &global,
            at("c/.pi/kendex/hooks/guard.sh"),
            &[],
            format!("global|{}", at("c/.pi")),
        ),
        (
            &project,
            r"C:\p\.pi\kendex\hooks\guard.sh".to_owned(),
            &[],
            r"project|C:\p".to_owned(),
        ),
        (
            &project,
            r"C:\.pi\kendex\hooks\guard.sh".to_owned(),
            &[],
            r"project|C:\".to_owned(),
        ),
        (
            &global,
            r"\\srv\share\pi\kendex\hooks\guard.sh".to_owned(),
            &[],
            r"global|\\srv\share\pi".to_owned(),
        ),
        // No registry spawned these: a relative path, and another hook's name.
        (
            &project,
            "p/.pi/kendex/hooks/guard.sh".to_owned(),
            &[],
            "unset|unset".to_owned(),
        ),
        (
            &project,
            at("p/.pi/kendex/hooks/other.sh"),
            &[],
            "unset|unset".to_owned(),
        ),
        // A carrier's own registration stands, either variable alone too.
        (
            &project,
            at("p/.pi/kendex/hooks/guard.sh"),
            &[("KENDEX_HOOK_SCOPE", "global"), ("KENDEX_HOOK_ROOT", "/r")],
            "global|/r".to_owned(),
        ),
        (
            &project,
            at("p/.pi/kendex/hooks/guard.sh"),
            &[("KENDEX_HOOK_ROOT", "")],
            "unset|".to_owned(),
        ),
    ] {
        assert_eq!(
            spawn(&dir, &spawned, script, carrier),
            (Some(0), expected),
            "{spawned} {carrier:?}"
        );
    }
}
