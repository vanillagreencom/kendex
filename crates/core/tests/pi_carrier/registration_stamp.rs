//! A Pi hook kendex renders names the install it runs under to a carrier
//! that names no registration (pi-hooks 0.19.2 and earlier): the scope and
//! root the spawned path and the carrier's global root give, and, where one
//! registry file is both scopes', what the hook's declaration says to do.

use super::{World, source_path, world};
use kendex_core::engine::audit;
use kendex_core::model::Scope;
use std::fs;
use std::path::Path;
use std::process::Command;

/// The rendered hooks' body: the registration it runs under.
const REPORT: &str =
    "printf '%s|%s\\n' \"${KENDEX_HOOK_SCOPE-unset}\" \"${KENDEX_HOOK_ROOT-unset}\"\n";

/// The three hooks the case renders, by what they read of their install:
/// none, an advisory reader of a skill, and a gate on a skill.
const HOOKS: [(&str, &str); 3] = [
    ("guard", ""),
    (
        "note",
        "# safety: Advisory reader. Reads the skill.\n# requires-skills: [s]\n",
    ),
    ("gate", "# requires-skills: [s]\n"),
];

/// Each hook's project render, through the ordinary plan of both scopes.
/// One file is both scopes' install in some layouts, so the two renders
/// must be the same bytes.
#[allow(clippy::unwrap_used)]
fn renders(w: &World) -> Vec<Vec<u8>> {
    let catalog = w.home.join("cat");
    fs::create_dir_all(catalog.join("hooks")).unwrap();
    fs::create_dir_all(catalog.join("skills/s")).unwrap();
    fs::write(catalog.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        catalog.join("skills/s/SKILL.md"),
        "---\nname: s\ndescription: Test skill\n---\n",
    )
    .unwrap();
    let mut manifest = format!(
        "schema = 8\n[sources.cat]\n{}\n[install]\nharnesses = [\"pi\"]\n",
        source_path(&catalog)
    );
    for (name, header) in HOOKS {
        fs::write(
            catalog.join(format!("hooks/{name}.sh")),
            format!(
                "#!/usr/bin/env bash\n# ---\n# name: {name}\n# event: PreToolUse\n# description: a hook\n# harnesses: [pi]\n{header}# ---\n{REPORT}"
            ),
        )
        .unwrap();
        manifest.push_str(&format!("[hooks.{name}]\nsource = \"cat\"\n"));
    }
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
    HOOKS
        .iter()
        .map(|(name, _)| {
            let file = format!("kendex/hooks/{name}.sh");
            let project = fs::read(w.project.join(".pi").join(&file)).unwrap();
            assert_eq!(project, fs::read(root.join(&file)).unwrap(), "{name}");
            project
        })
        .collect()
}

#[derive(Debug, PartialEq)]
enum Outcome {
    /// Exit 0 with the body's report.
    Ran(String),
    /// Exit 0 with the overlap notice on stdout, the body not run.
    Notice(String),
    /// Exit 2 with the overlap refusal on stderr, the body not run.
    Refused(String),
}

/// Run `script` saved at `spawned` as a carrier starts a rendered hook,
/// `bash <path>` from `cwd`, with only the variables `env` sets.
#[allow(clippy::unwrap_used)]
fn spawn(dir: &Path, spawned: &str, cwd: &Path, script: &[u8], env: &[(&str, &str)]) -> Outcome {
    let path = dir.join(spawned);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, script).unwrap();
    let out = Command::new("bash")
        .arg(spawned)
        .current_dir(cwd)
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap())
        .envs(env.iter().copied())
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    let first = |text: &str| text.lines().next().unwrap_or_default().to_owned();
    match out.status.code() {
        Some(0) if stdout.contains('|') => Outcome::Ran(stdout.trim_end().to_owned()),
        Some(0) => Outcome::Notice(first(&stdout)),
        Some(2) if stdout.is_empty() => Outcome::Refused(first(&stderr)),
        code => panic!("{spawned}: exit {code:?}\n{stdout}\n{stderr}"),
    }
}

/// One spawn: the hook, the path the carrier started, the working
/// directory, the environment and what the run does.
type Row<'a> = (&'a str, String, &'a Path, Vec<(&'a str, &'a str)>, Outcome);

fn overlap(hook: &str) -> String {
    format!("kendex-hook-scope-overlap: hook={hook} carrier=pi-hooks>=0.19.3")
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_rendered_pi_hook_names_its_install_to_a_carrier_that_names_none() {
    let w = world();
    let scripts = renders(&w);
    let script = |hook: &str| &scripts[HOOKS.iter().position(|(name, _)| *name == hook).unwrap()];
    let dir = w.home.join("spawned");
    for sub in ["c/sub", "d/g"] {
        fs::create_dir_all(dir.join(sub)).unwrap();
    }
    let at = |rest: &str| format!("{}/{rest}", dir.display());
    let home = dir.display().to_string();
    let (c, c_sub, d) = (dir.join("c"), dir.join("c/sub"), dir.join("d"));
    let checkout = at("c/.pi");
    let elsewhere = at("d/g");
    let installed = w.project.join(".pi/kendex/hooks/guard.sh");
    let ran = |text: String| Outcome::Ran(text);
    // A Windows carrier spawns with backslashes. A Linux file name may hold
    // them, so each of those spellings runs here as one literal file name.
    #[rustfmt::skip]
    let rows: Vec<Row> = vec![
        ("guard", installed.display().to_string(), &dir, vec![], ran(format!("project|{}", w.project.display()))),
        ("guard", at("p/.pi/kendex/hooks/guard.sh"), &dir, vec![], ran(format!("project|{}", at("p")))),
        ("guard", at("agent/kendex/hooks/guard.sh"), &dir, vec![], ran(format!("global|{}", at("agent")))),
        ("guard", r"C:\p\.pi\kendex\hooks\guard.sh".to_owned(), &dir, vec![], ran(r"project|C:\p".to_owned())),
        ("guard", r"C:\.pi\kendex\hooks\guard.sh".to_owned(), &dir, vec![], ran(r"project|C:\".to_owned())),
        ("guard", r"\\srv\share\pi\kendex\hooks\guard.sh".to_owned(), &dir, vec![], ran(r"global|\\srv\share\pi".to_owned())),
        // No registry spawned these: a relative path, and another hook's name.
        ("guard", "p/.pi/kendex/hooks/guard.sh".to_owned(), &dir, vec![], ran("unset|unset".to_owned())),
        ("guard", at("p/.pi/kendex/hooks/other.sh"), &dir, vec![], ran("unset|unset".to_owned())),
        // A carrier's own registration stands, either variable alone too.
        ("gate", at("p/.pi/kendex/hooks/gate.sh"), &dir, vec![("KENDEX_HOOK_SCOPE", "global"), ("KENDEX_HOOK_ROOT", "/r")], ran("global|/r".to_owned())),
        ("gate", at("p/.pi/kendex/hooks/gate.sh"), &dir, vec![("KENDEX_HOOK_ROOT", "")], ran("unset|".to_owned())),
        // Separate registries: the global root is elsewhere in the checkout,
        // as where the project's hook directory links into it, and each
        // registry's spelling names its own scope.
        ("gate", at("d/.pi/kendex/hooks/gate.sh"), &d, vec![("PI_CODING_AGENT_DIR", &elsewhere)], ran(format!("project|{}", at("d")))),
        ("gate", at("d/g/kendex/hooks/gate.sh"), &d, vec![("PI_CODING_AGENT_DIR", &elsewhere)], ran(format!("global|{}", at("d/g")))),
        // Pi pointed at a checkout's `.pi`, from outside that checkout: the
        // project registry there is not this session's, so the global root
        // answers, however the variable spells it.
        ("gate", at("c/.pi/kendex/hooks/gate.sh"), &dir, vec![("PI_CODING_AGENT_DIR", &checkout)], ran(format!("global|{checkout}"))),
        ("gate", at("c/.pi/kendex/hooks/gate.sh"), &dir, vec![("HOME", &home), ("PI_CODING_AGENT_DIR", " ~/c/x/../.pi/ ")], ran(format!("global|{checkout}"))),
        // From inside it, one registry file is both scopes', and each hook
        // follows its declaration.
        ("guard", at("c/.pi/kendex/hooks/guard.sh"), &c_sub, vec![("PI_CODING_AGENT_DIR", &checkout)], ran("unset|unset".to_owned())),
        ("note", at("c/.pi/kendex/hooks/note.sh"), &c_sub, vec![("PI_CODING_AGENT_DIR", &checkout)], Outcome::Notice(overlap("note"))),
        ("gate", at("c/.pi/kendex/hooks/gate.sh"), &c, vec![("PI_CODING_AGENT_DIR", &checkout)], Outcome::Refused(overlap("gate"))),
        // A relative variable is the carrier's default root, never this one.
        ("gate", at("c/.pi/kendex/hooks/gate.sh"), &c, vec![("PI_CODING_AGENT_DIR", "c/.pi")], ran(format!("project|{}", at("c")))),
    ];
    for (hook, spawned, cwd, env, expected) in rows {
        assert_eq!(
            spawn(&dir, &spawned, cwd, script(hook), &env),
            expected,
            "{hook} at {spawned} from {} {env:?}",
            cwd.display()
        );
    }
}
