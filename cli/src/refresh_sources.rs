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
    pub source_repo: Option<String>,
}

#[derive(Clone)]
pub struct RefreshSource {
    pub root: PathBuf,
    pub aliases: Vec<String>,
    pub source_repo: Option<String>,
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
            source_repo: record.source_repo.clone(),
            mapping: MappingConfig::load(&record.root),
            agents: crate::catalog::discover_agents(&record.root).unwrap_or_default(),
            skills: crate::catalog::discover_skills(&record.root).unwrap_or_default(),
            hooks: crate::catalog::discover_hooks(&record.root).unwrap_or_default(),
            pi_extensions: crate::catalog::discover_pi_extensions(&record.root).unwrap_or_default(),
        }
    }

    #[cfg(test)]
    pub(crate) fn from_root(root: &Path) -> Self {
        Self::load(&ResolvedSource {
            root: root.to_path_buf(),
            aliases: vec![root.to_string_lossy().into_owned()],
            source_repo: config::source_repo_for_source(Some(root), &root.to_string_lossy()),
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
    let source_repo = config::source_repo_for_source(Some(&root), &alias);
    if let Some(existing) = sources
        .iter_mut()
        .find(|source| same_path(&source.root, &root))
    {
        if !existing.aliases.iter().any(|known| known == &alias) {
            existing.aliases.push(alias);
        }
        if existing.source_repo.is_none() {
            existing.source_repo = source_repo;
        }
    } else {
        sources.push(ResolvedSource {
            root,
            aliases: vec![alias],
            source_repo,
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

    // Legacy fallback: an entry that recorded no usable source at all may bind
    // to the sole loaded source. A recorded path or remote that merely no
    // longer resolves must not — see `may_rebind_to_fallback_source`.
    if sources.len() == 1 && may_rebind_to_fallback_source(&entry.source) {
        sources.first()
    } else {
        None
    }
}

/// Whether an entry may be bound to a source it did not record.
///
/// Only a legacy placeholder qualifies: an empty source, or a bare token that
/// is neither path-like (`/…`, `~…`, `.`, `./…`, `../…`) nor remote-like
/// (`owner/repo`, a URL) — the shapes pre-1.0 locks and disk recovery wrote
/// when no source was known — and only while that token does not name a live
/// project-relative directory. A recorded path or remote that no longer
/// resolves stays bound to what it recorded and is reported missing:
/// rebinding it would refresh the entry from a source it was never installed
/// from, and a same-named asset there would silently replace the real one.
pub(crate) fn may_rebind_to_fallback_source(source: &str) -> bool {
    is_legacy_placeholder_source(source) && !recorded_source_exists(source)
}

fn is_legacy_placeholder_source(source: &str) -> bool {
    let source = source.trim();
    if source.is_empty() {
        return true;
    }
    let path_like = Path::new(source).is_absolute()
        || source.starts_with('~')
        || is_explicit_relative_local_source(source)
        || source == "..";
    let remote_like = source.contains('/') || source.contains("://") || source.contains('@');
    !path_like && !remote_like
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
    if let Some(path) = resolve_recorded_local_source(source) {
        return Some(path);
    }
    resolve_single_source(source)
}

/// Whether an entry's recorded source still names a usable directory on disk.
///
/// Deliberately side-effect free (no remote fetch): callers use it in per-entry
/// loops to decide whether an entry may fall back to a different source.
pub(crate) fn recorded_source_exists(source: &str) -> bool {
    let path = Path::new(source);
    if path.is_absolute() {
        return path.is_dir();
    }
    resolve_recorded_local_source(source).is_some()
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

    // Explicit relative local source tokens in locks/registries are
    // project-scoped. Treating them as "walk upward to any vstack source" can
    // rebind a live ./source entry to the checkout running the command from a
    // linked worktree, then repair the lock to the wrong source.
    if is_explicit_relative_local_source(source) {
        return resolve_relative_local_source(source, require_vstack_source);
    }

    // Legacy pure hash/reconcile paths accepted bare placeholders such as
    // "source" by falling back to the nearest vstack checkout from CWD. Keep
    // that compatibility only after trying the project-relative path, and only
    // for non-discovery calls where the historical fallback existed.
    if !require_vstack_source && is_bare_local_source(source, looks_like_remote) {
        if let Some(path) = resolve_relative_local_source(source, false) {
            return Some(path);
        }
        return find_vstack_source_from_cwd();
    }

    // Remote source — update once during top-level source resolution, then use
    // the cached clone without side effects from pure attribution/hash paths.
    // A cache whose recorded origin is not this source is never used: it holds
    // another repository's agents and hooks.
    let cached = config::usable_remote_cache(source)?;
    if update_remote {
        update_cached_repo(&cached);
    }
    Some(cached)
}

fn is_explicit_relative_local_source(source: &str) -> bool {
    source == "." || source.starts_with("./") || source.starts_with("../")
}

fn is_bare_local_source(source: &str, looks_like_remote: bool) -> bool {
    !source.is_empty()
        && !source.starts_with('~')
        && !Path::new(source).is_absolute()
        && !looks_like_remote
}

fn resolve_recorded_local_source(source: &str) -> Option<PathBuf> {
    let looks_like_remote =
        source.contains('/') && !source.starts_with('.') && !source.starts_with('/');
    if !is_explicit_relative_local_source(source)
        && !is_bare_local_source(source, looks_like_remote)
    {
        return None;
    }
    resolve_relative_local_source(source, false)
}

fn resolve_relative_local_source(source: &str, require_vstack_source: bool) -> Option<PathBuf> {
    if source.starts_with('~') {
        return None;
    }
    let candidate = config::project_root().join(source);
    if !candidate.is_dir() {
        return None;
    }
    if require_vstack_source && !crate::resolve::is_vstack_source(&candidate) {
        return None;
    }
    Some(canonicalish(&candidate))
}

fn find_vstack_source_from_cwd() -> Option<PathBuf> {
    let mut dir = std::env::current_dir().ok()?;
    loop {
        if crate::resolve::is_vstack_source(&dir) {
            return Some(dir);
        }
        if !dir.pop() {
            return None;
        }
    }
}

/// Pull latest changes for a cached remote repo.
///
/// Routed through [`config::fetch_remote_cache`] so the guard, the stamp and
/// the fetch itself are one mechanism: a refresh running beside a session-start
/// check can never reset the tree the check is reading, and a successful
/// refresh clears the failure the check would otherwise keep reporting. Runs
/// unbounded — a user is waiting on this one and expects it to finish.
pub(crate) fn update_cached_repo(repo_dir: &std::path::Path) {
    eprintln!("Updating cached repo...");
    report_fetch_outcome(config::fetch_remote_cache(
        repo_dir,
        None,
        config::FetchBound::Unbounded,
    ));
}

/// Say what the fetch did, for every outcome. One helper, shared by `refresh`
/// and `add`, so a variant can never be silently dropped at one call site and
/// leave a user installing from a stale cache with no marker.
pub(crate) fn report_fetch_outcome(attempt: config::FetchAttempt) {
    match attempt {
        config::FetchAttempt::Attempted(true) | config::FetchAttempt::Fresh => {}
        config::FetchAttempt::Attempted(false) => {
            eprintln!("  Warning: git fetch failed — using cached version")
        }
        config::FetchAttempt::Busy => {
            eprintln!(
                "  Warning: another vstack process is refreshing this cache — using cached version"
            )
        }
        config::FetchAttempt::Unwritable(reason) => {
            eprintln!("  Warning: cache cannot be refreshed ({reason}) — using cached version")
        }
    }
}

#[cfg(test)]
mod tests {
    /// VST-258: `vstack add` records the source string it was given, URL forms
    /// included. Every remote form must therefore resolve to the ONE cache the
    /// clone wrote, or `check` reports a perfectly good source unreachable at
    /// every session start and `refresh` falls back to a different source.
    #[test]
    fn every_remote_url_form_resolves_to_the_cache_its_clone_wrote() {
        let root = tmpdir("remote-url-forms");
        let config = root.join("config");
        std::fs::create_dir_all(&config).unwrap();
        crate::test_util::with_home_and_config(&root, &config, || {
            let cache = config::remote_cache_dir("owner/repo").unwrap();
            std::fs::create_dir_all(cache.join(".git")).unwrap();
            // The recorded origin is what identifies a cache: a clone that
            // cannot be proven to be this source is never used.
            std::fs::write(
                cache.join(".git").join("config"),
                "[remote \"origin\"]\n\turl = https://github.com/owner/repo.git\n",
            )
            .unwrap();
            for source in [
                "owner/repo",
                "https://github.com/owner/repo",
                "https://github.com/owner/repo.git",
                "git@github.com:owner/repo.git",
                "ssh://git@github.com/owner/repo.git",
            ] {
                assert_eq!(
                    resolve_source_path(source).as_ref(),
                    Some(&cache),
                    "{source}"
                );
            }
            // Control: an unrelated repo does not resolve to this cache.
            assert!(
                resolve_source_path("https://github.com/other/repo").is_none(),
                "a source with no cache must not resolve"
            );
        });
        let _ = std::fs::remove_dir_all(root);
    }

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
            source_repo: None,
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

    #[test]
    fn resolve_source_records_resolves_relative_sources_from_project_root() {
        let root = tmpdir("recorded-relative");
        let project = root.join("project");
        let relative_source = project.join("vendor").join("vstack");
        std::fs::create_dir_all(relative_source.join("skills/demo")).unwrap();

        let mut lock = config::LockFile::default();
        lock.add(lock_entry("demo", "./vendor/vstack"));

        let records = crate::test_util::with_project_root(&project, || {
            assert_eq!(
                resolve_recorded_source("./vendor/vstack"),
                Some(std::fs::canonicalize(&relative_source).unwrap())
            );
            assert!(recorded_source_exists("./vendor/vstack"));
            resolve_source_records(&lock)
        });

        assert_eq!(records.len(), 1);
        assert_eq!(
            records[0].root,
            std::fs::canonicalize(&relative_source).unwrap()
        );
        assert_eq!(records[0].aliases, vec!["./vendor/vstack".to_string()]);

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn resolve_source_records_records_remote_shorthand_repo_identity() {
        let root = tmpdir("remote-identity");
        let source = make_vstack_source(&root, "source");
        let mut lock = config::LockFile::default();
        lock.add(lock_entry("demo", "vanillagreencom/vstack"));

        let records = resolve_source_records_with(&lock, |source_name| {
            if source_name == "vanillagreencom/vstack" {
                Some(source.clone())
            } else {
                None
            }
        });

        assert_eq!(records.len(), 1);
        assert_eq!(
            records[0].source_repo.as_deref(),
            Some("vanillagreencom/vstack")
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn resolve_source_records_does_not_infer_identity_from_local_layout() {
        let root = tmpdir("local-layout-identity");
        let source = make_vstack_source(&root, "source");
        let mut lock = config::LockFile::default();
        lock.add(lock_entry("demo", &source.to_string_lossy()));

        let records = resolve_source_records(&lock);

        assert_eq!(records.len(), 1);
        assert_eq!(records[0].source_repo, None);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn relative_parent_source_uses_current_worktree_lexical_neighbor() {
        let root = tmpdir("recorded-relative-parent");
        let main_project = root.join("dev").join("consumer");
        let main_checkout_neighbor = root.join("dev").join("vstack");
        let linked_worktree = root
            .join("dev")
            .join(".worktrees")
            .join("consumer")
            .join("issue-1");
        let worktree_neighbor = root
            .join("dev")
            .join(".worktrees")
            .join("consumer")
            .join("vstack");
        std::fs::create_dir_all(&main_project).unwrap();
        std::fs::create_dir_all(main_checkout_neighbor.join("skills/demo")).unwrap();
        std::fs::create_dir_all(&linked_worktree).unwrap();
        std::fs::create_dir_all(worktree_neighbor.join("skills/demo")).unwrap();

        let resolved = crate::test_util::with_project_root(&linked_worktree, || {
            resolve_recorded_source("../vstack")
        });

        assert_eq!(
            resolved,
            Some(std::fs::canonicalize(&worktree_neighbor).unwrap()),
            "copied relative lock sources are resolved from the current worktree root"
        );
        assert_ne!(
            resolved,
            Some(std::fs::canonicalize(&main_checkout_neighbor).unwrap()),
            "../vstack must not silently keep pointing at the main checkout after a lock is copied"
        );

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn recorded_remote_shorthand_does_not_bind_to_project_local_shadow_dir() {
        let root = tmpdir("remote-shadow");
        let project = root.join("project");
        let shadow = project.join("owner").join("repo");
        std::fs::create_dir_all(&shadow).unwrap();

        crate::test_util::with_project_root(&project, || {
            assert!(resolve_recorded_local_source("owner/repo").is_none());
            assert!(!recorded_source_exists("owner/repo"));
        });

        let _ = std::fs::remove_dir_all(root);
    }

    /// An entry that recorded a real source — live or vanished — must never be
    /// silently rebound to the sole other loaded source; that reinstalled it
    /// from a repo it was never installed from (a same-named asset there
    /// replaced the real one). A vanished source is reported missing instead.
    #[test]
    fn refresh_source_for_entry_never_rebinds_a_recorded_source() {
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
        assert!(
            refresh_source_for_entry(&sources, &vanished).is_none(),
            "a recorded absolute source that vanished must not bind to a different source"
        );

        let uncached_remote = lock_entry("demo", "owner/repo");
        assert!(
            refresh_source_for_entry(&sources, &uncached_remote).is_none(),
            "a recorded remote that did not resolve must not bind to a local source"
        );

        let project = root.join("project");
        std::fs::create_dir_all(&project).unwrap();
        let vanished_relative = lock_entry("demo", "./vendor/gone");
        crate::test_util::with_project_root(&project, || {
            assert!(
                refresh_source_for_entry(&sources, &vanished_relative).is_none(),
                "a recorded relative source that vanished must not bind to a different source"
            );
        });

        let _ = std::fs::remove_dir_all(root);
    }

    /// The fallback exists for locks that recorded no usable source at all:
    /// an empty source (disk recovery into an empty lock) or a bare
    /// placeholder token (pre-1.0 hash/reconcile paths). Even those bind only
    /// while exactly one source is loaded and the token names no live
    /// project-relative directory.
    #[test]
    fn refresh_source_for_entry_falls_back_only_for_legacy_placeholder_sources() {
        let root = tmpdir("legacy-placeholder");
        let project = root.join("project");
        std::fs::create_dir_all(&project).unwrap();
        let only_source = make_vstack_source(&root, "other");
        let sources = vec![RefreshSource::from_root(&only_source)];

        crate::test_util::with_project_root(&project, || {
            for placeholder in ["", "source"] {
                assert_eq!(
                    refresh_source_for_entry(&sources, &lock_entry("demo", placeholder))
                        .map(|s| s.root.clone()),
                    Some(only_source.clone()),
                    "legacy placeholder {placeholder:?} keeps the single-source fallback"
                );
            }

            std::fs::create_dir_all(project.join("source")).unwrap();
            assert!(
                refresh_source_for_entry(&sources, &lock_entry("demo", "source")).is_none(),
                "a bare token that names a live project-relative dir is a real source"
            );

            for legacy in ["", "  ", "local"] {
                assert!(
                    may_rebind_to_fallback_source(legacy),
                    "{legacy:?} is a legacy placeholder"
                );
            }
            for recorded in [
                "/gone/checkout",
                "~/gone",
                ".",
                "./gone",
                "../gone",
                "owner/repo",
                "https://github.com/owner/repo.git",
                "git@github.com:owner/repo.git",
            ] {
                assert!(
                    !may_rebind_to_fallback_source(recorded),
                    "{recorded:?} is a recorded source, never rebound"
                );
            }
        });

        let second = make_vstack_source(&root, "second");
        let two_sources = vec![
            RefreshSource::from_root(&only_source),
            RefreshSource::from_root(&second),
        ];
        assert!(
            refresh_source_for_entry(&two_sources, &lock_entry("demo", "")).is_none(),
            "no fallback when more than one source is loaded"
        );

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn refresh_source_for_entry_does_not_fallback_for_live_relative_source() {
        let root = tmpdir("relative-no-rebind");
        let project = root.join("project");
        let relative_source = project.join("vendor").join("vstack");
        std::fs::create_dir_all(relative_source.join("skills/demo")).unwrap();
        let only_source = make_vstack_source(&root, "other");
        let sources = vec![RefreshSource::from_root(&only_source)];
        let live_relative = lock_entry("demo", "./vendor/vstack");

        crate::test_util::with_project_root(&project, || {
            assert!(
                refresh_source_for_entry(&sources, &live_relative).is_none(),
                "a live relative source must not rebind to the sole loaded source"
            );
        });

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
            source_repo: None,
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
