//! Scoring what is on disk, as opposed to what a plan would write.
//!
//! The other scoring path: the safety of what a tool would load if it
//! started this second, declared or not. Same rules as the plan-time pass,
//! different bytes. Advisory only — the rows inform the audit and every
//! package surface, and nothing acts on them.

use crate::env::Env;
use crate::error::Result;
use crate::model::Scope;

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
    let items: Vec<&crate::model::ObservedItem> = scan
        .items
        .iter()
        .filter(|item| item.vendor.is_none())
        .collect();
    Ok(items
        .iter()
        .zip(score_each(&items))
        .map(|(item, result)| ItemSafety {
            kind: item.kind,
            name: item.name.clone(),
            targets: vec![SafetyTarget {
                harness: item.harness,
                location: crate::paths::slashed(&item.path),
            }],
            scope: item.scope.clone(),
            advisory: result,
        })
        .collect())
}

/// Every observation's score, one reading per distinct set of bytes, spread
/// over the machine's cores.
///
/// Scoring is the slowest thing an audit does and the readings share
/// nothing, so they run side by side; `crate::parallel::map` hands them back
/// in the order they were given, which is the order the rows are built in.
fn score_each(items: &[&crate::model::ObservedItem]) -> Vec<crate::quality::AuditResult> {
    use crate::quality::observe::same_reading;
    let mut first = std::collections::HashMap::new();
    let mut distinct: Vec<&crate::model::ObservedItem> = Vec::new();
    let mut reading: Vec<usize> = Vec::with_capacity(items.len());
    for item in items {
        let at = *first.entry(same_reading(item)).or_insert_with(|| {
            distinct.push(item);
            distinct.len() - 1
        });
        reading.push(at);
    }
    let scored = crate::parallel::map(&distinct, |item| crate::quality::observe::score(item));
    reading.into_iter().map(|at| scored[at].clone()).collect()
}
