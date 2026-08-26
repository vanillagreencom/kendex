//! Commit-time guards — delegated, never reimplemented.
//!
//! The checks live in the growth-guards package, written in shell, and they
//! travel with the repository under `.agents/skills/`. That is the whole
//! portability property: git runs the shims, the shims run the committed
//! scripts, and no kendex binary is anywhere in the path at commit time. A
//! teammate who cloned the repo and has never heard of kendex still commits
//! through the same gate.
//!
//! So kendex implements no check. These verbs find the installed copy of the
//! package and hand it the work: arming the shims, disarming them, asking
//! whether they are armed, and standing in as the gate where no git hook has
//! been armed at all.
//!
//! Exit taxonomy, the family contract the package defines and this module
//! relays unchanged: 0 clean, 1 violations, 2 the check could not run. Both
//! nonzero verdicts block a commit.

use std::path::Path;
use std::time::Duration;

use crate::error::{CoreError, Result};
use crate::process::Hardened;

mod repo;
mod resolve;
pub(super) mod shims;
pub use repo::Repo;
pub use resolve::Installed;
use resolve::bind;
use shims::{missing_shims, stale_shims};

/// The package that owns the checks and the git shims.
pub const SKILL: &str = "growth-guards";

/// Where an installed skill can sit, in the order the package's own hook
/// helper searches them. Kept identical to that list on purpose: a repo
/// where the shim finds a script and kendex finds a different one would gate
/// commits one way and report them another.
const SKILL_ROOTS: [&str; 5] = [
    ".agents/skills",
    ".claude/skills",
    ".cursor/rules",
    ".opencode/skills",
    "skills",
];

/// The installer the package ships, relative to its own directory.
const INSTALLER: &str = "scripts/install-git-hooks";

/// Room for the whole chain, which ends in whatever the repository pointed
/// `GROWTH_GUARDS_PRE_COMMIT_LOCAL` at — a cold clippy build, in this repo.
/// It matches the `pre-commit-check` hook's own budget so that kendex is
/// never the thing that kills a run the harness was still willing to wait
/// for. Arming and reporting are fast and keep the ordinary timeout.
const CHAIN_TIMEOUT: Duration = Duration::from_secs(1800);

pub(crate) fn guard_err(check: &str, message: impl Into<String>) -> CoreError {
    CoreError::Guard {
        check: check.to_owned(),
        message: message.into(),
    }
}

/// What a delegated run said and how it ended. `code` is the package's own
/// exit status, relayed rather than reinterpreted.
#[derive(Debug)]
pub struct GuardReport {
    pub lines: Vec<String>,
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
    let script = &installed.script;
    // The message path is resolved against the invoker's directory before
    // anything else, because the child runs from the repository root: git
    // hands the hook `.git/COMMIT_EDITMSG` relative to where it ran the
    // hook, and rebasing that on the root names a file that is not there.
    let message = match message_file {
        Some(path) if path.is_relative() => Some(
            std::env::current_dir()
                .map_err(|error| guard_err(hook, error.to_string()))?
                .join(path)
                .to_string_lossy()
                .into_owned(),
        ),
        Some(path) => Some(path.to_string_lossy().into_owned()),
        None => None,
    };
    let args: Vec<&str> = message.as_deref().into_iter().collect();
    let output = Hardened::guard_hook(script, &args, &repo.worktree)
        .timeout(CHAIN_TIMEOUT)
        .run()
        .map_err(|error| guard_err(hook, error.to_string()))?;
    Ok(relay(&output))
}

/// The package's words and its verdict, both kept. A guard's report is the
/// remediation text a committer acts on, so it travels whole; a status the
/// platform cannot name is "could not run", never a pass.
fn relay(output: &std::process::Output) -> GuardReport {
    let mut lines: Vec<String> = Vec::new();
    for stream in [&output.stdout, &output.stderr] {
        lines.extend(String::from_utf8_lossy(stream).lines().map(str::to_owned));
    }
    let code = match output.status.code() {
        Some(code) => u8::try_from(code).unwrap_or(2),
        None => 2,
    };
    GuardReport { lines, code }
}

/// Arm the shims, with no moment where neither gate stands.
///
/// A repository carrying the retired `kendex-hooks` directory has to cross
/// over, and the two arrangements are compatible in exactly one direction:
/// the package writes into the repository's default hooks directory, which
/// `core.hooksPath` makes git ignore. So the new shims can be written while
/// the old gate is still live and gating — dormant, waiting — and the
/// takeback that removes the redirect is the single step that brings them
/// up as it takes the old one down.
///
/// The order follows: a sanity probe, then arm, then verify the files are
/// there, then take the old install back, then ask the installer for its
/// verdict. Every failure before the takeback leaves the retired gate
/// exactly as it was, fully armed.
/// Arm the shims: the package's own installer, in this repository.
///
/// A `core.hooksPath` pointing somewhere else is the installer's to report
/// — it stands down and says so, because shims git never reads would only
/// mislead. kendex knows nothing about where such a redirect came from.
pub fn install(dir: &Path) -> Result<GuardReport> {
    let (repo, installed) = bind(dir, INSTALLER)?;
    installer(&repo, &installed, &[])
}

/// Disarm: the package removes its helper and its own marked line, and
/// nothing else.
pub fn uninstall(dir: &Path) -> Result<GuardReport> {
    let mut lines = Vec::new();
    let code = match bind(dir, INSTALLER) {
        Ok((repo, installed)) => {
            let report = installer(&repo, &installed, &["--uninstall"])?;
            lines.extend(report.lines);
            report.code
        }
        // The package is gone and its shims may not be. A shim whose
        // scripts are missing fails closed on every commit, so a removal
        // that could not run is exit 2 — reporting success here would
        // leave a repository nobody can commit to looking disarmed.
        Err(error) => {
            lines.push(error.to_string());
            if let Ok(Some(repo)) = repo::Repo::probe(dir)
                && let Some(stale) = stale_shims(&repo)?
            {
                lines.push(stale);
            }
            lines.push(
                "the package's uninstaller could not run — any shims in the hooks directory must be removed by hand".to_owned(),
            );
            2
        }
    };
    Ok(GuardReport { lines, code })
}

/// Whether commits here are gated, read off the hook files themselves.
///
/// This one never executes anything. `kendex check` is a read, and a
/// checkout is other people's data: running a script out of one would mean
/// that cloning a repository and asking after its status ran code its
/// author chose. Everything it needs is on disk — whether the hooks git
/// runs delegate to the package, and whether the helper they reach for is
/// there — so it reads that and says so.
///
/// The package's own `--check` still exists and still speaks its full
/// vocabulary; a person can run it, and the explicit `guard` verbs do. The
/// difference is that those are invocations, and an invocation is consent.
///
/// `installed_here` says whether this project's own install record carries
/// the package. It decides wording, never permission — nothing is executed
/// either way. A checkout that merely carries the files, as every clone of
/// a repository committing its harness render does, is not missing an
/// arming nobody asked for, and saying so at every session start would be
/// noise on repositories that never opted in.
///
/// `Ok(None)` where nothing is owed: not a work tree, or a repository with
/// no shims and nothing expecting any. A verdict that could not be taken is
/// exit 2, never a silent pass.
pub fn armed(dir: &Path, installed_here: bool) -> Result<Option<GuardReport>> {
    // Only "this is not a work tree" is a missing verdict. Anything else —
    // git absent, metadata unreadable, a probe that failed — is a check
    // that could not be taken, and reporting it as "nothing to say" would
    // read as a pass.
    let Some(repo) = repo::Repo::probe(dir)? else {
        return Ok(None);
    };
    let live = repo.effective_hooks_dir()?;
    let package = Installed::resolve(&repo, INSTALLER);

    // Armed and whole: nothing to report.
    let missing = missing_shims(&live)?;
    if missing.is_none() {
        // Unless there is no package left to run them, which is the one
        // state where armed hooks are the problem rather than the answer.
        return Ok(match package.is_none() {
            true => stale_shims(&repo)?.map(|line| GuardReport {
                lines: vec![line],
                code: 2,
            }),
            false => None,
        });
    }

    // Partly armed: some of what the installer writes is there and some is
    // not, so a commit runs a hook that cannot reach what it delegates to.
    if stale_shims(&repo)?.is_some() {
        return Ok(Some(GuardReport {
            lines: vec![format!(
                "commit hooks in {} are not intact ({}) — run `kendex guard install` to repair them",
                live.display(),
                missing.unwrap_or_default()
            )],
            code: 1,
        }));
    }

    // Nothing armed. Worth saying only where somebody installed the
    // package here and is expecting it to gate their commits.
    if package.is_none() || !installed_here {
        return Ok(None);
    }
    Ok(Some(GuardReport {
        lines: vec![format!(
            "commit hooks are not armed in {} — `kendex guard install` arms them",
            live.display()
        )],
        code: 1,
    }))
}

fn installer(repo: &repo::Repo, installed: &Installed, args: &[&str]) -> Result<GuardReport> {
    let root = repo.worktree.display().to_string();
    let mut argv = vec!["--repo", root.as_str()];
    argv.extend_from_slice(args);
    let output = Hardened::guard_script(&installed.script, &argv, &repo.worktree)
        .run()
        .map_err(|error| guard_err("hooks", error.to_string()))?;
    Ok(relay(&output))
}
