//! Scoring what is on disk, as opposed to what a plan would write.
//!
//! The other scoring path: the safety of what a tool would load if it
//! started this second, declared or not. Same rules as the plan-time pass,
//! different bytes. Advisory only — the rows inform the audit and every
//! package surface, and nothing acts on them.

use std::collections::{BTreeMap, HashMap};

use crate::env::Env;
use crate::error::Result;
use crate::lock::{LockEntry, LockFile};
use crate::model::{ObservedItem, Scope};
use crate::quality::Publisher;

use super::scoring::{ItemSafety, SafetyTarget};

/// Every installation in this scope, scored — the clean ones included, so
/// a package with nothing found still has a score to show.
pub fn observed_rows(env: &Env, scope: &Scope) -> Result<Vec<ItemSafety>> {
    let scope = scope.canonical();
    let settings = crate::settings::load(env)?;
    let scan = crate::scan::scan_scopes(env, &settings.harness_roots, std::slice::from_ref(&scope));
    // Content a tool ships itself is that tool's to answer for: the reader
    // never chose it and cannot change it, so an audit that reports it is
    // asking them about software they did not install.
    let items: Vec<&ObservedItem> = scan
        .items
        .iter()
        .filter(|item| item.vendor.is_none())
        .collect();
    let publishers = publishers(env, &scope, &items)?;
    Ok(items
        .iter()
        .zip(score_each(&items, &publishers))
        .map(|(item, result)| ItemSafety {
            kind: item.kind,
            name: item.name.clone(),
            targets: vec![SafetyTarget {
                harness: item.harness,
                location: crate::paths::slashed(&item.path),
            }],
            scope: item.scope.clone(),
            // Installed bytes are the artifact itself: the finding's own
            // location is already the file a reader opens.
            source: None,
            advisory: result,
        })
        .collect())
}

/// Whose catalog each installation came from, as the scope's record says.
///
/// The bytes at one path are one installation whichever tool reads them:
/// a skill tree under the shared directory is observed once per adapter
/// that reads it, while the record holds one row per declared tool, so
/// the rows that wrote the observed path (`emitted`) answer for every
/// observation of it, and only where all of them name kendex is it
/// kendex's. A kind that records no paths (an agent, a hook, a server, a
/// plugin) lands at a place of its own per tool, so its row is the one
/// keyed by the observing tool. An installation no row accounts for is
/// nobody's, which is what a hand-placed copy is. An absent record names
/// nothing; one this build refuses is refused here too, as the audit over
/// the same scope refuses it.
fn publishers(env: &Env, scope: &Scope, items: &[&ObservedItem]) -> Result<Vec<Publisher>> {
    let entries: BTreeMap<String, LockEntry> =
        match crate::lock::load_file(&super::lock_path(env, scope))? {
            LockFile::Absent => BTreeMap::new(),
            LockFile::Current(lock) => lock.entries,
        };
    Ok(items
        .iter()
        .map(|item| {
            let wrote_it: Vec<Publisher> = entries
                .values()
                .filter(|entry| {
                    entry
                        .emitted
                        .as_ref()
                        .is_some_and(|emitted| emitted.paths.contains(&item.path))
                })
                .map(|entry| Publisher::of(&entry.source_repo))
                .collect();
            if !wrote_it.is_empty() {
                return match wrote_it.iter().all(|owner| *owner == Publisher::Kendex) {
                    true => Publisher::Kendex,
                    false => Publisher::Other,
                };
            }
            // Only a row that recorded no paths answers by the observing
            // tool's key: a row that did record them, and does not name
            // this path, wrote somewhere else, and what sits here is a
            // copy it does not account for.
            entries
                .get(&crate::lock::entry_key(item.kind, &item.name, item.harness))
                .filter(|entry| entry.emitted.is_none())
                .map_or(Publisher::Other, |entry| Publisher::of(&entry.source_repo))
        })
        .collect())
}

/// Every observation's score, one reading per distinct set of bytes, spread
/// over the machine's cores.
///
/// Scoring is the slowest thing an audit does and the readings share
/// nothing, so they run side by side; `crate::parallel::map` hands them back
/// in the order they were given, which is the order the rows are built in.
fn score_each(
    items: &[&ObservedItem],
    publishers: &[Publisher],
) -> Vec<crate::quality::AuditResult> {
    use crate::quality::observe::same_reading;
    let mut first = HashMap::new();
    let mut distinct: Vec<(&ObservedItem, Publisher)> = Vec::new();
    let mut reading: Vec<usize> = Vec::with_capacity(items.len());
    for (item, publisher) in items.iter().zip(publishers) {
        let at = *first
            .entry(same_reading(item, *publisher))
            .or_insert_with(|| {
                distinct.push((item, *publisher));
                distinct.len() - 1
            });
        reading.push(at);
    }
    let scored = crate::parallel::map(&distinct, |(item, publisher)| {
        crate::quality::observe::score(item, *publisher)
    });
    reading.into_iter().map(|at| scored[at].clone()).collect()
}
