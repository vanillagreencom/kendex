//! Taking back the retired hooks directory kendex used to own.
//!
//! Two generations of this binary armed commits by writing
//! `<git-common-dir>/kendex-hooks/` (or `vstack-hooks/`) and pointing
//! `core.hooksPath` at it. That arming is retired: the checks live in the
//! growth-guards package, and the package's installer writes `.git/hooks`
//! shims instead, deliberately never touching `core.hooksPath` — which
//! redirects the whole directory and disables the repository's own hooks.
//! A `core.hooksPath` set here also makes the package's installer stand
//! down, so a repository cannot cross to the surviving arming until this
//! one is undone.
//!
//! What survives is the removal, for one release: `kendex guard install`
//! and `kendex guard uninstall` take an old install back before they do
//! anything else. Removal stays receipt-scoped with compare-and-swap on
//! both sides — a user-changed hooksPath survives, a user-added file is a
//! refusal rather than a half-removal — and where the receipt is gone,
//! ownership is proven by content: a directory holding nothing but
//! byte-identical copies of either generation's entrypoints is ours by
//! construction, and anything else in it stays exactly where it is. The
//! entrypoint text is kept for that comparison alone; nothing writes it.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::Scope;
use crate::process::Hardened;

mod entrypoints;
mod refusals;
mod uninstall;
pub use entrypoints::{HOOKS, entrypoint, old_entrypoint};

/// git's own wording for the one failure that means "no repository here".
/// Matched as a phrase rather than by exit status: 128 is git's catch-all,
/// and a dubious-ownership refusal or a broken config carries it too.
const NOT_A_REPOSITORY: [&str; 2] = ["not a git repository", "not a working tree"];

pub const HOOKS_DIR: &str = "kendex-hooks";
/// The directory name the vstack-named binary wrote. Installs made under
/// it stay there — their receipts and `core.hooksPath` name it — until
/// uninstall takes the whole directory back.
pub const OLD_HOOKS_DIR: &str = "vstack-hooks";
pub const RECEIPT_FILE: &str = "receipt.json";
/// v1's shim sentinel: a hook carrying it is decommissioned, never chained.
pub const V1_SENTINEL: &str = "# vstack-guards-hook";

fn err(message: impl Into<String>) -> CoreError {
    crate::guard::guard_err("hooks", message)
}

/// One repository, resolved: the worktree that invoked us and the common
/// dir every linked worktree shares. Both canonical, because leases and
/// the registry compare paths as text: one worktree reached through a
/// symlink must never read as two, or as none.
pub struct Repo {
    pub worktree: PathBuf,
    pub common_dir: PathBuf,
}

impl Repo {
    pub fn at(dir: &Path) -> Result<Repo> {
        let output = Hardened::git(
            &["rev-parse", "--show-toplevel", "--git-common-dir"],
            Some(dir),
        )
        .run()?;
        if !output.status.success() {
            return Err(err("not inside a git repository"));
        }
        let text = String::from_utf8_lossy(&output.stdout);
        let mut lines = text.lines();
        let (Some(worktree), Some(common)) = (lines.next(), lines.next()) else {
            return Err(err(format!(
                "git named no working tree for {} — hooks install into a checkout, not a bare repository",
                dir.display()
            )));
        };
        let worktree = PathBuf::from(worktree);
        let worktree = worktree
            .canonicalize()
            .map_err(|e| CoreError::io(&worktree, e))?;
        // A relative common dir is relative to where git was asked — `dir`
        // — not to the top level: from a subdirectory git says `../.git`,
        // and joining that onto the top level names the wrong repository.
        let common = PathBuf::from(common);
        let common_dir = match common.is_absolute() {
            true => common,
            false => dir
                .canonicalize()
                .map_err(|e| CoreError::io(dir, e))?
                .join(common),
        };
        let common_dir = common_dir
            .canonicalize()
            .map_err(|e| CoreError::io(&common_dir, e))?;
        Ok(Repo {
            worktree,
            common_dir,
        })
    }

    /// The repository at `dir`, or `None` where there is none.
    ///
    /// [`Repo::at`] answers one question with two meanings: a directory
    /// outside any repository and a git that could not run both arrive as
    /// the same error. A caller deciding whether a verdict is *owed* needs
    /// them apart — "no repository here, so no gate is expected" is a clean
    /// answer, while "git would not run" is a check that could not be
    /// taken. Only the first is `Ok(None)`.
    pub fn probe(dir: &Path) -> Result<Option<Repo>> {
        let output = Hardened::git(&["rev-parse", "--is-inside-work-tree"], Some(dir)).run()?;
        let answer = String::from_utf8_lossy(&output.stdout);
        if output.status.success() {
            // Inside a repository. `false` means a git directory reached
            // directly, or a bare one — no work tree, so no gate is
            // expected. Anything else is an answer this cannot read.
            return match answer.trim() {
                "true" => Repo::at(dir).map(Some),
                "false" => Ok(None),
                other => Err(err(format!(
                    "git answered '{other}' when asked whether {} is a work tree",
                    dir.display()
                ))),
            };
        }
        // A failure is only "no repository" when git says so in as many
        // words. Exit 128 covers far more than that — a malformed config,
        // a repository whose ownership git refuses, an unreadable object
        // store — and every one of those is a check that could not be
        // taken. Calling them "nothing here" would read as a pass.
        let complaint = String::from_utf8_lossy(&output.stderr);
        match NOT_A_REPOSITORY
            .iter()
            .any(|phrase| complaint.contains(phrase))
        {
            true => Ok(None),
            false => Err(err(format!(
                "could not tell whether {} is a work tree (git exited {:?}): {}",
                dir.display(),
                output.status.code(),
                complaint.trim()
            ))),
        }
    }

    fn scope(&self) -> Scope {
        Scope::Project {
            root: self.worktree.clone(),
        }
    }

    /// Both directory names that can be ours, new generation first.
    fn generation_dirs(&self) -> [PathBuf; 2] {
        [
            self.common_dir.join(HOOKS_DIR),
            self.common_dir.join(OLD_HOOKS_DIR),
        ]
    }

    /// The owned directory this repository resolves to. `core.hooksPath`
    /// is what git actually executes, so when it names either
    /// generation's path that vote wins — a stray directory under the
    /// other name must never shadow the armed one. Absent that vote, a
    /// receipt marks the directory an install wrote; absent both, the
    /// old name counts only while it is the sole directory present.
    pub fn hooks_dir(&self) -> Result<PathBuf> {
        let [new, old] = self.generation_dirs();
        let config = crate::apply::read_git_config(&self.config_file(), "core.hooksPath")?;
        if let Some(value) = config
            && let Some(dir) = [&new, &old]
                .into_iter()
                .find(|dir| dir.display().to_string() == value)
        {
            return Ok(dir.clone());
        }
        if let Some(dir) = [&new, &old]
            .into_iter()
            .find(|dir| dir.join(RECEIPT_FILE).is_file())
        {
            return Ok(dir.clone());
        }
        Ok(match !new.exists() && old.exists() {
            true => old,
            false => new,
        })
    }

    pub(super) fn receipt_path(&self) -> Result<PathBuf> {
        Ok(self.hooks_dir()?.join(RECEIPT_FILE))
    }

    pub(super) fn config_file(&self) -> PathBuf {
        self.common_dir.join("config")
    }

    /// Whether a `--show-origin` line names a config file a takeback can
    /// clear: this repository's own, shared or per-worktree.
    ///
    /// git answers the origin relative to where it was asked (`file:.git/
    /// config` from the work tree), so the spelling is resolved against the
    /// work tree before it is compared. Everything under the common dir
    /// counts — `config` and every `worktrees/*/config.worktree` — because
    /// all of them go with the repository. Anything else, global or
    /// included from elsewhere, outlives it.
    pub(super) fn owns_config(&self, origin: &str) -> bool {
        let raw = origin.strip_prefix("file:").unwrap_or(origin);
        let path = std::path::Path::new(raw);
        let path = match path.is_absolute() {
            true => path.to_path_buf(),
            false => self.worktree.join(path),
        };
        let resolved = path.canonicalize().unwrap_or(path);
        resolved.starts_with(&self.common_dir)
    }

    /// Every live worktree git's own registry lists, canonicalized. A
    /// worktree whose directory is gone stays in the registry as
    /// `prunable` until someone prunes; it is dead for every purpose here
    /// — its lease is reaped, its config is not asked for.
    pub fn worktrees(&self) -> Result<Vec<PathBuf>> {
        let output =
            Hardened::git(&["worktree", "list", "--porcelain"], Some(&self.worktree)).run()?;
        if !output.status.success() {
            return Err(err("git worktree list failed"));
        }
        let text = String::from_utf8_lossy(&output.stdout);
        Ok(text
            .split("\n\n")
            .filter(|block| !block.lines().any(|line| line.starts_with("prunable")))
            .filter_map(|block| {
                block
                    .lines()
                    .find_map(|line| line.strip_prefix("worktree "))
            })
            .map(|path| {
                let path = PathBuf::from(path);
                path.canonicalize().unwrap_or(path)
            })
            .collect())
    }
}

/// The recorded proof of ownership: exactly what was written, exactly what
/// was set, and which worktrees enabled the install (the leases uninstall
/// counts down).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub struct Receipt {
    pub schema: u32,
    /// The exact `core.hooksPath` value set.
    pub hooks_path: String,
    /// Files written into the hooks directory, by name.
    pub files: Vec<String>,
    /// Worktree roots that enabled the install. The install stays armed
    /// while any lease survives.
    pub leases: BTreeSet<String>,
}

pub fn load_receipt(repo: &Repo) -> Result<Option<Receipt>> {
    let Some(text) = crate::fs::read_if_exists(&repo.receipt_path()?)? else {
        return Ok(None);
    };
    serde_json::from_str(&text)
        .map(Some)
        .map_err(|e| err(format!("unreadable hooks receipt: {e}")))
}

#[derive(Debug)]
pub struct HooksReport {
    pub lines: Vec<String>,
}

/// Whether this repository still carries an install of the retired
/// generation — a receipt, or something orphaned that is provably ours.
/// The guard verbs ask before taking anything back, so a repository that
/// never had one is never told about a directory it does not have.
pub fn installed(dir: &Path) -> Result<bool> {
    let repo = Repo::at(dir)?;
    Ok(load_receipt(&repo)?.is_some() || uninstall::orphaned(&repo)?)
}

/// Release this worktree's lease; disarm only when the last one goes —
/// see [`mod@uninstall`] for what that entails.
pub fn uninstall(env: &Env, dir: &Path) -> Result<HooksReport> {
    let repo = Repo::at(dir)?;
    // A repository with nothing of ours in it gets its answer without
    // taking any lock: there is nothing to serialize against.
    if load_receipt(&repo)?.is_none() && !uninstall::orphaned(&repo)? {
        return Ok(HooksReport {
            lines: vec![NOTHING_INSTALLED.to_owned()],
        });
    }
    let (_, mut lines) =
        crate::apply::execute_common(env, &repo.scope(), &repo.common_dir, || {
            uninstall::plan(&repo)
        })?;
    // What is effective after decides what the user sees next.
    let effective = effective_hooks_path(&repo.worktree)?;
    lines.push(match effective {
        Some(path) => format!("effective core.hooksPath is now {path}"),
        None => "no core.hooksPath is in effect; git's own hooks directory applies".into(),
    });
    Ok(HooksReport { lines })
}

const NOTHING_INSTALLED: &str = "no kendex hooks are installed in this repository";

/// The hooks directory git actually reads, its own answer. Under a
/// `core.hooksPath` redirect this is the redirected directory; without one
/// it is the repository's default. Asked rather than derived, because those
/// two cases are exactly what a check about hooks has to tell apart.
pub fn effective_hooks_dir(worktree: &Path) -> Result<PathBuf> {
    let output = Hardened::git(&["rev-parse", "--git-path", "hooks"], Some(worktree)).run()?;
    if !output.status.success() {
        return Err(err(format!(
            "could not resolve the hooks directory of {}",
            worktree.display()
        )));
    }
    let answer = String::from_utf8_lossy(&output.stdout);
    let path = PathBuf::from(answer.trim());
    // git answers relative to where it was asked when the path is inside
    // the repository it was asked from.
    Ok(match path.is_absolute() {
        true => path,
        false => worktree.join(path),
    })
}

/// The repository's default hooks directory, whether or not git reads it.
/// What an install writes to while a redirect is still in place, and what
/// goes live the moment that redirect is removed.
pub fn default_hooks_dir(repo: &Repo) -> PathBuf {
    repo.common_dir.join("hooks")
}

/// What `core.hooksPath` would resolve to once this repository's own value
/// is gone — a value and the file it came from, or `None` when nothing
/// else sets one.
///
/// A takeback unsets the repository-local value to let git read
/// `.git/hooks` again, and that does not always follow: a global value, or
/// one an `include.path` pulls in, surfaces as soon as the local one goes.
/// Removing the old gate would then leave the new shims dormant with
/// nothing gating, so this is asked before anything is removed. Precedence
/// is git's own — `--get-all` answers lowest source first, so the last
/// surviving entry wins.
pub fn hooks_path_beneath_local(repo: &Repo) -> Result<Option<(String, String)>> {
    let output = Hardened::git(
        &["config", "--show-origin", "--get-all", "core.hooksPath"],
        Some(&repo.worktree),
    )
    .run()?;
    match output.status.code() {
        Some(0) => {}
        // No value anywhere.
        Some(1) => return Ok(None),
        other => {
            return Err(err(format!(
                "could not read where core.hooksPath comes from (git exited {other:?}): {}",
                String::from_utf8_lossy(&output.stderr).trim()
            )));
        }
    }
    let text = String::from_utf8_lossy(&output.stdout);
    Ok(text
        .lines()
        .filter_map(|line| line.split_once('\t'))
        .filter(|(origin, _)| !repo.owns_config(origin))
        .map(|(origin, value)| (value.to_owned(), origin.to_owned()))
        .next_back())
}

/// The `core.hooksPath` a worktree actually resolves, git's own answer.
pub fn effective_hooks_path(worktree: &Path) -> Result<Option<String>> {
    let output = Hardened::git(&["config", "--get", "core.hooksPath"], Some(worktree)).run()?;
    match output.status.code() {
        Some(0) => Ok(Some(
            String::from_utf8_lossy(&output.stdout).trim().to_owned(),
        )),
        Some(1) => Ok(None),
        _ => Err(err(format!(
            "cannot read the effective core.hooksPath in {}",
            worktree.display()
        ))),
    }
}

pub(super) fn render_receipt(receipt: &Receipt) -> Result<Vec<u8>> {
    let mut text = serde_json::to_string_pretty(receipt)
        .map_err(|e| err(format!("unrenderable receipt: {e}")))?;
    text.push('\n');
    Ok(text.into_bytes())
}
