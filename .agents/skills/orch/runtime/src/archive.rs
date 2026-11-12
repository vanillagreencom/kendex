//! The archive before a removal. The retention duty's prune, an item's
//! close-out and the callers of the `archive` verbs each put every path
//! they are about to remove, and the records the prune drops, into one
//! private tarball under the archive root first, so nothing leaves as its
//! only copy. The root is `ORCH_ARCHIVE_ROOT`, else `archive/` under the
//! fleet directory; a configured root is refused where a removal would take
//! the archive with it: inside the state directory, a removal root, an
//! archived path or a linked worktree, which a merge removes. A configured
//! value that is not absolute refuses here, at the write, so a verb that
//! archives nothing still runs.

use agent_runtime::record::{self, Locking};
use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::host;
use serde_json::Value;

use crate::error::Result;
use agent_runtime::settings::value_refusal;

use crate::settings::ARCHIVE_ROOT_KEY;
use crate::state;
use crate::watch::Paths;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ArchiveRoot {
    /// `${FLEET_DIR:-$HOME/.fleet}/archive`, the operator's own folder:
    /// nothing a removal takes can hold it.
    Default(PathBuf),
    /// `ORCH_ARCHIVE_ROOT`: judged against every path a removal takes
    /// before the archive is written under it.
    Configured(PathBuf),
    /// A configured value that is not an absolute path, as given: `~` and
    /// a relative path would archive under whatever directory the writer
    /// runs in.
    Invalid(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Worktree {
    pub path: PathBuf,
    /// The branch checked out there, `None` for a detached head.
    pub branch: Option<String>,
}

const TAR_BOUND: Duration = Duration::from_secs(600);
const GIT_BOUND: Duration = Duration::from_secs(60);

fn io(operation: &'static str, path: &Path, e: std::io::Error) -> crate::Error {
    agent_runtime::Error::io(operation, path, e).into()
}

fn refused(key: &'static str, fields: &[(&str, &str)]) -> crate::Error {
    agent_runtime::Error::refused(key, fields).into()
}

pub(crate) fn name_of(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// The entries of `dir`, none where it does not stand.
pub(crate) fn read_dir(dir: &Path) -> Result<Vec<PathBuf>> {
    match std::fs::read_dir(dir) {
        Ok(entries) => entries
            .map(|e| e.map(|e| e.path()))
            .collect::<std::io::Result<Vec<_>>>()
            .map_err(|e| io("read-dir", dir, e)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(e) => Err(io("read-dir", dir, e)),
    }
}

/// `path` with its longest standing prefix resolved through its links and
/// the rest joined as given, so a path not yet created compares with one
/// that stands.
pub fn resolve(path: &Path) -> PathBuf {
    let mut rest = Vec::new();
    let mut current = path.to_path_buf();
    loop {
        if let Ok(resolved) = std::fs::canonicalize(&current) {
            return rest.iter().rev().fold(resolved, |out, name| out.join(name));
        }
        match (current.file_name(), current.parent()) {
            (Some(name), Some(parent)) => {
                rest.push(name.to_owned());
                current = parent.to_path_buf();
            }
            _ => return path.to_path_buf(),
        }
    }
}

/// The linked worktrees of `project`, the main checkout left out, in the
/// listing's order. A listing git cannot give is the failure named.
#[allow(
    clippy::disallowed_methods,
    reason = "the one read of the checkout's worktree list, which the archive root check and the item-state judgement both take, through the one runner"
)]
pub fn linked_worktrees(project: &Path) -> Result<Vec<Worktree>> {
    let cwd = project.display().to_string();
    let out = host::run_tagged(
        "archive",
        "git",
        Path::new("git"),
        "worktree-list",
        &["-C", &cwd, "worktree", "list", "--porcelain", "-z"],
        GIT_BOUND,
    )?;
    if !out.status.success() {
        return Err(agent_runtime::Error::External {
            program: "git",
            operation: "worktree-list",
            cause: host::stderr_text(&out),
        }
        .into());
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let mut trees = Vec::new();
    for record in text.split("\0\0").filter(|r| !r.is_empty()) {
        let mut path = None;
        let mut branch = None;
        for field in record.split('\0') {
            if let Some(p) = field.strip_prefix("worktree ") {
                path = Some(PathBuf::from(p));
            } else if let Some(b) = field.strip_prefix("branch refs/heads/") {
                branch = Some(b.to_owned());
            }
        }
        if let Some(path) = path {
            trees.push(Worktree { path, branch });
        }
    }
    Ok(trees.into_iter().skip(1).collect())
}

/// Where under the root `project`'s archives are filed.
fn oversee(project: &Path) -> PathBuf {
    PathBuf::from(name_of(project)).join("oversee")
}

/// The archive root for a destination `suffix` under it. A configured root
/// is judged against `removed` first, the paths the caller's removal takes,
/// and `project`'s linked worktrees.
fn judged(root: &ArchiveRoot, suffix: &Path, project: &Path, removed: &[&Path]) -> Result<PathBuf> {
    match root {
        ArchiveRoot::Default(path) => Ok(path.clone()),
        ArchiveRoot::Configured(configured) => {
            check_root(configured, &configured.join(suffix), project, removed)?;
            Ok(configured.clone())
        }
        ArchiveRoot::Invalid(value) => {
            Err(crate::Error::from(value_refusal(ARCHIVE_ROOT_KEY, value)))
        }
    }
}

/// A configured root a removal would take along is refused before anything
/// is written under it.
fn check_root(root: &Path, dir: &Path, project: &Path, removed: &[&Path]) -> Result<()> {
    let root_resolved = resolve(root);
    let dir_resolved = resolve(dir);
    let mut excluded: Vec<PathBuf> = removed.iter().map(|p| resolve(p)).collect();
    excluded.extend(
        linked_worktrees(project)?
            .into_iter()
            .map(|tree| resolve(&tree.path)),
    );
    for taken in excluded {
        if [&root_resolved, &dir_resolved]
            .iter()
            .any(|kept| kept.starts_with(&taken))
        {
            return Err(refused(
                "archive-root-overlap",
                &[
                    ("path", &root.display().to_string()),
                    ("removed", &taken.display().to_string()),
                ],
            ));
        }
    }
    Ok(())
}

fn suffix() -> String {
    const ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";
    let mut n = RandomState::new().build_hasher().finish();
    (0..6)
        .map(|_| {
            let c = ALPHABET[(n % ALPHABET.len() as u64) as usize] as char;
            n /= ALPHABET.len() as u64;
            c
        })
        .collect()
}

#[allow(
    clippy::disallowed_methods,
    reason = "the archive stage's exclusive creation under the archive directory, its mode set as the private scratch it is"
)]
fn stage_dir(dir: &Path, stem: &str) -> Result<PathBuf> {
    loop {
        let stage = dir.join(format!("{stem}-{}", suffix()));
        match std::fs::create_dir(&stage) {
            Ok(()) => {
                std::fs::set_permissions(&stage, std::fs::Permissions::from_mode(0o700))
                    .map_err(|e| io("chmod", &stage, e))?;
                return Ok(stage);
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(io("mkdir", &stage, e)),
        }
    }
}

fn relative(path: &Path) -> String {
    path.strip_prefix("/").unwrap_or(path).display().to_string()
}

#[allow(
    clippy::disallowed_methods,
    reason = "the archive's one build: the listing and the records written into the stage, the tarball through the one runner, its mode set as the private file it is"
)]
fn build(stage: &Path, tarball: &Path, records: Option<&Value>, paths: &[PathBuf]) -> Result<()> {
    let mut listing = String::new();
    if let Some(records) = records {
        let file = stage.join("records.json");
        let mut text = serde_json::to_string(records)?;
        text.push('\n');
        std::fs::write(&file, text).map_err(|e| io("write", &file, e))?;
        listing.push_str(&relative(&file));
        listing.push('\n');
    }
    for path in paths {
        listing.push_str(&relative(path));
        listing.push('\n');
    }
    let list = stage.join("paths");
    std::fs::write(&list, listing).map_err(|e| io("write", &list, e))?;
    let tarball_text = tarball.display().to_string();
    let list_text = list.display().to_string();
    let out = host::run_tagged(
        "archive",
        "tar",
        Path::new("tar"),
        "archive",
        &["-czf", &tarball_text, "-C", "/", "-T", &list_text],
        TAR_BOUND,
    )?;
    if !out.status.success() {
        return Err(agent_runtime::Error::External {
            program: "tar",
            operation: "archive",
            cause: host::stderr_text(&out),
        }
        .into());
    }
    std::fs::set_permissions(tarball, std::fs::Permissions::from_mode(0o600))
        .map_err(|e| io("chmod", tarball, e))
}

/// Write one archive under `root` for `project`: `<root>/<project
/// name>/oversee/<stem>-<suffix>.tgz`, holding `records` as `records.json`
/// where given and every path in `paths`, each as it stands on disk. A
/// build that fails leaves no partial tarball. `removal_root` is the
/// directory the removal acts in, which a configured root may not share.
pub fn write(
    root: &ArchiveRoot,
    project: &Path,
    removal_root: &Path,
    stem: &str,
    records: Option<&Value>,
    paths: &[PathBuf],
) -> Result<PathBuf> {
    archived(root, project, &[removal_root], stem, records, paths).map(|(_, tarball)| tarball)
}

/// [`write`] for a removal out of each of `removal_roots`: the archive's
/// directory and the tarball.
#[allow(
    clippy::disallowed_methods,
    reason = "the archive directory made under the root and the stage removed once the tarball stands or the build failed"
)]
fn archived(
    root: &ArchiveRoot,
    project: &Path,
    removal_roots: &[&Path],
    stem: &str,
    records: Option<&Value>,
    paths: &[PathBuf],
) -> Result<(PathBuf, PathBuf)> {
    let suffix = oversee(project);
    let mut removed = removal_roots.to_vec();
    removed.extend(paths.iter().map(PathBuf::as_path));
    let dir = judged(root, &suffix, project, &removed)?.join(suffix);
    std::fs::create_dir_all(&dir).map_err(|e| io("mkdir", &dir, e))?;
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))
        .map_err(|e| io("chmod", &dir, e))?;
    let stage = stage_dir(&dir, stem)?;
    let tarball = PathBuf::from(format!("{}.tgz", stage.display()));
    let built = build(&stage, &tarball, records, paths);
    let _ = std::fs::remove_dir_all(&stage);
    if let Err(e) = built {
        let _ = std::fs::remove_file(&tarball);
        return Err(e);
    }
    Ok((dir, tarball))
}

/// The archive verbs, for the callers that remove files outside any state
/// verb: the mailbox's compaction archives the rows it drops through
/// `write`, and the SSH provider's close-out files a hosted clone's records
/// under `root`. Each judges a configured root against the state directory
/// too, which the retention pass removes from.
#[derive(Debug, clap::Subcommand)]
pub enum Verb {
    /// Archive PATHS before the caller removes them from its removal root,
    /// filed under the project's name; the reply is `{archive, dir}`.
    Write {
        /// The checkout the archive is filed for, by its directory's name;
        /// a configured root may not sit in one of its linked worktrees.
        #[arg(long)]
        project: PathBuf,
        /// The directory the caller's removal acts in.
        #[arg(long)]
        removal_root: PathBuf,
        /// The tarball's name before its unique suffix.
        #[arg(long)]
        stem: String,
        /// The paths archived, each as it stands; a relative path is the
        /// caller's working directory's.
        #[arg(required = true)]
        paths: Vec<PathBuf>,
    },
    /// The archive root a caller files under SUFFIX; the reply is `{root}`.
    Root {
        #[arg(long)]
        suffix: PathBuf,
    },
}

/// Run one archive verb under `settings`: its archive root, its state
/// directory and the project the caller runs in.
pub fn verb(verb: Verb, settings: &crate::settings::Settings) -> Result<Value> {
    let state_dir = settings.state_dir.as_path();
    match verb {
        Verb::Write {
            project,
            removal_root,
            stem,
            paths,
        } => {
            let cwd = std::env::current_dir().map_err(|e| io("cwd", Path::new("."), e))?;
            let paths: Vec<PathBuf> = paths.iter().map(|path| cwd.join(path)).collect();
            let (dir, archive) = archived(
                &settings.archive_root,
                &project,
                &[&removal_root, state_dir],
                &stem,
                None,
                &paths,
            )?;
            Ok(serde_json::json!({"archive": archive, "dir": dir}))
        }
        Verb::Root { suffix } => {
            let root = judged(
                &settings.archive_root,
                &suffix,
                &settings.roots.project,
                &[state_dir],
            )?;
            Ok(serde_json::json!({ "root": root }))
        }
    }
}

/// Remove each path, a file or a tree, then read each back: a path still
/// standing or one that cannot be read is the failure named, so a removal
/// never reports more than the disk shows.
#[allow(
    clippy::disallowed_methods,
    reason = "the one removal of what an archive already holds, each path read back three-valued after"
)]
pub fn remove(paths: &[PathBuf]) -> Result<()> {
    for path in paths {
        let outcome = match std::fs::symlink_metadata(path) {
            Ok(meta) if meta.is_dir() => std::fs::remove_dir_all(path),
            Ok(_) => std::fs::remove_file(path),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => Err(e),
        };
        outcome.map_err(|e| io("remove", path, e))?;
    }
    for path in paths {
        match std::fs::symlink_metadata(path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Ok(_) => {
                return Err(refused(
                    "remove-incomplete",
                    &[("path", &path.display().to_string())],
                ));
            }
            Err(e) => {
                return Err(refused(
                    "remove-unreadable",
                    &[
                        ("path", &path.display().to_string()),
                        ("cause", &e.to_string()),
                    ],
                ));
            }
        }
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct CloseOut {
    /// The archive holding every path below, the lane mailbox and each
    /// standing `--archive` path; `None` where there was nothing to remove
    /// and no such path.
    pub archive: Option<PathBuf>,
    pub removed: Vec<PathBuf>,
}

/// An item's close-out, its explicit end: every entry [`lane_paths`] names
/// leaves, whatever its age, but the record's lock file
/// ([`without_record_locks`]); the archive holds them, the lane mailbox,
/// which no close-out removes, and each `extra` path that stands, which the
/// caller removes after. Nothing is removed until the archive stands. A
/// status file the lane's hook writes again after the removal stands until
/// the item's next close-out.
///
/// The snapshot and the removal run under the item record's lock
/// ([`records_locked`]); with neither the record nor its lock standing no
/// writer has a record to write, and no lock file is made.
pub fn close_out(
    root: &ArchiveRoot,
    project: &Path,
    state_dir: &Path,
    item: &str,
    extra: &[PathBuf],
    locking: Locking,
    now: u64,
) -> Result<CloseOut> {
    let record = state::item_path(state_dir, item);
    let held = if stands(&record)? || stands(&agent_runtime::record::lock_path(&record))? {
        vec![record.clone()]
    } else {
        Vec::new()
    };
    records_locked(&held, locking, |unlocked| {
        match unlocked.into_iter().next() {
            Some((_, cause)) => Err(cause),
            None => close_out_held(root, project, state_dir, item, extra, &record, now),
        }
    })
}

/// The records [`records_locked`] could not lock, each with the failure
/// its acquisition named.
pub type Unlocked = Vec<(PathBuf, crate::Error)>;

/// Run `f` holding the lock of each item record in `records`, the lock
/// every writer of the record takes, so a write in flight lands before `f`
/// reads the record, or finds no record after. The locks are taken in path
/// order, so two holders of overlapping sets never wait on each other. A
/// record whose lock cannot be taken within the wait, a writer's or a
/// stale mutex's, is handed to `f` as unlocked with its cause rather than
/// failing the rest: `f` leaves it alone or refuses.
#[allow(
    clippy::disallowed_methods,
    reason = "a removal of item records takes the locks every writer of those records takes, around its snapshot and its removal"
)]
pub fn records_locked<'a, R>(
    records: &[PathBuf],
    locking: Locking,
    f: impl FnOnce(Unlocked) -> Result<R> + 'a,
) -> Result<R> {
    type Body<'a, R> = Box<dyn FnOnce(Unlocked) -> Result<R> + 'a>;
    fn hold<'a, R>(
        records: &[PathBuf],
        locking: Locking,
        unlocked: Unlocked,
        f: Body<'a, R>,
    ) -> Result<R> {
        let Some((first, rest)) = records.split_first() else {
            return f(unlocked);
        };
        let body = std::cell::Cell::new(Some(f));
        let carried = std::cell::Cell::new(Some(unlocked));
        let held = record::locked(first, locking, || match (body.take(), carried.take()) {
            (Some(f), Some(unlocked)) => hold(rest, locking, unlocked, f),
            _ => unreachable!("the lock runs its body once"),
        });
        match (held, body.take(), carried.take()) {
            (Err(cause), Some(f), Some(mut unlocked)) => {
                unlocked.push((first.clone(), cause));
                hold(rest, locking, unlocked, f)
            }
            (held, _, _) => held,
        }
    }
    let mut sorted = records.to_vec();
    sorted.sort();
    sorted.dedup();
    hold(&sorted, locking, Vec::new(), Box::new(f))
}

/// `paths` without the lock file and the mutex directory of each of
/// `records`: the lock pathname stays, since the shell store locks it with
/// no check that the inode it holds is still the one the pathname names; a
/// waiter on an unlinked inode and a writer on a new one would both hold
/// "the" lock once the key is created again.
pub fn without_record_locks(paths: Vec<PathBuf>, records: &[PathBuf]) -> Vec<PathBuf> {
    let locks: Vec<PathBuf> = records
        .iter()
        .flat_map(|r| {
            [
                agent_runtime::record::lock_path(r),
                agent_runtime::record::mutex_path(r),
            ]
        })
        .collect();
    paths.into_iter().filter(|p| !locks.contains(p)).collect()
}

fn stands(path: &Path) -> Result<bool> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(io("read", path, e)),
    }
}

/// Whether `name` carries `item` as a whole token, `(^|[-_.])ITEM([-_.]|$)`,
/// so no file of an item whose key extends it.
fn names_item(name: &str, item: &str) -> bool {
    let boundary = |c: Option<char>| c.is_none_or(|c| matches!(c, '-' | '_' | '.'));
    name.match_indices(item).any(|(at, _)| {
        boundary(name[..at].chars().next_back()) && boundary(name[at + item.len()..].chars().next())
    })
}

/// The entries of the state directory named for `item`, each direct entry
/// and each file under `handoffs/`, but the mailbox and the fleet's and the
/// runner's own records (the runner's share the log's stem).
fn lane_paths(paths: &Paths, item: &str) -> Result<Vec<PathBuf>> {
    let fleet_name = name_of(&paths.state);
    let fleet_lock = format!("{fleet_name}.lock");
    let runner = format!(
        "{}.",
        paths
            .log
            .file_stem()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    );
    let mut out = Vec::new();
    for entry in read_dir(&paths.dir)? {
        let name = name_of(&entry);
        if name == fleet_name
            || name == fleet_lock
            || name.starts_with(&runner)
            || name == "lane-mail"
        {
            continue;
        }
        if name == "handoffs" {
            for file in read_dir(&entry)? {
                if names_item(&name_of(&file), item) {
                    out.push(file);
                }
            }
            continue;
        }
        if names_item(&name, item) {
            out.push(entry);
        }
    }
    out.sort();
    Ok(out)
}

fn close_out_held(
    root: &ArchiveRoot,
    project: &Path,
    state_dir: &Path,
    item: &str,
    extra: &[PathBuf],
    record: &Path,
    now: u64,
) -> Result<CloseOut> {
    let mut evidence = Vec::new();
    let mut targets = Vec::new();
    let mut own = Vec::new();
    if stands(state_dir)? {
        let paths = Paths::of(&record::fleet_path(state_dir))?;
        own.push(paths.dir.join(name_of(record)));
        for path in without_record_locks(lane_paths(&paths, item)?, &own) {
            targets.push(path.clone());
            evidence.push(path);
        }
        let mailbox = paths.dir.join("lane-mail").join(item);
        if std::fs::symlink_metadata(&mailbox).is_ok() {
            evidence.push(mailbox);
        }
    }
    let mut standing = 0;
    for path in extra {
        if stands(path)? {
            evidence.push(path.clone());
            standing += 1;
        }
    }
    let archive = if targets.is_empty() && standing == 0 {
        None
    } else {
        Some(write(
            root,
            project,
            state_dir,
            &format!("close-{item}-{now}"),
            None,
            &evidence,
        )?)
    };
    if let Err(e) = remove(&targets) {
        let kept = archive
            .as_ref()
            .map_or_else(|| "none".to_owned(), |a| a.display().to_string());
        return Err(refused(
            "remove-failed",
            &[("kept", &kept), ("cause", &e.to_string())],
        ));
    }
    targets.sort();
    Ok(CloseOut {
        archive,
        removed: targets,
    })
}

#[cfg(test)]
#[allow(
    clippy::disallowed_methods,
    reason = "the row plants the directory and the link it resolves"
)]
mod tests {
    use super::*;

    /// A path that does not stand yet resolves through the links of the
    /// prefix that does, so a configured root under a linked state
    /// directory is caught before it is created.
    #[test]
    fn resolve_follows_the_standing_prefix_and_keeps_the_rest() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().join("real");
        std::fs::create_dir(&real).unwrap();
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let want = std::fs::canonicalize(&real).unwrap().join("a").join("b");
        assert_eq!(resolve(&link.join("a").join("b")), want);
        assert_eq!(
            resolve(Path::new("/no/such/root/x")),
            PathBuf::from("/no/such/root/x")
        );
    }

    /// The token rule: the item whole, never a key that extends it.
    #[test]
    fn a_name_carries_an_item_as_a_whole_token_only() {
        let rows = [
            ("workflow-state-KEN-1.json", "KEN-1", true),
            ("workflow-state-KEN-1.json.lock", "KEN-1", true),
            ("lane-status-KEN-1.md", "KEN-1", true),
            ("KEN-1", "KEN-1", true),
            ("workflow-state-KEN-10.json", "KEN-1", false),
            ("workflow-state-KEN-1a.json", "KEN-1", false),
            ("xKEN-1.json", "KEN-1", false),
            ("KEN-1-handoff.md", "KEN-1", true),
            ("issue-7.run", "issue-7", true),
            ("issue-77.run", "issue-7", false),
        ];
        for (name, item, want) in rows {
            assert_eq!(names_item(name, item), want, "{name} {item}");
        }
    }
}
