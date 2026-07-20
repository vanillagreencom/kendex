use crate::agent::Agent;
use crate::config::{self, ItemKind};
use crate::hook::Hook;
use crate::mapping::MappingConfig;
use crate::pi_extension::PiExtension;
use crate::skill::Skill;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub(crate) struct ResolvedSource {
    pub root: PathBuf,
    pub aliases: Vec<String>,
}

#[derive(Clone)]
pub struct RefreshSource {
    pub root: PathBuf,
    pub aliases: Vec<String>,
    pub mapping: MappingConfig,
    pub agents: Vec<Agent>,
    pub skills: Vec<Skill>,
    pub hooks: Vec<Hook>,
    pub pi_extensions: Vec<PiExtension>,
}

impl RefreshSource {
    pub(crate) fn load(record: &ResolvedSource) -> Self {
        Self {
            root: record.root.clone(),
            aliases: record.aliases.clone(),
            mapping: MappingConfig::load(&record.root),
            agents: crate::agent::discover_agents(&record.root.join("agents")).unwrap_or_default(),
            skills: crate::skill::discover_skills(&record.root.join("skills")).unwrap_or_default(),
            hooks: crate::hook::discover_hooks(&record.root.join("hooks")).unwrap_or_default(),
            pi_extensions: crate::pi_extension::discover_pi_extensions(
                &record.root.join("pi-extensions"),
            )
            .unwrap_or_default(),
        }
    }

    #[cfg(test)]
    pub(crate) fn from_root(root: &Path) -> Self {
        Self::load(&ResolvedSource {
            root: root.to_path_buf(),
            aliases: vec![root.to_string_lossy().into_owned()],
        })
    }
}

/// Resolve source directories from lock file entries.
/// Handles absolute local paths, "." (walks up from CWD), and remote shorthand (cached clones).
pub(crate) fn resolve_sources(lock: &config::LockFile) -> Vec<PathBuf> {
    resolve_source_records(lock)
        .into_iter()
        .map(|source| source.root)
        .collect()
}

pub(crate) fn resolve_source_records(lock: &config::LockFile) -> Vec<ResolvedSource> {
    resolve_source_records_with(lock, resolve_recorded_source)
}

fn resolve_source_records_with(
    lock: &config::LockFile,
    mut resolver: impl FnMut(&str) -> Option<PathBuf>,
) -> Vec<ResolvedSource> {
    let mut sources: Vec<ResolvedSource> = Vec::new();
    let mut seen = std::collections::HashSet::new();

    for entry in lock.entries.values() {
        if !seen.insert(entry.source.clone()) {
            continue;
        }
        if let Some(dir) = resolver(&entry.source) {
            push_resolved_source(&mut sources, dir, entry.source.clone());
        }
    }

    // Fallback: walk up from CWD to find a vstack source repo.
    if sources.is_empty()
        && let Ok(mut dir) = std::env::current_dir()
    {
        loop {
            if crate::resolve::is_vstack_source(&dir) {
                let alias = dir.to_string_lossy().into_owned();
                push_resolved_source(&mut sources, dir, alias);
                break;
            }
            if !dir.pop() {
                break;
            }
        }
    }

    // Fallback: try the source registry (cached remote repos).
    if sources.is_empty() {
        let reg_path = config::source_registry_path();
        if let Ok(registry) = config::SourceRegistry::load(&reg_path) {
            for entry in registry.current.iter().chain(registry.entries.iter()) {
                if let Some(dir) = resolver(entry) {
                    push_resolved_source(&mut sources, dir, entry.clone());
                }
            }
        }
    }

    sources
}

fn push_resolved_source(sources: &mut Vec<ResolvedSource>, root: PathBuf, alias: String) {
    if let Some(existing) = sources
        .iter_mut()
        .find(|source| same_path(&source.root, &root))
    {
        if !existing.aliases.iter().any(|known| known == &alias) {
            existing.aliases.push(alias);
        }
    } else {
        sources.push(ResolvedSource {
            root,
            aliases: vec![alias],
        });
    }
}

pub(crate) fn load_refresh_sources(records: &[ResolvedSource]) -> Vec<RefreshSource> {
    records.iter().map(RefreshSource::load).collect()
}

fn canonicalish(path: &Path) -> PathBuf {
    path.canonicalize().unwrap_or_else(|_| path.to_path_buf())
}

fn same_path(a: &Path, b: &Path) -> bool {
    canonicalish(a) == canonicalish(b)
}

pub(crate) fn refresh_source_for_entry<'a>(
    sources: &'a [RefreshSource],
    entry: &config::LockEntry,
) -> Option<&'a RefreshSource> {
    if let Some(source) = sources
        .iter()
        .find(|source| source.aliases.iter().any(|alias| alias == &entry.source))
    {
        return Some(source);
    }

    let entry_path = Path::new(&entry.source);
    if entry_path.is_absolute()
        && let Some(source) = sources
            .iter()
            .find(|source| same_path(&source.root, entry_path))
    {
        return Some(source);
    }

    // Legacy/moved-source fallback: an old lock may record a source string
    // that no longer names anything on disk (a renamed repo, or a pre-1.0 lock
    // with no meaningful source). Those may fall back to the sole loaded
    // source. An entry whose own recorded source still exists must never be
    // rebound to a different one — that silently reinstalled such entries from
    // the wrong repo and masked the real source's edits.
    if sources.len() == 1 && !recorded_source_exists(&entry.source) {
        sources.first()
    } else {
        None
    }
}

pub(crate) fn all_source_hooks(sources: &[RefreshSource]) -> Vec<Hook> {
    sources
        .iter()
        .flat_map(|source| source.hooks.iter().cloned())
        .collect()
}

pub(crate) fn all_source_pi_extensions(sources: &[RefreshSource]) -> Vec<PiExtension> {
    sources
        .iter()
        .flat_map(|source| source.pi_extensions.iter().cloned())
        .collect()
}

pub(crate) fn resolve_skill_pairs_from_sources(
    names: &[String],
    lock: &config::LockFile,
    sources: &[RefreshSource],
) -> Vec<(String, String)> {
    names
        .iter()
        .map(|name| {
            let description = lock
                .entries
                .get(name)
                .filter(|entry| entry.kind == ItemKind::Skill)
                .and_then(|entry| refresh_source_for_entry(sources, entry))
                .and_then(|source| source.skills.iter().find(|skill| &skill.name == name))
                .or_else(|| {
                    sources
                        .iter()
                        .flat_map(|source| source.skills.iter())
                        .find(|skill| &skill.name == name)
                })
                .map(|skill| skill.description.clone())
                .unwrap_or_else(|| name.clone());
            (name.clone(), description)
        })
        .collect()
}

pub(crate) fn source_pi_extension_for_lock_name<'a>(
    pi_extensions: &'a [PiExtension],
    name: &str,
) -> Option<&'a PiExtension> {
    pi_extensions.iter().find(|e| e.name == name).or_else(|| {
        pi_extensions
            .iter()
            .find(|e| crate::pi_extension::legacy_names_for(&e.name).contains(&name))
    })
}

pub(crate) fn resolve_single_source(source: &str) -> Option<PathBuf> {
    resolve_single_source_with(source, true, true)
}

/// Resolve a source string that a lock entry recorded at install time.
///
/// Discovery (`resolve_single_source`) applies the [`crate::resolve::is_vstack_source`]
/// layout heuristic so that walking up from CWD does not mistake an arbitrary
/// directory for a package source. A recorded source needs no such guess: the
/// user named it explicitly on `vstack add`, which accepts any directory
/// holding the asset. Applying the heuristic here silently dropped alternate
/// sources that the heuristic rejects — a dot-named dir, or one carrying only
/// `skills/` — after which the entry fell back to whatever other source was
/// loaded and edits to the real source stopped propagating.
pub(crate) fn resolve_recorded_source(source: &str) -> Option<PathBuf> {
    let path = Path::new(source);
    if path.is_absolute() && path.is_dir() {
        return Some(path.to_path_buf());
    }
    resolve_single_source(source)
}

/// Whether an entry's recorded source still names a usable directory on disk.
///
/// Deliberately side-effect free (no remote fetch): callers use it in per-entry
/// loops to decide whether an entry may fall back to a different source.
pub(crate) fn recorded_source_exists(source: &str) -> bool {
    let path = Path::new(source);
    path.is_absolute() && path.is_dir()
}

pub(crate) fn resolve_source_path(source: &str) -> Option<PathBuf> {
    resolve_single_source_with(source, false, false)
}

fn resolve_single_source_with(
    source: &str,
    update_remote: bool,
    require_vstack_source: bool,
) -> Option<PathBuf> {
    // Absolute local path that exists.
    let p = std::path::Path::new(source);
    if p.is_absolute()
        && p.is_dir()
        && (!require_vstack_source || crate::resolve::is_vstack_source(p))
    {
        return Some(p.to_path_buf());
    }

    let looks_like_remote =
        source.contains('/') && !source.starts_with('.') && !source.starts_with('/');

    // Relative local source tokens resolve by walking up from CWD. The pure
    // config hash/reconcile path also preserves legacy bare-relative fallback.
    if source == "."
        || source.starts_with("./")
        || source.starts_with("../")
        || (!require_vstack_source && !looks_like_remote)
    {
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

    // Remote shorthand (owner/repo) — update once during top-level source resolution,
    // then use the cached clone without side effects from pure attribution/hash paths.
    let cache_dir = config::global_base_dir().join(".vstack").join("cache");
    let key = source.replace('/', "_");
    let cached = cache_dir.join(&key);
    if cached.join(".git").exists() {
        if update_remote {
            update_cached_repo(&cached);
        }
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
    use crate::config::{InstallMethod, LockEntry};
    use std::cell::RefCell;
    use std::collections::HashMap;
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

    fn make_vstack_source(root: &Path, name: &str) -> PathBuf {
        let source = root.join(name);
        std::fs::create_dir_all(source.join("agents")).unwrap();
        std::fs::create_dir_all(source.join("skills")).unwrap();
        source
    }

    fn lock_entry(name: &str, source: &str) -> LockEntry {
        LockEntry {
            name: name.into(),
            kind: ItemKind::Agent,
            source: source.into(),
            harnesses: vec!["claude-code".into()],
            method: InstallMethod::Copy,
            installed_at: "2026-07-03T00:00:00Z".into(),
            source_hash: String::new(),
        }
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

    /// `vstack add <SOURCE>` accepts any directory holding the asset, so a lock
    /// entry may record one that the discovery heuristic rejects — a dot-named
    /// dir, or one carrying only `skills/`. Dropping it here is what made
    /// refresh fall back to the majority source and stop propagating edits.
    #[test]
    fn resolve_source_records_keeps_a_source_the_layout_heuristic_rejects() {
        let root = tmpdir("recorded-alternate");
        let alternate = root.join(".agents");
        std::fs::create_dir_all(alternate.join("skills/demo")).unwrap();
        assert!(
            !crate::resolve::is_vstack_source(&alternate),
            "fixture must exercise the heuristic-rejected case"
        );
        assert_eq!(resolve_single_source(&alternate.to_string_lossy()), None);

        assert_eq!(
            resolve_recorded_source(&alternate.to_string_lossy()),
            Some(alternate.clone())
        );

        let mut lock = config::LockFile::default();
        lock.add(lock_entry("demo", &alternate.to_string_lossy()));
        let records = resolve_source_records(&lock);

        assert_eq!(
            records.iter().map(|r| r.root.clone()).collect::<Vec<_>>(),
            vec![alternate]
        );

        let _ = std::fs::remove_dir_all(root);
    }

    /// An entry whose own source still exists must never be silently rebound to
    /// the sole other loaded source; that reinstalled it from the wrong repo.
    /// The fallback stays available for a source that has genuinely gone away.
    #[test]
    fn refresh_source_for_entry_only_falls_back_when_the_recorded_source_is_gone() {
        let root = tmpdir("no-rebind");
        let alternate = root.join(".agents");
        std::fs::create_dir_all(alternate.join("skills/demo")).unwrap();
        let only_source = make_vstack_source(&root, "other");
        let sources = vec![RefreshSource::from_root(&only_source)];

        let live = lock_entry("demo", &alternate.to_string_lossy());
        assert!(
            refresh_source_for_entry(&sources, &live).is_none(),
            "an entry whose recorded source exists must not bind to a different source"
        );

        let vanished = lock_entry("demo", &root.join("deleted-repo").to_string_lossy());
        assert_eq!(
            refresh_source_for_entry(&sources, &vanished).map(|s| s.root.clone()),
            Some(only_source),
            "legacy lock with a missing source keeps the single-source fallback"
        );

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn resolve_source_records_calls_resolver_once_per_unique_lock_source() {
        let root = tmpdir("resolver-count");
        let source_a = root.join("source-a");
        let source_b = root.join("source-b");
        let mut lock = config::LockFile::default();
        lock.add(lock_entry("rust", "owner/repo"));
        lock.add(LockEntry {
            name: "dev".into(),
            kind: ItemKind::Skill,
            source: "owner/repo".into(),
            harnesses: vec!["claude-code".into()],
            method: InstallMethod::Copy,
            installed_at: "2026-07-03T00:00:00Z".into(),
            source_hash: String::new(),
        });
        lock.add(lock_entry("scout", "other/repo"));

        let counts: RefCell<HashMap<String, usize>> = RefCell::new(HashMap::new());
        let records = resolve_source_records_with(&lock, |source| {
            *counts.borrow_mut().entry(source.to_string()).or_default() += 1;
            match source {
                "owner/repo" => Some(source_a.clone()),
                "other/repo" => Some(source_b.clone()),
                _ => None,
            }
        });

        assert_eq!(records.len(), 2);
        assert_eq!(counts.borrow().get("owner/repo"), Some(&1));
        assert_eq!(counts.borrow().get("other/repo"), Some(&1));

        let _ = std::fs::remove_dir_all(root);
    }
}
