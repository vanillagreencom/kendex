use std::process::ExitCode;

use kendex_core::engine::{DriftRow, DriftState, audit};
use kendex_core::env::Env;
use kendex_core::lock::{load as load_lock, lock_path};

use super::engine_common::print_unmanaged;
use super::{fail, fail_refusal, resolve_scopes, say, scope_label};
use crate::scope::ScopeFilter;
use crate::ui;

/// Drift check over lock entries; non-zero exit on any failing row — this
/// is the signal consuming repos compose in shell pipelines. Content
/// nothing manages is named beside the rows, and never changes the count:
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
        ui::ledger("nothing installed", &[]);
        return Ok(ExitCode::SUCCESS);
    }
    print_unmanaged(&unmanaged);
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
