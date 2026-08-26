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

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::process::Hardened;

mod resolve;
pub(super) mod shims;
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

impl GuardReport {
    fn spoken(lines: Vec<String>) -> GuardReport {
        GuardReport { lines, code: 0 }
    }
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
pub fn install(env: &Env, dir: &Path) -> Result<GuardReport> {
    let (repo, installed) = bind(dir, INSTALLER)?;
    let mut lines = Vec::new();
    // Cheapest possible proof that the installer runs at all — a broken
    // interpreter or a syntax error fails here, before anything is written
    // and long before the old gate is touched. `--help` writes nothing and
    // must exit 0; anything else is a package this cannot arm with.
    let probe = installer(&repo, &installed, &["--help"])?;
    if probe.code != 0 {
        lines.extend(probe.lines);
        lines.push(format!(
            "{} could not run — nothing was changed",
            installed.script.display()
        ));
        return Ok(GuardReport { lines, code: 2 });
    }

    let retired = crate::githooks::installed(dir)?;
    // Under a live redirect the installer stands down by default, because
    // shims git ignores are otherwise only misleading. Here they are the
    // point: staged now, live the moment the redirect goes.
    let args: &[&str] = match retired {
        true => &["--into-default-hooks"],
        false => &[],
    };
    let report = installer(&repo, &installed, args)?;
    lines.extend(report.lines);
    if report.code != 0 {
        return Ok(GuardReport {
            lines,
            code: report.code,
        });
    }
    // Proven on disk before the old gate goes: the helper and both marked
    // hooks are in the directory that becomes live. The installer's own
    // `--check` cannot answer this yet — it judges where git reads, which
    // is still the retired directory.
    let staged = crate::githooks::default_hooks_dir(&repo);
    if let Some(missing) = missing_shims(&staged)? {
        lines.push(format!(
            "{} is not armed after the install above ({missing}) — the retired install was left in place",
            staged.display()
        ));
        return Ok(GuardReport { lines, code: 2 });
    }

    if retired {
        let taken = crate::githooks::uninstall(env, dir)?;
        lines.push(
            "took back the retired kendex-hooks directory; the package's shims are now live"
                .to_owned(),
        );
        lines.extend(taken.lines);
        // Removal is lease-counted: a receipt another worktree still holds
        // releases this worktree's lease and leaves the redirect standing,
        // so the staged shims are still dormant. Say so — the repository is
        // gated, by the old gate, and this command did not finish.
        if let Some(path) = crate::githooks::effective_hooks_path(&repo.worktree)? {
            lines.push(format!(
                "core.hooksPath still resolves to {path} — another worktree's lease keeps the retired install armed, so the shims written above stay dormant; run `kendex guard uninstall` in those worktrees, then rerun"
            ));
            return Ok(GuardReport { lines, code: 2 });
        }
    }

    // The installer's own verdict, asked once git reads where the shims
    // are: a repository this command calls armed has to be one the checker
    // calls armed too.
    let verdict = installer(&repo, &installed, &["--check"])?;
    if verdict.code != 0 {
        lines.extend(verdict.lines);
        lines.push("the shims are not armed after the install above".to_owned());
        return Ok(GuardReport { lines, code: 2 });
    }
    Ok(GuardReport::spoken(lines))
}

/// Disarm: the package removes its helper and its own marked line, and
/// nothing else. Any retired `kendex-hooks` install goes with it, so one
/// command leaves a repository with none of ours in it either generation.
pub fn uninstall(env: &Env, dir: &Path) -> Result<GuardReport> {
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
            if let Ok(Some(repo)) = crate::githooks::Repo::probe(dir)
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
    if crate::githooks::installed(dir)? {
        let taken = crate::githooks::uninstall(env, dir)?;
        lines.extend(taken.lines);
    }
    Ok(GuardReport { lines, code })
}

/// Whether the shims are armed, in the package's own words. The installer
/// answers this, so the thing that writes the shims and the thing that
/// reports on them cannot disagree about what "armed" means.
///
/// `Ok(None)` where no verdict is owed: this is not a work tree, or the
/// package is not installed here, so no shim can fire and none is expected.
/// A package that IS installed and whose installer cannot be run is an
/// error, never a quiet pass — that is a broken install, not a clean one.
pub fn armed(dir: &Path) -> Result<Option<GuardReport>> {
    // Only "this is not a work tree" is a missing verdict. Anything else —
    // git absent, metadata unreadable, a probe that failed — is a check
    // that could not be taken, and reporting it as "nothing to say" would
    // read as a pass.
    let Some(repo) = crate::githooks::Repo::probe(dir)? else {
        return Ok(None);
    };
    let Some(installed) = Installed::resolve(&repo, INSTALLER) else {
        // Nothing here can answer for the shims. Three different states
        // arrive at this line and only one of them is silence.
        let stale = stale_shims(&repo)?;
        // Shims with no installer: they are armed and failing closed on
        // every commit, which is the loudest of the three.
        if let Some(line) = stale {
            return Ok(Some(GuardReport {
                lines: vec![line],
                code: 2,
            }));
        }
        // A package that is here but whose installer is missing or not
        // executable is a broken install. Nothing is armed yet, so nothing
        // is blocked — but the next `guard install` cannot run either, and
        // a clean verdict would send a reader off believing the gate is a
        // command away.
        if let Some(dir) = Installed::present(&repo) {
            return Ok(Some(GuardReport {
                lines: vec![format!(
                    "the {SKILL} skill at {} carries no runnable {INSTALLER} — commit hooks cannot be armed or reported on until it is reinstalled (`kendex refresh`)",
                    dir.display()
                )],
                code: 2,
            }));
        }
        // No package and no shims: no gate is expected here.
        return Ok(None);
    };
    installer(&repo, &installed, &["--check"]).map(Some)
}

fn installer(
    repo: &crate::githooks::Repo,
    installed: &Installed,
    args: &[&str],
) -> Result<GuardReport> {
    let root = repo.worktree.display().to_string();
    let mut argv = vec!["--repo", root.as_str()];
    argv.extend_from_slice(args);
    let output = Hardened::guard_script(&installed.script, &argv, &repo.worktree)
        .run()
        .map_err(|error| guard_err("hooks", error.to_string()))?;
    Ok(relay(&output))
}
