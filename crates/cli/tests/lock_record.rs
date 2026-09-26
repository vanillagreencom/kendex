//! `tools/lock-record`: the install record is recorded on the default
//! branch after each merge and landed through one rolling pull request, so
//! two branches that each change one script of one package merge in
//! sequence with no conflict on `.kendex-lock.json`, and the record on
//! `main` is current after both.
//!
//! The script runs against a consumer of its own: one package with two
//! scripts, its record committed, on a bare origin the checkout under test
//! pushes to. The merge queue is the test itself, squash-merging each
//! branch and then the rolling branch into `main`. `gh` is a stub that logs
//! what it was asked and keeps the pull request's open and armed state in
//! files. The must-fail control for this surface: the script with its
//! `kendex refresh` line deleted answers the first run with
//! `stale-after-refresh`, and with its `current=` exit deleted answers the
//! third run with `refresh-wrote-nothing`.
#![cfg(unix)]

use crate::test_util;
use test_util::rooted;

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use kendex_core::process::Hardened;

fn script() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tools/lock-record")
}

fn said(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

/// The fixture's `bin/` ahead of the host's `PATH`: the built kendex under
/// its own name, and the `gh` stub.
#[allow(clippy::expect_used)]
fn fixture_path(home: &Path) -> std::ffi::OsString {
    let mut paths = vec![home.join("bin")];
    paths.extend(std::env::split_paths(
        &std::env::var_os("PATH").unwrap_or_default(),
    ));
    std::env::join_paths(paths).expect("fixture PATH joins")
}

/// git under the fixture home, so the developer's own configuration and
/// hooks never reach the repositories being built.
#[allow(clippy::unwrap_used)]
fn git(home: &Path, dir: &Path, args: &[&str]) -> Output {
    Hardened::git(args, Some(dir))
        .env("HOME", home.to_str().unwrap())
        .env("KENDEX_REAL_HOME", "1")
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@t")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@t")
        .run()
        .unwrap()
}

fn git_ok(home: &Path, dir: &Path, args: &[&str]) -> String {
    let out = git(home, dir, args);
    assert!(out.status.success(), "git {args:?}: {}", said(&out));
    String::from_utf8_lossy(&out.stdout).into_owned()
}

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("KENDEX_BACKGROUND_REFRESH", "off")
        .env("PATH", fixture_path(home))
        .output()
        .expect("kendex binary runs")
}

#[allow(clippy::unwrap_used)]
fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

#[allow(clippy::unwrap_used)]
fn executable(path: &Path, text: &str) {
    write(path, text);
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

/// The consumer, its bare origin, the checkout the script judges, and where
/// the `gh` stub keeps its log and its pull request's state.
struct World {
    _tmp: tempfile::TempDir,
    home: PathBuf,
    origin: PathBuf,
    main: PathBuf,
    gh_log: PathBuf,
    gh_state: PathBuf,
}

/// A consumer with one skill of two scripts from a path source, installed
/// on `claude` and committed with its record, cloned bare as the origin and
/// again as the checkout of `main` the script runs against. The `gh` stub
/// answers the four questions the script asks: `pr list` prints the open
/// pull request's number from `state/open` or nothing, `pr create` writes
/// that file and prints a URL, `pr view` prints whether `state/armed`
/// exists, and `pr merge` writes it.
#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let bin = home.join("bin");
    fs::create_dir_all(&bin).unwrap();
    std::os::unix::fs::symlink(env!("CARGO_BIN_EXE_kendex"), bin.join("kendex")).unwrap();
    let gh_log = home.join("gh.log");
    let gh_state = home.join("gh-state");
    fs::create_dir_all(&gh_state).unwrap();
    executable(
        &bin.join("gh"),
        "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$GH_LOG\"\n\
         case \"$1 $2\" in\n\
           'pr list') [ ! -f \"$GH_STATE/open\" ] || cat \"$GH_STATE/open\"; exit 0 ;;\n\
           'pr create') printf '41\\n' > \"$GH_STATE/open\"; printf 'https://example.test/pull/41\\n'; exit 0 ;;\n\
           'pr view') if [ -f \"$GH_STATE/armed\" ]; then echo true; else echo false; fi; exit 0 ;;\n\
           'pr merge') : > \"$GH_STATE/armed\"; exit 0 ;;\n\
         esac\n\
         echo \"gh stub: $*\" >&2; exit 97\n",
    );

    let seed = home.join("seed");
    write(
        &seed.join("kendex.toml"),
        "schema = 6\n\n[install]\nharnesses = [\"claude\"]\n\n[sources.cat]\npath = \"catalog\"\n\n[skills.deploy]\nsource = \"cat\"\n",
    );
    write(
        &seed.join("catalog/skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: ship the service\n---\nRun scripts/ship, then scripts/roll.\n",
    );
    write(
        &seed.join("catalog/skills/deploy/scripts/ship"),
        "#!/bin/sh\necho ship\n",
    );
    write(
        &seed.join("catalog/skills/deploy/scripts/roll"),
        "#!/bin/sh\necho roll\n",
    );
    git_ok(&home, &seed, &["init", "-q", "-b", "main"]);
    git_ok(&home, &seed, &["config", "commit.gpgsign", "false"]);
    git_ok(&home, &seed, &["config", "core.hooksPath", ".git/hooks"]);
    git_ok(&home, &seed, &["add", "-A"]);
    git_ok(&home, &seed, &["commit", "-q", "-m", "consumer"]);
    let installed = kendex(
        &home,
        &seed,
        &["refresh", "--scope", "project", "--yes", "--leave"],
    );
    assert!(installed.status.success(), "{}", said(&installed));
    git_ok(&home, &seed, &["add", "-A"]);
    git_ok(&home, &seed, &["commit", "-q", "-m", "install"]);
    let tracked = git_ok(&home, &seed, &["ls-files"]);
    assert!(
        tracked.lines().any(|line| line == ".kendex-lock.json"),
        "{tracked}"
    );

    let origin = home.join("origin.git");
    git_ok(
        &home,
        &seed,
        &[
            "clone",
            "--quiet",
            "--bare",
            ".",
            &origin.display().to_string(),
        ],
    );
    let main = home.join("main");
    git_ok(
        &home,
        &home,
        &[
            "clone",
            "--quiet",
            &origin.display().to_string(),
            &main.display().to_string(),
        ],
    );
    git_ok(&home, &main, &["config", "commit.gpgsign", "false"]);
    git_ok(&home, &main, &["config", "core.hooksPath", ".git/hooks"]);
    World {
        _tmp: tmp,
        home,
        origin,
        main,
        gh_log,
        gh_state,
    }
}

impl World {
    /// The script against the checkout of `main`, under the fixture home.
    #[allow(clippy::expect_used)]
    fn lock_record(&self) -> Output {
        Command::new("bash")
            .arg(script())
            .arg("--repo")
            .arg(&self.main)
            .arg("--base")
            .arg("main")
            .env_clear()
            .envs(test_util::fixture_env(&self.home))
            .env("KENDEX_BACKGROUND_REFRESH", "off")
            .env("PATH", fixture_path(&self.home))
            .env("GH_LOG", &self.gh_log)
            .env("GH_STATE", &self.gh_state)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .output()
            .expect("bash runs the script")
    }

    /// A branch off `main` that changes one script of the package, with
    /// its render landed beside it and the record left alone: the shape a
    /// lane's branch takes under the rule.
    fn branch(&self, name: &str, script: &str) {
        git_ok(
            &self.home,
            &self.main,
            &["checkout", "-q", "-b", name, "main"],
        );
        let text = format!("#!/bin/sh\necho {script} on {name}\n");
        write(
            &self.main.join("catalog/skills/deploy/scripts").join(script),
            &text,
        );
        write(
            &self.main.join(".agents/skills/deploy/scripts").join(script),
            &text,
        );
        git_ok(&self.home, &self.main, &["add", "-A"]);
        git_ok(&self.home, &self.main, &["commit", "-q", "-m", name]);
        git_ok(&self.home, &self.main, &["checkout", "-q", "main"]);
    }

    /// The merge queue: `branch` squashed onto `main` and pushed. The
    /// merge's own status is the answer, so a conflict is a failure the
    /// caller reads rather than a panic here.
    fn queue_merge(&self, branch: &str) -> Output {
        git_ok(&self.home, &self.main, &["checkout", "-q", "main"]);
        let merged = git(&self.home, &self.main, &["merge", "--squash", "-q", branch]);
        if !merged.status.success() {
            return merged;
        }
        git_ok(&self.home, &self.main, &["commit", "-q", "-m", branch]);
        git_ok(&self.home, &self.main, &["push", "-q", "origin", "main"]);
        merged
    }

    fn gh_log(&self) -> String {
        fs::read_to_string(&self.gh_log).unwrap_or_default()
    }

    /// A fresh clone of the origin's `main`, with its mirrors refreshed,
    /// verifies clean and stays clean: the record on `main` is current.
    fn fresh_clone_verifies_clean(&self) -> PathBuf {
        let fresh = self.home.join("fresh");
        git_ok(
            &self.home,
            &self.home,
            &[
                "clone",
                "--quiet",
                &self.origin.display().to_string(),
                &fresh.display().to_string(),
            ],
        );
        let refreshed = kendex(&self.home, &fresh, &["source", "refresh"]);
        assert!(refreshed.status.success(), "{}", said(&refreshed));
        let verified = kendex(&self.home, &fresh, &["verify", "--scope", "project"]);
        assert_eq!(verified.status.code(), Some(0), "{}", said(&verified));
        let status = git_ok(&self.home, &fresh, &["status", "--porcelain"]);
        assert_eq!(status, "", "{status}");
        fresh
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn two_branches_on_one_package_merge_in_sequence_and_main_records_after_each() {
    let world = world();
    world.branch("a", "ship");
    world.branch("b", "roll");

    let merged = world.queue_merge("a");
    assert!(merged.status.success(), "{}", said(&merged));

    let first = world.lock_record();
    let output = said(&first);
    assert_eq!(first.status.code(), Some(0), "{output}");
    let head = git_ok(&world.home, &world.main, &["rev-parse", "main"]);
    assert!(
        output.contains(&format!("lock-record: recorded={} paths=", head.trim())),
        "{output}"
    );
    assert!(
        output.contains("lock-record: pushed=origin/kendex/lock"),
        "{output}"
    );
    assert!(
        output.contains("lock-record: pull-request=41 action=opened"),
        "{output}"
    );
    assert!(output.contains("lock-record: armed=41"), "{output}");
    let log = world.gh_log();
    assert!(
        log.contains("pr create --base main --head kendex/lock --title chore(lock): record the install record at "),
        "{log}"
    );
    assert!(
        log.contains("pr merge 41 --squash --auto --match-head-commit "),
        "{log}"
    );
    // The commit on the rolling branch carries the record and nothing a
    // branch would carry: the head it records is main's, one commit ahead.
    let rolling = git_ok(
        &world.home,
        &world.main,
        &["rev-parse", "origin/kendex/lock"],
    );
    let parent = git_ok(
        &world.home,
        &world.main,
        &["rev-parse", "origin/kendex/lock^"],
    );
    assert_eq!(parent.trim(), head.trim(), "{output}");
    let changed = git_ok(
        &world.home,
        &world.main,
        &[
            "diff",
            "--name-only",
            &format!("{}^", rolling.trim()),
            rolling.trim(),
        ],
    );
    assert_eq!(changed.trim(), ".kendex-lock.json", "{output}");

    let merged = world.queue_merge("origin/kendex/lock");
    assert!(merged.status.success(), "{}", said(&merged));

    // The second branch on the same package: no conflict, because neither
    // branch carries the record.
    let merged = world.queue_merge("b");
    assert!(merged.status.success(), "{}", said(&merged));

    let second = world.lock_record();
    let output = said(&second);
    assert_eq!(second.status.code(), Some(0), "{output}");
    assert!(
        output.contains("lock-record: pull-request=41 action=updated"),
        "{output}"
    );
    assert!(output.contains("lock-record: armed=already"), "{output}");
    assert_eq!(
        world.gh_log().matches("pr create").count(),
        1,
        "{}",
        world.gh_log()
    );
    assert_eq!(
        world.gh_log().matches("pr merge").count(),
        1,
        "{}",
        world.gh_log()
    );
    let merged = world.queue_merge("origin/kendex/lock");
    assert!(merged.status.success(), "{}", said(&merged));

    // The record on main is current after both: a fresh clone verifies clean.
    let fresh = world.fresh_clone_verifies_clean();
    let ship = fs::read_to_string(fresh.join(".agents/skills/deploy/scripts/ship")).unwrap();
    let roll = fs::read_to_string(fresh.join(".agents/skills/deploy/scripts/roll")).unwrap();
    assert!(ship.contains("ship on a"), "{ship}");
    assert!(roll.contains("roll on b"), "{roll}");

    // A current main is judged and left alone: nothing committed, pushed
    // or asked of gh.
    let before = world.gh_log();
    let third = world.lock_record();
    let output = said(&third);
    assert_eq!(third.status.code(), Some(0), "{output}");
    let head = git_ok(&world.home, &world.main, &["rev-parse", "main"]);
    assert!(
        output.contains(&format!("lock-record: current={}", head.trim())),
        "{output}"
    );
    assert!(!output.contains("lock-record: recorded="), "{output}");
    assert_eq!(world.gh_log(), before);
}

/// The refusals before anything is judged, each with its stable first line.
#[test]
#[allow(clippy::unwrap_used)]
fn an_uncommitted_path_or_a_bad_option_refuses_before_the_record_is_judged() {
    let world = world();
    write(&world.main.join("scratch"), "x\n");
    let dirty = world.lock_record();
    let output = said(&dirty);
    assert_eq!(dirty.status.code(), Some(2), "{output}");
    assert!(output.contains("lock-record: dirty=1\n"), "{output}");
    assert!(output.contains("?? scratch"), "{output}");
    fs::remove_file(world.main.join("scratch")).unwrap();

    #[allow(clippy::expect_used)]
    let bad = Command::new("bash")
        .arg(script())
        .arg("--repo")
        .env_clear()
        .envs(test_util::fixture_env(&world.home))
        .env("PATH", fixture_path(&world.home))
        .output()
        .expect("bash runs the script");
    let output = said(&bad);
    assert_eq!(bad.status.code(), Some(2), "{output}");
    assert!(output.contains("lock-record: option=--repo\n"), "{output}");
    assert_eq!(world.gh_log(), "");
}
