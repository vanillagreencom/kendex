//! The session hook's view of a declaration sitting on files no record
//! accounts for: `kendex check --quiet` prints the stale line with the
//! take-over as its fix, the fix settles it, and a copy the render matches
//! is recorded with nothing printed and a clean exit, except in a checkout
//! off the default branch, where it is reported as not recorded and the
//! tree is left as git had it.
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
        assert!(text.starts_with("stale:\n"), "global={global}: {text}");
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

/// A repository whose default branch records `deploy`, and the checkout
/// `arrange` hands back, whose own commit adds `ship` to the manifest with
/// its render and leaves `.kendex-lock.json` as the default branch holds
/// it: the tree a lane commits under D007.
#[allow(clippy::unwrap_used)]
fn a_lane_adding_a_package(arrange: Arrange) -> (tempfile::TempDir, PathBuf, PathBuf) {
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
    git(&checkout, &["checkout", "--", ".kendex-lock.json"]);
    commit(&checkout, "ship");
    assert_eq!(
        git(&checkout, &["status", "--porcelain"]),
        "",
        "the fixture starts clean"
    );
    (tmp, home, checkout)
}

/// The session start D007 is about: `kendex check --quiet`, as the
/// session hook runs it, in a lane that adds a package. Off the default
/// branch, on a branch, in a linked worktree and on a detached HEAD
/// alike, it reports the proven render as not recorded and leaves the
/// tree as git had it. The default-branch row is the control: the same
/// state there is settled into the record, so `.kendex-lock.json` is
/// modified and the report is clean.
#[test]
#[allow(clippy::unwrap_used)]
fn a_session_start_off_the_default_branch_writes_nothing_git_sees() {
    let rows: [(&str, Arrange, Option<&str>); 4] = [
        (
            "a branch in the checkout",
            |root| {
                git(root, &["switch", "--quiet", "-c", "lane"]);
                root.to_path_buf()
            },
            Some("branch 'lane'"),
        ),
        (
            "a linked worktree on a branch",
            |root| {
                let linked = root.with_file_name("lane");
                let at = linked.to_str().unwrap();
                git(root, &["worktree", "add", "--quiet", "-b", "lane", at]);
                kendex_core::paths::canonical(&linked).unwrap()
            },
            Some("branch 'lane'"),
        ),
        (
            "a detached HEAD",
            |root| {
                git(root, &["switch", "--quiet", "--detach"]);
                root.to_path_buf()
            },
            Some("a detached HEAD"),
        ),
        ("the default branch", |root| root.to_path_buf(), None),
    ];
    for (shape, arrange, off) in rows {
        let (_tmp, home, checkout) = a_lane_adding_a_package(arrange);
        let checked = kendex(&home, &checkout, &["check", "--quiet"]);
        let status = git(&checkout, &["status", "--porcelain"]);
        let text = String::from_utf8_lossy(&checked.stdout);
        let (tree, code) = match off {
            Some(_) => ("", 1),
            None => (" M .kendex-lock.json\n", 0),
        };
        assert_eq!(status, tree, "{shape}: {}", said(&checked));
        assert_eq!(
            checked.status.code(),
            Some(code),
            "{shape}: {}",
            said(&checked)
        );
        if let Some(checkout_word) = off {
            assert!(
                text.contains(&format!(
                    "skill 'ship' for Claude Code matches its source but is not recorded: {checkout_word} leaves the install record as 'main' holds it"
                )),
                "{shape}: {text}"
            );
        }
    }
}
