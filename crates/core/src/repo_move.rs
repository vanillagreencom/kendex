//! The default catalog moved repositories (vanillagreencom/vstack →
//! vanillagreencom/kendex). A scope still naming the old repository is
//! planned as if it already named the new one, and the plan's own writes
//! record the move — the manifest in one write, the lock in one write. The
//! rewrite covers every place the repo string lives: leaving any one of
//! them behind makes the next plan read each installed package as
//! "installed from A but now set to come from B", a conflict per package.

use crate::lock::Lock;
use crate::manifest::{DEFAULT_SOURCE_REPO, LEGACY_SOURCE_REPO, Manifest};

/// The migration write's name in the plan preview.
pub const MOVE_DESCRIPTION: &str = "Point kendex at its new repository";

/// The `owner/repo` a GitHub reference names, in every shape a manifest
/// can carry: the shorthand kendex seeds, an `https`/`http` URL with or
/// without `www.`, an scp-style `git@`, or an `ssh://git@` URL — folded to
/// lowercase, because hosts and GitHub paths are case-insensitive. The
/// endings that say nothing about which repository it is — a trailing
/// slash, a `.git` suffix — are ignored, as the store's key already does.
/// `None` for another host or another shape: a missed spelling here reads
/// as a per-package source rebind, so matching must be by what the string
/// names, never by a list of literal spellings.
/// The public spelling of the normalization for callers outside this
/// module — the Community tab matches directory rows against existing
/// subscriptions by what the string names, never by literal spellings.
/// The moved default folds to its new key: a scope still declaring the
/// old repository subscribes to the same catalog the directory lists
/// under the new one, and every side that matches keys must say so.
pub fn owner_repo(reference: &str) -> Option<String> {
    github_owner_repo(canonical(reference))
}

pub(crate) fn github_owner_repo(reference: &str) -> Option<String> {
    let lower = reference.trim().to_ascii_lowercase();
    let trimmed = lower.trim_end_matches('/');
    let trimmed = trimmed.strip_suffix(".git").unwrap_or(trimmed);
    let path = if let Some(rest) = ["https://", "http://", "ssh://git@"]
        .iter()
        .find_map(|scheme| trimmed.strip_prefix(scheme))
    {
        rest.strip_prefix("www.")
            .unwrap_or(rest)
            .strip_prefix("github.com/")?
    } else if let Some(rest) = trimmed.strip_prefix("git@github.com:") {
        rest
    } else if trimmed.contains(':') || trimmed.contains('@') {
        return None;
    } else {
        trimmed
    };
    let mut parts = path.split('/');
    let (owner, repo) = (parts.next()?, parts.next()?);
    (parts.next().is_none() && !owner.is_empty() && !repo.is_empty())
        .then(|| format!("{owner}/{repo}"))
}

/// Whether a repo string names the moved repository, in any spelling.
pub fn names_old_default(repo: &str) -> bool {
    github_owner_repo(repo).as_deref() == Some(LEGACY_SOURCE_REPO)
}

/// A repo string with the moved default spelled the one way the rest of
/// kendex knows it. Anything else passes through unchanged, so exact
/// comparison of two canonical strings still separates unrelated repos.
pub fn canonical(repo: &str) -> &str {
    match names_old_default(repo) {
        true => DEFAULT_SOURCE_REPO,
        false => repo,
    }
}

/// Whether two repo strings name the same repository once the moved
/// default's spellings collapse: a record written before the move still
/// matches an entry the migration rewrote, and the other way round.
pub fn same_repo(a: &str, b: &str) -> bool {
    canonical(a) == canonical(b)
}

fn rewrite(repo: &mut String, changed: &mut bool) {
    if names_old_default(repo) {
        *repo = DEFAULT_SOURCE_REPO.to_owned();
        *changed = true;
    }
}

/// The manifest with every old-default repo string rewritten — source
/// declarations and fork provenance. Source *names* stay: a scope that
/// declared `[sources.vstack]` keeps that name, only the repository it
/// points at moves. `None` when nothing names the old repository.
pub fn migrate_manifest(manifest: &Manifest) -> Option<Manifest> {
    let mut migrated = manifest.clone();
    let mut changed = false;
    for decl in migrated.sources.values_mut() {
        if let Some(repo) = decl.repo.as_mut() {
            rewrite(repo, &mut changed);
        }
    }
    for forks in migrated.forks.values_mut() {
        for provenance in forks.values_mut() {
            if let Some(repo) = provenance.repo.as_mut() {
                rewrite(repo, &mut changed);
            }
        }
    }
    changed.then_some(migrated)
}

/// The lock with every old-default repo string rewritten — the per-source
/// revision records and every entry's provenance. `None` when nothing
/// names the old repository.
pub fn migrate_lock(lock: &Lock) -> Option<Lock> {
    let mut migrated = lock.clone();
    let mut changed = false;
    for revision in migrated.sources.values_mut() {
        rewrite(&mut revision.repo, &mut changed);
    }
    for entry in migrated.entries.values_mut() {
        rewrite(&mut entry.source_repo, &mut changed);
    }
    changed.then_some(migrated)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_spelling_of_the_old_repository_is_recognized() {
        assert!(names_old_default("vanillagreencom/vstack"));
        assert!(names_old_default(
            "https://github.com/vanillagreencom/vstack"
        ));
        assert!(names_old_default(
            "https://github.com/vanillagreencom/vstack.git"
        ));
        assert!(names_old_default(
            "http://github.com/vanillagreencom/vstack"
        ));
        assert!(names_old_default(
            "https://www.github.com/vanillagreencom/vstack/"
        ));
        assert!(names_old_default(
            "git@github.com:vanillagreencom/vstack.git"
        ));
        assert!(names_old_default(
            "ssh://git@github.com/vanillagreencom/vstack.git"
        ));
        assert!(names_old_default("VanillaGreenCom/VStack"));
        assert!(names_old_default(
            "https://GitHub.com/vanillagreencom/vstack"
        ));
        assert!(!names_old_default("vanillagreencom/kendex"));
        assert!(!names_old_default("someone/vstack"));
        assert!(!names_old_default(
            "https://gitlab.com/vanillagreencom/vstack"
        ));
        assert!(!names_old_default("git@example.com:vanillagreencom/vstack"));
        // A substring is a different repository, never a match.
        assert!(!names_old_default("vanillagreencom/vstack-extras"));
        assert!(!names_old_default("vanillagreencom/vstack2"));
    }

    #[test]
    fn the_public_key_of_the_moved_default_is_its_new_repository() {
        assert_eq!(
            owner_repo("git@github.com:VanillaGreenCom/vstack.git").as_deref(),
            Some(DEFAULT_SOURCE_REPO)
        );
        assert_eq!(
            owner_repo("someone/vstack").as_deref(),
            Some("someone/vstack")
        );
    }

    #[test]
    fn canonical_collapses_only_the_moved_default() {
        assert_eq!(canonical("vanillagreencom/vstack"), DEFAULT_SOURCE_REPO);
        assert_eq!(
            canonical("git@github.com:VanillaGreenCom/vstack.git"),
            DEFAULT_SOURCE_REPO
        );
        assert_eq!(canonical("someone/vstack"), "someone/vstack");
        assert!(same_repo(
            "https://github.com/vanillagreencom/vstack",
            DEFAULT_SOURCE_REPO
        ));
        assert!(same_repo(DEFAULT_SOURCE_REPO, "vanillagreencom/vstack"));
        assert!(!same_repo("someone/vstack", DEFAULT_SOURCE_REPO));
    }

    #[test]
    fn a_manifest_without_the_old_repository_is_untouched() {
        assert_eq!(migrate_manifest(&crate::manifest::seed(&[])), None);
        assert_eq!(migrate_lock(&Lock::default()), None);
    }
}
