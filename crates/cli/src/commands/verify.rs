use std::process::ExitCode;

use kendex_core::engine::{DriftRow, DriftState, audit};
use kendex_core::env::Env;
use kendex_core::lock::{load as load_lock, lock_path};

use super::engine_common::print_unmanaged;
use super::{resolve_scopes, say};
use crate::scope::ScopeFilter;

/// Drift check over lock entries; non-zero exit on any failing row — this
/// is the signal consuming repos compose in shell pipelines.
pub fn run(
    env: &Env,
    names: Vec<String>,
    filter: ScopeFilter,
) -> Result<ExitCode, Box<dyn std::error::Error>> {
    let mut checked = 0usize;
    let mut failed = 0usize;
    // What this run did not check, gathered across scopes and said once at
    // the end: a count of installations is only honest beside the content
    // that was never one.
    let mut unmanaged: Vec<DriftRow> = Vec::new();

    for scope in resolve_scopes(env, filter)? {
        let lock = load_lock(&lock_path(env, &scope))?;
        let report = audit(env, &scope)?;
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
            match problem {
                Some(row) => {
                    failed += 1;
                    say(&format!(
                        "✗ {} {} [{}]: {}",
                        entry.kind.name(),
                        entry.name,
                        entry.harness.name(),
                        row.detail
                    ));
                }
                None if unreachable_source => {
                    failed += 1;
                    say(&format!(
                        "✗ {} {} [{}]: source unavailable",
                        entry.kind.name(),
                        entry.name,
                        entry.harness.name()
                    ));
                }
                None => say(&format!(
                    "✓ {} {} [{}]",
                    entry.kind.name(),
                    entry.name,
                    entry.harness.name()
                )),
            }
            // An installation can match its declaration exactly and still do
            // nothing — switched off machine-wide, outranked by a system
            // file, or advisory on this tool. That is not drift, so it does
            // not fail the run, but a pipeline must not read a clean tick
            // where the thing installed cannot act.
            for warning in report.warnings.iter().filter(|warning| {
                warning.kind == entry.kind
                    && warning.name == entry.name
                    && warning
                        .harness
                        .is_none_or(|harness| harness == entry.harness)
            }) {
                say(&format!("  ! {}", warning.message));
            }
        }
    }

    if checked == 0 {
        say("nothing installed");
        print_unmanaged(&unmanaged);
        return Ok(ExitCode::SUCCESS);
    }
    say(&format!(
        "{checked} checked, {} OK, {failed} failed",
        checked - failed
    ));
    print_unmanaged(&unmanaged);
    Ok(if failed > 0 {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    })
}
