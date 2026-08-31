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
//! round after found the other. So the package owns every verdict about
//! what the shims ARE, on every surface, `kendex check` included. What
//! kendex may still say for itself is only what it can reach from local
//! state without running anything — whether this repository holds a helper
//! at all, whether the declared package is rendered.
//!
//! Exit taxonomy, the family contract the package defines and this module
//! relays unchanged: 0 clean, 1 violations, 2 the check could not run. Both
//! nonzero verdicts block a commit.

use std::ffi::OsString;
use std::path::Path;
use std::time::Duration;

use crate::error::{CoreError, Result};
use crate::process::{DEFAULT_TIMEOUT, Hardened};

mod repo;
mod resolve;
pub use repo::Repo;
pub use resolve::Installed;
/// The tool directories the verbs search, in order — the same roots the
/// package's own helper searches at commit time. `guard_skill_roots` holds
/// this list to the package's, order included, and holds BOTH to the
/// harness adapters that write the directories: two lists agreeing is no
/// evidence either is right.
pub use resolve::SKILL_ROOTS as SEARCH_ROOTS;
use resolve::{bind, installed_or_err};

/// The package that owns the checks and the git shims.
pub const SKILL: &str = "growth-guards";

/// The installer the package ships, relative to its own directory.
const INSTALLER: &str = "scripts/install-git-hooks";

/// The helper the installer writes into the hooks directory, and the one
/// file [`locally_armed`] reads for. Public because a report that says a
/// repository holds no helper has to name the file it looked for.
pub const HELPER: &str = "kendex-guards";

/// What the session-start `--check` gets, and why it is not the default.
///
/// [`check_repo`] is the fold's call, and the fold runs inside a harness
/// budget of 20 seconds (`drift::hook`'s `HOOK_SCRIPT` frontmatter). The
/// default 120 would be spent inside that budget and lose the whole drift
/// report to the harness's own kill; this gives up first, and the fold
/// classes the refusal as a verdict it could not take. Ten seconds is far
/// longer than a read of two files and a `cmp`, so only a wedged script
/// reaches it. The two numbers are held together by
/// `guard_timeout_budget::the_guard_check_timeout_fits_inside_the_hooks_budget`,
/// which reads the frontmatter, rather than by this comment citing it.
///
/// [`check`], [`install`] and [`uninstall`] are verbs somebody typed, under
/// no budget but the person's patience, so they name
/// [`DEFAULT_TIMEOUT`] instead: a cold or networked filesystem is slow,
/// not wedged. Naming it rather than omitting it is the point — this is
/// the one call in the tree that needs a smaller bound, and a lane that
/// said nothing would be indistinguishable from one that lost it.
pub const CHECK_TIMEOUT: Duration = Duration::from_secs(10);

/// How much the session-start `--check` may write before the run is
/// refused, and why that bound exists at all.
///
/// [`CHECK_TIMEOUT`]'s argument for the other unbounded resource. That call
/// runs a script the checkout supplies, unattended, and the reader holds
/// what the script writes in memory until it exits — so a bound on the wall
/// clock alone still lets one that loops on `echo` grow this process for ten
/// seconds.
///
/// Sixty-four kibibytes because the report declines to carry a relayed line
/// past `drift::report::RELAYED_CHARS`, which is 2000 characters, so a real
/// verdict — the summary line the package contracts to write, plus whatever
/// its shell put on stderr behind it — sits far below this.
///
/// Past the bound the process layer refuses rather than truncates, so
/// [`run_installer`] returns the error and the fold in `commands::check`
/// classes it the way it already classes an installer that exited with no
/// verdict: a check that could not be taken. Output that was cut off is not
/// a repository anybody measured.
const CHECK_OUTPUT_CAP: usize = 64 * 1024;

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
    installer(dir, &[], DEFAULT_TIMEOUT)
}

/// Disarm: the package removes its helper and its own marked line, and
/// nothing else.
///
/// A package that is gone cannot disarm the shims it left, and shims whose
/// scripts are missing fail closed on every commit — so a removal that
/// could not run is exit 2 with the reason, never a quiet success about a
/// repository nobody can commit to.
pub fn uninstall(dir: &Path) -> Result<GuardReport> {
    installer(dir, &["--uninstall"], DEFAULT_TIMEOUT)
}

/// Whether somebody standing at this repository ran the installer.
///
/// The license to run the package's scripts, and the whole of it. git
/// clones no hook files and no helper, so anything the installer left in
/// the hooks directory got there from a local act by whoever owns this
/// machine — while every byte under the work tree arrived with a fetch and
/// is whatever the branch's author wrote. That asymmetry is the only
/// durable line between the two, and it is the line [`check`]'s callers
/// draw before executing anything.
///
/// The helper's PATH, not its contents. Reading the file to decide whether
/// this package wrote it is the second grammar this module deleted, and it
/// would be answering a question already asked: a foreign file of that name
/// in a directory git never clones is still local state. What the file
/// actually is remains the package's `--check` to say, and it does.
///
/// `symlink_metadata`, so a dangling link still counts: something local
/// made it, and the package's checker is the one that grades it.
///
/// Three states, not two. `NotFound` is an answer — nothing of this
/// package's is there. Every other error is the absence of one, and it is
/// returned rather than folded into `false`: an unreadable hooks directory
/// answered `false` alongside a plain absence, and the caller turned that
/// into a positive verdict about a repository whose commits were gated
/// perfectly well.
pub fn locally_armed(repo: &Repo) -> Result<bool> {
    let helper = repo.common_dir.join("hooks").join(HELPER);
    match std::fs::symlink_metadata(&helper) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(CoreError::io(&helper, error)),
    }
}

/// Whether any copy of the package's installer is where this repository
/// would look for it.
///
/// For a caller that already knows the project DECLARED the package: a
/// declaration with nothing at all to run is a missing render, whose remedy
/// is an apply, and not the absent install [`bind`] would name.
///
/// Three states for the same reason [`locally_armed`] has three. Every
/// candidate answering `NotFound` is the only evidence that there is
/// nothing here; a directory that would not open is a search that did not
/// happen, and reporting it as "nothing rendered" would name a remedy for
/// a state nobody looked at.
///
/// Presence, not executability. This is reached only after [`bind`] has
/// already refused, and bind's own two sentences separate a copy that
/// cannot run from no copy at all — so what is left to establish here is
/// whether anything is there.
pub fn installer_present(repo: &Repo) -> Result<bool> {
    resolve::any_candidate(repo, INSTALLER)
}

/// Ask the package whether this repository is armed, and relay its answer.
///
/// Its `--check` is read-only and speaks the whole vocabulary — armed,
/// drifted, unverifiable. The only reader of a hook file anywhere in this
/// product is the script that wrote it, so every claim about what the shims
/// ARE comes from here, and `kendex guard check` and the commit-hook line
/// of `kendex check` are both this call. A caller that cannot reach this —
/// nothing local armed the repository, the render is gone, the directory
/// would not open — says what it read, never what the shims are.
///
/// It runs a script out of the checkout, so a caller reaching it without
/// somebody asking for it needs a license first. An install record is not
/// one: `.kendex-lock.json` sits under the work tree and arrives with the
/// fetch like everything else there. [`locally_armed`] is, and the
/// session-start fold in `commands::check` asks it before this. A guard
/// verb somebody typed is its own license and asks nothing.
pub fn check(dir: &Path) -> Result<GuardReport> {
    installer(dir, &["--check"], DEFAULT_TIMEOUT)
}

/// The same `--check` over a repository the caller already resolved, under
/// the session-start bound.
///
/// Resolving a repository and finding the package costs seven git children
/// where the path is taken from a directory, and five here, because the
/// `Repo` the caller already probed is not resolved a second time. The
/// fold pays those five once per project scope.
pub fn check_repo(repo: &Repo) -> Result<GuardReport> {
    let installed = installed_or_err(repo, INSTALLER)?;
    run_installer(
        repo,
        &installed,
        &["--check"],
        CHECK_TIMEOUT,
        Some(CHECK_OUTPUT_CAP),
    )
}

/// The installer, run from the repository it was pointed at, with its
/// verdict relayed unchanged.
///
/// The bound is a `Duration` and not an `Option<Duration>`, so no lane can
/// reach the process layer's default by saying nothing. It was optional
/// once, and mutating the session-start `Some(CHECK_TIMEOUT)` to `None`
/// left the whole guard suite green while the session-start `--check` ran
/// under 120 seconds inside a hook the harness gives 20. Now that call
/// does not compile.
fn installer(dir: &Path, args: &[&str], timeout: Duration) -> Result<GuardReport> {
    let (repo, installed) = bind(dir, INSTALLER)?;
    // Uncapped, named rather than omitted for the same reason the timeout
    // is: what a verb somebody typed prints is that person's to read, and a
    // script running away in front of them is theirs to stop.
    // [`CHECK_OUTPUT_CAP`] is for the call nobody is watching.
    run_installer(&repo, &installed, args, timeout, None)
}

fn run_installer(
    repo: &Repo,
    installed: &Installed,
    args: &[&str],
    timeout: Duration,
    max_output: Option<usize>,
) -> Result<GuardReport> {
    // `--repo` is a path, so it travels as one: a work tree whose name is
    // not UTF-8 would otherwise reach the installer as replacement
    // characters and be reported as a repository that does not exist.
    let mut argv = vec![
        OsString::from("--repo"),
        repo.worktree.as_os_str().to_owned(),
    ];
    argv.extend(args.iter().map(OsString::from));
    let mut script =
        Hardened::guard_script(&installed.script, argv, &repo.worktree).timeout(timeout);
    if let Some(cap) = max_output {
        script = script.max_output(cap);
    }
    let output = script
        .run()
        .map_err(|error| guard_err("hooks", error.to_string()))?;
    Ok(relay(&output))
}
