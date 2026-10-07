//! `kendex check --quiet`'s view of a declaration sitting on files no
//! record accounts for: it prints the stale line with the take-over as its
//! fix, the fix settles it, and a copy the render matches is recorded with
//! nothing printed and a clean exit. The session hook's check,
//! `--report-only`, and a check in a checkout off the default branch
//! record nothing: they report the missing row and leave the tree as git
//! had it.
#![cfg(unix)]

use crate::test_util;
use test_util::rooted;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use kendex_core::{engine, env::Env, lock, manifest, model::Scope};

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

fn said(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

struct Installed {
    home: PathBuf,
    project: PathBuf,
    scope_name: &'static str,
    lock_path: PathBuf,
    /// The skill's rendered file, under the position its install recorded.
    rendered: PathBuf,
}

/// One skill from a path catalog, applied and recorded, at the scope the
/// row names.
#[allow(clippy::unwrap_used)]
fn installed(global: bool) -> (tempfile::TempDir, Installed) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("project");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::create_dir_all(home.join(".claude")).unwrap();
    let env = Env::host_rooted(&home);
    let scope = if global {
        Scope::Global
    } else {
        Scope::Project {
            root: project.clone(),
        }
    };
    let scope_name = if global { "global" } else { "project" };
    let manifest_path = manifest::manifest_path(&env, &scope);
    fs::create_dir_all(manifest_path.parent().unwrap()).unwrap();
    let catalog = if global { &home } else { &project }.join("catalog");
    fs::create_dir_all(catalog.join("skills/deploy")).unwrap();
    fs::write(
        catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: Ship it.\n---\n\nRun the deploy.\n",
    )
    .unwrap();
    fs::write(
        &manifest_path,
        "schema = 6\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n[sources.cat]\npath = \"catalog\"\n[skills.deploy]\nsource = \"cat\"\n",
    )
    .unwrap();
    let applied = kendex(&home, &project, &["apply", "--scope", scope_name, "--yes"]);
    assert!(applied.status.success(), "{}", said(&applied));
    let lock_path = lock::lock_path(&env, &scope);
    let recorded = lock::load(&lock_path).unwrap();
    let entry = recorded
        .entries
        .values()
        .find(|entry| entry.name == "deploy")
        .unwrap();
    let rendered = engine::installed_paths(&env, &scope, entry)
        .into_iter()
        .find(|path| path.is_dir())
        .unwrap()
        .join("SKILL.md");
    assert!(rendered.is_file(), "{}", rendered.display());
    (
        tmp,
        Installed {
            home,
            project,
            scope_name,
            lock_path,
            rendered,
        },
    )
}

/// The record gone and the render edited behind it — the overseer's
/// state, a committed render some commits behind its source with no
/// record saying so — prints one stale line under `--quiet`, naming the
/// count and the take-over, at each scope with that scope's flag. The fix
/// it names settles it: the next check is silent and exits clean.
#[test]
#[allow(clippy::unwrap_used)]
fn a_differing_copy_is_stale_under_quiet_and_its_fix_settles_it() {
    for (global, fix) in [
        (false, "kendex apply --replace-unmanaged"),
        (true, "kendex apply --replace-unmanaged --global"),
    ] {
        let (_tmp, w) = installed(global);
        fs::remove_file(&w.lock_path).unwrap();
        fs::write(&w.rendered, "the render from before\n").unwrap();

        let checked = kendex(
            &w.home,
            &w.project,
            &["check", "--scope", w.scope_name, "--quiet"],
        );
        assert_eq!(checked.status.code(), Some(1), "{}", said(&checked));
        let text = String::from_utf8(checked.stdout).unwrap();
        assert!(text.starts_with("stale: 1\n"), "global={global}: {text}");
        let trash = kendex_core::paths::slashed(&Env::host_rooted(&w.home).trash_dir());
        let line = format!(
            "  unmanaged copy of skill 'deploy' for Claude Code: 1 file differs from source 'cat'; take-over moves the existing content to the trash at {trash} — fix: {fix}\n"
        );
        assert!(text.contains(&line), "global={global}: {text}");
        assert!(
            !w.lock_path.exists(),
            "global={global}: a copy that differs is not recorded"
        );

        let mut args: Vec<&str> = fix.split_whitespace().skip(1).collect();
        args.push("--yes");
        let taken = kendex(&w.home, &w.project, &args);
        assert!(taken.status.success(), "global={global}: {}", said(&taken));

        let again = kendex(
            &w.home,
            &w.project,
            &["check", "--scope", w.scope_name, "--quiet"],
        );
        assert_eq!(
            again.status.code(),
            Some(0),
            "global={global}: {}",
            said(&again)
        );
        assert!(again.stdout.is_empty(), "global={global}: {}", said(&again));
    }
}

/// The record gone and the render as the apply left it: the check records
/// it and prints nothing, exiting clean — the session hook stays silent,
/// which is the whole contract of a clean start.
#[test]
#[allow(clippy::unwrap_used)]
fn a_matching_copy_is_recorded_silently_under_quiet() {
    let (_tmp, w) = installed(false);
    let rendered = fs::read(&w.rendered).unwrap();
    fs::remove_file(&w.lock_path).unwrap();

    let checked = kendex(
        &w.home,
        &w.project,
        &["check", "--scope", w.scope_name, "--quiet"],
    );
    assert_eq!(checked.status.code(), Some(0), "{}", said(&checked));
    assert!(checked.stdout.is_empty(), "{}", said(&checked));
    let recorded = lock::load(&w.lock_path).unwrap();
    assert!(
        recorded
            .entries
            .values()
            .any(|entry| entry.name == "deploy"),
        "{:?}",
        recorded.entries.keys()
    );
    assert_eq!(fs::read(&w.rendered).unwrap(), rendered);
}

/// One git command in a fixture repository, through the constructor that
/// drops the caller's git environment.
#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) -> String {
    let output = kendex_core::process::Hardened::git(args, Some(dir))
        .run()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap()
}

fn commit(dir: &Path, message: &str) {
    git(dir, &["add", "-A"]);
    git(
        dir,
        &[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "--quiet",
            "-m",
            message,
        ],
    );
}

const MANIFEST: &str = "schema = 6\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n[sources.cat]\npath = \"catalog\"\n[skills.deploy]\nsource = \"cat\"\n";

/// Where a checkout stands once `Arrange` has run in a repository on the
/// default branch.
type Arrange = fn(&Path) -> PathBuf;

/// A lane that adds a package: its checkout, and the hash its render
/// records to.
struct Lane {
    home: PathBuf,
    checkout: PathBuf,
    rendered: String,
}

/// A repository whose default branch records `deploy`, and the checkout
/// `arrange` hands back, whose own commit adds `ship` to the manifest with
/// its render and leaves `.kendex-lock.json` as the default branch holds
/// it: the tree a lane commits under D007. The hash is what the apply
/// recorded for `ship` before the record was put back.
#[allow(clippy::unwrap_used)]
fn a_lane_adding_a_package(arrange: Arrange) -> (tempfile::TempDir, Lane) {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let root = home.join("project");
    fs::create_dir_all(root.join(".claude")).unwrap();
    for skill in ["deploy", "ship"] {
        fs::create_dir_all(root.join(format!("catalog/skills/{skill}"))).unwrap();
        fs::write(
            root.join(format!("catalog/skills/{skill}/SKILL.md")),
            format!("---\nname: {skill}\ndescription: Do it.\n---\n\nRun {skill}.\n"),
        )
        .unwrap();
    }
    fs::write(root.join("kendex.toml"), MANIFEST).unwrap();
    git(&root, &["init", "--quiet", "-b", "main"]);
    git(&root, &["config", "gc.auto", "0"]);
    git(&root, &["config", "maintenance.auto", "false"]);
    let applied = kendex(&home, &root, &["apply", "--yes", "--leave"]);
    assert!(applied.status.success(), "{}", said(&applied));
    commit(&root, "deploy");

    let checkout = arrange(&root);
    fs::write(
        checkout.join("kendex.toml"),
        format!("{MANIFEST}[skills.ship]\nsource = \"cat\"\n"),
    )
    .unwrap();
    let applied = kendex(&home, &checkout, &["apply", "--yes", "--leave"]);
    assert!(applied.status.success(), "{}", said(&applied));
    let recorded = lock::load(&checkout.join(".kendex-lock.json")).unwrap();
    let rendered = recorded
        .entries
        .values()
        .find(|entry| entry.name == "ship")
        .and_then(|entry| entry.rendered_hash.clone())
        .unwrap();
    git(&checkout, &["checkout", "--", ".kendex-lock.json"]);
    commit(&checkout, "ship");
    assert_eq!(
        git(&checkout, &["status", "--porcelain"]),
        "",
        "the fixture starts clean"
    );
    (
        tmp,
        Lane {
            home,
            checkout,
            rendered,
        },
    )
}

/// How a row runs the check.
#[derive(Clone, Copy)]
enum Run {
    /// The session-drift-check hook itself, fed a fresh start's payload,
    /// with this build's kendex first on PATH.
    Hook,
    /// The kendex-drift script `kendex drift-hook` installs, run the same
    /// way.
    KendexDrift,
    /// `kendex check --quiet`, as a person runs it.
    ByHand,
}

/// The hook's stdout, or the check's, and the check's exit status; the
/// hook always exits 0, so its status is not the check's.
#[allow(clippy::expect_used, clippy::unwrap_used)]
fn run(lane: &Lane, how: Run) -> (String, Option<i32>, String) {
    let output = match how {
        Run::ByHand => kendex(&lane.home, &lane.checkout, &["check", "--quiet"]),
        Run::Hook | Run::KendexDrift => {
            let (shell, hook) = match how {
                Run::Hook => (
                    "bash",
                    Path::new(env!("CARGO_MANIFEST_DIR"))
                        .join("../../hooks/session-drift-check.sh"),
                ),
                Run::KendexDrift => {
                    let script = lane.home.join("kendex-drift.sh");
                    fs::write(&script, kendex_core::drift::hook::HOOK_SCRIPT).unwrap();
                    ("sh", script)
                }
                Run::ByHand => unreachable!("a check run by hand is no hook"),
            };
            let bin = Path::new(env!("CARGO_BIN_EXE_kendex")).parent().unwrap();
            let path = std::env::join_paths(std::iter::once(bin.to_path_buf()).chain(
                std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()),
            ))
            .unwrap();
            let mut child = Command::new(shell)
                .arg(hook)
                .current_dir(&lane.checkout)
                .env_clear()
                .envs(test_util::fixture_env(&lane.home))
                .env("KENDEX_BACKGROUND_REFRESH", "off")
                .env("CLAUDE_PROJECT_DIR", &lane.checkout)
                .env("PATH", path)
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::piped())
                .spawn()
                .expect("the hook runs");
            use std::io::Write;
            child
                .stdin
                .take()
                .unwrap()
                .write_all(br#"{"source":"startup"}"#)
                .unwrap();
            child.wait_with_output().unwrap()
        }
    };
    (
        String::from_utf8_lossy(&output.stdout).into_owned(),
        output.status.code(),
        said(&output),
    )
}

/// The checkout shapes a lane stands in.
fn on_a_branch(root: &Path) -> PathBuf {
    git(root, &["switch", "--quiet", "-c", "lane"]);
    root.to_path_buf()
}

#[allow(clippy::unwrap_used)]
fn in_a_linked_worktree(root: &Path) -> PathBuf {
    let linked = root.with_file_name("lane");
    let at = linked.to_str().unwrap();
    git(root, &["worktree", "add", "--quiet", "-b", "lane", at]);
    kendex_core::paths::canonical(&linked).unwrap()
}

fn on_a_detached_head(root: &Path) -> PathBuf {
    git(root, &["switch", "--quiet", "--detach"]);
    root.to_path_buf()
}

fn on_the_default_branch(root: &Path) -> PathBuf {
    root.to_path_buf()
}

/// A session start never writes a tracked file: the session-drift-check
/// hook and the kendex-drift script run `kendex check --report-only`,
/// which reports the proven render's missing row, with its path and both
/// hashes, and leaves the tree as git had it on a branch, in a linked
/// worktree, on a detached HEAD and on the default branch alike. A check
/// run by hand keeps D007's branch rule: off the default branch it records
/// nothing and says why; on it, the control, it settles the render into
/// the record, so `.kendex-lock.json` is modified and the report is clean.
#[test]
fn a_session_start_writes_nothing_git_sees() {
    let session = "the session check leaves the record as this checkout holds it";
    let lane =
        "branch 'lane' leaves the record as 'main' holds it, and 'main' records it after the merge";
    let detached = "a detached HEAD leaves the record as 'main' holds it";
    // The tree the run leaves, and the reason its line gives; `None` where
    // the run records and prints nothing.
    let rows: [(&str, Arrange, Run, &str, Option<&str>); 9] = [
        ("hook, branch", on_a_branch, Run::Hook, "", Some(session)),
        (
            "hook, worktree",
            in_a_linked_worktree,
            Run::Hook,
            "",
            Some(session),
        ),
        (
            "hook, detached",
            on_a_detached_head,
            Run::Hook,
            "",
            Some(session),
        ),
        (
            "hook, default",
            on_the_default_branch,
            Run::Hook,
            "",
            Some(session),
        ),
        (
            "kendex-drift, branch",
            on_a_branch,
            Run::KendexDrift,
            "",
            Some(session),
        ),
        (
            "kendex-drift, default",
            on_the_default_branch,
            Run::KendexDrift,
            "",
            Some(session),
        ),
        ("by hand, branch", on_a_branch, Run::ByHand, "", Some(lane)),
        (
            "by hand, detached",
            on_a_detached_head,
            Run::ByHand,
            "",
            Some(detached),
        ),
        (
            "by hand, default",
            on_the_default_branch,
            Run::ByHand,
            " M .kendex-lock.json\n",
            None,
        ),
    ];
    for (shape, arrange, how, tree, why) in rows {
        let (_tmp, lane) = a_lane_adding_a_package(arrange);
        let (stdout, code, all) = run(&lane, how);
        assert_eq!(
            git(&lane.checkout, &["status", "--porcelain"]),
            tree,
            "{shape}: {all}"
        );
        match (how, why) {
            (Run::Hook, Some(why)) => {
                let opening = if shape == "hook, worktree" {
                    "session-drift-check: lane=1\n"
                } else {
                    "session-drift-check: drift=found\n"
                };
                assert!(stdout.starts_with(opening), "{shape}: {all}");
                assert!(
                    stdout
                        .lines()
                        .any(|line| line == "session-drift-check: drift=found"),
                    "{shape}: {all}"
                );
                assert_unrecorded(&lane, &stdout, why, shape);
            }
            // The kendex-drift script relays a drift report with no notice
            // line of its own.
            (Run::KendexDrift, Some(why)) => assert_unrecorded(&lane, &stdout, why, shape),
            (Run::ByHand, Some(why)) => {
                assert_eq!(code, Some(1), "{shape}: {all}");
                assert_unrecorded(&lane, &stdout, why, shape);
            }
            (Run::ByHand, None) => {
                assert_eq!(code, Some(0), "{shape}: {all}");
                assert_eq!(stdout, "", "{shape}: {all}");
            }
            (Run::Hook | Run::KendexDrift, None) => {
                unreachable!("{shape}: a session hook records nothing")
            }
        }
    }
}

/// The missing row's line: the render's path, no recorded hash, the hash
/// the apply recorded for it, and why the record stays as it is.
fn assert_unrecorded(lane: &Lane, stdout: &str, why: &str, shape: &str) {
    let line = format!(
        "skill 'ship' for Claude Code has no row in the install record: .claude/skills/ship, recorded hash none, rendered hash {}; {why}",
        lane.rendered
    );
    assert!(stdout.contains(&line), "{shape}: {stdout}");
}
