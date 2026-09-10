use std::collections::BTreeSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use crate::error::{CoreError, Result};

const MARKER_DIRS: [&str; 7] = [
    ".claude",
    ".codex",
    ".opencode",
    ".cursor",
    ".pi",
    ".agents",
    ".gemini",
];
const MARKER_FILES: [&str; 6] = [
    "kendex.toml",
    ".kendex-lock.json",
    ".mcp.json",
    "opencode.json",
    "opencode.jsonc",
    // Copilot's own file. `.github/` alone marks nearly every repository
    // and would make the whole machine look like one project.
    ".github/copilot-instructions.md",
];
const SKIP_DIRS: [&str; 7] = [
    "node_modules",
    "target",
    ".git",
    "dist",
    "build",
    ".venv",
    ".cache",
];
const MAX_DEPTH: usize = 5;

pub fn is_project(dir: &Path) -> bool {
    MARKER_DIRS.iter().any(|m| dir.join(m).is_dir())
        || MARKER_FILES.iter().any(|m| dir.join(m).is_file())
}

/// Current-project resolution: walk up from `start`; a `.kendex-lock.json`
/// wins even at the home directory, otherwise the first directory carrying
/// a harness marker — refusing home itself.
///
/// The walk and the `home` test run in `std::fs::canonicalize`'s spelling,
/// and `paths::reduced` speaks only for the answer. Reducing each end
/// separately decides the extended-length prefix per path, and the refusal
/// here is a comparison: a start deep enough to keep the prefix would
/// never meet the home that lost it, and a marker at home would be taken
/// for a project.
pub fn project_root_from(start: &Path, home: &Path) -> Option<PathBuf> {
    let start = start.canonicalize().ok()?;
    let home = home.canonicalize().unwrap_or_else(|_| home.to_path_buf());
    let mut current = Some(start.as_path());
    while let Some(dir) = current {
        if dir.join(crate::lock::LOCK_FILE).is_file() {
            return Some(crate::paths::reduced(dir));
        }
        if dir != home && MARKER_DIRS.iter().any(|m| dir.join(m).is_dir()) {
            return Some(crate::paths::reduced(dir));
        }
        current = dir.parent();
    }
    None
}

/// Walk `root` looking for directories that carry a harness marker.
/// Results are canonicalized, deduplicated, and sorted.
///
/// The chosen folder's own listing is the search, so a failure to read it
/// is an error rather than an empty answer: "no projects in there" is a
/// claim about a folder, and a folder nobody could look in supports none.
/// `is_dir` is not that check — a directory with no read permission is
/// still a directory, and its listing is what fails.
///
/// Failures deeper down stay silent. One unreadable directory among many
/// is not a failed search of the folder that was chosen, and refusing the
/// whole answer for it would report nothing over a tree that mostly read.
///
/// The listing fails in two places, and both are the chosen folder's own:
/// opening it, and reading it out. A `ReadDir` opened over a directory
/// that goes away, or over a mount that stops answering, hands its failure
/// back part-way through the entries — so a partial listing is not the
/// folder's contents either, and it is answered the same way the open's
/// failure is.
pub fn discover_projects(root: &Path) -> Result<Vec<PathBuf>> {
    let root = crate::paths::canonical(root).map_err(|e| CoreError::io(root, e))?;
    if !root.is_dir() {
        return Err(CoreError::NotADirectory { path: root });
    }
    let mut found = BTreeSet::new();
    if is_project(&root) {
        keep(&root, &mut found);
        return Ok(found.into_iter().collect());
    }
    let entries = fs::read_dir(&root).map_err(|e| CoreError::io(&root, e))?;
    descend(entries, 0, &mut found).map_err(|e| CoreError::io(&root, e))?;
    Ok(found.into_iter().collect())
}

fn keep(dir: &Path, found: &mut BTreeSet<PathBuf>) {
    if let Ok(canonical) = crate::paths::canonical(dir) {
        found.insert(canonical);
    }
}

fn walk(dir: &Path, depth: usize, found: &mut BTreeSet<PathBuf>) {
    if is_project(dir) {
        keep(dir, found);
        return;
    }
    if depth >= MAX_DEPTH {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    // Dropped, like the open above it: a directory deeper in the tree that
    // stops answering part-way through is the silent failure this walk is
    // best-effort about.
    let _ = descend(entries, depth, found);
}

/// The children of a directory already read, walked in turn. Shared so the
/// root's listing and every deeper one are descended by one rule, and only
/// how their read failures are answered differs: the entry that failed is
/// handed back, and each caller decides what that means for its own
/// directory. Stopping there rather than reading on is what keeps a
/// listing kendex could not finish from being answered as a whole folder.
fn descend(
    entries: impl Iterator<Item = io::Result<fs::DirEntry>>,
    depth: usize,
    found: &mut BTreeSet<PathBuf>,
) -> io::Result<()> {
    for entry in entries {
        let path = entry?.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        // Hidden directories can't be projects themselves, and marker dirs are
        // already covered by the is_project probe on their parent.
        if name.starts_with('.') || SKIP_DIRS.contains(&name) {
            continue;
        }
        // Symlinked dirs are skipped to keep the walk cycle-free.
        if path.is_dir() && !path.is_symlink() {
            walk(&path, depth + 1, found);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What a walk from `root` finds, as paths relative to it, in the
    /// order they come back.
    fn found_under(root: &Path) -> Vec<PathBuf> {
        let canonical = crate::paths::canonical(root).unwrap();
        discover_projects(root)
            .unwrap()
            .iter()
            .map(|project| project.strip_prefix(&canonical).unwrap().to_path_buf())
            .collect()
    }

    /// A folder kendex could not look in is not a folder with no projects
    /// in it. `is_dir` says yes to a directory with no read permission,
    /// and its listing is what fails — so the search has to answer with
    /// that failure, or the dialog above it says "No projects in there"
    /// about a folder nobody read.
    ///
    /// Skipped where the process can read it anyway: running as root,
    /// permissions do not refuse, and there is no unreadable directory to
    /// test against. The probe is the same read the code under test makes.
    /// Unix only — a mode is what makes a directory unreadable here, and
    /// Windows has no equivalent to set.
    #[cfg(unix)]
    #[test]
    fn an_unreadable_root_is_an_error_and_never_an_empty_result() {
        use std::os::unix::fs::PermissionsExt;

        let tmp = tempfile::tempdir().unwrap();
        let shut = tmp.path().join("shut");
        fs::create_dir(&shut).unwrap();
        fs::set_permissions(&shut, fs::Permissions::from_mode(0o000)).unwrap();
        let readable = fs::read_dir(&shut).is_ok();
        // Put it back first, so a failure below cannot leave a directory
        // the harness can no longer clean up.
        fs::set_permissions(&shut, fs::Permissions::from_mode(0o700)).unwrap();
        if readable {
            return;
        }

        fs::set_permissions(&shut, fs::Permissions::from_mode(0o000)).unwrap();
        let answer = discover_projects(&shut);
        fs::set_permissions(&shut, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(
            matches!(answer, Err(CoreError::Io { .. })),
            "an unreadable root answered {answer:?}"
        );
    }

    /// A listing can fail after it opened: the directory goes away, or the
    /// mount under it stops answering, and the failure arrives as one of
    /// the entries. The walk hands that back rather than reading past it,
    /// so the root's caller answers the folder with the failure instead of
    /// with however much of it had been read — which is the same claim the
    /// unreadable root above refuses to make.
    ///
    /// Driven through `descend` because a real `ReadDir` cannot be made to
    /// fail part-way on demand: the entries are the ones the directory
    /// actually holds, with the failure among them.
    #[test]
    fn a_listing_that_fails_part_way_is_handed_back_and_not_read_past() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        fs::create_dir_all(root.join("good/.claude")).unwrap();
        let mut entries: Vec<io::Result<fs::DirEntry>> = fs::read_dir(root).unwrap().collect();
        entries.insert(0, Err(io::Error::other("the listing stopped answering")));

        let mut found = BTreeSet::new();
        let answer = descend(entries.into_iter(), 0, &mut found);
        assert!(answer.is_err(), "a failed entry answered {answer:?}");
        // The project after it in the listing is what a partial answer
        // would be made of.
        assert!(found.is_empty(), "read past the failure: {found:?}");
    }

    /// One unreadable directory among many is not a failed search of the
    /// folder that was chosen: the answer keeps what did read. Unix only,
    /// for the reason above.
    #[cfg(unix)]
    #[test]
    fn an_unreadable_child_leaves_the_rest_of_the_answer_standing() {
        use std::os::unix::fs::PermissionsExt;

        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("root");
        fs::create_dir_all(root.join("good/.claude")).unwrap();
        let shut = root.join("shut");
        fs::create_dir(&shut).unwrap();
        fs::set_permissions(&shut, fs::Permissions::from_mode(0o000)).unwrap();
        let readable = fs::read_dir(&shut).is_ok();

        let answer = discover_projects(&root);
        fs::set_permissions(&shut, fs::Permissions::from_mode(0o700)).unwrap();
        if readable {
            return;
        }
        assert_eq!(
            answer.unwrap(),
            [crate::paths::canonical(&root.join("good")).unwrap()]
        );
    }

    /// One row per tree shape, and the projects a walk from its root
    /// finds. A marker directory or file marks a project; a bare
    /// `.github` does not, only one holding Copilot instructions; noise
    /// such as `node_modules` is skipped; a project root is not descended
    /// into; both marker generations mark; and nothing deeper than the
    /// depth limit is found.
    #[test]
    fn a_walk_finds_every_marked_project_and_nothing_else() {
        type Row<'a> = (&'a [&'a str], &'a [&'a str], &'a [&'a str]);
        let rows: [Row<'_>; 5] = [
            (
                &["a/.claude", "b/sub", "node_modules/fake/.claude", "plain"],
                &["b/sub/kendex.toml"],
                &["a", "b/sub"],
            ),
            (
                &["g/.gemini", "c/.github", "plain/.github/workflows"],
                &["c/.github/copilot-instructions.md"],
                &["c", "g"],
            ),
            (&["proj/.claude", "proj/nested/.claude"], &[], &["proj"]),
            (
                &["new", "newlock"],
                &["new/kendex.toml", "newlock/.kendex-lock.json"],
                &["new", "newlock"],
            ),
            (&["1/2/3/4/5/6/.claude"], &[], &[]),
        ];
        for (dirs, files, projects) in rows {
            let tmp = tempfile::tempdir().unwrap();
            let root = tmp.path();
            for dir in dirs {
                fs::create_dir_all(root.join(dir)).unwrap();
            }
            for file in files {
                fs::write(root.join(file), "").unwrap();
            }
            let expected: Vec<PathBuf> = projects.iter().map(PathBuf::from).collect();
            assert_eq!(found_under(root), expected, "{dirs:?} {files:?}");
        }
    }

    #[test]
    fn project_root_walks_up_and_lock_file_wins_at_home() {
        for (start, lock_at_home, expected) in [
            ("home/dev/app/src/nested", false, "home/dev/app"),
            ("home/dev", false, ""),
            ("home/dev", true, "home"),
        ] {
            let tmp = tempfile::tempdir().unwrap();
            let root = crate::paths::canonical(tmp.path()).unwrap();
            let home = root.join("home");
            // The private ancestor catches a walk past home before any
            // real marker above the fixture can decide the answer.
            fs::create_dir_all(root.join(".claude")).unwrap();
            fs::create_dir_all(home.join(".claude")).unwrap();
            fs::create_dir_all(home.join("dev/app/.claude")).unwrap();
            fs::create_dir_all(home.join("dev/app/src/nested")).unwrap();
            if lock_at_home {
                fs::write(home.join(".kendex-lock.json"), "{}").unwrap();
            }
            assert_eq!(
                project_root_from(&root.join(start), &home),
                Some(root.join(expected)),
                "{start}, home lock={lock_at_home}",
            );
        }
    }
}
