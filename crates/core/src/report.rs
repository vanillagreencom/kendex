//! Report routing: which repo an issue about an installed item belongs to.
//! The lock is the one judge, and it records where every kind of asset came
//! from, skills included. An item whose every lock entry was recorded from
//! the upstream files there; everything else files against the user's own
//! repo, the safe default. A name whose entries disagree about their origin
//! is ambiguous, and an ambiguous name stays local.
//!
//! A lock entry keeps the manifest's repo declaration verbatim, so the same
//! repository arrives here spelled as a shorthand, an https URL or an scp
//! `git@` one. Every comparison runs over `source_ref::repo_identity`, which
//! folds those to one string, so a spelling never decides ownership. The
//! judge names the destination too, in the shape a caller can file against:
//! `gh issue create --repo` and a `github.com/<repo>/issues/new` URL both
//! take `owner/repo`, never the URL a subscription may be spelled with.

use crate::lock::{Lock, LockEntry};
use crate::model::ItemKind;
use crate::source_ref::{owner_repo, repo_identity};

pub const DEFAULT_UPSTREAM: &str = crate::manifest::DEFAULT_SOURCE_REPO;

/// What the lock recorded about where the reported asset came from, so a
/// triager can date a report against the fix that already landed. The
/// lock keys an installation per harness, and each half states what those
/// entries agree on: one name at two commits dates nothing at all, while
/// one name rendered two ways is still dated and simply claims no
/// rendering.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Provenance {
    /// `<repo>@<commit7>`, the repo spelled the way a lookup takes it.
    pub source: String,
    /// The first seven characters of what the apply wrote, where the
    /// entries recorded one and agree on it.
    pub rendered: Option<String>,
}

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
    /// Where the matching entries agree the bytes came from. `None` when
    /// nothing dated them, when they name different commits, or when the
    /// kind itself is unresolved: an installation nothing dated cannot be
    /// dated after the fact, and a guess would be read as a date.
    pub provenance: Option<Provenance>,
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
    Route {
        kendex_owned: owned,
        repo: owned.then(|| filing_target(upstream)),
        label: (owned && wanted == repo_identity(DEFAULT_UPSTREAM))
            .then(|| derive_label(name, kind).to_owned()),
        kind,
        provenance: provenance(&matching, kind),
    }
}

/// What the dated matching entries agree they came from, the way ownership
/// and `agreed_kind` decide: disagreement answers nothing rather than
/// picking one. The lock keys an installation per harness, so one name is
/// several entries that can sit at different commits and hold different
/// renderings, and a marker naming one of them would date the report
/// against an install it did not come from. An unresolved kind is that
/// same disagreement one level up — the resolved kind is the kind every
/// matching entry has, or there is none — so it dates nothing either.
fn provenance(matching: &[&LockEntry], kind: Option<ItemKind>) -> Option<Provenance> {
    kind?;
    // Whole values, agreed whole and cut short only on the way out: two
    // commits sharing seven characters are two commits. A dated entry the
    // marker cannot use — an unusable repo, a value that is no hash —
    // answers `None` rather than dropping out, because dropping it would
    // leave a sibling's commit standing as the only one. Only an entry
    // that recorded nothing is silent, which is what the `?` is for.
    let dated: Vec<Recorded> = matching
        .iter()
        .filter_map(|entry| {
            let commit = entry.source_commit.as_deref()?;
            Some(Recorded {
                origin: marker_repo(&entry.source_repo).zip(hash_shaped(commit)),
                rendered: entry.rendered_hash.as_deref().and_then(hash_shaped),
            })
        })
        .collect();
    let (repo, commit) = agreed(dated.iter().map(|entry| &entry.origin))?.clone()?;
    Some(Provenance {
        source: format!("{repo}@{}", short(&commit)),
        // Independently: renderings differ per harness and per project at
        // one commit, and a disagreement there is no reason to withhold
        // the commit itself.
        rendered: agreed(dated.iter().map(|entry| &entry.rendered))
            .cloned()
            .flatten()
            .map(|rendered| short(&rendered)),
    })
}

/// One dated entry as the marker would carry it, whole. Either half is
/// `None` where the entry recorded something the marker cannot use, which
/// is a value the others have to agree with, not an absence.
struct Recorded {
    /// The repo it came from and the commit it came from, both usable.
    origin: Option<(String, String)>,
    rendered: Option<String>,
}

/// The one value every entry gives, or `None` when they disagree or there
/// are none.
fn agreed<T: PartialEq>(mut values: impl Iterator<Item = T>) -> Option<T> {
    let first = values.next()?;
    values.all(|value| value == first).then_some(first)
}

/// A recorded value, whole, when it is shaped like the hash it claims to
/// be: hex, and no shorter than what the marker quotes nor longer than a
/// sha256. The lock is a file anyone can edit and the marker lands in a
/// public issue body, so nothing else travels — a value holding `-->`
/// would end the comment early and take the rest of the marker with it,
/// and one shorter than seven characters would be quoted whole while
/// reading as a prefix.
fn hash_shaped(recorded: &str) -> Option<String> {
    let width = (SHORT..=64).contains(&recorded.chars().count());
    (width && recorded.chars().all(|c| c.is_ascii_hexdigit())).then(|| recorded.to_owned())
}

/// How much of a hash the marker quotes.
const SHORT: usize = 7;

/// A hash as the marker carries it.
fn short(hash: &str) -> String {
    hash.chars().take(SHORT).collect()
}

/// The entry's repo as a marker can carry it: the filing target, and only
/// when every character of it is one a repo reference is spelled with.
/// `filing_target` hands back what the lock holds when it is no GitHub
/// reference, and the marker is space-delimited inside an HTML comment.
fn marker_repo(source_repo: &str) -> Option<String> {
    let target = filing_target(source_repo);
    let spellable = !target.is_empty()
        && target
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '/' | ':'));
    spellable.then_some(target)
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
mod tests;
