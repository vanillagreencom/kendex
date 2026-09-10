use std::fs;
use std::path::{Path, PathBuf};

pub use super::pre::Pre;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::lock::Lock;
use crate::manifest::Manifest;

#[derive(Clone, PartialEq)]
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
    /// A file holding credentials: created readable by its owner alone,
    /// and left at whatever mode it already carries.
    ///
    /// Apart from `WriteFile` for the mode and nothing else. `fs::write`
    /// creates at the process umask, which on a default account is
    /// world-readable, so the first save of a secret would publish it to
    /// every account on the machine. Creating through `OpenOptions` with
    /// an explicit mode settles that at creation, where there is no
    /// window between the file existing and being private — a chmod after
    /// the write leaves one. An existing file keeps its own mode, which
    /// is the person's choice about their own file.
    ///
    /// The journal's pre-image is `fs::copy`. On Unix it carries the mode
    /// across, so a recovery copy of a private file is private too. On
    /// Windows no copy carries an access-control list: the pre-image
    /// takes the journal folder's, under the profile's application data,
    /// rather than the file's own.
    WritePrivateFile {
        path: PathBuf,
        bytes: Vec<u8>,
        pre: Pre,
        /// The work tree the file must be out of git's reach inside, or
        /// `None` where the project is in no repository and there is
        /// nothing to be carried by.
        ///
        /// Planning asks git whether the path is ignored and plans the
        /// `.gitignore` line it owes, but neither answer survives to the
        /// write: the line lands in the project's root `.gitignore`, and
        /// whether git then honours it is a question only git can settle
        /// — a nearer `.gitignore` may negate the rule, and a
        /// `.gitignore` that is a symlink is one git does not read at all
        /// while a write follows it. So the answer is taken again here,
        /// after the ignore op has run and before a credential exists on
        /// disk, rather than enumerating the layouts that would defeat
        /// it.
        ignored_under: Option<PathBuf>,
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

/// Derived for every op but one.
///
/// `WritePrivateFile` carries a credential in `bytes`, and a derived
/// `Debug` prints it. That is not a hypothetical: a `Plan` reaches an
/// assertion message, a panic and anything that formats one, so a single
/// `{plan:?}` anywhere would put a person's API key in a log. The bytes
/// have to stay — they are what the write writes — so what changes is
/// that they cannot be rendered. Their length is kept, which is what a
/// reader debugging a write actually needs.
///
/// Written out rather than `#[derive]`d plus a redacting newtype so the
/// redaction lives beside the variant it protects; a newtype could be
/// unwrapped anywhere and the next reader would not know why it existed.
impl std::fmt::Debug for Op {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Op::WritePrivateFile {
                path,
                bytes,
                pre,
                ignored_under,
            } => f
                .debug_struct("WritePrivateFile")
                .field("path", path)
                .field("bytes", &format_args!("<{} redacted bytes>", bytes.len()))
                .field("pre", pre)
                .field("ignored_under", ignored_under)
                .finish(),
            Op::WriteFile { path, bytes, pre } => f
                .debug_struct("WriteFile")
                .field("path", path)
                .field("bytes", bytes)
                .field("pre", pre)
                .finish(),
            Op::WriteTree { root, files, pre } => f
                .debug_struct("WriteTree")
                .field("root", root)
                .field("files", files)
                .field("pre", pre)
                .finish(),
            Op::Symlink { link, target, pre } => f
                .debug_struct("Symlink")
                .field("link", link)
                .field("target", target)
                .field("pre", pre)
                .finish(),
            Op::Rename {
                from,
                to,
                from_pre,
                to_pre,
            } => f
                .debug_struct("Rename")
                .field("from", from)
                .field("to", to)
                .field("from_pre", from_pre)
                .field("to_pre", to_pre)
                .finish(),
            Op::Trash {
                path,
                pre,
                absent_is_done,
            } => f
                .debug_struct("Trash")
                .field("path", path)
                .field("pre", pre)
                .field("absent_is_done", absent_is_done)
                .finish(),
            Op::EditFile { path, edits, pre } => f
                .debug_struct("EditFile")
                .field("path", path)
                .field("edits", edits)
                .field("pre", pre)
                .finish(),
            Op::WriteLock { path, lock, pre } => f
                .debug_struct("WriteLock")
                .field("path", path)
                .field("lock", lock)
                .field("pre", pre)
                .finish(),
            Op::WriteManifest {
                path,
                manifest,
                pre,
            } => f
                .debug_struct("WriteManifest")
                .field("path", path)
                .field("manifest", manifest)
                .field("pre", pre)
                .finish(),
            Op::WriteExecutable { path, bytes, pre } => f
                .debug_struct("WriteExecutable")
                .field("path", path)
                .field("bytes", bytes)
                .field("pre", pre)
                .finish(),
            Op::GitConfigSwap {
                file,
                key,
                expected,
                value,
            } => f
                .debug_struct("GitConfigSwap")
                .field("file", file)
                .field("key", key)
                .field("expected", expected)
                .field("value", value)
                .finish(),
        }
    }
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
            Op::WritePrivateFile { path, .. } => vec![path.clone()],
            Op::GitConfigSwap { file, .. } => vec![file.clone()],
        }
    }

    /// The same paths, borrowed so they can be replaced by where they
    /// land ([`super::landing`]). Exhaustive like [`Op::touched`], so an
    /// op joining this enum can no more skip the landing than the
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
            Op::WritePrivateFile { path, .. } => vec![path],
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
            Op::WritePrivateFile {
                path,
                bytes,
                pre,
                ignored_under,
            } => {
                pre.check(path)?;
                // Before `ensure_parent`, so a refusal here has mutated
                // nothing at all.
                if let Some(root) = ignored_under {
                    refuse_unless_ignored(root, path)?;
                }
                ensure_parent(path)?;
                crate::fs::write_private(path, bytes)
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

/// Refuse unless git, asked now, ignores the path a credential is about
/// to be written to.
///
/// `git check-ignore` is the only thing that knows the answer: it reads
/// every `.gitignore` on the way down, the repository's exclude file and
/// its core.excludesFile, and applies the precedence between them. Asking
/// it here rather than trusting the plan's own earlier read is the point
/// — the ignore line this plan owed has just been written, and this is
/// where whether it worked stops being a guess.
///
/// It fails closed twice over: an exit status that is neither "ignored"
/// nor "not ignored" is a check that could not be taken, and that refuses
/// too.
fn refuse_unless_ignored(root: &Path, path: &Path) -> Result<()> {
    let named = path.display().to_string();
    let output =
        crate::process::Hardened::git(&["check-ignore", "-q", "--", &named], Some(root)).run()?;
    // `-q` answers with its exit status alone: 0 ignored, 1 not, anything
    // else a failure to answer.
    match output.status.code() {
        Some(0) => Ok(()),
        Some(1) => Err(CoreError::GitFailed {
            command: format!("git check-ignore -- {named}"),
            stderr: format!(
                "git does not ignore {named}, so a credential written there would be committed; nothing was written"
            ),
        }),
        other => Err(CoreError::GitFailed {
            command: format!("git check-ignore -- {named}"),
            stderr: format!(
                "git could not say whether it ignores {named} (exited {other:?}): {}; nothing was written",
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        }),
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
    crate::fs::move_to_trash(env, path)
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
