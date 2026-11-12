//! A checkout's GitHub repository, as the github package's resolver
//! (`scripts/lib/gh-repo.sh`) names it. That library owns the rule: `gh repo
//! view` in the directory, else the `owner/name` its origin remote names on
//! github.com, judged by the classes GitHub issues. This module runs it
//! through the one runner and never spells the rule again.
//!
//! The read answers the directory's own repository: `GH_REPO` and
//! `GITHUB_REPOSITORY` are set empty for it, since the resolver lets
//! `GH_REPO` win and a value the caller's environment carries for another
//! command must not stand in for the checkout's.

use std::ffi::OsStr;
use std::fmt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::host;

/// How long one resolution may take: one `gh repo view` and one git read.
const BOUND: Duration = Duration::from_secs(60);
/// The runner tag a resolution is counted under, whichever duty asked.
const TAG: &str = "repo";

/// Why a directory names no repository.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Unread {
    /// Neither gh nor the origin remote names one: the resolver's exit 1.
    Unresolved,
    /// What was named is not an `owner/name` GitHub issues, the candidate
    /// beside it: the resolver's exit 2.
    SlugForm(String),
    /// The resolver could not be run, or answered outside its contract.
    Failed(String),
}

impl fmt::Display for Unread {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Unread::Unresolved => f.write_str("unresolved"),
            Unread::SlugForm(candidate) => write!(f, "slug-form: {candidate}"),
            Unread::Failed(cause) => write!(f, "failed: {cause}"),
        }
    }
}

/// The resolver library as the project at `project` installs the github
/// package.
pub fn resolver(project: &Path) -> PathBuf {
    project.join(".agents/skills/github/scripts/lib/gh-repo.sh")
}

/// The repository of the checkout at `dir`, read by the resolver at
/// `resolver` (`kendex_github_resolve_gh_repo`).
pub fn of(resolver: &Path, dir: &Path) -> Result<String, Unread> {
    resolve(resolver, dir, "kendex_github_resolve_gh_repo")
}

/// The repository a lane works in: the one its record names, else the
/// fleet's own, the checkout at `project`. A hosted lane's worktree is on
/// the provider's disk, so a lane's repository is never read from it.
pub fn of_lane(recorded: Option<&str>, project: &Path) -> Result<String, Unread> {
    match recorded.filter(|r| !r.is_empty()) {
        Some(repo) => Ok(repo.to_owned()),
        None => of(&resolver(project), project),
    }
}

/// The `owner/name` the origin remote of the checkout at `dir` names on
/// github.com (`kendex_github_origin_slug`): read offline, and not judged
/// by the classes, as the resolver prints it.
pub fn origin(resolver: &Path, dir: &Path) -> Result<String, Unread> {
    resolve(resolver, dir, "kendex_github_origin_slug")
}

#[allow(
    clippy::disallowed_methods,
    reason = "the one reader of a checkout's repository, the github package's resolver run through the one runner in that checkout; it acts on nothing"
)]
fn resolve(resolver: &Path, dir: &Path, function: &'static str) -> Result<String, Unread> {
    let library = resolver.display().to_string();
    let place = dir.display().to_string();
    // gh reads GitHub under the watch's renewed sign-in where one stands.
    let credential = crate::watch::github::renewed_credential();
    let mut env = crate::watch::github::credential_env(&credential);
    env.extend([
        ("GH_REPO", OsStr::new("")),
        ("GITHUB_REPOSITORY", OsStr::new("")),
    ]);
    let out = host::run_tagged_in(
        TAG,
        "bash",
        Path::new("bash"),
        function,
        &[
            "-c",
            "source \"$1\" || exit 3; \"$2\" \"$3\"",
            "repo",
            &library,
            function,
            &place,
        ],
        host::Place {
            cwd: Some(dir),
            env: &env,
        },
        BOUND,
    )
    .map_err(|e| Unread::Failed(e.to_string()))?;
    let printed = host::stdout_text(&out).trim().to_owned();
    match out.status.code() {
        Some(0) if !printed.is_empty() => Ok(printed),
        Some(1) => Err(Unread::Unresolved),
        Some(2) => Err(Unread::SlugForm(printed)),
        _ => Err(Unread::Failed(format!(
            "{} {}",
            out.status,
            host::stderr_text(&out).lines().next().unwrap_or("")
        ))),
    }
}
