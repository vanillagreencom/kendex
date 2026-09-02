use std::process::ExitCode;

use kendex_core::engine::{DriftRow, DriftState, audit};
use kendex_core::env::Env;
use kendex_core::lock::{load as load_lock, lock_path};
use kendex_core::manifest::{ManifestFile, load as load_manifest, manifest_path};
use kendex_core::model::{ItemKind, Scope};

use super::engine_common::print_unmanaged;
use super::{fail, fail_refusal, note, resolve_scopes, say, scope_label};
use crate::scope::ScopeFilter;
use crate::ui;

/// Drift check over lock entries; non-zero exit on any failing row — this
/// is the signal consuming repos compose in shell pipelines. Content
/// nothing manages is named beside the rows, and so is a scope declaring
/// packages its install record holds none of; neither changes the count:
/// the count is the verdict and closes the run.
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
    // Scopes whose manifest asks for packages while their install record
    // holds none. Every check this run makes is a lock entry, so these
    // contribute nothing to the count, and a count printed without them
    // reports a smaller installation than the one on disk.
    let mut unrecorded: Vec<(Scope, Vec<(ItemKind, String)>)> = Vec::new();

    for scope in resolve_scopes(env, filter)? {
        let lock = load_lock(&lock_path(env, &scope))?;
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
        unmanaged.extend(
            report
                .drift
                .iter()
                .filter(|row| row.state == DriftState::Unmanaged)
                .filter(|row| names.is_empty() || names.contains(&row.name))
                .cloned(),
        );
        if lock.entries.is_empty() {
            let declared = declared_packages(env, &scope, &names)?;
            if !declared.is_empty() {
                unrecorded.push((scope.clone(), declared));
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

    if checked == 0 {
        print_unmanaged(&unmanaged);
        print_unrecorded(&unrecorded);
        // A scope declaring packages it could not check is not a machine
        // with nothing installed on it, and saying so would close the run
        // on the one reading the reader came for.
        ui::ledger(
            match unrecorded.is_empty() {
                true => "nothing installed",
                false => "nothing checked",
            },
            &[],
        );
        return Ok(ExitCode::SUCCESS);
    }
    print_unmanaged(&unmanaged);
    print_unrecorded(&unrecorded);
    ui::ledger(
        &format!(
            "{checked} checked, {} OK, {failed} failed",
            checked - failed
        ),
        &[],
    );
    Ok(if failed > 0 {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    })
}

/// What a scope's manifest asks to have installed, by kind and name, held
/// to the names the run was asked about. Read for a scope whose install
/// record holds nothing: the audit above says nothing about a declaration
/// no entry covers, and a Pi extension never gets an entry at all.
///
/// A declaration switched off asks for no installation, so its absence
/// from the record is the record being right.
fn declared_packages(
    env: &Env,
    scope: &Scope,
    names: &[String],
) -> Result<Vec<(ItemKind, String)>, Box<dyn std::error::Error>> {
    let ManifestFile::Current(manifest) = load_manifest(&manifest_path(env, scope))? else {
        return Ok(Vec::new());
    };
    let mut declared = Vec::new();
    for kind in ItemKind::ALL {
        for (name, decl) in manifest.declared(kind) {
            if !decl.enabled || (!names.is_empty() && !names.contains(name)) {
                continue;
            }
            declared.push((kind, name.clone()));
        }
    }
    Ok(declared)
}

/// Enough to recognise what went unchecked without burying the rows above
/// it.
const UNRECORDED_SHOWN: usize = 10;

/// The scopes that declare packages and have no install record to check
/// them against, said once at the end beside the unmanaged rows. Not a
/// verdict: the exit code answers about drift, and there is no drift to
/// read where there is nothing recorded to compare against.
fn print_unrecorded(scopes: &[(Scope, Vec<(ItemKind, String)>)]) {
    for (scope, items) in scopes {
        note(&format!(
            "{}: {} item{} declared, none in the install record and none checked",
            scope_label(scope),
            items.len(),
            if items.len() == 1 { "" } else { "s" }
        ));
        for (kind, name) in items.iter().take(UNRECORDED_SHOWN) {
            say(&format!("  - {} {name}", kind.name()));
        }
        if items.len() > UNRECORDED_SHOWN {
            say(&format!("  … and {} more", items.len() - UNRECORDED_SHOWN));
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
