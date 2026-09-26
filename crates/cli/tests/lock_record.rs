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
//! what it was asked and keeps the pull request's open, armed and queued
//! state in files; `kendex` on the fixture's `PATH` is a wrapper over the
//! built binary that fails one verb on request. The must-fail controls for
//! this surface: the script with its rolling judge replaced by a byte
//! compare of the refresh against the rolling commit pushes over the open
//! rolling pull request a record-free merge left current, because a git
//! source's `sources.<name>.commit` line moves with every merge; with the
//! judge's conflict arm narrowed to a clean apply it refuses the merge that
//! re-recorded the lock; and with the judge a squash merge it refuses every
//! run from the workflow's checkout, which holds no history behind the head.
#![cfg(unix)]

use crate::test_util;
use test_util::rooted;

use std::collections::BTreeSet;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use kendex_core::process::Hardened;

fn script() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tools/lock-record")
}

/// The github skill's merge-queue library the script sources, named here
/// so a change to that render runs this suite.
fn merge_queue_library() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../.agents/skills/github/scripts/lib/merge-queue.sh")
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

/// Where `needle` first occurs in the `gh` log, as an assertion that it
/// does.
fn at(log: &str, needle: &str) -> usize {
    log.find(needle)
        .unwrap_or_else(|| panic!("{needle:?} is not in the gh log:\n{log}"))
}

/// The `gh` stub. `pr list` prints the open pull request's number and node
/// id from `state/open` or nothing; `pr create` writes that file from the
/// `state/next` counter and prints a URL; `pr merge` writes `state/armed`;
/// `api graphql` answers the arming and queue read from `state/armed` and
/// `state/queued` and removes each for its mutation. `GH_FAIL` names the
/// one call that fails: `list` or `state` exit 1, and `disarm` or `dequeue`
/// answer their mutation with an `errors` body and exit 0, as GitHub
/// reports a mutation it refused.
const GH_STUB: &str = "#!/bin/sh
printf '%s\\n' \"$*\" >> \"$GH_LOG\"
case \"$1 $2\" in
  'pr list')
    [ \"$GH_FAIL\" != list ] || { echo 'gh stub: list refused' >&2; exit 1; }
    [ ! -f \"$GH_STATE/open\" ] || { n=$(cat \"$GH_STATE/open\"); printf '%s PR_node%s\\n' \"$n\" \"$n\"; }
    exit 0 ;;
  'pr create')
    n=$(cat \"$GH_STATE/next\")
    printf '%s\\n' \"$n\" > \"$GH_STATE/open\"; printf '%s\\n' $((n + 1)) > \"$GH_STATE/next\"
    printf 'https://example.test/pull/%s\\n' \"$n\"; exit 0 ;;
  'pr merge') : > \"$GH_STATE/armed\"; exit 0 ;;
  'api graphql')
    case \"$*\" in
      *isInMergeQueue*)
        [ \"$GH_FAIL\" != state ] || { echo 'gh stub: state refused' >&2; exit 1; }
        if [ -f \"$GH_STATE/armed\" ]; then a=true; else a=false; fi
        if [ -f \"$GH_STATE/queued\" ]; then q=true; else q=false; fi
        printf '%s\\t%s\\n' \"$a\" \"$q\"; exit 0 ;;
      *disablePullRequestAutoMerge*)
        [ \"$GH_FAIL\" != disarm ] || { printf '{\"errors\":[{\"message\":\"refused\"}]}\\n'; exit 0; }
        rm -f \"$GH_STATE/armed\"
        printf '{\"data\":{\"disablePullRequestAutoMerge\":{\"clientMutationId\":null}}}\\n'; exit 0 ;;
      *dequeuePullRequest*)
        [ \"$GH_FAIL\" != dequeue ] || { printf '{\"errors\":[{\"message\":\"refused\"}]}\\n'; exit 0; }
        rm -f \"$GH_STATE/queued\"
        printf '{\"data\":{\"dequeuePullRequest\":{\"mergeQueueEntry\":null}}}\\n'; exit 0 ;;
    esac ;;
esac
echo \"gh stub: $*\" >&2; exit 97
";

/// The `kendex` wrapper on the fixture's `PATH`, over the built binary at
/// `REAL`. `KENDEX_FAIL` names the verb answered with exit 7 in place of a
/// run (`source`, `refresh`), or `verify` for every verify to run and then
/// exit 1, or `verify-first` for the first verify alone, marked in
/// `KENDEX_STATE`.
const KENDEX_WRAPPER: &str = "#!/bin/sh
case \"$KENDEX_FAIL:$1\" in
  source:source | refresh:refresh) exit 7 ;;
  verify:verify) 'REAL' \"$@\"; exit 1 ;;
  verify-first:verify)
    if [ ! -f \"$KENDEX_STATE/verified\" ]; then : > \"$KENDEX_STATE/verified\"; 'REAL' \"$@\"; exit 1; fi ;;
esac
exec 'REAL' \"$@\"
";

/// Where the consumer's package comes from.
#[derive(Clone, Copy)]
enum Source {
    /// A directory inside the consumer, which records no commit line.
    Path,
    /// The consumer's own origin as a git source, the shape this
    /// repository takes: the record's `sources.<name>.commit` line moves
    /// to the origin's tip on every refresh.
    Git,
}

impl Source {
    /// The directory under the consumer the package's `skills/` sits in.
    fn root(self) -> &'static str {
        match self {
            Source::Path => "catalog/",
            Source::Git => "",
        }
    }
}

/// The checkout the script judges.
#[derive(Clone, Copy)]
enum Checkout {
    /// The full clone of the origin the queue merges in.
    Clone,
    /// The workflow's shape, built fresh for each run: `git init`, a fetch
    /// of `main`'s head at depth 1 and a checkout of that head, so the
    /// checkout holds no history behind the head it judges.
    Shallow,
}

/// The consumer, its bare origin, the checkout the queue merges in, the
/// shape of the checkout the script judges, and where the `gh` stub keeps
/// its log and its pull request's state.
struct World {
    _tmp: tempfile::TempDir,
    source: Source,
    checkout: Checkout,
    home: PathBuf,
    origin: PathBuf,
    main: PathBuf,
    gh_log: PathBuf,
    gh_state: PathBuf,
}

fn world() -> World {
    world_with(Source::Path, Checkout::Clone)
}

/// A consumer with one skill of two scripts, cloned bare as the origin and
/// again as the checkout of `main` the queue merges in, where it is
/// installed on `claude`, committed with its record and pushed.
#[allow(clippy::unwrap_used)]
fn world_with(source: Source, checkout: Checkout) -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let bin = home.join("bin");
    fs::create_dir_all(&bin).unwrap();
    executable(
        &bin.join("kendex"),
        &KENDEX_WRAPPER.replace("REAL", env!("CARGO_BIN_EXE_kendex")),
    );
    let gh_log = home.join("gh.log");
    let gh_state = home.join("gh-state");
    write(&gh_state.join("next"), "41\n");
    executable(&bin.join("gh"), GH_STUB);

    let seed = home.join("seed");
    let origin = home.join("origin.git");
    let declared = match source {
        Source::Path => "path = \"catalog\"".to_owned(),
        Source::Git => format!("repo = \"file://{}\"", origin.display()),
    };
    write(
        &seed.join("kendex.toml"),
        &format!(
            "schema = 6\n\n[install]\nharnesses = [\"claude\"]\n\n[sources.cat]\n{declared}\n\n[skills.deploy]\nsource = \"cat\"\n"
        ),
    );
    let package = seed.join(source.root()).join("skills/deploy");
    write(
        &package.join("SKILL.md"),
        "---\nname: deploy\ndescription: ship the service\n---\nRun scripts/ship, then scripts/roll.\n",
    );
    write(&package.join("scripts/ship"), "#!/bin/sh\necho ship\n");
    write(&package.join("scripts/roll"), "#!/bin/sh\necho roll\n");
    write(&seed.join("README.md"), "the consumer\n");
    git_ok(&home, &seed, &["init", "-q", "-b", "main"]);
    git_ok(&home, &seed, &["config", "commit.gpgsign", "false"]);
    git_ok(&home, &seed, &["config", "core.hooksPath", ".git/hooks"]);
    git_ok(&home, &seed, &["add", "-A"]);
    git_ok(&home, &seed, &["commit", "-q", "-m", "consumer"]);
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
    let installed = kendex(
        &home,
        &main,
        &["refresh", "--scope", "project", "--yes", "--leave"],
    );
    assert!(installed.status.success(), "{}", said(&installed));
    git_ok(&home, &main, &["add", "-A"]);
    git_ok(&home, &main, &["commit", "-q", "-m", "install"]);
    git_ok(&home, &main, &["push", "-q", "origin", "main"]);
    let tracked = git_ok(&home, &main, &["ls-files"]);
    assert!(
        tracked.lines().any(|line| line == ".kendex-lock.json"),
        "{tracked}"
    );
    World {
        _tmp: tmp,
        source,
        checkout,
        home,
        origin,
        main,
        gh_log,
        gh_state,
    }
}

impl World {
    /// The script with these arguments in place of `--repo <judged> --base
    /// main`, under the fixture home, with `GH_FAIL` and `KENDEX_FAIL` set
    /// to `gh_fail` and `kendex_fail`.
    #[allow(clippy::expect_used)]
    fn run(&self, args: &[&str], gh_fail: &str, kendex_fail: &str) -> Output {
        Command::new("bash")
            .arg(script())
            .args(args)
            .env_clear()
            .envs(test_util::fixture_env(&self.home))
            .env("KENDEX_BACKGROUND_REFRESH", "off")
            .env("PATH", fixture_path(&self.home))
            .env("GH_LOG", &self.gh_log)
            .env("GH_STATE", &self.gh_state)
            .env("GH_FAIL", gh_fail)
            .env("KENDEX_STATE", self.home.join("kendex-state"))
            .env("KENDEX_FAIL", kendex_fail)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .output()
            .expect("bash runs the script")
    }

    /// The script against the checkout it judges, every `gh` read answered
    /// and every `kendex` verb run.
    fn lock_record(&self) -> Output {
        let judged = match self.checkout {
            Checkout::Clone => self.main.clone(),
            Checkout::Shallow => self.shallow_checkout(),
        };
        self.run(
            &["--repo", &judged.display().to_string(), "--base", "main"],
            "",
            "",
        )
    }

    /// The checkout the script judged on its last run.
    fn judged(&self) -> PathBuf {
        match self.checkout {
            Checkout::Clone => self.main.clone(),
            Checkout::Shallow => self.home.join("runner"),
        }
    }

    /// A fresh checkout of `main`'s head the way `actions/checkout` builds
    /// one with no `fetch-depth`: the head alone, read as parentless.
    #[allow(clippy::unwrap_used)]
    fn shallow_checkout(&self) -> PathBuf {
        let runner = self.home.join("runner");
        let _ = fs::remove_dir_all(&runner);
        fs::create_dir_all(&runner).unwrap();
        let head = self.main_head();
        let origin = self.origin.display().to_string();
        git_ok(&self.home, &runner, &["init", "-q"]);
        git_ok(&self.home, &runner, &["remote", "add", "origin", &origin]);
        git_ok(
            &self.home,
            &runner,
            &["fetch", "-q", "--depth=1", "origin", &head],
        );
        git_ok(&self.home, &runner, &["checkout", "-q", &head]);
        git_ok(&self.home, &runner, &["config", "commit.gpgsign", "false"]);
        git_ok(
            &self.home,
            &runner,
            &["config", "core.hooksPath", ".git/hooks"],
        );
        let shallow = git_ok(
            &self.home,
            &runner,
            &["rev-parse", "--is-shallow-repository"],
        );
        assert_eq!(shallow.trim(), "true", "the runner checkout is not shallow");
        runner
    }

    /// A branch off `main` that changes one script of the package, with
    /// its render landed beside it and the record left alone: the shape a
    /// lane's branch takes under the rule.
    fn branch(&self, name: &str, script: &str) {
        let text = format!("#!/bin/sh\necho {script} on {name}\n");
        self.branch_writing(
            name,
            &[
                (
                    &format!("{}skills/deploy/scripts/{script}", self.source.root()),
                    text.as_str(),
                ),
                (
                    &format!(".agents/skills/deploy/scripts/{script}"),
                    text.as_str(),
                ),
            ],
        );
    }

    /// A branch off `main` that moves nothing the record covers.
    fn branch_outside_the_package(&self, name: &str) {
        self.branch_writing(name, &[("README.md", "the consumer, changed\n")]);
    }

    /// A branch off `main` that changes one script of the package and
    /// re-records the lock with `kendex refresh`, as the one branch the
    /// rule admits does: a change to the lock's own format.
    fn branch_recording(&self, name: &str, script: &str) {
        git_ok(
            &self.home,
            &self.main,
            &["checkout", "-q", "-b", name, "main"],
        );
        write(
            &self.main.join(format!(
                "{}skills/deploy/scripts/{script}",
                self.source.root()
            )),
            &format!("#!/bin/sh\necho {script} on {name}\n"),
        );
        let recorded = kendex(
            &self.home,
            &self.main,
            &["refresh", "--scope", "project", "--yes", "--leave"],
        );
        assert!(recorded.status.success(), "{}", said(&recorded));
        git_ok(&self.home, &self.main, &["add", "-A"]);
        git_ok(&self.home, &self.main, &["commit", "-q", "-m", name]);
        git_ok(&self.home, &self.main, &["checkout", "-q", "main"]);
    }

    fn branch_writing(&self, name: &str, files: &[(&str, &str)]) {
        git_ok(
            &self.home,
            &self.main,
            &["checkout", "-q", "-b", name, "main"],
        );
        for (path, text) in files {
            write(&self.main.join(path), text);
        }
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

    /// The rolling pull request merged: its branch squashed onto `main`,
    /// and the pull request closed, so `gh` lists none open and the next
    /// record opens a new one.
    fn merge_rolling(&self) {
        self.fetch_origin();
        let merged = self.queue_merge("origin/kendex/lock");
        assert!(merged.status.success(), "{}", said(&merged));
        for state in ["open", "armed", "queued"] {
            let _ = fs::remove_file(self.gh_state.join(state));
        }
    }

    /// The queue's checkout brought up to the origin: a push from the
    /// runner checkout moves no remote-tracking ref here.
    fn fetch_origin(&self) {
        git_ok(&self.home, &self.main, &["fetch", "-q", "origin"]);
    }

    fn rolling_head(&self) -> String {
        self.fetch_origin();
        git_ok(&self.home, &self.main, &["rev-parse", "origin/kendex/lock"])
            .trim()
            .to_owned()
    }

    /// The rolling branch's tip replaced by a merge of `main` into it: a
    /// commit the judge cannot apply, since a cherry-pick of a merge names
    /// no parent to apply it against.
    fn merge_main_into_rolling(&self) -> String {
        self.fetch_origin();
        git_ok(
            &self.home,
            &self.main,
            &["checkout", "-q", "-B", "rolling-tip", "origin/kendex/lock"],
        );
        git_ok(
            &self.home,
            &self.main,
            &[
                "merge",
                "-q",
                "--no-ff",
                "-m",
                "main into the rolling branch",
                "main",
            ],
        );
        git_ok(
            &self.home,
            &self.main,
            &[
                "push",
                "-q",
                "--force",
                "origin",
                "HEAD:refs/heads/kendex/lock",
            ],
        );
        git_ok(&self.home, &self.main, &["checkout", "-q", "main"]);
        git_ok(
            &self.home,
            &self.main,
            &["branch", "-q", "-D", "rolling-tip"],
        );
        self.rolling_head()
    }

    fn main_head(&self) -> String {
        git_ok(&self.home, &self.main, &["rev-parse", "main"])
            .trim()
            .to_owned()
    }

    fn gh_log(&self) -> String {
        fs::read_to_string(&self.gh_log).unwrap_or_default()
    }

    /// A fresh clone of the origin's `main`, with its mirrors refreshed,
    /// verifies clean and stays clean: the record on `main` is current.
    fn fresh_clone_verifies_clean(&self) -> PathBuf {
        let fresh = self.home.join("fresh");
        let _ = fs::remove_dir_all(&fresh);
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

/// One record run over a stale `main`: recorded on the rolling branch from
/// `main`'s head with the record and nothing else, pushed, its pull
/// request `number` opened and armed on the pushed head.
fn assert_recorded_and_opened(world: &World, output: &str, number: u32) {
    let head = world.main_head();
    assert!(
        output.contains(&format!("lock-record: recorded={head} paths=")),
        "{output}"
    );
    assert!(
        output.contains("lock-record: pushed=origin/kendex/lock"),
        "{output}"
    );
    assert!(
        output.contains(&format!("lock-record: pull-request={number} action=opened")),
        "{output}"
    );
    assert!(
        output.contains(&format!("lock-record: armed={number}")),
        "{output}"
    );
    let rolling = world.rolling_head();
    let parent = git_ok(
        &world.home,
        &world.main,
        &["rev-parse", "origin/kendex/lock^"],
    );
    assert_eq!(parent.trim(), head, "{output}");
    let changed = git_ok(
        &world.home,
        &world.main,
        &["diff", "--name-only", &format!("{rolling}^"), &rolling],
    );
    assert_eq!(changed.trim(), ".kendex-lock.json", "{output}");
    let log = world.gh_log();
    assert!(
        log.contains(&format!(
            "pr merge {number} --squash --auto --match-head-commit {rolling}\n"
        )),
        "{log}"
    );
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
    assert_recorded_and_opened(&world, &output, 41);
    let log = world.gh_log();
    assert_eq!(
        log.matches("pr list --head kendex/lock --base main --state open")
            .count(),
        1,
        "{log}"
    );
    assert!(
        log.contains("pr create --base main --head kendex/lock --title chore(lock): record the install record at "),
        "{log}"
    );
    world.merge_rolling();

    // The second branch on the same package: no conflict, because neither
    // branch carries the record, and a new pull request for its record.
    let merged = world.queue_merge("b");
    assert!(merged.status.success(), "{}", said(&merged));
    let second = world.lock_record();
    let output = said(&second);
    assert_eq!(second.status.code(), Some(0), "{output}");
    assert_recorded_and_opened(&world, &output, 42);
    world.merge_rolling();

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
    assert!(
        output.contains(&format!("lock-record: current={}", world.main_head())),
        "{output}"
    );
    assert!(!output.contains("lock-record: recorded="), "{output}");
    assert_eq!(world.gh_log(), before);
}

/// One stand-down run over `main` moved on by a merge outside the package:
/// the rolling pull request's commit verifies clean on the new head, so
/// nothing is pushed and the gh reads are the list and the state.
fn assert_stood_down(world: &World, before: &str, output: &str, rolling: &str) {
    assert!(
        output.contains(&format!(
            "lock-record: rolling-current={rolling} pull-request=41"
        )),
        "{output}"
    );
    assert!(!output.contains("lock-record: recorded="), "{output}");
    assert_eq!(world.rolling_head(), rolling, "{output}");
    let asked = world.gh_log();
    let asked = asked.strip_prefix(before).unwrap_or(&asked);
    assert!(
        asked.starts_with("pr list --head kendex/lock --base main --state open"),
        "{asked}"
    );
    assert!(asked.contains("isInMergeQueue"), "{asked}");
    assert!(!asked.contains("pr create"), "{asked}");
    let status = git_ok(&world.home, &world.judged(), &["status", "--porcelain"]);
    assert_eq!(
        status, "",
        "the stand-down left the checkout as it found it"
    );
}

/// One push over the open rolling pull request `41`, armed from an earlier
/// run: disarmed first, the record re-recorded from `main`'s head, the
/// pull request updated and armed on the pushed head, and the judged
/// checkout left as it was found.
fn assert_pushed_over(world: &World, output: &str) {
    let head = world.main_head();
    for line in [
        "lock-record: disarmed=41\n".to_owned(),
        format!("lock-record: recorded={head} paths="),
        "lock-record: pull-request=41 action=updated\n".to_owned(),
        "lock-record: armed=41\n".to_owned(),
    ] {
        assert!(output.contains(&line), "{line:?} missing:\n{output}");
    }
    let rolling = world.rolling_head();
    let parent = git_ok(
        &world.home,
        &world.main,
        &["rev-parse", &format!("{rolling}^")],
    );
    assert_eq!(parent.trim(), head, "{output}");
    let status = git_ok(&world.home, &world.judged(), &["status", "--porcelain"]);
    assert_eq!(
        status, "",
        "the push left the checkout other than it found it"
    );
}

#[test]
fn a_merge_that_moves_no_record_leaves_the_open_rolling_pull_request_untouched() {
    let world = world_with(Source::Git, Checkout::Clone);
    world.branch("a", "ship");
    world.branch_outside_the_package("c");
    world.branch_writing("d", &[("NOTES.md", "notes\n")]);
    let merged = world.queue_merge("a");
    assert!(merged.status.success(), "{}", said(&merged));
    let first = world.lock_record();
    assert_eq!(first.status.code(), Some(0), "{}", said(&first));
    let rolling = world.rolling_head();

    // Main moves on under the armed pull request without touching what the
    // record covers. The commit line the refresh would write has moved to
    // the new tip; the record the pull request carries still verifies.
    let merged = world.queue_merge("c");
    assert!(merged.status.success(), "{}", said(&merged));
    let before = world.gh_log();
    let second = world.lock_record();
    let output = said(&second);
    assert_eq!(second.status.code(), Some(0), "{output}");
    assert_stood_down(&world, &before, &output, &rolling);
    assert!(output.contains("lock-record: armed=already\n"), "{output}");
    let asked = world.gh_log();
    let asked = asked.strip_prefix(&before).unwrap_or(&asked);
    assert_eq!(asked.lines().count(), 2, "{asked}");

    // The same, with the arm gone (a cancelled run, or a queue removal):
    // the stand-down arms the rolling head it judged current.
    let merged = world.queue_merge("d");
    assert!(merged.status.success(), "{}", said(&merged));
    fs::remove_file(world.gh_state.join("armed")).unwrap();
    let before = world.gh_log();
    let third = world.lock_record();
    let output = said(&third);
    assert_eq!(third.status.code(), Some(0), "{output}");
    assert_stood_down(&world, &before, &output, &rolling);
    assert!(output.contains("lock-record: armed=41\n"), "{output}");
    assert!(
        world.gh_log().contains(&format!(
            "pr merge 41 --squash --auto --match-head-commit {rolling}\n"
        )),
        "{output}"
    );
    assert!(world.gh_state.join("armed").exists(), "{output}");

    // The queue merges the untouched pull request onto the newer main.
    world.merge_rolling();
    world.fresh_clone_verifies_clean();
}

#[test]
fn a_push_over_an_armed_and_queued_rolling_pull_request_disarms_and_dequeues_first() {
    assert!(
        merge_queue_library().is_file(),
        "{}",
        merge_queue_library().display()
    );
    let world = world();
    world.branch("a", "ship");
    world.branch("b", "roll");
    let merged = world.queue_merge("a");
    assert!(merged.status.success(), "{}", said(&merged));
    let first = world.lock_record();
    assert_eq!(first.status.code(), Some(0), "{}", said(&first));
    write(&world.gh_state.join("queued"), "");

    // A second record-moving merge lands while the armed pull request
    // waits in the queue.
    let merged = world.queue_merge("b");
    assert!(merged.status.success(), "{}", said(&merged));
    let before = world.gh_log();
    let second = world.lock_record();
    let output = said(&second);
    assert_eq!(second.status.code(), Some(0), "{output}");
    for line in [
        "lock-record: disarmed=41\n",
        "lock-record: dequeued=41\n",
        "lock-record: pull-request=41 action=updated\n",
        "lock-record: armed=41\n",
    ] {
        assert!(output.contains(line), "{line:?} missing:\n{output}");
    }
    let rolling = world.rolling_head();
    let parent = git_ok(
        &world.home,
        &world.main,
        &["rev-parse", "origin/kendex/lock^"],
    );
    assert_eq!(parent.trim(), world.main_head(), "{output}");
    let asked = world.gh_log();
    let asked = asked.strip_prefix(&before).unwrap_or(&asked);
    let disarm = at(asked, "disablePullRequestAutoMerge");
    let dequeue = at(asked, "dequeuePullRequest");
    let arm = at(
        asked,
        &format!("pr merge 41 --squash --auto --match-head-commit {rolling}\n"),
    );
    assert!(disarm < dequeue && dequeue < arm, "{asked}");
    assert!(!asked.contains("pr create"), "{asked}");
    assert!(world.gh_state.join("armed").exists(), "{asked}");
    assert!(!world.gh_state.join("queued").exists(), "{asked}");
}

/// The workflow's checkout holds the head alone, so the judge has no
/// history to find a merge base in: the stand-down and the push over a
/// stale rolling pull request both still happen from it.
#[test]
fn the_workflows_shallow_checkout_stands_down_and_pushes_over_the_rolling_pull_request() {
    let world = world_with(Source::Git, Checkout::Shallow);
    world.branch("a", "ship");
    world.branch_outside_the_package("c");
    world.branch("b", "roll");
    let merged = world.queue_merge("a");
    assert!(merged.status.success(), "{}", said(&merged));
    let first = world.lock_record();
    let output = said(&first);
    assert_eq!(first.status.code(), Some(0), "{output}");
    assert_recorded_and_opened(&world, &output, 41);
    let rolling = world.rolling_head();

    let merged = world.queue_merge("c");
    assert!(merged.status.success(), "{}", said(&merged));
    let before = world.gh_log();
    let second = world.lock_record();
    let output = said(&second);
    assert_eq!(second.status.code(), Some(0), "{output}");
    assert_stood_down(&world, &before, &output, &rolling);
    assert!(output.contains("lock-record: armed=already\n"), "{output}");

    let merged = world.queue_merge("b");
    assert!(merged.status.success(), "{}", said(&merged));
    let third = world.lock_record();
    let output = said(&third);
    assert_eq!(third.status.code(), Some(0), "{output}");
    assert_pushed_over(&world, &output);
    world.merge_rolling();
    world.fresh_clone_verifies_clean();
}

/// The one branch the rule admits, a re-record of the lock, merged under
/// an open rolling pull request: the rolling commit conflicts with `main`'s
/// lock, which the judge reads as stale, and the record is re-recorded
/// from the head and pushed over the pull request.
#[test]
fn a_merge_that_re_records_the_lock_conflicts_with_the_rolling_commit_and_is_re_recorded() {
    let world = world();
    world.branch("a", "ship");
    world.branch_recording("f", "roll");
    let merged = world.queue_merge("a");
    assert!(merged.status.success(), "{}", said(&merged));
    let first = world.lock_record();
    assert_eq!(first.status.code(), Some(0), "{}", said(&first));

    let merged = world.queue_merge("f");
    assert!(merged.status.success(), "{}", said(&merged));
    let second = world.lock_record();
    let output = said(&second);
    assert_eq!(second.status.code(), Some(0), "{output}");
    assert_pushed_over(&world, &output);
    world.merge_rolling();
    world.fresh_clone_verifies_clean();
}

/// What `main` looks like when a refusal row runs.
#[derive(Clone, Copy)]
enum Main {
    /// The record current.
    Current,
    /// An uncommitted path in the checkout.
    Dirty,
    /// A merge moved the record and no rolling pull request is open.
    Stale,
    /// A merge moved the record under an open rolling pull request.
    StaleUnderOpenPullRequest,
    /// The same, with that pull request in the merge queue.
    StaleUnderQueuedPullRequest,
    /// The same, with the rolling branch's tip a merge commit.
    StaleUnderRollingMergeCommit,
}

impl Main {
    /// `main` arranged so, and the rolling branch's head where one exists,
    /// which the refusal must leave where it is.
    fn arrange(self, world: &World) -> Option<String> {
        match self {
            Main::Current => None,
            Main::Dirty => {
                write(&world.main.join("scratch"), "x\n");
                None
            }
            Main::Stale => {
                world.branch("a", "ship");
                assert!(world.queue_merge("a").status.success());
                None
            }
            Main::StaleUnderOpenPullRequest => {
                world.branch("a", "ship");
                world.branch("b", "roll");
                assert!(world.queue_merge("a").status.success());
                let first = world.lock_record();
                assert_eq!(first.status.code(), Some(0), "{}", said(&first));
                assert!(world.queue_merge("b").status.success());
                Some(world.rolling_head())
            }
            Main::StaleUnderQueuedPullRequest => {
                let rolling = Main::StaleUnderOpenPullRequest.arrange(world);
                write(&world.gh_state.join("queued"), "");
                rolling
            }
            Main::StaleUnderRollingMergeCommit => {
                Main::StaleUnderOpenPullRequest.arrange(world);
                Some(world.merge_main_into_rolling())
            }
        }
    }
}

/// One refusal: `main`'s shape, the arguments, with `EMPTY`, `MAIN` and
/// `HEAD` filled in per world, the `gh` call and the `kendex` verb that
/// fail, the exit status, the first notice line on stderr, where every
/// refusal goes and no success notice does, and what `git status` lists
/// afterwards: the record the refresh staged where the refusal came after
/// it, and nothing where it came before or where the judge reset. `above`
/// is text stderr must carry before that first line, what git printed on
/// its own where the notice says it passed through, and empty where the
/// row pins nothing above it.
struct Refusal {
    main: Main,
    args: &'static [&'static str],
    gh_fail: &'static str,
    kendex_fail: &'static str,
    code: i32,
    first: &'static str,
    left: &'static str,
    above: &'static str,
}

const REFUSALS: &[Refusal] = &[
    Refusal {
        main: Main::Current,
        args: &["--repo", "EMPTY"],
        gh_fail: "",
        kendex_fail: "",
        code: 2,
        first: "lock-record: repo=EMPTY\n",
        left: "",
        above: "",
    },
    Refusal {
        main: Main::Current,
        args: &["--repo", "MAIN", "--bogus"],
        gh_fail: "",
        kendex_fail: "",
        code: 2,
        first: "lock-record: option=--bogus\n",
        left: "",
        above: "",
    },
    Refusal {
        main: Main::Current,
        args: &["--repo", "MAIN", "--base"],
        gh_fail: "",
        kendex_fail: "",
        code: 2,
        first: "lock-record: option=--base\n",
        left: "",
        above: "",
    },
    Refusal {
        main: Main::Dirty,
        args: &["--repo", "MAIN"],
        gh_fail: "",
        kendex_fail: "",
        code: 2,
        first: "lock-record: dirty=1\n",
        left: "?? scratch\n",
        above: "",
    },
    Refusal {
        main: Main::Current,
        args: &["--repo", "MAIN"],
        gh_fail: "",
        kendex_fail: "source",
        code: 1,
        first: "lock-record: source-refresh=7\n",
        left: "",
        above: "",
    },
    Refusal {
        main: Main::Stale,
        args: &["--repo", "MAIN", "--remote", "nowhere"],
        gh_fail: "",
        kendex_fail: "",
        code: 1,
        first: "lock-record: rolling-read=128\n",
        left: "",
        above: "",
    },
    Refusal {
        main: Main::Stale,
        args: &["--repo", "MAIN"],
        gh_fail: "list",
        kendex_fail: "",
        code: 1,
        first: "lock-record: pull-request-list=kendex/lock\n",
        left: "",
        above: "",
    },
    Refusal {
        main: Main::StaleUnderOpenPullRequest,
        args: &["--repo", "MAIN"],
        gh_fail: "state",
        kendex_fail: "",
        code: 1,
        first: "lock-record: pull-request-state=41\n",
        left: "",
        above: "",
    },
    Refusal {
        main: Main::StaleUnderRollingMergeCommit,
        args: &["--repo", "MAIN"],
        gh_fail: "",
        kendex_fail: "",
        code: 1,
        first: "lock-record: status=MAIN\n",
        left: "",
        above: "is a merge but no -m option was given",
    },
    Refusal {
        main: Main::Stale,
        args: &["--repo", "MAIN"],
        gh_fail: "",
        kendex_fail: "refresh",
        code: 1,
        first: "lock-record: refresh=7\n",
        left: "",
        above: "",
    },
    Refusal {
        main: Main::Current,
        args: &["--repo", "MAIN"],
        gh_fail: "",
        kendex_fail: "verify",
        code: 1,
        first: "lock-record: stale-after-refresh=HEAD\n",
        left: "",
        above: "",
    },
    Refusal {
        main: Main::Current,
        args: &["--repo", "MAIN"],
        gh_fail: "",
        kendex_fail: "verify-first",
        code: 1,
        first: "lock-record: refresh-wrote-nothing=HEAD\n",
        left: "",
        above: "",
    },
    Refusal {
        main: Main::StaleUnderOpenPullRequest,
        args: &["--repo", "MAIN"],
        gh_fail: "disarm",
        kendex_fail: "",
        code: 1,
        first: "lock-record: disarm=41\n",
        left: "M  .kendex-lock.json\n",
        above: "",
    },
    Refusal {
        main: Main::StaleUnderQueuedPullRequest,
        args: &["--repo", "MAIN"],
        gh_fail: "dequeue",
        kendex_fail: "",
        code: 1,
        first: "lock-record: dequeue=41\n",
        left: "M  .kendex-lock.json\n",
        above: "",
    },
];

/// The refusals, each with its stable first line, and each leaving the
/// rolling branch where it was with no pull request opened or armed.
#[test]
fn a_refusal_names_its_cause_first_and_pushes_nothing() {
    assert!(!REFUSALS.is_empty(), "the refusal table is empty");
    for row in REFUSALS {
        assert_refused(row);
    }
}

#[allow(clippy::unwrap_used)]
fn assert_refused(row: &Refusal) {
    let world = world();
    let empty = world.home.join("empty");
    fs::create_dir_all(&empty).unwrap();
    fs::create_dir_all(world.home.join("kendex-state")).unwrap();
    let rolling = row.main.arrange(&world);
    let fill = |text: &str| {
        text.replace("EMPTY", &empty.display().to_string())
            .replace("MAIN", &world.main.display().to_string())
            .replace("HEAD", &world.main_head())
    };
    let args: Vec<String> = row.args.iter().map(|arg| fill(arg)).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let before = world.gh_log();
    let refused = world.run(&args, row.gh_fail, row.kendex_fail);
    let output = said(&refused);
    let first = fill(row.first.trim_end_matches('\n'));
    assert_eq!(refused.status.code(), Some(row.code), "{args:?}: {output}");
    let stderr = String::from_utf8_lossy(&refused.stderr);
    let at = stderr
        .match_indices("lock-record: ")
        .map(|(at, _)| at)
        .find(|at| *at == 0 || stderr.as_bytes()[at - 1] == b'\n')
        .unwrap_or_else(|| panic!("{args:?}: no notice on stderr in\n{output}"));
    let notice = stderr[at..].lines().next().unwrap_or_default();
    assert_eq!(notice, first, "{args:?}: {output}");
    assert!(
        stderr[..at].contains(row.above),
        "{args:?}: {:?} is not above the notice in\n{output}",
        row.above
    );
    let asked = world.gh_log();
    let asked = asked.strip_prefix(&before).unwrap_or(&asked);
    assert!(!asked.contains("pr create"), "{args:?}: {asked}");
    assert!(!asked.contains("pr merge"), "{args:?}: {asked}");
    let status = git_ok(&world.home, &world.main, &["status", "--porcelain"]);
    assert_eq!(status, row.left, "{args:?}: {output}");
    match rolling {
        Some(head) => assert_eq!(world.rolling_head(), head, "{args:?}: {output}"),
        None => {
            let absent = git(
                &world.home,
                &world.main,
                &[
                    "ls-remote",
                    "--exit-code",
                    "origin",
                    "refs/heads/kendex/lock",
                ],
            );
            assert_eq!(absent.status.code(), Some(2), "{args:?}: {}", said(&absent));
        }
    }
}

/// Every keyed line the script's header lists is pinned by a row of the
/// refusal table or by a scenario here, and every keyed line pinned here is
/// one the header lists: the header's `#   <key>=<value>` lines against the
/// `lock-record: <key>=` literals in this file's expectations, so a keyed
/// line added with no row, or a row expecting a line the script never
/// prints, reddens the suite.
#[test]
#[allow(clippy::unwrap_used)]
fn every_keyed_line_the_header_lists_is_pinned_by_a_row() {
    let header = fs::read_to_string(script()).unwrap();
    let listed: BTreeSet<&str> = header
        .lines()
        .take_while(|line| line.starts_with('#'))
        .filter_map(|line| line.strip_prefix("#   "))
        .filter_map(|line| line.split_whitespace().next())
        .filter_map(|word| word.split_once('=').map(|(key, _)| key))
        .collect();
    assert!(
        listed.contains("recorded"),
        "the header's key list did not parse: {listed:?}"
    );
    let source = include_str!("lock_record.rs");
    let literal = format!("{}lock-record: ", '"');
    let pinned: BTreeSet<&str> = source
        .match_indices(&literal)
        .filter_map(|(at, _)| {
            let rest = &source[at + literal.len()..];
            let key = rest.trim_start_matches(|c: char| c.is_ascii_lowercase() || c == '-');
            let key = &rest[..rest.len() - key.len()];
            (!key.is_empty() && rest[key.len()..].starts_with('=')).then_some(key)
        })
        .collect();
    assert!(
        pinned.contains("dirty"),
        "this file's expectations did not parse: {pinned:?}"
    );
    let unpinned: Vec<_> = listed.difference(&pinned).collect();
    assert!(
        unpinned.is_empty(),
        "keyed lines the header lists with no row pinning them: {unpinned:?}"
    );
    let unlisted: Vec<_> = pinned.difference(&listed).collect();
    assert!(
        unlisted.is_empty(),
        "rows pin keyed lines the header does not list: {unlisted:?}"
    );
}
