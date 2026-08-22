use std::fs;
use std::path::{Path, PathBuf};

use super::journal;
pub use super::pre::Pre;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::lock::Lock;
use crate::manifest::Manifest;
use crate::model::Scope;

#[derive(Debug, Clone, PartialEq)]
pub enum Op {
    WriteFile {
        path: PathBuf,
        bytes: Vec<u8>,
        pre: Pre,
    },
    /// Replace `root` wholesale with the given rendered tree.
    WriteTree {
        root: PathBuf,
        files: Vec<(PathBuf, Vec<u8>)>,
        pre: Pre,
    },
    Symlink {
        link: PathBuf,
        target: PathBuf,
        pre: Pre,
    },
    Rename {
        from: PathBuf,
        to: PathBuf,
        /// Checked against `to`: rename(2) replaces its destination
        /// silently, so a file that appeared since planning must abort.
        to_pre: Pre,
    },
    /// Removal never deletes: the artifact moves to the trash.
    Trash { path: PathBuf, pre: Pre },
    /// Apply every structured edit destined for one config file in a single
    /// mutation with a single precondition — two registrations into one
    /// settings file must both land in one apply. Unrelated keys always
    /// survive.
    EditFile {
        path: PathBuf,
        edits: Vec<crate::configedit::ConfigEdit>,
        pre: Pre,
    },
    /// Both records are written as whole plan-time snapshots, so `pre`
    /// keeps a stale plan from reverting a concurrent apply's work.
    WriteLock {
        path: PathBuf,
        lock: Box<Lock>,
        pre: Pre,
    },
    WriteManifest {
        path: PathBuf,
        manifest: Box<Manifest>,
        pre: Pre,
    },
    /// A file that must carry the executable bit — a git hook entrypoint.
    /// Same rollback story as WriteFile: the journal holds the pre-image.
    WriteExecutable {
        path: PathBuf,
        bytes: Vec<u8>,
        pre: Pre,
    },
    /// Compare-and-swap one key in one git config file. `expected` is the
    /// current value the plan observed (None = unset); a config that moved
    /// since planning aborts, so a user's hand-set value is never
    /// clobbered and an uninstall never unsets somebody else's path.
    /// Rollback restores the whole config file from its journaled
    /// pre-image.
    GitConfigSwap {
        /// The config file itself — what the journal snapshots.
        file: PathBuf,
        key: String,
        expected: Option<String>,
        /// None unsets the key.
        value: Option<String>,
    },
}

impl Op {
    /// Every path this op mutates — journaled before execution.
    pub(super) fn touched(&self) -> Vec<PathBuf> {
        match self {
            Op::WriteFile { path, .. } => vec![path.clone()],
            Op::WriteTree { root, .. } => vec![root.clone()],
            Op::Symlink { link, .. } => vec![link.clone()],
            Op::Rename { from, to, .. } => vec![from.clone(), to.clone()],
            Op::Trash { path, .. } => vec![path.clone()],
            Op::EditFile { path, .. } => vec![path.clone()],
            Op::WriteLock { path, .. } => vec![path.clone()],
            Op::WriteManifest { path, .. } => vec![path.clone()],
            Op::WriteExecutable { path, .. } => vec![path.clone()],
            Op::GitConfigSwap { file, .. } => vec![file.clone()],
        }
    }

    pub(super) fn run(&self, env: &Env) -> Result<()> {
        match self {
            Op::WriteFile { path, bytes, pre } => {
                pre.check(path)?;
                if let Some(parent) = path.parent() {
                    fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
                }
                fs::write(path, bytes).map_err(|e| CoreError::io(path, e))
            }
            Op::WriteTree { root, files, pre } => write_tree(root, files, pre),
            Op::Symlink { link, target, pre } => {
                pre.check(link)?;
                if let Some(parent) = link.parent() {
                    fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
                }
                if link.is_symlink() {
                    fs::remove_file(link).map_err(|e| CoreError::io(link, e))?;
                }
                journal::make_symlink(target, link)
            }
            Op::Rename { from, to, to_pre } => {
                to_pre.check(to)?;
                fs::rename(from, to).map_err(|e| CoreError::io(from, e))
            }
            Op::Trash { path, pre } => {
                pre.check(path)?;
                let trash = env.trash_dir();
                fs::create_dir_all(&trash).map_err(|e| CoreError::io(&trash, e))?;
                let base = path
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| "item".to_owned());
                let dest = unique_in(&trash, &base);
                if fs::rename(path, &dest).is_err() {
                    // Cross-device: copy then remove.
                    if path.is_dir() {
                        journal::copy_tree(path, &dest)?;
                    } else {
                        fs::copy(path, &dest).map_err(|e| CoreError::io(path, e))?;
                    }
                    journal::remove_any(path)?;
                }
                Ok(())
            }
            Op::EditFile { path, edits, pre } => {
                pre.check(path)?;
                let current = crate::fs::read_if_exists(path)?.unwrap_or_default();
                let mut updated = current.clone();
                for edit in edits {
                    updated = edit
                        .apply(&updated)
                        .map_err(|message| CoreError::ConfigEdit {
                            path: path.clone(),
                            message,
                        })?;
                }
                if updated != current {
                    if let Some(parent) = path.parent() {
                        fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
                    }
                    fs::write(path, updated).map_err(|e| CoreError::io(path, e))?;
                }
                Ok(())
            }
            Op::WriteLock { path, lock, pre } => {
                pre.check(path)?;
                crate::lock::save(path, lock)
            }
            Op::WriteManifest {
                path,
                manifest,
                pre,
            } => {
                pre.check(path)?;
                crate::manifest::save(path, manifest)
            }
            Op::WriteExecutable { path, bytes, pre } => {
                pre.check(path)?;
                if let Some(parent) = path.parent() {
                    fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
                }
                fs::write(path, bytes).map_err(|e| CoreError::io(path, e))?;
                executable_bit(path)
            }
            Op::GitConfigSwap {
                file,
                key,
                expected,
                value,
            } => git_config_swap(file, key, expected.as_deref(), value.as_deref()),
        }
    }
}

fn write_tree(root: &Path, files: &[(PathBuf, Vec<u8>)], pre: &Pre) -> Result<()> {
    pre.check(root)?;
    journal::remove_any(root)?;
    for (rel, bytes) in files {
        let dest = root.join(rel);
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
        }
        fs::write(&dest, bytes).map_err(|e| CoreError::io(&dest, e))?;
        // A tree carries bytes, not modes; a script that opens with a
        // shebang was written to be run, and a skill's helper that lands
        // 644 fails its own hook the first time something calls it.
        if bytes.starts_with(b"#!") {
            executable_bit(&dest)?;
        }
    }
    Ok(())
}

#[cfg(unix)]
fn executable_bit(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).map_err(|e| CoreError::io(path, e))
}

#[cfg(not(unix))]
fn executable_bit(_path: &Path) -> Result<()> {
    Ok(())
}

/// The swap runs through git itself against the named file, so quoting and
/// includes behave exactly as git will read them back. The precondition is
/// revalidated here, immediately before the write (invariant 7).
fn git_config_swap(
    file: &Path,
    key: &str,
    expected: Option<&str>,
    value: Option<&str>,
) -> Result<()> {
    let current = read_git_config(file, key)?;
    if current.as_deref() != expected {
        return Err(CoreError::PlanStale {
            path: file.to_path_buf(),
        });
    }
    if current.as_deref() == value {
        return Ok(());
    }
    let file_text = file.display().to_string();
    let args: Vec<&str> = match value {
        Some(value) => vec!["config", "--file", &file_text, key, value],
        None => vec!["config", "--file", &file_text, "--unset", key],
    };
    let output = crate::process::Hardened::git(&args, file.parent()).run()?;
    if !output.status.success() {
        return Err(CoreError::GitFailed {
            command: format!("git config {key}"),
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        });
    }
    Ok(())
}

/// One key's value in one config file, read the way git reads it.
pub fn read_git_config(file: &Path, key: &str) -> Result<Option<String>> {
    if !file.exists() {
        return Ok(None);
    }
    let file_text = file.display().to_string();
    let output = crate::process::Hardened::git(
        &["config", "--file", &file_text, "--get", key],
        file.parent(),
    )
    .run()?;
    match output.status.code() {
        Some(0) => Ok(Some(
            String::from_utf8_lossy(&output.stdout)
                .trim_end_matches('\n')
                .to_owned(),
        )),
        Some(1) => Ok(None),
        _ => Err(CoreError::GitFailed {
            command: format!("git config --get {key}"),
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        }),
    }
}

fn unique_in(dir: &Path, base: &str) -> PathBuf {
    let stamp = crate::clock::timestamp().replace(':', "-");
    let mut candidate = dir.join(format!("{stamp}-{base}"));
    let mut counter = 1;
    while candidate.exists() {
        candidate = dir.join(format!("{stamp}-{counter}-{base}"));
        counter += 1;
    }
    candidate
}

#[derive(Debug, Clone, PartialEq)]
pub struct PlannedOp {
    pub description: String,
    pub op: Op,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Plan {
    pub scope: Scope,
    pub ops: Vec<PlannedOp>,
}

impl Plan {
    pub fn is_empty(&self) -> bool {
        self.ops.is_empty()
    }
}
