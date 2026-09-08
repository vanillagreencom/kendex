use std::collections::BTreeSet;
use std::fs;
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
pub fn discover_projects(root: &Path) -> Result<Vec<PathBuf>> {
    let root = crate::paths::canonical(root).map_err(|e| CoreError::io(root, e))?;
    if !root.is_dir() {
        return Err(CoreError::NotADirectory { path: root });
    }
    let mut found = BTreeSet::new();
    walk(&root, 0, &mut found);
    Ok(found.into_iter().collect())
}

fn walk(dir: &Path, depth: usize, found: &mut BTreeSet<PathBuf>) {
    if is_project(dir) {
        if let Ok(canonical) = crate::paths::canonical(dir) {
            found.insert(canonical);
        }
        return;
    }
    if depth >= MAX_DEPTH {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
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
