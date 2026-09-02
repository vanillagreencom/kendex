//! A project hook command finds the kendex project when it runs, and names
//! no directory while it waits.
//!
//! Two things have to hold at once. The command has to reach the project's
//! own script from a project that is no git repository and from one sitting
//! below the git top level, which `$(git rev-parse --show-toplevel)` did not:
//! it answers with nothing in the first and with the enclosing tree's root in
//! the second. And its text has to be the same on every machine, because a
//! project registry is a file repositories commit, which a rendered absolute
//! path would not be.
//!
//! So every case reads the command out of the registry the harness will read,
//! asserts what git answers for the fixture, and runs it from a directory of
//! the project's. What passes is the hook firing, not a string.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use kendex_core::apply;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;
use serde_json::Value;

/// The rendered script prints the file that ran, so a command resolving to
/// another tree's copy — or to nothing at all — cannot pass for this one.
const AUDIT_HOOK: &str = "#!/usr/bin/env bash\n# ---\n# name: audit\n# event: PreToolUse\n# matcher: Bash\n# description: log shell commands\n# ---\nprintf '%s\\n' \"$0\"\n";

/// Where each harness registers a project hook, and where the JSON it writes
/// keeps the command: the registry, the path to the command inside it, and the
/// script that command has to reach.
const HARNESSES: &[(&str, &str, &[&str], &str)] = &[
    (
        "codex",
        ".codex/hooks.json",
        &["hooks", "PreToolUse", "0", "hooks", "0", "command"],
        ".codex/hooks/audit.sh",
    ),
    (
        "gemini",
        ".gemini/settings.json",
        &["hooks", "BeforeTool", "0", "hooks", "0", "command"],
        ".gemini/hooks/audit.sh",
    ),
    (
        "copilot",
        ".github/hooks/audit.json",
        &["hooks", "preToolUse", "0", "bash"],
        ".github/hooks/audit.sh",
    ),
    (
        "pi",
        ".pi/kendex/hooks.json",
        &["hooks", "tool_call", "0", "hooks", "0", "command"],
        ".pi/kendex/hooks/audit.sh",
    ),
];

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
}

/// git with every redirect scrubbed: an inherited `GIT_DIR` outranks
/// `current_dir`, so `git init` here would initialize whatever it names.
#[allow(clippy::expect_used)]
fn git(dir: &Path, args: &[&str]) {
    let status = scrubbed(Command::new("git").args(args).current_dir(dir))
        .status()
        .expect("git runs");
    assert!(status.success(), "git {args:?} failed in {}", dir.display());
}

/// The environment every child runs under: no redirect from the runner's own
/// checkout, and a ceiling so a repository above the fixture — a `TMPDIR`
/// inside one — cannot answer for a project that is meant to have no git.
fn scrubbed(command: &mut Command) -> &mut Command {
    command
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_COMMON_DIR")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_CONFIG_GLOBAL")
        .env_remove("GIT_CONFIG_COUNT")
}

/// What `$(git rev-parse --show-toplevel)` would have substituted, run where
/// the harness runs the hook. `None` where git has no answer to give.
#[allow(clippy::expect_used)]
fn git_toplevel(dir: &Path, ceiling: &Path) -> Option<PathBuf> {
    let output = scrubbed(
        Command::new("git")
            .args(["rev-parse", "--show-toplevel"])
            .current_dir(dir),
    )
    .env("GIT_CEILING_DIRECTORIES", ceiling)
    .output()
    .expect("git runs");
    let answer = String::from_utf8(output.stdout).expect("git prints its answer as UTF-8");
    match output.status.success() && !answer.trim().is_empty() {
        true => Some(PathBuf::from(answer.trim())),
        false => None,
    }
}

/// A project declaring one hook for every harness whose project command this
/// covers. `project` is a path under the fixture root, not yet created.
#[allow(clippy::unwrap_used)]
fn fixture(tmp: tempfile::TempDir, project: PathBuf) -> Fixture {
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    for (_, _, _, script) in HARNESSES {
        fs::create_dir_all(project.join(script).parent().unwrap()).unwrap();
    }

    let source = home.join("catalog");
    fs::create_dir_all(source.join("hooks")).unwrap();
    fs::write(source.join("hooks/audit.sh"), AUDIT_HOOK).unwrap();
    // Executable kinds install only from a catalog that declares kendex's layout.
    fs::write(source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();

    let harnesses = HARNESSES
        .iter()
        .map(|(harness, ..)| format!("\"{harness}\""))
        .collect::<Vec<_>>()
        .join(", ");
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [{harnesses}]\nmethod = \"symlink\"\n\n[hooks.audit]\nsource = \"cat\"\n",
            source_path(&source)
        ),
    )
    .unwrap();

    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used, clippy::expect_used)]
fn at(value: &Value, keys: &[&str]) -> String {
    let mut value = value;
    for key in keys {
        value = match key.parse::<usize>() {
            Ok(index) => &value[index],
            Err(_) => &value[*key],
        };
    }
    value
        .as_str()
        .unwrap_or_else(|| panic!("no command at {keys:?}: {value}"))
        .to_owned()
}

/// Every harness's registered command, after an apply.
#[allow(clippy::unwrap_used)]
fn commands(f: &Fixture) -> Vec<(&'static str, String)> {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    HARNESSES
        .iter()
        .map(|(harness, registry, keys, _)| {
            let text = fs::read_to_string(f.project.join(registry))
                .unwrap_or_else(|error| panic!("{registry} is written: {error}"));
            (*harness, at(&serde_json::from_str(&text).unwrap(), keys))
        })
        .collect()
}

/// Every registered hook, run the way the harness runs it: through a shell,
/// from `from`, a directory of the project's. Every harness is reported, not
/// just the first to break: one arm carrying the defect and three that do not
/// is a different repair from four that all do.
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn each_hook_runs(f: &Fixture, from: &Path, ceiling: &Path) {
    let mut wrong = Vec::new();
    for ((harness, command), (_, _, _, script)) in commands(f).iter().zip(HARNESSES) {
        // The text a repository commits carries no directory of this machine's.
        let root = f.project.to_string_lossy();
        assert!(
            !command.contains(root.as_ref()),
            "{harness}: the command names this machine's project root: {command}"
        );

        let output = scrubbed(Command::new("sh").arg("-c").arg(command).current_dir(from))
            .env("GIT_CEILING_DIRECTORIES", ceiling)
            .output()
            .expect("sh runs");
        let ran = String::from_utf8_lossy(&output.stdout).trim().to_owned();
        let wanted = f.project.join(script).to_string_lossy().into_owned();
        if !output.status.success() || ran != wanted {
            wrong.push(format!(
                "{harness}: `{command}` exited {:?} and ran {ran:?}, wanted {wanted:?} — {}",
                output.status.code(),
                String::from_utf8_lossy(&output.stderr).trim()
            ));
        }
    }
    assert!(wrong.is_empty(), "{}", wrong.join("\n"));
}

/// A project with no repository anywhere above it. Its root also holds a space
/// and a `$`, so nothing in the command may take the path for shell syntax.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_in_a_project_that_is_no_repository_runs_the_projects_script() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let f = fixture(tmp, root.join("plain/my $app"));

    assert_eq!(
        git_toplevel(&f.project, &root),
        None,
        "the fixture is a project git has no answer for"
    );
    each_hook_runs(&f, &f.project, &root);
}

/// A project below the git top level: the vendored checkout, the repository
/// with a project root of its own further down. git answers with the tree
/// above, which is not where kendex rendered anything. The hook runs from a
/// directory two levels into the project, so the command has to walk.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hook_in_a_project_below_the_git_top_level_runs_the_projects_script() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let repo = root.join("repo");
    fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q"]);
    let f = fixture(tmp, repo.join("app"));

    assert_eq!(
        git_toplevel(&f.project, &root),
        Some(repo.clone()),
        "the fixture is a project below a git top level"
    );
    assert_ne!(repo, f.project, "and that top level is not the project");
    let deep = f.project.join("src/deep");
    fs::create_dir_all(&deep).unwrap();
    each_hook_runs(&f, &deep, &root);
}

/// The registry a repository commits reads the same in every clone: two
/// projects at different paths render the same command, byte for byte.
#[test]
#[allow(clippy::unwrap_used)]
fn two_projects_at_different_paths_register_the_same_text() {
    let here = somewhere("here");
    let there = somewhere("a much longer name over there");
    assert_ne!(here.project, there.project);
    assert_eq!(commands(&here), commands(&there));
}

/// A fixture project named `at`, under a fresh root of its own.
#[allow(clippy::unwrap_used)]
fn somewhere(at: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let project = rooted(&tmp).join(at);
    fixture(tmp, project)
}

/// Nothing above the working directory holds the script: the command refuses
/// rather than running whatever bash makes of a missing file, and it says
/// which file from where. Twice, from a directory that is a sibling of the
/// project: once while it stands, so the walk climbs to `/` and has to stop
/// there, and once after it is removed under the hook's shell — a worktree
/// deleted while a session is open — where the shell answers `.` or nothing
/// for its directory, and a walk that took `.` literally would climb forever.
#[test]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn a_hook_with_no_script_above_the_working_directory_refuses() {
    let f = somewhere("app");
    let (_, command) = commands(&f).into_iter().next().unwrap();
    let gone = f.project.parent().unwrap().join("gone");
    fs::create_dir_all(&gone).unwrap();

    for (what, script) in [
        ("from a directory with no script above it", command.clone()),
        (
            "from a directory removed under the shell",
            format!(
                "rmdir \"$PWD\" && exec sh -c {}",
                kendex_core::names::quoted(&command)
            ),
        ),
    ] {
        let mut child = scrubbed(
            Command::new("sh")
                .args(["-c", &script])
                .current_dir(&gone)
                .stderr(Stdio::piped()),
        )
        .spawn()
        .expect("sh runs");
        let deadline = Instant::now() + Duration::from_secs(30);
        let status = loop {
            if let Some(status) = child.try_wait().unwrap() {
                break status;
            }
            if Instant::now() > deadline {
                child.kill().unwrap();
                panic!("{what}: the command is still running, the walk never stopped");
            }
            std::thread::sleep(Duration::from_millis(20));
        };
        let mut stderr = String::new();
        child
            .stderr
            .take()
            .unwrap()
            .read_to_string(&mut stderr)
            .unwrap();
        assert_eq!(status.code(), Some(1), "{what}: {stderr}");
        assert!(
            stderr.contains("kendex: no directory above")
                && stderr.contains(".codex/hooks/audit.sh"),
            "{what}: the refusal names the start and the file: {stderr}"
        );
    }
}
