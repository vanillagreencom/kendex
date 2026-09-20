//! A package seen through its versions: the commits that changed its own
//! files, up to what its source tracks right now, and what a version
//! selector resolves to. A projection over the mirror and the lock —
//! nothing here writes.

use serde::Serialize;
use specta::Type;

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::{ItemKind, Scope};
use crate::remote::history;

use super::{package_ref, resolve_selector};

/// One version of a package: a commit that changed its files, wearing any
/// tag names that point at it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct VersionRow {
    /// Full commit id.
    pub id: String,
    /// The release name, when a tag points at this commit.
    pub label: Option<String>,
    /// ISO-8601 committer date.
    pub date: String,
    pub summary: String,
    /// This is the content revision the installed package holds.
    pub installed: bool,
    pub newer_than_installed: bool,
}

/// The package's timeline, newest first: every commit that changed its
/// files up to the source's tracked tip. Tags decorate the timeline, they
/// never replace it — a repository's tags may live far from this package.
/// The installed marker lands on the newest content commit at-or-before
/// the locked source commit, because an installed commit that changed
/// other files is not itself on this package's timeline.
pub fn versions(env: &Env, scope: &Scope, kind: ItemKind, name: &str) -> Result<Vec<VersionRow>> {
    let manifest = crate::engine::ops::manifest_for_mutation(env, scope)?;
    let package = package_ref(env, scope, &manifest, kind, name)?;
    let log = history::subtree_log(&package.mirror, &package.tip, &package.subtree)?;
    let lock = crate::lock::load(&crate::lock::lock_path(env, scope))?;
    // The mirror just proved readable; a lock commit that still cannot be
    // mapped costs the installed marker, never the timeline the mirror can
    // perfectly well render.
    let installed_commit = installed_commit(&lock, kind, name).and_then(|commit| {
        history::last_content_commit(&package.mirror, &commit, &package.subtree)
            .ok()
            .flatten()
    });
    let installed_at = log
        .iter()
        .position(|row| Some(&row.commit) == installed_commit.as_ref());
    Ok(log
        .into_iter()
        .enumerate()
        .map(|(index, row)| VersionRow {
            installed: Some(index) == installed_at,
            newer_than_installed: installed_at.is_some_and(|installed| index < installed),
            id: row.commit,
            label: row.tags.first().cloned(),
            date: row.date,
            summary: row.summary,
        })
        .collect())
}

/// The source commit this package's installations were produced from —
/// `None` when no harness has it installed yet or the lock predates the
/// record. Installations that disagree (mid-apply, or a partial refresh)
/// answer with the newest record's value, and the updates projection flags
/// the disagreement separately. When a record was made is this machine's
/// half of it; a clone holding none of those reads them as equally old,
/// which on a clone they are, and among equally old records the one
/// keyed last answers.
fn installed_commit(lock: &crate::lock::Lock, kind: ItemKind, name: &str) -> Option<String> {
    lock.entries
        .values()
        .filter(|entry| entry.kind == kind && entry.name == name)
        .filter(|entry| entry.source_commit.is_some())
        .max_by_key(|entry| entry.machine.as_ref().map(|machine| &machine.installed_at))
        .and_then(|entry| entry.source_commit.clone())
}

/// A version selector as a commit id: whatever the repository can name —
/// tag, branch, commit — resolved against this item's source. The cache
/// answers first; the network fills in what it cannot.
pub fn resolve_version(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    selector: &str,
) -> Result<String> {
    let manifest = crate::engine::ops::manifest_for_mutation(env, scope)?;
    let Some(decl) = manifest.declared(kind).get(name) else {
        return Err(CoreError::NotDeclared {
            kind,
            name: name.to_owned(),
        });
    };
    let Some(repo) = manifest
        .sources
        .get(&decl.source)
        .and_then(|s| s.repo.clone())
    else {
        return Err(CoreError::ItemRevUnsupported {
            source_name: decl.source.clone(),
        });
    };
    Ok(resolve_selector(env, &repo, selector)?.commit)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lock::{LOCK_VERSION, Lock, LockEntry, MachineRecord, Reason, entry_key};
    use crate::manifest::Method;
    use crate::model::HarnessId;
    use std::collections::BTreeSet;

    fn recorded(
        harness: HarnessId,
        commit: &str,
        installed_at: Option<&str>,
    ) -> (String, LockEntry) {
        (
            entry_key(ItemKind::Skill, "gh", harness),
            LockEntry {
                registration: None,
                name: "gh".into(),
                kind: ItemKind::Skill,
                harness,
                source: "cat".into(),
                source_repo: "owner/catalog".into(),
                machine: installed_at.map(|at| MachineRecord {
                    method: Method::Symlink,
                    installed_at: at.to_owned(),
                }),
                source_hash: "abc".into(),
                source_commit: Some(commit.to_owned()),
                rendered_hash: None,
                enabled: true,
                upstream_skills: None,
                emitted: None,
                reasons: BTreeSet::from([Reason::Requested]),
            },
        )
    }

    /// One row per state this machine's half can be in for two records
    /// that disagree: with it, the newer record answers whichever key it
    /// sits under; without it — a clone, a cleared cache — the records
    /// are equally old and the one keyed last answers.
    #[test]
    fn the_installed_commit_is_the_newest_record_or_the_last_keyed_one_in_a_clone() {
        for (label, claude_at, codex_at, answer) in [
            (
                "the machine half present",
                Some("2026-02-02T00:00:00Z"),
                Some("2026-01-01T00:00:00Z"),
                "aaa",
            ),
            ("the machine half gone", None, None, "bbb"),
        ] {
            let mut lock = Lock {
                version: LOCK_VERSION,
                ..Lock::default()
            };
            lock.entries.extend([
                recorded(HarnessId::Claude, "aaa", claude_at),
                recorded(HarnessId::Codex, "bbb", codex_at),
            ]);
            assert_eq!(
                installed_commit(&lock, ItemKind::Skill, "gh").as_deref(),
                Some(answer),
                "{label}"
            );
        }
    }
}
