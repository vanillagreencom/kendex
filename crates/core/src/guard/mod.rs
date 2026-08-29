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
//! round after found the other. So there is one engine, and it is the one
//! that runs on a machine which never installed kendex.
//!
//! Exit taxonomy, the family contract the package defines and this module
//! relays unchanged: 0 clean, 1 violations, 2 the check could not run. Both
//! nonzero verdicts block a commit.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::error::{CoreError, Result};
use crate::process::Hardened;

mod repo;
mod resolve;
use crate::fs::is_executable;
pub use repo::Repo;
pub use resolve::Installed;
/// The tool directories the verbs search, in order — the installer's own
/// list, pinned against it by `guard_hooks::the_search_roots_match…`.
pub use resolve::SKILL_ROOTS as SEARCH_ROOTS;
use resolve::bind;

/// The package that owns the checks and the git shims.
pub const SKILL: &str = "growth-guards";

/// The marker every delegating line the installer writes ends with.
///
/// The one thing kendex reads out of a hook file, and only to answer "did
/// this package arm this repository". Present means armed; anything else —
/// a foreign hook, no file at all, a `core.hooksPath` pointing elsewhere —
/// means not armed, which is the safe answer for all of them and needs no
/// taxonomy to reach.
///
/// Where it has to be is the installer's rule, not this module's: see
/// [`hook_is_ours`].
pub const MARKER: &str = "# kendex-guards-hook";

/// The whole line the installer writes into a hook file it CREATED, which
/// is how removal tells one from a consumer's own shebang-only hook. It
/// mentions the marker without ending in it, so it is owned by name.
pub const CREATED_MARKER: &str = "# kendex-guards-hook created this file";

/// The marker inside the helper the installer writes.
///
/// The name is not the identity: the installer refuses to overwrite a file
/// of the helper's name that does not carry this, and the uninstaller
/// refuses to remove one, so a report that named such a file by its name
/// alone would tell a reader to delete what the package itself leaves.
pub const HELPER_MARKER: &str = "kendex growth-guards git hooks";

/// The helper the installer writes beside the hooks.
const HELPER: &str = "kendex-guards";

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
/// drifted, unverifiable — which is exactly what a person running this verb
/// asked for. Invoking a guard verb is the consent to run the
/// package's scripts; `kendex check`, which nobody invoked for that, reads
/// the marker instead and executes nothing.
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

/// Whether a hook file carries a line this package wrote.
///
/// The installer's own `gg_owned_lines_re`, which is the predicate its
/// removal deletes by and its `--check` reads by: a line the marker CLOSES,
/// or a line that is exactly the created marker. Matching the marker
/// anywhere is wider than that on purpose — it would claim a consumer's own
/// comment that quotes the marker mid-sentence, and both readers here would
/// then describe a gate nothing installed. Pinned to the script by
/// `guard_hooks::the_ownership_markers_match_the_installers_own`.
///
/// Split on `\n` and not [`str::lines`], which also eats a `\r`: grep does
/// not, so a CRLF hook whose line ends in `marker\r` is not owned there and
/// must not be owned here.
fn hook_is_ours(text: &str) -> bool {
    text.split('\n')
        .any(|line| line.ends_with(MARKER) || line == CREATED_MARKER)
}

/// Whether the file at the helper's path is the helper this package wrote.
///
/// The uninstaller's own predicate: a regular file, not a symlink, whose
/// bytes carry [`HELPER_MARKER`]. It deliberately preserves anything else
/// of that name, so naming one here would advise a deletion the package
/// refuses to make. A path that cannot be stat'ed is not ours either — a
/// helper left beside no lane hook of ours execs on no commit, so the
/// unsure answer costs a stray file and never a lost one.
fn helper_is_ours(path: &Path) -> Result<bool> {
    if !std::fs::symlink_metadata(path).is_ok_and(|meta| meta.is_file()) {
        return Ok(false);
    }
    Ok(crate::fs::read_if_exists(path)?.is_some_and(|text| text.contains(HELPER_MARKER)))
}

/// Whether this package armed this repository's commit hooks, read off the
/// hook files and nothing else.
///
/// `kendex check` is a read, and a checkout is other people's data: running
/// a script out of one would mean that cloning a repository and asking after
/// its status ran code its author chose. So this executes nothing, and it
/// asks the smallest question that is safe to answer from bytes alone.
///
/// The marker and the execute bit. Both lanes have to carry a line the
/// installer owns ([`hook_is_ours`]), in the directory git reads with no
/// redirect in the way, and both have to be files git will actually run —
/// git skips a hook without `+x` in silence, so an owned line in a file it
/// ignores describes a gate that is not there.
/// Executability is git's own rule about hook files rather than anything
/// this package puts in them, which is why reading it is not the grammar
/// this module deliberately no longer has.
///
/// A `core.hooksPath` set to anything at all means the answer is no — not
/// because such a repository is necessarily ungated, but because deciding
/// whether it is takes a grammar nothing here has, the package's own
/// `--check` included: it stands down on that value rather than grade it.
/// Every uncertainty inside a repository lands on "not armed", whose remedy
/// is a command that is safe to run twice.
///
/// Over a repository the caller already probed: whether there is one here
/// at all is the caller's question, and probing it again for every read
/// spends three git processes per answer.
///
/// A person who wants the full vocabulary runs `kendex guard check`, which
/// asks the package. That is an invocation, and an invocation is consent.
pub fn armed(repo: &Repo) -> Result<bool> {
    if repo.hooks_redirected()? {
        return Ok(false);
    }
    let hooks = repo.default_hooks_dir();
    for lane in LANES {
        let path = hooks.join(lane);
        let Some(text) = crate::fs::read_if_exists(&path)? else {
            return Ok(false);
        };
        if !hook_is_ours(&text) || !is_executable(&path) {
            return Ok(false);
        }
    }
    Ok(true)
}

/// The hook files this package left behind in a repository that no longer
/// carries the package anywhere.
///
/// The same read as [`armed`] — an owned line, in the directory git reads —
/// with the opposite precondition: no copy of the package anywhere the
/// shared hooks gate, which is every work tree attached to this common git
/// dir. A shim that survives its package execs a script that is not there,
/// so every commit in the repository fails closed, and nothing else reports
/// it: the lock no longer names the package, so the drift report has
/// nothing to compare, and `guard check` cannot run an installer that is
/// gone.
///
/// Cheapest question first. The hook files are read before anything is
/// spawned, because a repository with no owned line in them is the ordinary
/// case and this runs at every session start; only an owned line earns the
/// git process behind `hooks_redirected` and the search behind
/// `Installed::anywhere`.
///
/// Hooks-directory-wide, not project-wide and not work-tree-wide. Every
/// project in a work tree shares one hooks directory, and so does every
/// work tree attached to the same common git dir — so a project or a work
/// tree without the package beside one that armed it is a gated
/// repository, not a stranded one, and the advice here, followed, would
/// have disarmed the gate that other copy asked for.
///
/// A domain that could not be read in full yields the error rather than an
/// empty list: the caller reports "could not check" instead of telling a
/// reader to delete hook files that may be gating a copy nobody could see.
///
/// Each lane carrying a line the installer owns, and the helper beside
/// them when it carries the installer's helper marker, so the report can
/// say which files to clean up. Both predicates are the installer's own
/// ([`hook_is_ours`], [`helper_is_ours`]) rather than an approximation of
/// them, because the advice here is a deletion: a lane hook the installer
/// would not strip and a helper it would not remove are somebody else's
/// files. A helper with no owned lane beside it runs on no commit, so it
/// is named only where one is.
/// Empty where `core.hooksPath` is set: git reads no hook here, so nothing
/// fails, and what a redirected directory means is a grammar this module
/// does not have. The execute bit is not consulted: a leftover git happens
/// to skip is still a leftover.
pub fn stranded(repo: &Repo) -> Result<Vec<PathBuf>> {
    let hooks = repo.default_hooks_dir();
    let mut files = Vec::new();
    for lane in LANES {
        let path = hooks.join(lane);
        if crate::fs::read_if_exists(&path)?.is_some_and(|text| hook_is_ours(&text)) {
            files.push(path);
        }
    }
    if files.is_empty() || repo.hooks_redirected()? || Installed::anywhere(repo)? {
        return Ok(Vec::new());
    }
    let helper = hooks.join(HELPER);
    if helper_is_ours(&helper)? {
        files.push(helper);
    }
    Ok(files)
}
