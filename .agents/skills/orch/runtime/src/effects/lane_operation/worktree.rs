//! The lane's local worktree as a close reads, releases or keeps it: the
//! reads through git, the judgement of what a removal would lose, and the
//! worktree package's `remove`, the one owner of what a removal must
//! preserve.

use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::host;

/// How long one git read or one worktree package call may run.
const CLI_TIMEOUT: Duration = Duration::from_secs(60);

/// Why the close kept the lane's worktree instead of removing it: each a
/// read of the worktree itself through the handle's runner,
/// recorded as the lane's `kept` reason.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::effects) enum KeptReason {
    /// The worktree holds a submodule by the reads of git's own unforced
    /// removal, its module store or a populated gitlink of its index: the
    /// worktree is never judged, as that removal refuses it and the reads
    /// are data no setting changes.
    Submodules,
    /// `HEAD` carries commits no other local or remote ref reaches:
    /// removal would lose them.
    Unmerged,
    /// The pinned status read of `judge_worktree` (`host.rs`) names
    /// modified or untracked files, a claim worktree's by-design deletions
    /// aside.
    Dirty,
    /// The path holds no `.git` entry: it is no git worktree this close can
    /// release.
    NotAWorktree,
    /// The path's `.git` is a directory: the repository's main worktree,
    /// which the worktree package's `remove` never removes.
    MainWorktree,
    /// The worktree package's `remove` could not move a lane mailbox under
    /// the worktree to the main checkout's, so it removed nothing: the mail
    /// stands where the lane wrote it.
    MailUnmoved,
    /// The worktree package's `remove` refused a clean, merged worktree
    /// (git's refusal, a lock, an unreconciled rebase map, an unregistered
    /// target); `detail` is its exit status and its keyed stderr lines.
    Refused { detail: String },
}

impl KeptReason {
    /// The reason's word, what the lane record's `kept` carries.
    pub(super) fn word(&self) -> String {
        match self {
            KeptReason::Submodules => "submodules".to_owned(),
            KeptReason::Unmerged => "unmerged".to_owned(),
            KeptReason::Dirty => "dirty".to_owned(),
            KeptReason::NotAWorktree => "not-a-worktree".to_owned(),
            KeptReason::MainWorktree => "main-worktree".to_owned(),
            KeptReason::MailUnmoved => "mail-unmoved".to_owned(),
            KeptReason::Refused { detail } => format!("refused:{detail}"),
        }
    }
}

/// How the close's release of the lane's worktree went, by the release's
/// own reads: what it discharges the obligation by, and what its
/// observation reports.
pub(in crate::effects) enum WorktreeRelease {
    /// The path read gone before any removal.
    Gone,
    /// Removed by the worktree package; `kept_mail` is a lane mailbox it
    /// kept beside the main checkout's, where one could not join.
    Released {
        kept_mail: Option<String>,
    },
    Kept {
        reason: KeptReason,
    },
    /// The obligation stands: the path or a read of it failed.
    Held {
        cause: String,
    },
}

/// What the path a lane records as its worktree reads as: a linked
/// worktree, whose `.git` is a file naming its repository's directory
/// (git-worktree(1) § DETAILS); the main worktree, whose `.git` is a
/// directory; a directory with no `.git` entry; gone; or unreadable.
enum WorktreeRead {
    Gone,
    NotAWorktree,
    Main,
    Linked,
    Unreadable { cause: String },
}

fn read_worktree(path: &str) -> WorktreeRead {
    match std::fs::metadata(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return WorktreeRead::Gone,
        Err(e) => {
            return WorktreeRead::Unreadable {
                cause: e.kind().to_string(),
            };
        }
        Ok(meta) if !meta.is_dir() => return WorktreeRead::NotAWorktree,
        Ok(_) => {}
    }
    match std::fs::symlink_metadata(Path::new(path).join(".git")) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => WorktreeRead::NotAWorktree,
        Err(e) => WorktreeRead::Unreadable {
            cause: format!("git-entry:{}", e.kind()),
        },
        Ok(meta) if meta.is_dir() => WorktreeRead::Main,
        Ok(meta) if meta.is_file() => WorktreeRead::Linked,
        Ok(_) => WorktreeRead::NotAWorktree,
    }
}

/// Whether a linked worktree at `path` must be kept: it holds a submodule
/// (`holds_submodule`), its tree is dirty (the status read below lists a
/// line that is dirt), or its `HEAD` carries a commit no other local or
/// remote ref reaches (`git rev-list` with every ref but its own branch
/// negated), which removal would lose. `Err` is a read that failed.
///
/// A worktree holding a submodule is kept `submodules` and never judged:
/// git's own unforced `worktree remove` refuses it
/// (git-worktree(1)), while the package's removal is forced and a
/// submodule's tree and commits are read under settings the superproject's
/// command line does not reach. The keep reads exactly what that refusal
/// reads, the worktree's module store and the populated gitlinks of its
/// index, data no activation, ignore or status setting changes, where `git
/// submodule status` lists a populated submodule as uninitialized under a
/// documented setting (gitsubmodules(7) § Active submodules) and fails on
/// a gitlink with no `.gitmodules` mapping. A never-initialized gitlink
/// with no store has nothing to lose, and its worktree continues to the
/// status read.
///
/// A listing used as evidence names its completeness flags. The status
/// read is `git status --porcelain --untracked-files=all
/// --ignore-submodules=none`: `--untracked-files=all` overrides
/// `status.showUntrackedFiles` (git-status(1), git-config(1));
/// `--ignore-submodules=none` overrides `submodule.<name>.ignore` and
/// `diff.ignoreSubmodules` (gitmodules(5), git-status(1)), whose `all`
/// hides a gitlink path a person replaced with a file (` T`), the one
/// case left to it once a populated submodule is kept above. The listing
/// then proves the superproject's tracked and untracked files. Ignored
/// files are not work and are not listed; a lane mailbox under an ignored
/// `tmp/` is the worktree package's to move at the removal.
///
/// A worktree the package made with `create --no-checkout` is a claim: its
/// index read from `HEAD`, no file written, marked
/// `kendex-worktree.checkoutMode claim` in its own config (the package's
/// `setup_app_worktree`), so every tracked file lists ` D`, the
/// worktree-side deletion the claim makes by design. In a claim a ` D`
/// line is not dirt and every other line (an untracked file, an index
/// change, a modification) still is; in any other mode, or none, every
/// line is dirt. The mark is read with `--default ""`, so an absent key is
/// no mode and a config that cannot be read is a failed read.
fn judge_worktree(path: &str) -> std::result::Result<Option<KeptReason>, String> {
    if holds_submodule(path)? {
        return Ok(Some(KeptReason::Submodules));
    }
    let status = git_lines(
        path,
        "status",
        &[
            "status",
            "--porcelain",
            "--untracked-files=all",
            "--ignore-submodules=none",
        ],
    )?;
    if !status.is_empty() {
        let claim = git_lines(
            path,
            "checkout-mode",
            &[
                "config",
                "--get",
                "--default",
                "",
                "kendex-worktree.checkoutMode",
            ],
        )?
        .first()
        .is_some_and(|mode| mode == "claim");
        if !claim || status.iter().any(|line| !line.starts_with(" D ")) {
            return Ok(Some(KeptReason::Dirty));
        }
    }
    let branch = git_lines(path, "branch", &["branch", "--show-current"])?;
    let mut args = vec!["rev-list", "-n", "1", "HEAD", "--not"];
    let own_branch;
    let own_remote;
    // `--exclude` takes the ref's name under the set the next option names,
    // without its `refs/heads/` or `refs/remotes/` prefix (git-rev-list(1)).
    if let Some(branch) = branch.first() {
        own_branch = format!("--exclude={branch}");
        own_remote = format!("--exclude=*/{branch}");
        args.extend([
            own_branch.as_str(),
            "--branches",
            own_remote.as_str(),
            "--remotes",
        ]);
    } else {
        args.extend(["--branches", "--remotes"]);
    }
    let unreached = git_lines(path, "rev-list", &args)?;
    Ok((!unreached.is_empty()).then_some(KeptReason::Unmerged))
}

/// The main checkout of the repository the linked worktree at `path`
/// belongs to: the parent of its common git directory (`git rev-parse
/// --path-format=absolute --git-common-dir`, git-rev-parse(1)), as the
/// worktree package resolves its own `PROJECT_ROOT`. The package takes its
/// repository from the directory it runs in, so the removal runs there,
/// never inside the tree it deletes.
fn main_worktree(path: &str) -> std::result::Result<String, String> {
    let common = git_path(
        path,
        "common-dir",
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )?;
    common
        .parent()
        .map(|main| main.display().to_string())
        .ok_or_else(|| format!("common-dir:no-parent:{}", common.display()))
}

/// Run the worktree package's `remove` on `path` through the one runner,
/// which bounds and counts it under the `worktree` tag, with `main` as the
/// child's working directory: the package takes its repository from the
/// directory it runs in, so the removal runs in the main worktree, never
/// inside the tree it deletes. The package inherits the runtime's
/// environment. `Err` is a run with no reply, held so the next close or
/// reconcile asks again: a package that never started (a `main` that cannot
/// be entered included) removed nothing, `removal-not-started`; one that
/// outran the bound may have removed it, `removal-unanswered`.
fn package_remove(cli: &Path, main: &str, path: &str) -> std::result::Result<RemoveReply, String> {
    let output = host::run_tagged_in(
        "worktree",
        "worktree",
        cli,
        "remove",
        &["remove", path],
        host::Place {
            cwd: Some(Path::new(main)),
            env: &[],
        },
        CLI_TIMEOUT,
    )
    .map_err(|e| {
        if let agent_runtime::Error::NotStarted { .. } = e {
            format!("removal-not-started:{e}")
        } else {
            format!("removal-unanswered:{e}")
        }
    })?;
    let stdout = host::stdout_text(&output);
    let stderr = host::stderr_text(&output);
    Ok(RemoveReply {
        status: output.status.code().unwrap_or(-1),
        success: output.status.success(),
        removed: keyed_lines(&stdout).any(|(key, _)| key == "removed"),
        keyed: keyed_lines(&stderr)
            .map(|(key, value)| (key.to_owned(), value.to_owned()))
            .collect(),
        first_stderr: stderr.lines().next().unwrap_or_default().trim().to_owned(),
    })
}

/// The worktree package's keyed lines in `text`, `worktree-<key>: <value>`
/// (`worktree --help`: the stable message records), as (key, value).
fn keyed_lines(text: &str) -> impl Iterator<Item = (&str, &str)> {
    text.lines()
        .filter_map(|line| line.strip_prefix("worktree-")?.split_once(": "))
}

/// What the worktree package's `remove` answered: its exit, whether it
/// reported the worktree removed (`worktree-removed` on stdout, the
/// `remove` arm's last line), and
/// its keyed stderr lines, among which `lane-mail-move-failed` says a lane
/// mailbox could not be moved and nothing was removed
/// (`git_remove_worktree`), and `lane-mail-kept` names a
/// mailbox kept beside the main checkout's after the removal
/// (`lane_mail_settle`); `worktree remove --help` § Lane
/// mailboxes states both.
struct RemoveReply {
    status: i32,
    success: bool,
    removed: bool,
    keyed: Vec<(String, String)>,
    first_stderr: String,
}

impl RemoveReply {
    /// The worktree's end from this reply and the path read `after` it. A
    /// reply that is no success and carries no `worktree-` keyed line is no
    /// answer from the package (an executable at the package's path that is
    /// not the package, or a package ended by a signal; one that cannot
    /// start, or a main worktree that cannot be entered, never reaches a
    /// reply: `package_remove` returns the runner's `Err`) and is held
    /// `removal-unanswered` whatever the path reads: every refusal the
    /// package's `remove` arm issues writes a keyed line. Else the path
    /// gone after a removal the package reported, or a success, is
    /// `released`, carrying the mailbox it kept where it named one; a path
    /// gone after a refusal that reported no removal is held, the package's
    /// recovery steps apply (`worktree --help` § Recovering a failed
    /// removal); a path standing after a success is held `worktree-present`;
    /// one standing after a refusal is kept `mail-unmoved` where the package
    /// moved no mailbox, else `refused` with the package's lines.
    fn judge(&self, after: WorktreeRead) -> WorktreeRelease {
        if !self.success && !self.removed && self.keyed.is_empty() {
            return WorktreeRelease::Held {
                cause: format!("removal-unanswered:{}", self.detail()),
            };
        }
        match after {
            WorktreeRead::Gone if self.removed || self.success => WorktreeRelease::Released {
                kept_mail: self.value("lane-mail-kept").map(str::to_owned),
            },
            WorktreeRead::Gone => WorktreeRelease::Held {
                cause: format!("removal-unanswered:{}", self.detail()),
            },
            WorktreeRead::Unreadable { cause } => WorktreeRelease::Held { cause },
            WorktreeRead::NotAWorktree | WorktreeRead::Main | WorktreeRead::Linked => {
                if self.success {
                    WorktreeRelease::Held {
                        cause: "worktree-present".to_owned(),
                    }
                } else if self.value("lane-mail-move-failed").is_some() {
                    WorktreeRelease::Kept {
                        reason: KeptReason::MailUnmoved,
                    }
                } else {
                    WorktreeRelease::Kept {
                        reason: KeptReason::Refused {
                            detail: self.detail(),
                        },
                    }
                }
            }
        }
    }

    /// The value of the keyed stderr line `key`, where the package wrote one.
    fn value(&self, key: &str) -> Option<&str> {
        self.keyed
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    }

    /// The reply as a refusal's record: the exit status and the keyed
    /// stderr lines, or the first stderr line where the package wrote none.
    fn detail(&self) -> String {
        let lines = if self.keyed.is_empty() {
            self.first_stderr.clone()
        } else {
            self.keyed
                .iter()
                .map(|(k, v)| format!("worktree-{k}: {v}"))
                .collect::<Vec<_>>()
                .join("; ")
        };
        format!("status={} {lines}", self.status)
    }
}

/// Whether the worktree at `path` holds a submodule, by the two reads of
/// git's own unforced `worktree remove` (`worktree.c`
/// `validate_no_submodules`): the worktree's module store, `git rev-parse
/// --git-path modules`, is a directory, or a gitlink of its index (`git
/// ls-files --stage -z`, an entry of mode `160000`, NUL-separated so a path
/// with special characters is not quoted) has a `.git` under its path.
/// `Err` is a read that failed.
fn holds_submodule(path: &str) -> std::result::Result<bool, String> {
    use std::os::unix::ffi::OsStrExt;
    let modules = git_path(
        path,
        "modules-path",
        &[
            "rev-parse",
            "--path-format=absolute",
            "--git-path",
            "modules",
        ],
    )?;
    match std::fs::metadata(&modules) {
        Ok(meta) if meta.is_dir() => return Ok(true),
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => {
            return Err(format!("modules-path:{}:{}", modules.display(), e.kind()));
        }
    }
    let index = git_output(path, "ls-files", &["ls-files", "--stage", "-z"])?;
    for entry in index.stdout.split(|byte| *byte == 0) {
        // `<mode> <object> <stage>\t<path>` (git-ls-files(1)).
        let Some(rest) = entry.strip_prefix(b"160000 ") else {
            continue;
        };
        let Some(tab) = rest.iter().position(|byte| *byte == b'\t') else {
            return Err("ls-files:a gitlink entry names no path".to_owned());
        };
        let git_entry = Path::new(path)
            .join(std::ffi::OsStr::from_bytes(&rest[tab + 1..]))
            .join(".git");
        // A file standing at the gitlink's path (a person's replacement of
        // a vendored submodule) is no populated submodule, as git reads it;
        // the status read lists it as dirt.
        match std::fs::symlink_metadata(&git_entry) {
            Ok(_) => return Ok(true),
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory
                ) => {}
            Err(e) => {
                return Err(format!("ls-files:{}:{}", git_entry.display(), e.kind()));
            }
        }
    }
    Ok(false)
}

/// The output of a git read that must succeed: a run that could not start
/// or exited non-zero is `Err`, naming the operation, the exit and the
/// first stderr line.
fn git_output(
    path: &str,
    operation: &'static str,
    args: &[&str],
) -> std::result::Result<std::process::Output, String> {
    let mut argv = vec!["-C", path];
    argv.extend_from_slice(args);
    let output = host::run_tagged(
        "worktree",
        "git",
        Path::new("git"),
        operation,
        &argv,
        CLI_TIMEOUT,
    )
    .map_err(|e| e.to_string())?;
    if !output.status.success() {
        let line = host::stderr_text(&output)
            .lines()
            .next()
            .unwrap_or_default()
            .trim()
            .to_owned();
        return Err(format!(
            "{operation}:status={} {line}",
            output.status.code().unwrap_or(-1)
        ));
    }
    Ok(output)
}

/// The one pathname a git read that must succeed prints (`rev-parse
/// --git-path`, `--git-common-dir`): its stdout less the one newline git
/// ends it with, as bytes, since a pathname is one value whatever
/// characters it holds; an empty answer is a failed read.
fn git_path(
    path: &str,
    operation: &'static str,
    args: &[&str],
) -> std::result::Result<PathBuf, String> {
    use std::os::unix::ffi::OsStrExt;
    let output = git_output(path, operation, args)?;
    let bytes = output.stdout.strip_suffix(b"\n").unwrap_or(&output.stdout);
    if bytes.is_empty() {
        return Err(format!("{operation}:no path printed"));
    }
    Ok(PathBuf::from(std::ffi::OsStr::from_bytes(bytes)))
}

/// The non-empty stdout lines of a git read that must succeed.
fn git_lines(
    path: &str,
    operation: &'static str,
    args: &[&str],
) -> std::result::Result<Vec<String>, String> {
    let output = git_output(path, operation, args)?;
    Ok(host::stdout_text(&output)
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(str::to_owned)
        .collect())
}

/// What a release finds before it acts: an answer by its reads alone, or a
/// clean, merged linked worktree its main worktree's package removes.
pub(super) enum Plan {
    Answered(WorktreeRelease),
    Remove { main: String },
}

/// The reads of the worktree at `path` before any removal: the path gone,
/// unreadable, no worktree or the main worktree answers at once; a linked
/// worktree that holds a submodule, a dirty tree or unmerged commits is
/// kept with its reason; a clean, merged one is the package's to remove.
pub(super) fn plan(path: &str) -> Plan {
    Plan::Answered(match read_worktree(path) {
        WorktreeRead::Gone => WorktreeRelease::Gone,
        WorktreeRead::Unreadable { cause } => WorktreeRelease::Held { cause },
        WorktreeRead::NotAWorktree => WorktreeRelease::Kept {
            reason: KeptReason::NotAWorktree,
        },
        WorktreeRead::Main => WorktreeRelease::Kept {
            reason: KeptReason::MainWorktree,
        },
        WorktreeRead::Linked => match judge_worktree(path).and_then(|kept| match kept {
            Some(reason) => Ok(Err(reason)),
            None => main_worktree(path).map(Ok),
        }) {
            Err(cause) => WorktreeRelease::Held { cause },
            Ok(Err(reason)) => WorktreeRelease::Kept { reason },
            Ok(Ok(main)) => return Plan::Remove { main },
        },
    })
}

/// The worktree package's removal of `path` from `main`, judged by its
/// reply and a read of the path after it.
pub(super) fn remove(cli: &Path, main: &str, path: &str) -> WorktreeRelease {
    match package_remove(cli, main, path) {
        Err(cause) => WorktreeRelease::Held { cause },
        Ok(reply) => reply.judge(read_worktree(path)),
    }
}

/// Whether `worktree merged ITEM`, asked from the project checkout
/// `project`, shows the item's branch merged: `Ok(true)` on 0, `Ok(false)`
/// on 1, `Err` with the status on any other answer.
pub(super) fn merged(cli: &Path, project: &Path, item: &str) -> std::result::Result<bool, String> {
    let out = host::run_tagged_in(
        "close",
        "worktree",
        cli,
        "merged",
        &["merged", item],
        host::Place {
            cwd: Some(project),
            env: &[],
        },
        CLI_TIMEOUT,
    )
    .map_err(|e| format!("cause={e}"))?;
    match out.status.code() {
        Some(0) => Ok(true),
        Some(1) => Ok(false),
        Some(code) => Err(format!("status={code}")),
        None => Err(format!("status={}", out.status)),
    }
}
