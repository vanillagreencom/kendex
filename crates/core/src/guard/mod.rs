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

use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::process::Hardened;

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

/// An installed copy of the package, found in one repository.
pub struct Installed {
    /// The skill directory itself, for messages that name where it was found.
    pub dir: PathBuf,
}

impl Installed {
    /// The package as this work tree carries it. The search walks the same
    /// roots the shim walks, and stops at the first that exists — a present
    /// skill whose scripts are missing is a broken install, not a reason to
    /// keep looking, so that case surfaces later as a refusal naming the
    /// path rather than as "not installed".
    pub fn find(root: &Path) -> Option<Installed> {
        SKILL_ROOTS
            .iter()
            .map(|base| root.join(base).join(SKILL))
            .find(|dir| dir.exists() || dir.is_symlink())
            .map(|dir| Installed { dir })
    }

    fn script(&self, relative: &str) -> Result<PathBuf> {
        let path = self.dir.join(relative);
        match is_executable(&path) {
            true => Ok(path),
            false => Err(guard_err(
                "hooks",
                format!(
                    "the {SKILL} skill is installed at {} but {} is missing or not executable — reinstall it with `kendex refresh`",
                    self.dir.display(),
                    path.display()
                ),
            )),
        }
    }
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path)
            .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

/// The repository the caller is standing in, and the package it carries.
/// Both refusals name what to do next, because this is reached from a
/// commit hook as often as from a terminal.
fn bind(dir: &Path) -> Result<(crate::githooks::Repo, Installed)> {
    let repo = crate::githooks::Repo::at(dir)?;
    let Some(installed) = Installed::find(&repo.worktree) else {
        return Err(guard_err(
            "hooks",
            format!(
                "no {SKILL} skill under {} ({}) — the checks live in that package; install it with `kendex add {SKILL}`",
                repo.worktree.display(),
                SKILL_ROOTS.join(" ")
            ),
        ));
    };
    Ok((repo, installed))
}

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
    let (repo, installed) = bind(dir)?;
    let script = installed.script(&format!("scripts/{hook}"))?;
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
    let output = Hardened::guard_hook(&script, &args, &repo.worktree)
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

/// Arm the shims.
///
/// A repository carrying the retired `kendex-hooks` directory has to cross
/// over: that generation points `core.hooksPath` at itself, which sends git
/// away from `.git/hooks` and makes the package's installer stand down. So
/// the old gate has to go before the new one can be written — and a gate is
/// the one thing that must never be removed on the promise of a
/// replacement.
///
/// The order that follows from it: prove the replacement can run, take the
/// old gate back, arm, then ask the installer whether the repository is
/// actually armed. Anything short of an armed verdict is a nonzero exit
/// naming what is wrong, never a success line over an ungated repository.
pub fn install(env: &Env, dir: &Path) -> Result<GuardReport> {
    // Proven before anything is removed: the package is here, its installer
    // is executable, and it actually runs. `--check` is that proof and
    // writes nothing. Its *verdict* is discarded on purpose — a repository
    // still under the old arming is one it cannot read, which is the very
    // state this command exists to leave — so only the fact that it ran
    // counts here. A script that could not run at all is the error this
    // returns instead, with the old gate untouched.
    let (repo, installed) = bind(dir)?;
    installed.script(INSTALLER)?;
    let mut lines = Vec::new();
    installer(&repo, &installed, &["--check"])?;
    if crate::githooks::installed(dir)? {
        let taken = crate::githooks::uninstall(env, dir)?;
        lines.push(
            "took back the retired kendex-hooks directory before arming the package's shims"
                .to_owned(),
        );
        lines.extend(taken.lines);
        // Removal is lease-counted: a receipt another worktree still holds
        // releases this worktree's lease and leaves the install armed, so
        // `core.hooksPath` survives and the package installer would stand
        // down and exit 0 having armed nothing. Refuse instead, naming the
        // other worktrees, rather than reporting an arming that cannot
        // happen yet.
        if let Some(path) = crate::githooks::effective_hooks_path(&repo.worktree)? {
            lines.push(format!(
                "core.hooksPath still resolves to {path} — another worktree's lease keeps the retired install armed; run `kendex guard uninstall` in those worktrees first, then rerun"
            ));
            return Ok(GuardReport { lines, code: 2 });
        }
    }
    let report = installer(&repo, &installed, &[])?;
    lines.extend(report.lines);
    if report.code != 0 {
        return Ok(GuardReport {
            lines,
            code: report.code,
        });
    }
    // The installer's own verdict, asked after the write: a repository this
    // command reports as armed has to be one the checker calls armed.
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
    let code = match bind(dir) {
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
            if let Some(stale) = stale_shims(dir)? {
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
    let Some(installed) = Installed::find(&repo.worktree) else {
        // No package, but its shims may still be armed and failing closed
        // on every commit. That is a state to report, not silence.
        return Ok(stale_shims(dir)?.map(|line| GuardReport {
            lines: vec![line],
            code: 2,
        }));
    };
    installer(&repo, &installed, &["--check"]).map(Some)
}

/// The helper the package's installer writes, and the marker it puts on the
/// delegating line — the two ways a repository can still be armed after the
/// package that armed it is gone.
const HELPER: &str = "kendex-guards";
const SENTINEL: &str = "# kendex-guards-hook";

/// A line naming shims left behind with no package to run them, or `None`
/// where the hooks directory holds nothing of the package's.
///
/// Read off the shim files rather than by asking the installer, which is
/// exactly what is missing in this case. The hooks directory is the common
/// one: linked worktrees share it, and so share whatever is armed there.
fn stale_shims(dir: &Path) -> Result<Option<String>> {
    let Some(repo) = crate::githooks::Repo::probe(dir)? else {
        return Ok(None);
    };
    let hooks = repo.common_dir.join("hooks");
    let mut found = Vec::new();
    if hooks.join(HELPER).exists() {
        found.push(HELPER.to_owned());
    }
    for lane in LANES {
        let path = hooks.join(lane);
        if crate::fs::read_if_exists(&path)?.is_some_and(|text| text.contains(SENTINEL)) {
            found.push(lane.to_owned());
        }
    }
    Ok((!found.is_empty()).then(|| {
        format!(
            "{} still carries the package's shims ({}) with no {SKILL} skill to run them — every commit here is blocked until they are removed or the package is reinstalled",
            hooks.display(),
            found.join(", ")
        )
    }))
}

fn installer(
    repo: &crate::githooks::Repo,
    installed: &Installed,
    args: &[&str],
) -> Result<GuardReport> {
    let script = installed.script(INSTALLER)?;
    let root = repo.worktree.display().to_string();
    let mut argv = vec!["--repo", root.as_str()];
    argv.extend_from_slice(args);
    let output = Hardened::guard_script(&script, &argv, &repo.worktree)
        .run()
        .map_err(|error| guard_err("hooks", error.to_string()))?;
    Ok(relay(&output))
}
