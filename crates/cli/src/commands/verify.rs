use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use kendex_core::attest::{self, Document, Foreign, Placed, Reading, Row, Stale, Standing, State};
use kendex_core::engine::{
    DriftState, Installation, Owns, Position, ShimStanding, planned_declarations,
};
use kendex_core::env::Env;
use kendex_core::lock::lock_path;
use kendex_core::manifest::Manifest;
use kendex_core::model::{HarnessId, ItemKind, Scope};

use super::engine_common::print_unmanaged;
use super::{fail, fail_refusal, note, resolve_scopes, say, scope_label};
use crate::scope::ScopeFilter;
use crate::ui;

/// What the run renders against and what the machine-readable mode asks
/// for: the document, and the revision each shared file's foreign part is
/// compared against.
#[derive(Debug, Clone, Default, clap::Args)]
pub struct Output {
    /// Render each recorded package at the commit the install record names, not at its source's revision now; that commit must be on the source's history
    #[arg(long)]
    pub at_record: bool,
    /// Also print one JSON document on stdout: every row with its state and the positions it occupies
    #[arg(long)]
    pub json: bool,
    /// A git revision of the project; with --json, each shared file kendex writes keys in under the project scope says whether the rest of it is as that revision held it
    #[arg(long, requires = "json", value_name = "REV")]
    pub base: Option<String>,
}

impl Output {
    /// What each recorded package is rendered at.
    fn reading(&self) -> Reading {
        match self.at_record {
            true => Reading::Recorded,
            false => Reading::Current,
        }
    }
}

fn report_record_problem(scope: &Scope, path: &Path, problem: Option<&str>) {
    let detail = problem.map_or_else(
        || format!("no install record at {}", path.display()),
        |problem| format!("install record unreadable: {problem}"),
    );
    fail(&format!(
        "! {}: {detail} — checking what this place lists against its installed files",
        scope_label(scope)
    ));
}

/// Everything a run gathers across its scopes, and what closes it.
#[derive(Default)]
struct Tally {
    /// The count the closing line reports: lock entries, nothing else.
    checked: usize,
    failed: usize,
    /// What this run did not check, said once at the end: a count of
    /// installations is only honest beside the content that was never one.
    unmanaged: Vec<kendex_core::engine::DriftRow>,
    /// The sources each scope's record trails, for the document.
    stale: Vec<Stale>,
    /// What each scope declares that its record does not hold. None of it
    /// reaches the count, and a count printed without them covers less
    /// than the scope does.
    gaps: Vec<(Scope, Vec<(ItemKind, String)>)>,
    /// Whether any scope's record was unavailable; the run already said
    /// which scope it was, where it found it.
    recordless: bool,
    /// Instruction shims not in sync, recorded armings the package no
    /// longer stands behind, and the two bookkeeping files: each printed
    /// its own row where it was found, and these are for the exit code.
    shims_failed: usize,
    setup_failed: usize,
    bookkeeping_failed: usize,
    rows: Vec<Row>,
}

impl Tally {
    fn clean(&self) -> bool {
        !(self.failed > 0
            || self.shims_failed > 0
            || self.setup_failed > 0
            || self.bookkeeping_failed > 0
            || self.recordless
            || !self.gaps.is_empty())
    }
}

/// Drift check over lock entries; non-zero exit on any failing row — this
/// is the signal consuming repos compose in shell pipelines.
///
/// Six things are named beside the rows without changing the count, which
/// is a count of lock entries and nothing else: content nothing manages,
/// what a scope declares that its record does not hold, the instruction
/// shims the scope owes, a repository effect kendex recorded arming that
/// the package no longer stands behind, and the two files a project
/// commits about itself — the record and the inventory, each held to what
/// this pass would write — each printed as a row of its own where it
/// fails, and a failing one closes the run non-zero like a failing lock
/// row. The arming check fails closed: a recorded arming whose check could
/// not be taken is a row nothing measured, never a clean one.
///
/// A recorded entry nothing in the scope declares fails its row, and a
/// declared installation the record does not hold is a gap, for every
/// kind: the row set is closed against the declarations in both
/// directions, so a record edit that moves an entry's kind, harness or
/// name is a failed row and a gap rather than a passing row.
///
/// A missing or unreadable install record closes the run non-zero. The verb
/// still weighs current manifest and render bytes, so a recovery decision has
/// the measured rows and the original record failure together.
///
/// `--json` prints one document on stdout after the human rows: every row
/// above with its state and the positions the engine resolved for it,
/// which is what a reader owning changed paths reads instead of the rows'
/// wording. The human rows, the closing counts line and the exit status
/// are the same with or without it.
///
/// `--at-record` renders each recorded package at the commit the record
/// names rather than at its source's revision now, which weighs a record
/// on its own terms after the source has moved on, and holds that commit
/// to the source's history instead.
pub fn run(
    env: &Env,
    names: Vec<String>,
    filter: ScopeFilter,
    output: Output,
) -> Result<ExitCode, Box<dyn std::error::Error>> {
    ui::intro("kendex verify");
    let mut tally = Tally::default();
    for scope in resolve_scopes(env, filter)? {
        check_scope(env, scope, &names, &output, &mut tally)?;
    }
    print_unmanaged(&tally.unmanaged);
    print_gaps(&tally.gaps);
    ui::ledger(
        &head(tally.checked, tally.failed, !tally.gaps.is_empty()),
        &[],
    );
    let clean = tally.clean();
    if output.json {
        super::answer(&serde_json::to_string_pretty(&Document::new(
            clean,
            tally.checked,
            tally.failed,
            tally.rows,
            tally.stale,
        ))?);
    }
    Ok(match clean {
        true => ExitCode::SUCCESS,
        false => ExitCode::FAILURE,
    })
}

/// One scope's rows, into the tally. A scope whose record or manifest
/// cannot be read is said and skipped; the exit code remembers it.
fn check_scope(
    env: &Env,
    scope: Scope,
    names: &[String],
    output: &Output,
    tally: &mut Tally,
) -> Result<(), Box<dyn std::error::Error>> {
    let reading = output.reading();
    let path = lock_path(env, &scope);
    let records = kendex_core::ownership::read(env, &scope);
    let fallback = records.fallback;
    let manifest = records.manifest.as_deref();
    if records.record_problem.is_some() || fallback && manifest.is_some_and(declares_items) {
        report_record_problem(&scope, &path, records.record_problem.as_deref());
        tally.recordless = true;
    }
    if let Some(error) = &records.manifest_problem {
        fail_refusal(&format!("! {} not checked: ", scope_label(&scope)), error);
        tally.recordless |= records.record_problem.is_some() || !records.lock.entries.is_empty();
        return Ok(());
    }
    for warning in &records.warnings {
        fail(&format!("! {}: {warning}", scope_label(&scope)));
    }
    if manifest.is_none() && !records.warnings.is_empty() {
        tally.recordless = true;
        return Ok(());
    }
    let audited =
        match kendex_core::ownership::audit(env, &scope, &records, &reading.plan_options()) {
            Ok(audited) => audited,
            Err(error) => {
                fail_refusal(&format!("! {} not checked: ", scope_label(&scope)), &error);
                tally.recordless = true;
                return Ok(());
            }
        };
    let lock = audited.matching;
    let report = audited.report;
    tally.stale.extend(trailed(&scope, &lock, &report, reading));
    let placer = Placer::new(env, &scope, output.base.as_deref(), &report);
    let named = |name: &str| names.is_empty() || names.iter().any(|wanted| wanted == name);
    tally.unmanaged.extend(
        report
            .drift
            .iter()
            .filter(|row| row.state == DriftState::Unmanaged)
            .filter(|row| named(&row.name))
            .cloned(),
    );
    let declared = manifest
        .map(|manifest| declared_packages(env, &scope, manifest))
        .unwrap_or_default();
    let gap = gap_rows(&declared, &lock, &report, &placer, &named, &mut tally.rows);
    if !gap.is_empty() {
        tally.gaps.push((scope.clone(), gap));
    }
    for (key, entry) in &lock.entries {
        if !named(&entry.name) {
            continue;
        }
        tally.checked += 1;
        let problem = say_row(entry, &report);
        tally.failed += usize::from(problem.is_some());
        let positions = report
            .installations
            .get(key)
            .map(|installation| installation.positions.as_slice())
            .unwrap_or_default();
        tally.rows.push(placer.row(
            entry.kind.name(),
            &entry.name,
            Some(entry.harness),
            State::of(problem.is_none()),
            problem,
            positions,
        ));
    }
    for shim in &report.instruction_shims {
        if !named(&shim.name) {
            continue;
        }
        let problem = say_shim(shim);
        tally.shims_failed += usize::from(problem.is_some());
        tally.rows.push(placer.row(
            "shim",
            &shim.name,
            Some(shim.harness),
            State::of(problem.is_none()),
            problem,
            &[shim.position()],
        ));
    }
    tally.setup_failed += super::repo_effects::say_lapsed(env, &scope, names);
    let record = match fallback {
        true => None,
        false => attest::record(env, &scope, &lock, &report, reading)?,
    };
    bookkeeping_rows(&scope, record, &report, &placer, tally)?;
    Ok(())
}

/// The sources this scope's record trails, each said beside the rows
/// where the run rendered at the record's commits: the rows then pass
/// on a render the source has moved past, and this is its age.
fn trailed(
    scope: &Scope,
    lock: &kendex_core::lock::Lock,
    report: &kendex_core::engine::EngineReport,
    reading: Reading,
) -> Vec<Stale> {
    let stale = attest::stale(scope, lock, report);
    if reading == Reading::Recorded {
        for behind in &stale {
            note(&format!(
                "{}: source {} checked at its recorded commit {}; it resolves to {} now",
                scope_label(scope),
                behind.source,
                behind.recorded,
                behind.resolved
            ));
        }
    }
    stale
}

/// The two files a project commits about itself, as rows. The record is a
/// row only where there is one: its absence is the refusal already
/// printed, not a second failed row.
fn bookkeeping_rows(
    scope: &Scope,
    record: Option<Standing>,
    report: &kendex_core::engine::EngineReport,
    placer: &Placer,
    tally: &mut Tally,
) -> Result<(), Box<dyn std::error::Error>> {
    for (kind, standing) in [
        ("record", record),
        ("inventory", attest::inventory(scope, report)?),
    ] {
        let Some(standing) = standing else {
            continue;
        };
        let name = placer.spelled(&standing.path);
        let problem = say_bookkeeping(kind, &name, &standing);
        tally.bookkeeping_failed += usize::from(problem.is_some());
        let position = Position {
            path: standing.path.clone(),
            owns: Owns::File,
        };
        tally.rows.push(placer.row(
            kind,
            &name,
            None,
            State::of(problem.is_none()),
            problem,
            &[position],
        ));
    }
    Ok(())
}

/// Both directions the record can fall short of the scope, as rows and as
/// the names the gap line prints: an installation the pass derived that
/// the record holds no entry for, and a declaration the record holds no
/// entry for at all — one the pass could place nowhere, which no
/// installation carries. Whatever else the record holds, either is a gap.
/// Named once each, in the order the scope declares them, with the
/// installations the declarations did not account for after.
fn gap_rows(
    declared: &[(ItemKind, String)],
    lock: &kendex_core::lock::Lock,
    report: &kendex_core::engine::EngineReport,
    placer: &Placer,
    named: &dyn Fn(&str) -> bool,
    rows: &mut Vec<Row>,
) -> Vec<(ItemKind, String)> {
    let unrecorded: Vec<&Installation> = report
        .installations
        .iter()
        .filter(|(key, installation)| named(&installation.name) && !lock.entries.contains_key(*key))
        .map(|(_, installation)| installation)
        .collect();
    for installation in &unrecorded {
        rows.push(placer.row(
            installation.kind.name(),
            &installation.name,
            Some(installation.harness),
            State::Unrecorded,
            None,
            &installation.positions,
        ));
    }
    let mut gap: Vec<(ItemKind, String)> = Vec::new();
    for (kind, name) in declared {
        let placed =
            |entry: &kendex_core::lock::LockEntry| entry.kind == *kind && entry.name == *name;
        if !named(name) || lock.entries.values().any(placed) || gap.contains(&(*kind, name.clone()))
        {
            continue;
        }
        if !report
            .installations
            .values()
            .any(|installation| installation.kind == *kind && installation.name == *name)
        {
            rows.push(placer.row(kind.name(), name, None, State::Unrecorded, None, &[]));
        }
        gap.push((*kind, name.clone()));
    }
    for installation in &unrecorded {
        let named_gap = (installation.kind, installation.name.clone());
        if !gap.contains(&named_gap) {
            gap.push(named_gap);
        }
    }
    gap
}

/// Spells positions for one scope: relative to its root where they sit
/// under it, and for a `keys` position what the foreign comparison said.
struct Placer<'a> {
    scope: &'a Scope,
    /// What a position is spelled under: the project root, or the home
    /// directory for the global scope. A spelling root only; the foreign
    /// comparison never reads it as a repository.
    root: PathBuf,
    /// `None` without `--base`: a `keys` position then carries no
    /// judgement, and the field is left out rather than answered.
    foreign: Option<BTreeMap<PathBuf, Foreign>>,
}

impl<'a> Placer<'a> {
    fn new(
        env: &Env,
        scope: &'a Scope,
        base: Option<&str>,
        report: &kendex_core::engine::EngineReport,
    ) -> Placer<'a> {
        let root = match scope {
            Scope::Project { root } => root.clone(),
            Scope::Global => env.home.clone(),
        };
        // `--base` names a revision of the project. The global scope has
        // no project: its files sit under the home directory, which may be
        // a repository of its own, and a revision resolved there would
        // judge a global file against a history that is not this project's.
        // Every global `keys` position is `unknown` instead.
        let foreign = match (scope, base) {
            (Scope::Project { root }, Some(rev)) => Some(attest::foreign_since(root, rev, report)),
            (Scope::Global, Some(_)) => Some(BTreeMap::new()),
            (_, None) => None,
        };
        Placer {
            scope,
            root,
            foreign,
        }
    }

    /// The path as the document spells it: the remainder under the scope's
    /// root, slashed, or the whole path slashed where it sits elsewhere.
    fn spelled(&self, path: &Path) -> String {
        kendex_core::paths::slashed(path.strip_prefix(&self.root).unwrap_or(path))
    }

    fn row(
        &self,
        kind: &str,
        name: &str,
        harness: Option<HarnessId>,
        state: State,
        detail: Option<String>,
        positions: &[Position],
    ) -> Row {
        Row {
            scope: self.scope.clone(),
            kind: kind.to_owned(),
            name: name.to_owned(),
            harness,
            state,
            detail,
            positions: positions
                .iter()
                .map(|position| Placed {
                    path: self.spelled(&position.path),
                    owns: position.owns,
                    foreign: match position.owns {
                        Owns::Keys => self.foreign.as_ref().map(|foreign| {
                            foreign
                                .get(&position.path)
                                .copied()
                                .unwrap_or(Foreign::Unknown)
                        }),
                        Owns::File | Owns::Tree => None,
                    },
                })
                .collect(),
        }
    }
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
            "{}: {} package{} listed and not in the install record",
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

/// One instruction shim's row, and the problem that failed it. A shim is
/// content, not a lock entry: the row reads its state off the engine's
/// standing for it, which compared the bytes (invariant 12).
fn say_shim(shim: &ShimStanding) -> Option<String> {
    let harness = shim.harness.name();
    let name = &shim.name;
    match shim.problem() {
        Some(problem) => {
            fail(&format!("✗ shim {name} [{harness}]: {problem}"));
            Some(problem)
        }
        None => {
            say(&format!("✓ shim {name} [{harness}]"));
            None
        }
    }
}

/// One bookkeeping file's row, printed only where it fails: a passing one
/// is the ordinary state of every project and says nothing a reader came
/// for, while the machine-readable document carries it either way.
fn say_bookkeeping(kind: &str, name: &str, standing: &Standing) -> Option<String> {
    if standing.problems.is_empty() {
        return None;
    }
    let problem = standing.problems.join("; ");
    fail(&format!("✗ {kind} {name}: {problem}"));
    Some(problem)
}

/// One locked installation's row, and the problem that failed it. The
/// headline is the verdict; anything the installation cannot do despite
/// matching its declaration is detail under it.
///
/// A row fails on the engine's drift for exactly this installation —
/// missing, stale, in conflict, or recorded here while nothing declares
/// it — and on a source it cannot reach.
fn say_row(
    entry: &kendex_core::lock::LockEntry,
    report: &kendex_core::engine::EngineReport,
) -> Option<String> {
    let problem = report.drift.iter().find(|row| {
        row.name == entry.name
            && row.kind == entry.kind
            && row.harness == entry.harness
            && matches!(
                row.state,
                DriftState::Missing
                    | DriftState::Stale
                    | DriftState::Conflict
                    | DriftState::Orphaned
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
            Some(row.detail.clone())
        }
        None if unreachable_source => {
            let detail = "where this package comes from is unavailable".to_owned();
            fail(&format!("✗ {kind} {name} [{harness}]: {detail}"));
            Some(detail)
        }
        None => {
            say(&format!("✓ {kind} {name} [{harness}]"));
            None
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
