use std::fs;
use std::path::{Path, PathBuf};

pub use super::pre::Pre;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::lock::Lock;
use crate::manifest::Manifest;

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
        /// Checked against `from`: the bytes the plan proved it may move.
        /// A writer outside the transaction landing on the source after
        /// the journal snapshot must abort the move — a completed rename
        /// puts its paths in the restore set, so a later refusal's
        /// rollback would delete the moved bytes and restore the old
        /// snapshot over the source.
        from_pre: Pre,
        /// Checked against `to`: rename(2) replaces its destination
        /// silently, so a file that appeared since planning must abort.
        to_pre: Pre,
    },
    /// Removal never deletes: the artifact moves to the trash.
    Trash {
        path: PathBuf,
        pre: Pre,
        /// Whether nothing at `path` is this op's end state. A removal
        /// asks for exactly that, so a copy already gone satisfies it.
        /// Every other Trash is half of a pair — the bytes it takes were
        /// captured into the same plan, or a write after it replaces
        /// them — and absence there means the bytes the plan read are not
        /// the bytes on disk, which nothing but the precondition catches.
        /// Set by the removal planner and nowhere else.
        absent_is_done: bool,
    },
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

    /// The same paths, borrowed so they can be replaced by where they
    /// land ([`super::landing`]). Exhaustive like [`Op::touched`], so an
    /// op added to this enum can no more skip the landing than the
    /// journal.
    pub(super) fn touched_mut(&mut self) -> Vec<&mut PathBuf> {
        match self {
            Op::WriteFile { path, .. } => vec![path],
            Op::WriteTree { root, .. } => vec![root],
            Op::Symlink { link, .. } => vec![link],
            Op::Rename { from, to, .. } => vec![from, to],
            Op::Trash { path, .. } => vec![path],
            Op::EditFile { path, .. } => vec![path],
            Op::WriteLock { path, .. } => vec![path],
            Op::WriteManifest { path, .. } => vec![path],
            Op::WriteExecutable { path, .. } => vec![path],
            Op::GitConfigSwap { file, .. } => vec![file],
        }
    }

    /// Contract for every arm: `PlanStale` may only be returned before the
    /// op has mutated anything, because the in-process rollback takes that
    /// error as proof the failing op ran nothing and leaves its paths out
    /// of the restore set (see `mutated_before_failure`).
    pub(super) fn run(&self, env: &Env) -> Result<()> {
        match self {
            Op::WriteFile { path, bytes, pre } => {
                pre.check(path)?;
                ensure_parent(path)?;
                fs::write(path, bytes).map_err(|e| CoreError::io(path, e))
            }
            Op::WriteTree { root, files, pre } => write_tree(root, files, pre),
            Op::Symlink { link, target, pre } => {
                pre.check(link)?;
                ensure_parent(link)?;
                if link.is_symlink() {
                    fs::remove_file(link).map_err(|e| CoreError::io(link, e))?;
                }
                crate::fs::make_symlink(target, link)
            }
            Op::Rename {
                from,
                to,
                from_pre,
                to_pre,
            } => {
                from_pre.check(from)?;
                to_pre.check(to)?;
                // The destination's parent may not exist yet — a move into
                // a tree this scope has not written to before. Created the
                // way every other writing op creates its parent, and after
                // both preconditions, so a stale plan never leaves a
                // directory behind.
                ensure_parent(to)?;
                fs::rename(from, to).map_err(|e| CoreError::io(from, e))
            }
            Op::Trash {
                path,
                pre,
                absent_is_done,
            } => trash(env, path, pre, *absent_is_done),
            Op::EditFile { path, edits, pre } => {
                pre.check(path)?;
                // Strictly, as `read_if_exists` reads: a lossy decode
                // would put U+FFFD where somebody's bytes were and write
                // the replacement back over them.
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
                // Nothing made for a write that does not happen: an edit
                // that changes nothing leaves the place as it found it.
                if updated == current {
                    return Ok(());
                }
                ensure_parent(path)?;
                fs::write(path, updated).map_err(|e| CoreError::io(path, e))
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
                ensure_parent(path)?;
                fs::write(path, bytes).map_err(|e| CoreError::io(path, e))?;
                crate::fs::make_executable(path)
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

/// The directory a write lands in, made if it is not there.
fn ensure_parent(path: &Path) -> Result<()> {
    match path.parent() {
        Some(parent) => fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e)),
        None => Ok(()),
    }
}

/// Move one artifact to the trash. Removal never deletes, so every op that
/// takes something off disk lands here.
fn trash(env: &Env, path: &Path, pre: &Pre, absent_is_done: bool) -> Result<()> {
    // A removal asks for one end state: nothing at this path. A copy that
    // is already gone is that end state, so it is satisfied rather than
    // failed — an installation whose harness copies are only partly
    // present would otherwise roll its whole removal back on the missing
    // one and stay half-present with no way forward. Nothing here is
    // nothing to protect either, so the precondition, which binds the op
    // to bytes it may take, has nothing to bind to. Every other Trash
    // falls through to that precondition and is refused exactly as it
    // always was.
    //
    // Absence proven by the stat, never inferred from its failure: an
    // unreadable path is one this op knows nothing about, and calling it
    // removed would take the item off the books while its files stay
    // installed and still load. Asked without following a link, so a link
    // whose target is gone is still here and still proven.
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            if absent_is_done {
                return Ok(());
            }
        }
        Err(error) => return Err(CoreError::io(path, error)),
        Ok(_) => {}
    }
    pre.check(path)?;
    let trash = env.trash_dir();
    fs::create_dir_all(&trash).map_err(|e| CoreError::io(&trash, e))?;
    let base = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "item".to_owned());
    crate::fs::move_any(path, &unique_in(&trash, &base))
}

fn write_tree(root: &Path, files: &[(PathBuf, Vec<u8>)], pre: &Pre) -> Result<()> {
    pre.check(root)?;
    crate::fs::remove_any(root)?;
    for (rel, bytes) in files {
        let dest = root.join(rel);
        ensure_parent(&dest)?;
        fs::write(&dest, bytes).map_err(|e| CoreError::io(&dest, e))?;
        crate::fs::executable_if_script(&dest, bytes)?;
    }
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
    // A link, not what it points at: a relative link lands in the trash
    // pointing nowhere, and `exists` on a broken link says the name is
    // free. The rename onto it then fails, and one apply's rollback takes
    // the whole removal with it.
    while candidate.exists() || candidate.is_symlink() {
        candidate = dir.join(format!("{stamp}-{counter}-{base}"));
        counter += 1;
    }
    candidate
}
