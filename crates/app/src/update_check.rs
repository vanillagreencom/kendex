//! The Updates page's standing: what has a newer version, how old the
//! reading is, and which packages are muted — thin shells over core, like
//! every other command here.

use kendex_core::env::Env;
use kendex_core::model::{ItemKind, Scope};
use kendex_core::package::updates;
use kendex_core::{manifest, remote};

use crate::scopes::{all as all_scopes, env};

/// Every scope's update standing in one query — the sidebar badge, the
/// Updates page, and the Library's fork/edited flags all read this. Rows
/// carry the facts; warnings carry every package the standing could not be
/// computed for, which is never silently shown as current.
#[tauri::command(async)]
#[specta::specta]
pub fn updates_overview() -> Result<updates::UpdatesReport, String> {
    let env = env()?;
    Ok(overview(&env, &all_scopes(&env)?))
}

/// The standing across the scopes given, with a scope kendex cannot read
/// carried in `unreadable` rather than failing the whole query.
///
/// A lock or manifest this build refuses belongs to one place. Bubbled
/// up, it would leave the page with no rows at all and the sidebar with a
/// bare "?" while every other place's standing is known, so the scope is
/// carried as data instead, the way [`crate::audit::AuditView`] carries
/// its own.
/// Only as far as the message, though: an `AuditView` also carries a typed
/// [`crate::audit::ScopeErrorKind`], and a surface wanting to word a
/// corrupt lock differently from one whose schema is too recent reads that on the Problems
/// page rather than parsing the prose here.
pub fn overview(env: &Env, scopes: &[Scope]) -> updates::UpdatesReport {
    let mut reports = Vec::new();
    let mut unreadable = Vec::new();
    for scope in scopes {
        let mut report = match updates::updates(env, scope) {
            Ok(report) => report,
            Err(error) => {
                unreadable.push(updates::UnreadableScope {
                    scope: scope.clone(),
                    message: error.to_string(),
                });
                continue;
            }
        };
        // The deep work just ran; the session-start check reads this. A
        // failure is a warning on the page, never silence — the CLI paths
        // say the same thing.
        if let Err(error) = kendex_core::drift::snapshot::record_with(env, scope, &report) {
            report.warnings.push(kendex_core::engine::ItemWarning {
                kind: kendex_core::model::ItemKind::Skill,
                name: scope.label(),
                harness: None,
                message: format!("drift snapshot not derived: {error}"),
                remediation: None,
            });
        }
        reports.push(report);
    }
    let mut merged = merge(reports);
    merged.unreadable = unreadable;
    merged
}

/// Fold every scope's standing into the one view the page draws.
///
/// One page, one age: the rows are drawn together under a single hint, and
/// it says when this view last reached the network at all — the newest of
/// the scopes, the same reading a single scope takes across its own
/// mirrors. A scope that has never fetched holds no opinion rather than
/// dragging the whole page to never-checked while another fetched minutes
/// ago.
fn merge(reports: impl IntoIterator<Item = updates::UpdatesReport>) -> updates::UpdatesReport {
    let mut merged = updates::UpdatesReport {
        rows: Vec::new(),
        warnings: Vec::new(),
        unreadable: Vec::new(),
        last_fetched: None,
    };
    for report in reports {
        merged.last_fetched = merged.last_fetched.max(report.last_fetched);
        merged.rows.extend(report.rows);
        merged.warnings.extend(report.warnings);
    }
    merged
}

/// Fetch every source's mirror — pinned ones included, that is the point —
/// then answer with the fresh standing. Fetch problems degrade to
/// warnings; a check for updates is never worth an error dialog.
#[tauri::command(async)]
#[specta::specta]
pub fn updates_refresh() -> Result<updates::UpdatesReport, String> {
    let env = env()?;
    for scope in all_scopes(&env)? {
        let path = manifest::manifest_path(&env, &scope);
        if let Ok(Some(loaded)) = manifest::load_for_mutation(&path) {
            let _warnings = remote::fetch_all(&env, &loaded);
        }
    }
    updates_overview()
}

#[tauri::command(async)]
#[specta::specta]
pub fn update_set_ignored(
    scope: Scope,
    kind: ItemKind,
    name: String,
    repo: String,
    ignored: bool,
) -> Result<updates::UpdatesReport, String> {
    let env = env()?;
    updates::set_ignored(&env, &scope, kind, &name, &repo, ignored).map_err(|e| e.to_string())?;
    updates_overview()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dated(last_fetched: Option<u32>) -> updates::UpdatesReport {
        updates::UpdatesReport {
            rows: Vec::new(),
            warnings: Vec::new(),
            unreadable: Vec::new(),
            last_fetched,
        }
    }

    /// The scopes are drawn together under one hint, so it answers when this
    /// view last reached the network: the newest of them. A project just
    /// registered, or one whose sources are all local paths, has never
    /// fetched, and global is folded first, so an oldest-wins rule would let
    /// that scope drag the header to "Not checked for updates yet" while
    /// every other scope fetched minutes ago; nothing fetched anywhere says
    /// so rather than naming an instant. One row per shape of scope list.
    #[test]
    fn the_page_is_dated_by_the_newest_scope_that_fetched() {
        type Row<'a> = (&'a str, Vec<Option<u32>>, Option<u32>);
        let rows: [Row; 5] = [
            (
                "the newest of three",
                vec![Some(1_000), Some(2_000), Some(1_500)],
                Some(2_000),
            ),
            (
                "an unfetched scope after a fetched one",
                vec![Some(2_000), None],
                Some(2_000),
            ),
            (
                "an unfetched scope before a fetched one",
                vec![None, Some(2_000)],
                Some(2_000),
            ),
            ("every scope unfetched", vec![None, None], None),
            ("no scope at all", vec![], None),
        ];
        for (what, scopes, expected) in rows {
            assert_eq!(
                merge(scopes.into_iter().map(dated)).last_fetched,
                expected,
                "{what}"
            );
        }
    }
}
