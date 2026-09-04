//! Report routing: which repo an issue about an installed item belongs to.
//! A current lock is the first judge. When it has no answer, current manifest
//! declarations and installed skill or Pi-package metadata can prove the same
//! provenance without hiding a lock read failure. Everything unresolved files
//! against the user's own repo. A name whose candidates disagree stays local.
//!
//! A lock entry keeps the manifest's repo declaration verbatim, so the same
//! repository arrives here spelled as a shorthand, an https URL or an scp
//! `git@` one. Every comparison runs over `source_ref::repo_identity`, which
//! folds those to one string, so a spelling never decides ownership. The
//! judge names the destination too, in the shape a caller can file against:
//! `gh issue create --repo` and a GitHub issue-creation URL each
//! take `owner/repo`, never the URL a subscription may be spelled with.

use crate::lock::{Lock, LockEntry, LockFile};
use crate::manifest::Manifest;
use crate::model::{ItemKind, Scope};
use crate::source_ref::{owner_repo, repo_identity};

pub const DEFAULT_UPSTREAM: &str = crate::manifest::DEFAULT_SOURCE_REPO;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Route {
    pub kendex_owned: bool,
    /// Where to file, and the only string a caller should file against:
    /// `owner/repo` for a GitHub reference however the manifest spelled it,
    /// another host's reference as it stands. Only when kendex-owned.
    pub repo: Option<String>,
    /// Routing label — only on the canonical upstream, where it exists.
    pub label: Option<String>,
    /// The kind the report is about: the one the caller named, or the one
    /// the matching lock entries agree on when the caller named none.
    pub kind: Option<ItemKind>,
    /// `<repo>@<commit7>` off the first matching lock entry, so a triager
    /// can date a report against the fix that already landed. `None` where
    /// nothing recorded a commit.
    pub source: Option<String>,
    /// The first seven characters of what the apply wrote, off that same
    /// entry, where it recorded one.
    pub rendered: Option<String>,
}

/// One routing decision plus the record failures the caller must show.
/// Fallback provenance never turns an unreadable record into a readable one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedRoute {
    pub route: Route,
    pub warnings: Vec<String>,
}

/// Resolve report ownership from the durable record, then the manifest's
/// expanded declarations, then metadata in the installed render. The latter
/// two sources keep routing available while the record is absent or unreadable.
pub fn resolve(
    env: &crate::env::Env,
    scope: &Scope,
    name: &str,
    kind: Option<ItemKind>,
    upstream: &str,
) -> ResolvedRoute {
    let mut warnings = Vec::new();
    let (mut lock, fallback) = match crate::lock::load_file(&crate::lock::lock_path(env, scope)) {
        Ok(LockFile::Current(lock)) => (lock, false),
        Ok(LockFile::Absent) => (Lock::default(), true),
        Err(error) => {
            warnings.push(format!("install record unreadable: {error}"));
            (Lock::default(), true)
        }
    };
    let manifest = match crate::manifest::load_current(&crate::manifest::manifest_path(env, scope))
    {
        Ok(manifest) => manifest,
        Err(error) => {
            warnings.push(format!("manifest unreadable: {error}"));
            None
        }
    };
    if fallback && let Some(manifest) = &manifest {
        match crate::engine::audit_without_record(env, scope, manifest) {
            Ok(audit) => lock = audit.matching,
            Err(error) => warnings.push(format!("render ownership could not be checked: {error}")),
        }
    }
    let recorded = route(&lock, name, kind, upstream);
    if has_match(&lock, name, kind) {
        return ResolvedRoute {
            route: recorded,
            warnings,
        };
    }
    if let Some(route) = manifest
        .as_ref()
        .and_then(|manifest| route_from_manifest(env, scope, manifest, name, kind, upstream))
    {
        return ResolvedRoute { route, warnings };
    }
    if let Some(route) = route_from_render(env, scope, name, kind, upstream, &mut warnings) {
        return ResolvedRoute { route, warnings };
    }
    ResolvedRoute {
        route: recorded,
        warnings,
    }
}

fn has_match(lock: &Lock, name: &str, kind: Option<ItemKind>) -> bool {
    lock.entries
        .values()
        .any(|entry| entry.name == name && kind.is_none_or(|wanted| wanted == entry.kind))
}

fn route_from_manifest(
    env: &crate::env::Env,
    scope: &Scope,
    manifest: &Manifest,
    name: &str,
    kind: Option<ItemKind>,
    upstream: &str,
) -> Option<Route> {
    let mut matches = Vec::new();
    for declared in crate::engine::planned_declarations(env, scope, manifest) {
        if kind.is_some_and(|wanted| wanted != declared.kind) {
            continue;
        }
        let named = declared.name == name
            || (declared.kind == ItemKind::PiExtension
                && declared.name.rsplit('/').next() == Some(name));
        if !named {
            continue;
        }
        let repo = manifest
            .sources
            .get(&declared.decl.source)
            .and_then(|source| source.repo.as_deref())?;
        matches.push((declared.kind, repo));
    }
    unique_provenance(&matches, name, upstream)
}

fn route_from_render(
    env: &crate::env::Env,
    scope: &Scope,
    name: &str,
    kind: Option<ItemKind>,
    upstream: &str,
    warnings: &mut Vec<String>,
) -> Option<Route> {
    let roots = match crate::settings::load(env) {
        Ok(settings) => settings.harness_roots,
        Err(error) => {
            warnings.push(format!("installed render roots unreadable: {error}"));
            return None;
        }
    };
    let mut matches = Vec::new();
    for candidate in [ItemKind::Skill, ItemKind::PiExtension] {
        if kind.is_some_and(|wanted| wanted != candidate) {
            continue;
        }
        let Some(installed) = crate::scan::find_installed(env, &roots, scope, candidate, name)
        else {
            continue;
        };
        if let Some(repo) = rendered_repository(candidate, &installed.path) {
            matches.push((candidate, repo));
        }
    }
    let borrowed: Vec<(ItemKind, &str)> = matches
        .iter()
        .map(|(candidate, repo)| (*candidate, repo.as_str()))
        .collect();
    unique_provenance(&borrowed, name, upstream)
}

fn rendered_repository(kind: ItemKind, path: &std::path::Path) -> Option<String> {
    match kind {
        ItemKind::Skill => {
            let text = crate::fs::read_if_exists(&path.join("SKILL.md")).ok()??;
            let (yaml, _) = crate::frontmatter::split(&text).ok()?;
            let parsed = crate::frontmatter::parse_tolerant(yaml).ok()?;
            let crate::frontmatter::Value::Map(metadata) = parsed.map.get("metadata")? else {
                return None;
            };
            metadata
                .get("repository")
                .and_then(crate::frontmatter::Value::as_str)
                .map(str::to_owned)
        }
        ItemKind::PiExtension => {
            let text = crate::fs::read_if_exists(&path.join("package.json")).ok()??;
            let value: serde_json::Value = serde_json::from_str(&text).ok()?;
            match value.get("repository")? {
                serde_json::Value::String(repo) => Some(repo.clone()),
                serde_json::Value::Object(repo) => repo
                    .get("url")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned),
                _ => None,
            }
        }
        ItemKind::Agent
        | ItemKind::Hook
        | ItemKind::Command
        | ItemKind::McpServer
        | ItemKind::Plugin => None,
    }
}

fn unique_provenance(matches: &[(ItemKind, &str)], name: &str, upstream: &str) -> Option<Route> {
    let [(kind, repo)] = matches else {
        return None;
    };
    let wanted = repo_identity(upstream);
    let owned = repo_identity(repo) == wanted;
    Some(Route {
        kendex_owned: owned,
        repo: owned.then(|| filing_target(upstream)),
        label: (owned && wanted == repo_identity(DEFAULT_UPSTREAM))
            .then(|| derive_label(name, Some(*kind)).to_owned()),
        kind: Some(*kind),
        source: None,
        rendered: None,
    })
}

/// The routing label for a kendex-owned asset, by what it is.
pub fn derive_label(name: &str, kind: Option<ItemKind>) -> &'static str {
    if name.contains("review-gate") {
        return "ci-infra";
    }
    match kind {
        Some(ItemKind::Hook | ItemKind::PiExtension) => "harness",
        Some(ItemKind::Skill | ItemKind::Agent) => "skills",
        _ => "cli",
    }
}

pub fn route(lock: &Lock, name: &str, kind: Option<ItemKind>, upstream: &str) -> Route {
    let matching: Vec<&LockEntry> = lock
        .entries
        .values()
        .filter(|entry| entry.name == name && kind.is_none_or(|k| k == entry.kind))
        .collect();
    // Provenance, not delivery. One entry recorded from anywhere else — a
    // second marketplace, a path, `local` — means the name does not name a
    // kendex asset on its own, and the report stays with the user's repo
    // rather than going to a stranger's.
    let wanted = repo_identity(upstream);
    let owned = !matching.is_empty()
        && matching
            .iter()
            .all(|e| repo_identity(&e.source_repo) == wanted);
    let kind = kind.or_else(|| agreed_kind(&matching));
    let recorded = matching.first();
    Route {
        kendex_owned: owned,
        repo: owned.then(|| filing_target(upstream)),
        label: (owned && wanted == repo_identity(DEFAULT_UPSTREAM))
            .then(|| derive_label(name, kind).to_owned()),
        kind,
        source: recorded.and_then(|entry| {
            let commit = entry.source_commit.as_deref()?;
            Some(format!(
                "{}@{}",
                filing_target(&entry.source_repo),
                short(commit)
            ))
        }),
        rendered: recorded
            .and_then(|entry| entry.rendered_hash.as_deref())
            .map(short),
    }
}

/// A hash as the marker carries it: seven characters, cut on a character
/// boundary because a lock is a file anyone can edit.
fn short(hash: &str) -> String {
    hash.chars().take(7).collect()
}

/// The upstream as something to file against: a GitHub reference folded to
/// the bare `owner/repo` that `gh --repo` and an issue URL take, anything
/// else left as the caller spelled it.
fn filing_target(upstream: &str) -> String {
    owner_repo(upstream).unwrap_or_else(|| upstream.to_owned())
}

/// The one kind the matching entries are, when they are all one kind.
fn agreed_kind(matching: &[&LockEntry]) -> Option<ItemKind> {
    let first = matching.first()?.kind;
    matching.iter().all(|e| e.kind == first).then_some(first)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(name: &str, kind: ItemKind, source_repo: &str) -> LockEntry {
        LockEntry {
            name: name.to_owned(),
            kind,
            harness: crate::model::HarnessId::Claude,
            source: "kendex".to_owned(),
            source_repo: source_repo.to_owned(),
            method: crate::manifest::Method::Copy,
            installed_at: "2026-01-01T00:00:00Z".to_owned(),
            source_hash: "x".to_owned(),
            source_commit: None,
            rendered_hash: None,
            enabled: true,
            upstream_skills: None,
            emitted: None,
            registration: None,
            reasons: std::collections::BTreeSet::from([crate::lock::Reason::Requested]),
        }
    }

    fn lock_of(entries: &[(&str, ItemKind, &str)]) -> Lock {
        let mut lock = Lock::default();
        for (name, kind, source_repo) in entries {
            lock.entries.insert(
                format!("{}:{name}:{source_repo}", kind.name()),
                entry(name, *kind, source_repo),
            );
        }
        lock
    }

    /// The lock records provenance for every kind of asset alike, so a skill
    /// recorded from the default repo routes upstream like an agent or hook.
    #[test]
    fn a_default_repo_entry_routes_upstream() {
        for (kind, label) in [
            (ItemKind::Hook, "harness"),
            (ItemKind::Skill, "skills"),
            (ItemKind::Agent, "skills"),
        ] {
            let lock = lock_of(&[("guard", kind, DEFAULT_UPSTREAM)]);
            let route = route(&lock, "guard", Some(kind), DEFAULT_UPSTREAM);
            assert!(route.kendex_owned, "{kind:?} from the default repo");
            assert_eq!(route.repo.as_deref(), Some(DEFAULT_UPSTREAM));
            assert_eq!(route.label.as_deref(), Some(label));
        }
    }

    /// Nothing in the lock says nothing about ownership, and the safe answer
    /// is the user's own repo.
    #[test]
    fn an_unlocked_name_stays_project_local() {
        let route = route(&Lock::default(), "mystery", None, DEFAULT_UPSTREAM);
        assert!(!route.kendex_owned);
        assert_eq!(route.repo, None);
        assert_eq!(route.label, None);
    }

    /// A skill installed from another marketplace keeps filing against the
    /// consumer's own repo.
    #[test]
    fn a_third_party_entry_stays_project_local() {
        let lock = lock_of(&[("guard", ItemKind::Skill, "someone/else")]);
        assert!(!route(&lock, "guard", Some(ItemKind::Skill), DEFAULT_UPSTREAM).kendex_owned);
    }

    /// A subscription spells its repo however it likes and the lock keeps
    /// that spelling, so ownership compares folded identities: the scp-style
    /// and `.git`-suffixed entries are the same repository as the shorthand,
    /// and a `--upstream` spelled either way matches too. Another host with
    /// the same path is another repository.
    #[test]
    fn a_differently_spelled_upstream_is_the_same_repository() {
        for spelling in [
            "git@github.com:vanillagreencom/kendex.git",
            "https://github.com/VanillaGreenCom/kendex",
            "vanillagreencom/kendex.git",
        ] {
            let lock = lock_of(&[("guard", ItemKind::Skill, spelling)]);
            let recorded = route(&lock, "guard", Some(ItemKind::Skill), DEFAULT_UPSTREAM);
            assert!(recorded.kendex_owned, "{spelling}");
            assert_eq!(recorded.label.as_deref(), Some("skills"), "{spelling}");

            // However the caller spells it, what comes back is what `gh
            // --repo` and an issue URL take.
            let named = route(&lock, "guard", Some(ItemKind::Skill), spelling);
            assert!(named.kendex_owned, "{spelling}");
            assert_eq!(named.repo.as_deref(), Some(DEFAULT_UPSTREAM), "{spelling}");
            assert_eq!(named.label.as_deref(), Some("skills"), "{spelling}");
        }

        let elsewhere = lock_of(&[(
            "guard",
            ItemKind::Skill,
            "https://gitlab.com/vanillagreencom/kendex",
        )]);
        assert!(!route(&elsewhere, "guard", Some(ItemKind::Skill), DEFAULT_UPSTREAM).kendex_owned);
    }

    /// Only a GitHub reference folds to `owner/repo`; another host has no
    /// shorthand, so the report files against the reference as spelled.
    #[test]
    fn another_hosts_upstream_is_the_target_as_spelled() {
        let lock = lock_of(&[(
            "guard",
            ItemKind::Skill,
            "https://gitlab.com/team/catalog.git",
        )]);
        let route = route(
            &lock,
            "guard",
            Some(ItemKind::Skill),
            "https://gitlab.com/team/catalog",
        );
        assert!(route.kendex_owned);
        assert_eq!(
            route.repo.as_deref(),
            Some("https://gitlab.com/team/catalog")
        );
        assert_eq!(route.label, None);
    }

    /// A named upstream routes there only when the lock recorded the asset
    /// from it; naming a repo is not by itself proof of ownership.
    #[test]
    fn a_named_upstream_must_match_recorded_provenance() {
        let lock = lock_of(&[("guard", ItemKind::Skill, "someone/else")]);
        let matched = route(&lock, "guard", Some(ItemKind::Skill), "someone/else");
        assert!(matched.kendex_owned);
        assert_eq!(matched.repo.as_deref(), Some("someone/else"));
        // Labels exist only on the canonical repo.
        assert_eq!(matched.label, None);
        assert!(!route(&Lock::default(), "guard", None, "someone/else").kendex_owned);
    }

    /// `--asset <name>` names no kind, so entries of every kind match it. A
    /// name shared with something from elsewhere is ambiguous and stays
    /// local; naming the kind resolves it.
    #[test]
    fn a_name_shared_with_another_origin_is_ambiguous() {
        let lock = lock_of(&[
            ("dev", ItemKind::Skill, DEFAULT_UPSTREAM),
            ("dev", ItemKind::Hook, "someone/else"),
        ]);
        assert!(!route(&lock, "dev", None, DEFAULT_UPSTREAM).kendex_owned);
        assert!(route(&lock, "dev", Some(ItemKind::Skill), DEFAULT_UPSTREAM).kendex_owned);
    }

    /// A kind-less report takes the kind its entries agree on, so it carries
    /// the same label a named kind would; disagreement leaves it unresolved.
    #[test]
    fn a_kindless_report_takes_the_kind_its_entries_agree_on() {
        let one_kind = lock_of(&[("dev", ItemKind::Skill, DEFAULT_UPSTREAM)]);
        let resolved = route(&one_kind, "dev", None, DEFAULT_UPSTREAM);
        assert_eq!(resolved.kind, Some(ItemKind::Skill));
        assert_eq!(resolved.label.as_deref(), Some("skills"));

        let mut two_kinds = one_kind;
        two_kinds.entries.insert(
            "hook:dev:claude".to_owned(),
            entry("dev", ItemKind::Hook, DEFAULT_UPSTREAM),
        );
        let unresolved = route(&two_kinds, "dev", None, DEFAULT_UPSTREAM);
        assert_eq!(unresolved.kind, None);
        assert_eq!(unresolved.label.as_deref(), Some("cli"));
    }

    #[test]
    fn a_committed_skill_render_routes_when_manifest_and_lock_cannot_answer() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("project");
        std::fs::create_dir_all(root.join(".agents/skills/guard")).unwrap();
        std::fs::write(
            root.join(".agents/skills/guard/SKILL.md"),
            "---\nname: guard\nmetadata:\n  repository: https://github.com/vanillagreencom/kendex\n---\n",
        )
        .unwrap();
        let env = crate::env::Env::fake(tmp.path(), crate::env::FakeOs::Linux);
        let resolved = resolve(
            &env,
            &crate::model::Scope::Project { root },
            "guard",
            Some(ItemKind::Skill),
            DEFAULT_UPSTREAM,
        );
        assert!(resolved.route.kendex_owned);
        assert_eq!(resolved.route.repo.as_deref(), Some(DEFAULT_UPSTREAM));
    }
}
