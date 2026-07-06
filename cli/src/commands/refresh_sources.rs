use crate::config;
use std::path::PathBuf;

/// Resolve source directories from lock file entries.
/// Handles absolute local paths, "." (walks up from CWD), and remote shorthand (cached clones).
pub(crate) fn resolve_sources(lock: &config::LockFile) -> Vec<PathBuf> {
    let mut sources: Vec<PathBuf> = Vec::new();
    let mut seen = std::collections::HashSet::new();

    for entry in lock.entries.values() {
        if seen.contains(&entry.source) {
            continue;
        }
        seen.insert(entry.source.clone());

        if let Some(dir) = resolve_single_source(&entry.source)
            && !sources.contains(&dir)
        {
            sources.push(dir);
        }
    }

    // Fallback: walk up from CWD to find a vstack source repo
    if sources.is_empty()
        && let Ok(mut dir) = std::env::current_dir()
    {
        loop {
            if crate::resolve::is_vstack_source(&dir) {
                sources.push(dir);
                break;
            }
            if !dir.pop() {
                break;
            }
        }
    }

    // Fallback: try the source registry (cached remote repos)
    if sources.is_empty() {
        let reg_path = config::source_registry_path();
        if let Ok(registry) = config::SourceRegistry::load(&reg_path) {
            for entry in registry.current.iter().chain(registry.entries.iter()) {
                if let Some(dir) = resolve_single_source(entry)
                    && !sources.contains(&dir)
                {
                    sources.push(dir);
                }
            }
        }
    }

    sources
}

pub(crate) fn resolve_single_source(source: &str) -> Option<PathBuf> {
    // Absolute local path that exists.
    let p = std::path::Path::new(source);
    if p.is_absolute() && p.is_dir() && crate::resolve::is_vstack_source(p) {
        return Some(p.to_path_buf());
    }

    // "." — walk up from CWD
    if source == "." {
        let mut dir = std::env::current_dir().ok()?;
        loop {
            if crate::resolve::is_vstack_source(&dir) {
                return Some(dir);
            }
            if !dir.pop() {
                break;
            }
        }
        return None;
    }

    // Remote shorthand (owner/repo) — update and use cached clone
    let cache_dir = config::global_base_dir().join(".vstack").join("cache");
    let key = source.replace('/', "_");
    let cached = cache_dir.join(&key);
    if cached.join(".git").exists() {
        update_cached_repo(&cached);
        return Some(cached);
    }

    None
}

/// Pull latest changes for a cached remote repo.
fn update_cached_repo(repo_dir: &std::path::Path) {
    eprintln!("Updating cached repo...");
    let fetch = std::process::Command::new("git")
        .args(["fetch", "origin", "--quiet"])
        .current_dir(repo_dir)
        .status();
    match fetch {
        Ok(s) if s.success() => {
            let reset = std::process::Command::new("git")
                .args(["reset", "--hard", "origin/HEAD"])
                .current_dir(repo_dir)
                .stderr(std::process::Stdio::null())
                .status();
            if !reset.is_ok_and(|s| s.success()) {
                eprintln!("  Warning: git reset failed — cached repo may be stale");
            }
        }
        Ok(_) => eprintln!("  Warning: git fetch failed — using cached version"),
        Err(_) => eprintln!("  Warning: git not available — using cached version"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn tmpdir(label: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before epoch")
            .as_nanos();
        std::env::temp_dir().join(format!(
            "vstack-refresh-source-{label}-{}-{nanos}",
            std::process::id()
        ))
    }

    #[test]
    fn resolve_single_source_accepts_absolute_vstack_source() {
        let root = tmpdir("absolute");
        let source = root.join("source");
        std::fs::create_dir_all(source.join("agents")).unwrap();
        std::fs::create_dir_all(source.join("hooks")).unwrap();

        assert_eq!(
            resolve_single_source(&source.to_string_lossy()),
            Some(source.clone())
        );
        assert!(resolve_single_source(&root.to_string_lossy()).is_none());

        let _ = std::fs::remove_dir_all(root);
    }
}
