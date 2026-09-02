use std::process::ExitCode;

use kendex_core::engine::{
    DriftRow, DriftState, audit, planned_declarations, recorded_by_the_plan,
};
use kendex_core::env::Env;
use kendex_core::lock::{Lock, LockFile, load_file as load_lock_file, lock_path};
use kendex_core::manifest::{Manifest, ManifestFile, load as load_manifest, manifest_path};
use kendex_core::model::{ItemKind, Scope};

use super::engine_common::print_unmanaged;
use super::{fail, fail_refusal, note, resolve_scopes, say, scope_label};
use crate::scope::ScopeFilter;
use crate::ui;

/// Drift check over lock entries; non-zero exit on any failing row — this
/// is the signal consuming repos compose in shell pipelines.
///
/// Two things are named beside the rows without changing the count, which
/// is a count of lock entries and nothing else: content nothing manages,
/// and what a scope declares that its record does not hold.
///
/// One state closes the run non-zero on its own: a scope whose manifest
/// asks for items and whose install record is not there. That is the
/// state the lock version floor's move-it-aside remedy leaves, there is
/// nothing on disk to weigh a declaration against, and a count that leaves
/// such a scope out reads as a pass to the pipeline that composed it. A
/// record that is present and empty is a judged scope: it says nothing is
/// installed, and this verb agrees with it.
pub fn run(
    env: &Env,
    names: Vec<String>,
    filter: ScopeFilter,
) -> Result<ExitCode, Box<dyn std::error::Error>> {
    ui::intro("kendex verify");
    let mut checked = 0usize;
    let mut failed = 0usize;
    // What this run did not check, gathered across scopes and said once at
    // the end: a count of installations is only honest beside the content
    // that was never one.
    let mut unmanaged: Vec<DriftRow> = Vec::new();
    // What each scope declares that its record does not hold. The count is
    // of lock entries, so none of this reaches it, and a count printed
    // without them covers less than the scope does.
    let mut gaps: Vec<(Scope, Vec<(ItemKind, String)>)> = Vec::new();
    // Whether any scope's record was gone. Read at the end for the exit
    // code alone — the run already said which scope it was, where it found
    // it.
    let mut recordless = false;

    for scope in resolve_scopes(env, filter)? {
        let path = lock_path(env, &scope);
        // Absent and empty read alike through `load`, and here the
        // difference decides the verdict.
        let record = load_lock_file(&path)?;
        let absent = matches!(record, LockFile::Absent);
        let lock = match record {
            LockFile::Current(lock) => lock,
            LockFile::Absent => Lock::default(),
        };
        // One read of the manifest per scope, so the gate below and the
        // declarations printed at the end are one answer about one file.
        // Read twice, the two can disagree: a read that fails and then
        // succeeds on the retry left the gate saying the scope asked for
        // nothing while the line under it named what the scope asked for,
        // and the run closed green having checked none of it.
        let manifest = match load_manifest(&manifest_path(env, &scope)) {
            Ok(ManifestFile::Current(manifest)) => Some(manifest),
            Ok(ManifestFile::Absent) => None,
            // A file this build could not open is not a file declaring
            // nothing, and the gate never answers for one. It leaves by
            // the door a manifest break already leaves by, on that door's
            // terms: a line where there is nothing installed to misreport,
            // and the run's own error where there is.
            Err(error) if lock.entries.is_empty() => {
                fail_refusal(&format!("! {} not checked: ", scope_label(&scope)), &error);
                continue;
            }
            Err(error) => return Err(error.into()),
        };
        // The one state this run refuses, read off the manifest itself so
        // no source, catalog or expansion can change the answer.
        if absent && manifest.as_deref().is_some_and(declares_items) {
            fail(&format!(
                "! {}: no install record at {} — this scope was not checked",
                scope_label(&scope),
                path.display()
            ));
            recordless = true;
            continue;
        }
        // A scope with nothing installed has nothing to verify, and this
        // run reaches it only to name content nothing manages. That errand
        // never costs the run: a manifest this build cannot plan against
        // is worth a line, not a failure, and the exit code answers about
        // drift alone. A scope that does have installs fails loudly.
        let audited = {
            let _reading = ui::spinner(&format!("checking {}", scope_label(&scope)));
            audit(env, &scope)
        };
        let report = match (audited, lock.entries.is_empty()) {
            (Ok(report), _) => report,
            (Err(error), true) => {
                // The error picks its own door. A manifest that will not
                // parse names one finding per line and keeps those breaks;
                // every other failure here — unreadable TOML, a file that
                // would not open — is a sentence naming a path, and a break
                // in that path is content rather than a line of kendex's
                // own verdict.
                fail_refusal(&format!("! {} not checked: ", scope_label(&scope)), &error);
                continue;
            }
            (Err(error), false) => return Err(error.into()),
        };
        let declared = manifest
            .as_deref()
            .map(|manifest| declared_packages(env, &scope, manifest))
            .unwrap_or_default();
        unmanaged.extend(
            report
                .drift
                .iter()
                .filter(|row| row.state == DriftState::Unmanaged)
                .filter(|row| names.is_empty() || names.contains(&row.name))
                .cloned(),
        );
        // A kind the plan derives no entry for is missing from the record
        // whatever else it holds; one the plan does derive is missing only
        // while the record holds nothing at all.
        let gap: Vec<(ItemKind, String)> = declared
            .into_iter()
            .filter(|(_, name)| names.is_empty() || names.contains(name))
            .filter(|(kind, _)| !recorded_by_the_plan(*kind) || lock.entries.is_empty())
            .collect();
        if !gap.is_empty() {
            gaps.push((scope.clone(), gap));
        }
        if lock.entries.is_empty() {
            continue;
        }
        for entry in lock.entries.values() {
            if !names.is_empty() && !names.contains(&entry.name) {
                continue;
            }
            checked += 1;
            failed += usize::from(say_row(entry, &report));
        }
    }

    print_unmanaged(&unmanaged);
    print_gaps(&gaps);
    ui::ledger(&head(checked, failed, !gaps.is_empty()), &[]);
    Ok(match failed > 0 || recordless {
        true => ExitCode::FAILURE,
        false => ExitCode::SUCCESS,
    })
}

/// The line that closes the run: the count, or why there was none.
///
/// A scope whose declarations were named above is not a machine with
/// nothing installed on it, and saying so would close the run on the one
/// reading the reader came for.
fn head(checked: usize, failed: usize, named: bool) -> String {
    match (checked, named) {
        (0, true) => "nothing checked".to_owned(),
        (0, false) => "nothing installed".to_owned(),
        _ => format!(
            "{checked} checked, {} OK, {failed} failed",
            checked - failed
        ),
    }
}

/// What a scope asks to have installed, by kind and name.
///
/// [`planned_declarations`] is the engine's own answer to that question,
/// so a bundle counts as the members it brings in rather than as a name
/// the manifest happens to hold, and a scope whose only declaration is a
/// bundle is not read as asking for nothing. It costs one expansion pass,
/// which is less than the `audit` this verb already runs on every scope.
///
/// It does not answer for plugins, and the plugin table is added here
/// rather than there. A `PlannedDeclaration` carries an `ItemDecl`, which
/// names the source a package is read from; a plugin declares through
/// `[plugins.<key>]` with an enabled flag and a harness, and has no source
/// at all. Emitting one would mean inventing that field, and
/// `package::updates` feeds every planned declaration through an
/// evaluation built on it — the source's pin, the declaration's rev, the
/// package reference — so an invented source would put a row on the
/// Updates surface for a package that is not updated one at a time. The
/// engine's set stays what it is; this one is what `verify` asks about.
///
/// A declaration switched off is still a declaration. `enabled` rides on
/// the lock entry rather than deciding whether one exists — a disabled
/// agent installs and stays tracked — so the flag is not this function's
/// to read, and the engine's own predicate for keeping a record does not
/// read it either.
fn declared_packages(env: &Env, scope: &Scope, manifest: &Manifest) -> Vec<(ItemKind, String)> {
    planned_declarations(env, scope, manifest)
        .into_iter()
        .map(|declared| (declared.kind, declared.name))
        .chain(
            manifest
                .plugins
                .keys()
                .map(|name| (ItemKind::Plugin, name.clone())),
        )
        .collect()
}

/// Whether the scope's manifest asks for anything at all — every
/// declaration table, read as it sits.
///
/// The refusal binds to this rather than to the expanded plan. An
/// expansion asks a catalog what a bundle holds and what a skill requires,
/// and every way that read can come back short is a way the refusal would
/// stop firing on a scope that is still missing its record.
///
/// `Manifest::declared` covers six kinds; bundles and plugins each declare
/// through a table of their own and are asked for here.
fn declares_items(manifest: &Manifest) -> bool {
    ItemKind::ALL
        .iter()
        .any(|kind| !manifest.declared(*kind).is_empty())
        || !manifest.bundles.is_empty()
        || !manifest.plugins.is_empty()
}

/// What each scope declares that its record does not hold, said once at
/// the end beside the unmanaged rows. Not a verdict: the count above is of
/// lock entries and none of this is one.
///
/// One headline, because both kinds of gap are the same fact — a
/// declaration with no entry behind it — and what to do about each is not.
/// A Pi extension has no entry by design and no `apply` gives it one;
/// anything else is waiting on an `apply` that has not run. Each name
/// carries which it is, so the headline stays true of the whole list and
/// the reader still knows what to do with a row.
///
/// Every name, uncapped, and the cap rule stays stated in the one place
/// `print_unmanaged` states it. The list is the expanded closure, so one
/// `[bundles.x]` prints every member and everything those members require,
/// and a large set makes a long list; the names are what a reader looking
/// at an empty record came for.
fn print_gaps(scopes: &[(Scope, Vec<(ItemKind, String)>)]) {
    for (scope, items) in scopes {
        note(&format!(
            "{}: {} item{} declared and not in the install record",
            scope_label(scope),
            items.len(),
            if items.len() == 1 { "" } else { "s" }
        ));
        for (kind, name) in items {
            say(&format!(
                "  - {} {name} — {}",
                kind.name(),
                match recorded_by_the_plan(*kind) {
                    true => "kendex apply records it",
                    false => "no record ever holds one; kendex update-pi checks it",
                }
            ));
        }
    }
}

/// One locked installation's row, and whether it failed the run. The
/// headline is the verdict; anything the installation cannot do despite
/// matching its declaration is detail under it.
fn say_row(
    entry: &kendex_core::lock::LockEntry,
    report: &kendex_core::engine::EngineReport,
) -> bool {
    let problem = report.drift.iter().find(|row| {
        row.name == entry.name
            && row.kind == entry.kind
            && row.harness == entry.harness
            && matches!(
                row.state,
                DriftState::Missing | DriftState::Stale | DriftState::Conflict
            )
    });
    // Only genuine can't-build-it notes fail the row; advisory
    // render/parse warnings share the "{name}:" prefix and must not
    // read as an unavailable source.
    let unreachable_source = report.notes.iter().any(|n| {
        n.starts_with(&format!("{}:", entry.name))
            && (n.contains("— skipped")
                || n.contains("not found in source")
                || n.contains("unreadable"))
    });
    let kind = entry.kind.name();
    let name = &entry.name;
    let harness = entry.harness.name();
    let bad = match problem {
        Some(row) => {
            fail(&format!("✗ {kind} {name} [{harness}]: {}", row.detail));
            true
        }
        None if unreachable_source => {
            fail(&format!("✗ {kind} {name} [{harness}]: source unavailable"));
            true
        }
        None => {
            say(&format!("✓ {kind} {name} [{harness}]"));
            false
        }
    };
    // An installation can match its declaration exactly and still do
    // nothing — switched off machine-wide, outranked by a system file, or
    // advisory on this tool. That is not drift, so it does not fail the
    // run, but a pipeline must not read a clean tick where the thing
    // installed cannot act.
    for warning in report.warnings.iter().filter(|warning| {
        warning.kind == entry.kind
            && warning.name == entry.name
            && warning
                .harness
                .is_none_or(|harness| harness == entry.harness)
    }) {
        say(&format!("  ! {}", warning.message));
    }
    bad
}
