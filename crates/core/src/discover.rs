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

    #[test]
    fn finds_marked_projects_and_skips_noise() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        fs::create_dir_all(root.join("a/.claude")).unwrap();
        fs::create_dir_all(root.join("b/sub")).unwrap();
        fs::write(root.join("b/sub/kendex.toml"), "").unwrap();
        fs::create_dir_all(root.join("node_modules/fake/.claude")).unwrap();
        fs::create_dir_all(root.join("plain")).unwrap();

        let found = discover_projects(root).unwrap();
        let names: Vec<_> = found
            .iter()
            .map(|p| {
                p.strip_prefix(crate::paths::canonical(root).unwrap())
                    .unwrap()
                    .to_path_buf()
            })
            .collect();
        assert_eq!(names, [PathBuf::from("a"), PathBuf::from("b/sub")]);
    }

    #[test]
    fn gemini_and_copilot_repos_are_projects_but_a_bare_github_dir_is_not() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        fs::create_dir_all(root.join("g/.gemini")).unwrap();
        fs::create_dir_all(root.join("c/.github")).unwrap();
        fs::write(root.join("c/.github/copilot-instructions.md"), "").unwrap();
        fs::create_dir_all(root.join("plain/.github/workflows")).unwrap();

        let found = discover_projects(root).unwrap();
        let names: Vec<_> = found
            .iter()
            .map(|p| {
                p.strip_prefix(crate::paths::canonical(root).unwrap())
                    .unwrap()
            })
            .collect();
        assert_eq!(names, [Path::new("c"), Path::new("g")]);
    }

    #[test]
    fn a_project_root_is_not_descended_into() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        fs::create_dir_all(root.join("proj/.claude")).unwrap();
        fs::create_dir_all(root.join("proj/nested/.claude")).unwrap();

        let found = discover_projects(&root.join("proj")).unwrap();
        assert_eq!(found.len(), 1);
    }

    #[test]
    fn project_root_walks_up_and_lock_file_wins_at_home() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        fs::create_dir_all(home.join("dev/app/.claude")).unwrap();
        fs::create_dir_all(home.join("dev/app/src/nested")).unwrap();

        let found = project_root_from(&home.join("dev/app/src/nested"), home).unwrap();
        assert_eq!(
            found,
            crate::paths::canonical(&home.join("dev/app")).unwrap()
        );

        // Markers at home itself never make home the project…
        fs::create_dir_all(home.join(".claude")).unwrap();
        assert_eq!(project_root_from(&home.join("dev"), home), None);

        // …but a lock file there does.
        fs::write(home.join(".kendex-lock.json"), "{}").unwrap();
        assert_eq!(
            project_root_from(&home.join("dev"), home).unwrap(),
            crate::paths::canonical(home).unwrap()
        );
    }

    #[test]
    fn both_marker_generations_mark_projects_and_win_at_home() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        fs::create_dir_all(root.join("new")).unwrap();
        fs::write(root.join("new/kendex.toml"), "").unwrap();
        fs::create_dir_all(root.join("newlock")).unwrap();
        fs::write(root.join("newlock/.kendex-lock.json"), "{}").unwrap();

        let found = discover_projects(root).unwrap();
        let names: Vec<_> = found
            .iter()
            .map(|p| {
                p.strip_prefix(crate::paths::canonical(root).unwrap())
                    .unwrap()
            })
            .collect();
        assert_eq!(names, [Path::new("new"), Path::new("newlock")]);

        let home = root;
        fs::create_dir_all(home.join("dev")).unwrap();
        fs::write(home.join(".kendex-lock.json"), "{}").unwrap();
        assert_eq!(
            project_root_from(&home.join("dev"), home).unwrap(),
            crate::paths::canonical(home).unwrap()
        );
    }

    #[test]
    fn depth_limit_holds() {
        let tmp = tempfile::tempdir().unwrap();
        let deep = tmp.path().join("1/2/3/4/5/6");
        fs::create_dir_all(deep.join(".claude")).unwrap();
        let found = discover_projects(tmp.path()).unwrap();
        assert!(found.is_empty());
    }
}
