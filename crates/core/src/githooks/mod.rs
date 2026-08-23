//! A hooks directory kendex owns — provably, not declaratively.
//!
//! Install writes `<git-common-dir>/kendex-hooks/` with two entrypoints
//! and a receipt recording the exact files written and the exact
//! `core.hooksPath` value set. Repair rewrites only receipt-listed files;
//! uninstall deletes only receipt-listed files, removes the directory only
//! if empty after, and unsets `core.hooksPath` only while its current
//! value still equals the receipt's — compare-and-swap on both sides.
//! kendex never edits a hook file it did not create: a pre-existing or
//! symlinked `kendex-hooks` directory is a refusal, and so are foreign
//! files found there at uninstall, because unsetting `core.hooksPath`
//! around a surviving user hook would silently disable it.
//!
//! Repos armed by the vstack-named binary keep their `vstack-hooks`
//! directory: the receipt and `core.hooksPath` both name it, and moving
//! it is a different mutation than owning it. Every verb resolves the
//! live directory the same way — the one `core.hooksPath` names when it
//! names either generation's path, else the one holding a receipt, else
//! the old name only while it is the sole directory present — and works
//! there in place.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::apply::{Op, PlannedOp, Pre};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::Scope;
use crate::process::Hardened;

mod entrypoints;
mod refusals;
mod repair;
mod uninstall;
pub use entrypoints::{HOOKS, entrypoint, old_entrypoint};
pub use repair::repair;

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

/// Install (or repair) the owned hooks directory for the repository at
/// `dir`, recording this worktree's lease. The plan — refusals included
/// (see [`refusals`]) — is built under the common lock, so the directory
/// shape the refusals observe is the shape the writes land in.
pub fn install(env: &Env, dir: &Path) -> Result<HooksReport> {
    let repo = Repo::at(dir)?;
    let (_, hooks_path) =
        crate::apply::execute_common(env, &repo.scope(), &repo.common_dir, || plan_install(&repo))?;
    Ok(HooksReport {
        lines: vec![format!(
            "commit checks installed: core.hooksPath -> {hooks_path} (covers every linked worktree)"
        )],
    })
}

fn plan_install(repo: &Repo) -> Result<(Vec<PlannedOp>, String)> {
    let receipt = load_receipt(repo)?;
    refusals::check_install(repo, receipt.as_ref())?;

    let hooks_dir = repo.hooks_dir()?;
    let hooks_path = hooks_dir.display().to_string();
    let mut leases = receipt.map(|r| r.leases).unwrap_or_default();
    leases.insert(repo.worktree.display().to_string());
    let updated = Receipt {
        schema: 1,
        hooks_path: hooks_path.clone(),
        files: HOOKS
            .iter()
            .map(|name| (*name).to_owned())
            .chain(std::iter::once(RECEIPT_FILE.to_owned()))
            .collect(),
        leases,
    };

    let mut ops = Vec::new();
    for name in HOOKS {
        let path = hooks_dir.join(name);
        ops.push(PlannedOp {
            description: format!("write the {name} entrypoint"),
            op: Op::WriteExecutable {
                pre: Pre::observed(&path)?,
                path,
                bytes: entrypoint(name).into_bytes(),
            },
        });
    }
    let receipt_path = repo.receipt_path()?;
    ops.push(PlannedOp {
        description: "record the ownership receipt".into(),
        op: Op::WriteFile {
            pre: Pre::observed(&receipt_path)?,
            path: receipt_path,
            bytes: render_receipt(&updated)?,
        },
    });
    let current = crate::apply::read_git_config(&repo.config_file(), "core.hooksPath")?;
    if current.as_deref() != Some(hooks_path.as_str()) {
        ops.push(PlannedOp {
            description: "point core.hooksPath at the owned directory".into(),
            op: Op::GitConfigSwap {
                file: repo.config_file(),
                key: "core.hooksPath".into(),
                expected: current,
                value: Some(hooks_path.clone()),
            },
        });
    }
    Ok((ops, hooks_path))
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
