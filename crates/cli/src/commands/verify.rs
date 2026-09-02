use std::process::ExitCode;

use kendex_core::engine::{
    DriftRow, DriftState, audit, planned_declarations, recorded_by_the_plan,
};
use kendex_core::env::Env;
use kendex_core::lock::{Lock, LockFile, load_file as load_lock_file, lock_path};
use kendex_core::manifest::{ManifestFile, load as load_manifest, manifest_path};
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
/// and packages of a kind the plan derives no entry for, which `kendex
/// update-pi` checks and this verb never can.
///
/// A scope asking for packages with no record at all is the third case and
/// it does close the run, non-zero. There is nothing there to weigh a
/// declaration against, and a count that leaves such a scope out reads as
/// a pass to the pipeline that composed it.
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
    // Packages of a kind the plan derives no lock entry for, gathered on
    // every scope whatever its record holds. No run of this verb checks
    // one, so a scope's count covers less than the scope does, and only
    // saying so makes the count readable.
    let mut outside: Vec<(Scope, Vec<(ItemKind, String)>)> = Vec::new();
    // Scopes holding a record with nothing in it while asking for packages
    // the plan does derive entries for. An apply resolves this; the lines
    // above cannot be resolved and are not meant to be.
    let mut unrecorded: Vec<(Scope, Vec<(ItemKind, String)>)> = Vec::new();
    // Whether any scope's record was gone. Set once, read at the end: the
    // run says which scope it was where it found it, and the exit code
    // carries it out.
    let mut unjudged = false;

    for scope in resolve_scopes(env, filter)? {
        let path = lock_path(env, &scope);
        // Absent and empty read alike through `load`, and this is the one
        // place the difference decides something.
        let record = load_lock_file(&path)?;
        let absent = matches!(record, LockFile::Absent);
        let lock = match record {
            LockFile::Current(lock) => lock,
            LockFile::Absent => Lock::default(),
        };
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
        // Read after the door above, so a manifest this build refuses still
        // leaves by that door rather than by this function's error.
        let declared = declared_packages(env, &scope)?;
        // Nothing on disk says what this scope should be holding, so every
        // count below would be a count of a scope this run never looked at.
        // A scope asking for nothing is not that — there is no record
        // because none was ever owed.
        if absent && !declared.is_empty() {
            fail(&format!(
                "! {}: no install record at {} — nothing in this scope was checked",
                scope_label(&scope),
                path.display()
            ));
            say("  to write one: kendex apply");
            unjudged = true;
            continue;
        }
        unmanaged.extend(
            report
                .drift
                .iter()
                .filter(|row| row.state == DriftState::Unmanaged)
                .filter(|row| names.is_empty() || names.contains(&row.name))
                .cloned(),
        );
        let (recordable, unrecordable): (Vec<_>, Vec<_>) = declared
            .into_iter()
            .filter(|(_, name)| names.is_empty() || names.contains(name))
            .partition(|(kind, _)| recorded_by_the_plan(*kind));
        if !unrecordable.is_empty() {
            outside.push((scope.clone(), unrecordable));
        }
        if lock.entries.is_empty() {
            if !recordable.is_empty() {
                unrecorded.push((scope.clone(), recordable));
            }
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
    print_declared(
        &outside,
        "the install record never holds — kendex update-pi checks those",
    );
    print_declared(
        &unrecorded,
        "declared and none in the install record — kendex apply writes it",
    );
    ui::ledger(
        &match checked {
            // A scope that asked for something is not a machine with
            // nothing installed on it, and saying so would close the run on
            // the one reading the reader came for.
            0 => match unjudged || !unrecorded.is_empty() || !outside.is_empty() {
                true => "nothing checked".to_owned(),
                false => "nothing installed".to_owned(),
            },
            _ => format!(
                "{checked} checked, {} OK, {failed} failed",
                checked - failed
            ),
        },
        &[],
    );
    Ok(match failed > 0 || unjudged {
        true => ExitCode::FAILURE,
        false => ExitCode::SUCCESS,
    })
}

/// What a scope asks to have installed, by kind and name.
///
/// [`planned_declarations`] is the engine's own answer to that question,
/// so a bundle counts as the members it brings in rather than as a name
/// the manifest happens to hold, and a scope whose only declaration is a
/// bundle is not read as asking for nothing. It costs one expansion pass,
/// which is less than the `audit` this verb already runs on every scope.
///
/// A declaration switched off is still a declaration. `enabled` rides on
/// the lock entry rather than deciding whether one exists — a disabled
/// agent installs and stays tracked — so the flag is not this function's
/// to read, and the engine's own predicate for keeping a record does not
/// read it either.
fn declared_packages(
    env: &Env,
    scope: &Scope,
) -> Result<Vec<(ItemKind, String)>, Box<dyn std::error::Error>> {
    let ManifestFile::Current(manifest) = load_manifest(&manifest_path(env, scope))? else {
        return Ok(Vec::new());
    };
    let mut declared: Vec<(ItemKind, String)> = planned_declarations(env, scope, &manifest)
        .into_iter()
        .map(|declared| (declared.kind, declared.name))
        .collect();
    // Plugins declare through `[plugins.<key>]` with only an enabled flag,
    // so `Manifest::declared` has no map to hand back for them and
    // `planned_declarations` has no closure to walk. The plan still derives
    // the toggle and records it, which makes a scope declaring only plugins
    // a scope asking for something.
    declared.extend(
        manifest
            .plugins
            .keys()
            .map(|name| (ItemKind::Plugin, name.clone())),
    );
    Ok(declared)
}

/// A scope's declarations said once at the end beside the unmanaged rows,
/// under a headline that names what is true of them. Not a verdict: the
/// count above is of lock entries, and neither of these lines has one to
/// contribute.
///
/// Every name, uncapped. What a person wrote in a manifest is bounded by
/// what they were willing to type, unlike the unmanaged content
/// `print_unmanaged` caps, and the cap rule stays stated in that one
/// place.
fn print_declared(scopes: &[(Scope, Vec<(ItemKind, String)>)], tail: &str) {
    for (scope, items) in scopes {
        note(&format!(
            "{}: {} item{} {tail}",
            scope_label(scope),
            items.len(),
            if items.len() == 1 { "" } else { "s" }
        ));
        for (kind, name) in items {
            say(&format!("  - {} {name}", kind.name()));
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
