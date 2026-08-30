//! Commit-time guards — delegated, never reimplemented.
//!
//! The checks live in the growth-guards package, written in shell, and they
//! travel with the repository under `.agents/skills/`. That is the whole
//! portability property: git runs the shims, the shims run the committed
//! scripts, and no kendex binary is anywhere in the path at commit time. A
//! teammate who cloned the repo and has never heard of kendex still commits
//! through the same gate.
//!
//! kendex implements no check and no verdict. These verbs find the installed
//! package and hand it the work, then relay what it said and how it ended.
//!
//! There was a second engine here — a native reader of hook files with its
//! own grammar for what "armed" means, kept in step with the package's by
//! hand. It never was in step. Every fix landed on one side, and the review
//! round after found the other. So there is one engine, it is the one that
//! runs on a machine which never installed kendex, and every verdict about
//! a repository's shims comes out of [`check`] — `kendex check` included.
//!
//! Exit taxonomy, the family contract the package defines and this module
//! relays unchanged: 0 clean, 1 violations, 2 the check could not run. Both
//! nonzero verdicts block a commit.

use std::ffi::OsString;
use std::path::Path;
use std::time::Duration;

use crate::error::{CoreError, Result};
use crate::process::Hardened;

mod repo;
mod resolve;
pub use repo::Repo;
pub use resolve::Installed;
/// The tool directories the verbs search, in order. Derived from the
/// harness adapters that write them by `guard_skill_roots::
/// a_root_for_every_harness_skills_surface`, not transcribed from the
/// package's own copy: two lists agreeing is no evidence either is right.
pub use resolve::SKILL_ROOTS as SEARCH_ROOTS;
use resolve::bind;

/// The package that owns the checks and the git shims.
pub const SKILL: &str = "growth-guards";

/// The installer the package ships, relative to its own directory.
const INSTALLER: &str = "scripts/install-git-hooks";

/// Room for the whole chain, which ends in whatever the repository pointed
/// `GROWTH_GUARDS_PRE_COMMIT_LOCAL` at — a cold clippy build, in this repo,
/// and no bound kendex can derive. Half an hour is chosen to be longer than
/// any commit gate a person would sit through, so the timeout only ever
/// catches a chain that has hung. Arming and reporting are fast and keep
/// the ordinary timeout.
const CHAIN_TIMEOUT: Duration = Duration::from_secs(1800);

pub(crate) fn guard_err(check: &str, message: impl Into<String>) -> CoreError {
    CoreError::Guard {
        check: check.to_owned(),
        message: message.into(),
    }
}

/// What a delegated run said and how it ended. `code` is the package's own
/// exit status, relayed rather than reinterpreted.
///
/// The two streams stay apart because the package's contract distinguishes
/// them: one summary line on stdout, warnings and diagnostics on stderr
/// (`install-git-hooks --help`). Merging them put every `::warning::` line
/// into the stdout a caller pipes, and dropped the summary line into the
/// middle of them.
#[derive(Debug)]
pub struct GuardReport {
    pub stdout: Vec<String>,
    pub stderr: Vec<String>,
    pub code: u8,
}

/// The hook lanes the package carries. Each name is both the git hook and
/// the script that runs it.
pub const LANES: [&str; 2] = ["pre-commit", "commit-msg"];

/// Run one hook lane: the package's own script, in the repository, with the
/// environment passed through untouched.
///
/// Untouched is the point. Every other process this crate launches has git's
/// redirect variables scrubbed, because an inherited `GIT_DIR` would send it
/// at the wrong repository. This one *is* a hook body — git set those
/// variables for it, `GIT_INDEX_FILE` naming the temporary index of the
/// commit being made, and scrubbing them would make the chain judge the
/// wrong snapshot.
pub fn run_hook(dir: &Path, hook: &str, message_file: Option<&Path>) -> Result<GuardReport> {
    if !LANES.contains(&hook) {
        return Err(guard_err(
            "hooks",
            format!("unknown hook '{hook}' ({})", LANES.join(" | ")),
        ));
    }
    let (repo, installed) = bind(dir, &format!("scripts/{hook}"))?;
    // The message path is resolved against the invoker's directory before
    // anything else, because the child runs from the repository root: git
    // hands the hook `.git/COMMIT_EDITMSG` relative to where it ran the
    // hook, and rebasing that on the root names a file that is not there.
    let message = match message_file {
        Some(path) if path.is_relative() => Some(
            std::env::current_dir()
                .map_err(|error| guard_err(hook, error.to_string()))?
                .join(path)
                .into_os_string(),
        ),
        Some(path) => Some(path.as_os_str().to_owned()),
        None => None,
    };
    let args: Vec<OsString> = message.into_iter().collect();
    let output = Hardened::guard_hook(&installed.script, args, &repo.worktree)
        .timeout(CHAIN_TIMEOUT)
        .run()
        .map_err(|error| guard_err(hook, error.to_string()))?;
    Ok(relay(&output))
}

/// The package's words and its verdict, both kept. A guard's report is the
/// remediation text a committer acts on, so it travels whole; a status the
/// platform cannot name is "could not run", never a pass.
pub(crate) fn relay(output: &std::process::Output) -> GuardReport {
    let split = |stream: &[u8]| -> Vec<String> {
        String::from_utf8_lossy(stream)
            .lines()
            .map(str::to_owned)
            .collect()
    };
    let code = match output.status.code() {
        Some(code) => u8::try_from(code).unwrap_or(2),
        None => 2,
    };
    GuardReport {
        stdout: split(&output.stdout),
        stderr: split(&output.stderr),
        code,
    }
}

/// Arm the shims: the package's own installer, in this repository.
pub fn install(dir: &Path) -> Result<GuardReport> {
    installer(dir, &[])
}

/// Disarm: the package removes its helper and its own marked line, and
/// nothing else.
///
/// A package that is gone cannot disarm the shims it left, and shims whose
/// scripts are missing fail closed on every commit — so a removal that
/// could not run is exit 2 with the reason, never a quiet success about a
/// repository nobody can commit to.
pub fn uninstall(dir: &Path) -> Result<GuardReport> {
    installer(dir, &["--uninstall"])
}

/// Ask the package whether this repository is armed, and relay its answer.
///
/// Its `--check` is read-only and speaks the whole vocabulary — armed,
/// drifted, unverifiable. There is no second opinion to have: the only
/// reader of a hook file anywhere in this product is the script that wrote
/// it, so `kendex guard check` and the commit-hook line of `kendex check`
/// are both this call.
///
/// It runs a script out of the checkout, which `kendex check` reaches at
/// every session start. What licenses that is the project's own install
/// record: the fold in `commands::check` asks only where the project
/// declares this package as an enabled skill, which is the same
/// declaration `kendex apply` acts on.
pub fn check(dir: &Path) -> Result<GuardReport> {
    installer(dir, &["--check"])
}

/// The installer, run from the repository it was pointed at, with its
/// verdict relayed unchanged.
fn installer(dir: &Path, args: &[&str]) -> Result<GuardReport> {
    let (repo, installed) = bind(dir, INSTALLER)?;
    // `--repo` is a path, so it travels as one: a work tree whose name is
    // not UTF-8 would otherwise reach the installer as replacement
    // characters and be reported as a repository that does not exist.
    let mut argv = vec![
        OsString::from("--repo"),
        repo.worktree.as_os_str().to_owned(),
    ];
    argv.extend(args.iter().map(OsString::from));
    let output = Hardened::guard_script(&installed.script, argv, &repo.worktree)
        .run()
        .map_err(|error| guard_err("hooks", error.to_string()))?;
    Ok(relay(&output))
}
