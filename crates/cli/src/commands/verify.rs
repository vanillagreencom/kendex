use std::process::ExitCode;

use kendex_core::engine::{
    DriftRow, DriftState, ShimStanding, audit, audit_without_record, planned_declarations,
};
use kendex_core::env::Env;
use kendex_core::lock::{Lock, LockFile, load_file as load_lock_file, lock_path};
use kendex_core::manifest::{Manifest, ManifestFile, load as load_manifest, manifest_path};
use kendex_core::model::{ItemKind, Scope};

use super::engine_common::print_unmanaged;
use super::{fail, fail_refusal, note, resolve_scopes, say, scope_label};
use crate::scope::ScopeFilter;
use crate::ui;

struct VerifyAudit {
    report: kendex_core::engine::EngineReport,
    matching: Option<Lock>,
}

struct RecordRead {
    lock: Lock,
    fallback: bool,
    problem: Option<String>,
}

fn read_record(path: &std::path::Path) -> RecordRead {
    match load_lock_file(path) {
        Ok(LockFile::Current(lock)) => RecordRead {
            lock,
            fallback: false,
            problem: None,
        },
        Ok(LockFile::Absent) => RecordRead {
            lock: Lock::default(),
            fallback: true,
            problem: None,
        },
        Err(error) => RecordRead {
            lock: Lock::default(),
            fallback: true,
            problem: Some(error.to_string()),
        },
    }
}

fn report_record_problem(scope: &Scope, path: &std::path::Path, problem: Option<&str>) {
    let detail = problem.map_or_else(
        || format!("no install record at {}", path.display()),
        |problem| format!("install record unreadable: {problem}"),
    );
    fail(&format!(
        "! {}: {detail} — checking current manifest and render bytes",
        scope_label(scope)
    ));
}

fn audit_for_verify(
    env: &Env,
    scope: &Scope,
    manifest: Option<&Manifest>,
    fallback: bool,
) -> Result<Option<VerifyAudit>, Box<dyn std::error::Error>> {
    match (fallback, manifest) {
        (true, Some(manifest)) => {
            let recordless = audit_without_record(env, scope, manifest)?;
            Ok(Some(VerifyAudit {
                report: recordless.report,
                matching: Some(recordless.matching),
            }))
        }
        (true, None) => Ok(None),
        (false, _) => Ok(Some(VerifyAudit {
            report: audit(env, scope)?,
            matching: None,
        })),
    }
}

fn missing_declarations(
    declared: Vec<(ItemKind, String)>,
    names: &[String],
    lock: &Lock,
    fallback: bool,
) -> Vec<(ItemKind, String)> {
    declared
        .into_iter()
        .filter(|(_, name)| names.is_empty() || names.contains(name))
        .filter(|(kind, name)| {
            let recorded = lock
                .entries
                .values()
                .any(|entry| entry.kind == *kind && entry.name == *name);
            match kind {
                ItemKind::PiExtension => !recorded,
                ItemKind::Agent
                | ItemKind::Skill
                | ItemKind::Hook
                | ItemKind::Command
                | ItemKind::McpServer
                | ItemKind::Plugin => fallback && !recorded || lock.entries.is_empty(),
            }
        })
        .collect()
}

/// Drift check over lock entries; non-zero exit on any failing row — this
/// is the signal consuming repos compose in shell pipelines.
///
/// Three things are named beside the rows without changing the count, which
/// is a count of lock entries and nothing else: content nothing manages,
/// what a scope declares that its record does not hold, and the
/// instruction shims the scope owes — each printed as a row of its own,
/// and a failing one closes the run non-zero like a failing lock row.
///
/// A missing or unreadable install record closes the run non-zero. The verb
/// still weighs current manifest and render bytes, so a recovery decision has
/// the measured rows and the original record failure together.
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
    // Whether any scope's record was unavailable. Read at the end for the exit
    // code alone — the run already said which scope it was, where it found
    // it.
    let mut recordless = false;
    // Instruction shims not in sync, gathered for the exit code alone: the
    // count above is of lock entries, and each shim already printed its
    // own row where it was found.
    let mut shims_failed = 0usize;

    for scope in resolve_scopes(env, filter)? {
        let path = lock_path(env, &scope);
        let RecordRead {
            mut lock,
            fallback,
            problem: record_problem,
        } = read_record(&path);
        // One read of the manifest per scope, so the gate below and the
        // declarations printed at the end are one answer about one file.
        // Read twice, the two can disagree: a read that fails and then
        // succeeds on the retry leaves the gate saying the scope asked for
        // nothing while the line under it names what the scope asked for,
        // and the run closes green having checked none of it.
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
        // The record failure stays part of the verdict while the read-only
        // fallback checks what current source and render bytes can prove.
        if fallback && manifest.as_deref().is_some_and(declares_items) {
            report_record_problem(&scope, &path, record_problem.as_deref());
            recordless = true;
        }
        // A scope with nothing installed has nothing to verify, and this
        // run reaches it only to name content nothing manages. That errand
        // never costs the run: a manifest this build cannot plan against
        // is worth a line, not a failure, and the exit code answers about
        // drift alone. A scope that does have installs fails loudly.
        let audited = {
            let _reading = ui::spinner(&format!("checking {}", scope_label(&scope)));
            audit_for_verify(env, &scope, manifest.as_deref(), fallback)
        };
        let Some(audited) = (match (audited, lock.entries.is_empty()) {
            (Ok(report), _) => report,
            (Err(error), true) => {
                // The error picks its own door. A manifest that will not
                // parse names one finding per line and keeps those breaks;
                // every other failure here — unreadable TOML, a file that
                // would not open — is a sentence naming a path, and a break
                // in that path is content rather than a line of kendex's
                // own verdict.
                fail_refusal(
                    &format!("! {} not checked: ", scope_label(&scope)),
                    error.as_ref(),
                );
                continue;
            }
            (Err(error), false) => return Err(error),
        }) else {
            fail(&format!(
                "! {} not checked: {}",
                scope_label(&scope),
                record_problem.as_deref().unwrap_or("manifest absent")
            ));
            continue;
        };
        if let Some(fallback_lock) = audited.matching {
            lock = fallback_lock;
        }
        let report = audited.report;
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
        let gap = missing_declarations(declared, &names, &lock, fallback);
        if !gap.is_empty() {
            gaps.push((scope.clone(), gap));
        }
        for entry in lock.entries.values() {
            if !names.is_empty() && !names.contains(&entry.name) {
                continue;
            }
            checked += 1;
            failed += usize::from(say_row(entry, &report));
        }
        for shim in &report.instruction_shims {
            if !names.is_empty() && !names.contains(&shim.name) {
                continue;
            }
            shims_failed += usize::from(say_shim(shim));
        }
    }

    print_unmanaged(&unmanaged);
    print_gaps(&gaps);
    ui::ledger(&head(checked, failed, !gaps.is_empty()), &[]);
    Ok(match failed > 0 || shims_failed > 0 || recordless {
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
/// It does not answer for plugins, and the plugin table is chained on here
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
                match kind {
                    ItemKind::PiExtension => "kendex update-pi records it",
                    ItemKind::Agent
                    | ItemKind::Skill
                    | ItemKind::Hook
                    | ItemKind::Command
                    | ItemKind::McpServer
                    | ItemKind::Plugin => "kendex apply records it",
                }
            ));
        }
    }
}

/// One instruction shim's row, and whether it failed the run. A shim is
/// content, not a lock entry: the row reads its state off the engine's
/// standing for it, which compared the bytes (invariant 12).
fn say_shim(shim: &ShimStanding) -> bool {
    let harness = shim.harness.name();
    let name = &shim.name;
    match shim.problem() {
        Some(problem) => {
            fail(&format!("✗ shim {name} [{harness}]: {problem}"));
            true
        }
        None => {
            say(&format!("✓ shim {name} [{harness}]"));
            false
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
