use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use kendex_core::attest::{
    self, Document, Floor, Foreign, Placed, Reading, Row, Stale, Standing, State,
};
use kendex_core::engine::{
    DeclarationStatus, DriftState, EngineReport, Installation, Owns, Pin, Position, ShimStanding,
    planned_closure,
};
use kendex_core::env::Env;
use kendex_core::lock::lock_path;
use kendex_core::manifest::Manifest;
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::tracked_output::Held;

use super::engine_common::print_unmanaged;
use super::{resolve_scopes, scope_label};
use crate::scope::ScopeFilter;
use crate::ui::{self, Span, Status, Style};

/// What a warning row does to the run: `--strict` fails it like any other
/// failed row. The one warning today is a declared tracked output the
/// project's repository ignores, a choice the project may make on purpose.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Warnings {
    /// Said and counted apart; the run stays clean.
    Warn,
    /// Failed and counted with the other failed rows.
    Fail,
}

impl Warnings {
    pub fn strict(strict: bool) -> Warnings {
        match strict {
            true => Warnings::Fail,
            false => Warnings::Warn,
        }
    }
}

/// What the run renders against and what the machine-readable mode asks
/// for: the document, and the revision each shared file's foreign part is
/// compared against.
#[derive(Debug, Clone, Default, clap::Args)]
pub struct Output {
    /// Render each package that follows its source at the commit the install record names, not at the source's revision now; that commit must be on the source's history and, with --base, no older than the base revision's record names. A package with a revision of its own, or whose installations disagree on a commit, resolves as usual. An adopted workflow copy is compared with its template at that recorded commit; without this flag, with its template at the revision the manifest declares now, so a revision bump fails a stale copy before any refresh records it
    #[arg(long)]
    pub at_record: bool,
    /// Also print one JSON document on stdout: every row with its state and the positions it occupies
    #[arg(long)]
    pub json: bool,
    /// A git revision of the project; with --json, each shared file kendex writes keys in under the project scope says whether the rest of it is as that revision held it, and base_owned lists the whole files and trees that revision's install record names
    #[arg(long, requires = "json", value_name = "REV")]
    pub base: Option<String>,
}

impl Output {
    /// What each recorded package is rendered at: under `--at-record`, a
    /// package that follows its source and that the record can place at
    /// the commit the record names, held to the source's history and, with
    /// `--base`, to no older than the base revision's record.
    fn reading(&self) -> Reading {
        match self.at_record {
            true => Reading::Recorded,
            false => Reading::Current,
        }
    }

    /// How far back a held commit may reach in `scope`: the record
    /// `--base` held, for a project run at the record's commits. The
    /// global scope has no project revision to read one from.
    fn floor(&self, scope: &Scope) -> Floor {
        match (self.reading(), scope, self.base.as_deref()) {
            (Reading::Recorded, Scope::Project { root }, Some(rev)) => attest::floor_at(root, rev),
            (Reading::Recorded, Scope::Global, _)
            | (Reading::Recorded, Scope::Project { .. }, None)
            | (Reading::Current, _, _) => Floor::Open,
        }
    }
}

fn report_record_problem(style: &Style, scope: &Scope, path: &Path, problem: Option<&str>) {
    let detail = problem.map_or_else(
        || format!("no install record at {}", path.display()),
        |problem| format!("install record unreadable: {problem}"),
    );
    ui::stderr(&style.report_row(
        Status::Failed,
        &[Span::Prose(&format!(
            "{}: {detail} — checking what this place lists against its installed files",
            scope_label(scope)
        ))],
        "! ",
    ));
}

/// A scope the run could not check, said and passed over: the refusal's
/// own lines under the scope's headline.
fn scope_refusal(style: &Style, scope: &Scope, error: &(dyn std::error::Error + 'static)) {
    ui::stderr(&style.refusal(&format!("{} not checked: ", scope_label(scope)), error));
}

/// What the record read could not settle, one failed row per warning,
/// each opening on the scope it is about.
fn record_warnings(style: &Style, scope: &Scope, warnings: &[String]) {
    for warning in warnings {
        ui::stderr(&style.report_row(
            Status::Failed,
            &[Span::Prose(&format!("{}: {warning}", scope_label(scope)))],
            "! ",
        ));
    }
}

/// Everything a run gathers across its scopes, and what closes it.
#[derive(Default)]
struct Tally {
    /// The count the closing line opens with: lock entries, nothing else.
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
    /// What each scope declares that installs on none of its tools, by the
    /// package's own harnesses line: said once at the end, never a gap.
    left_out: Vec<(Scope, Vec<(ItemKind, String)>)>,
    /// Whether any scope's record was unavailable; the run already said
    /// which scope it was, where it found it.
    recordless: bool,
    /// Instruction shims not in sync, recorded armings the package no
    /// longer stands behind, the two bookkeeping files and adopted
    /// workflow copies: each printed its own row where it was found, and
    /// these are for the exit code and the closing line's other-rows count.
    shims_failed: usize,
    setup_failed: usize,
    bookkeeping_failed: usize,
    /// Declared tracked outputs the project ignores under `--strict`, and
    /// projects whose ignore rules git could not be asked about.
    outputs_failed: usize,
    /// Unsupported hook deliveries with no recorded installation.
    deliveries_failed: usize,
    /// Declared tracked outputs the project ignores, without `--strict`:
    /// counted on the closing line apart from every failure.
    warned: usize,
    rows: Vec<Row>,
}

impl Tally {
    /// Failed rows outside the lock-entry count, including unsupported
    /// hook deliveries with no recorded entry.
    fn beside_failed(&self) -> usize {
        self.shims_failed
            + self.setup_failed
            + self.bookkeeping_failed
            + self.outputs_failed
            + self.deliveries_failed
    }

    fn clean(&self) -> bool {
        !(self.failed > 0
            || self.shims_failed > 0
            || self.setup_failed > 0
            || self.bookkeeping_failed > 0
            || self.outputs_failed > 0
            || self.deliveries_failed > 0
            || self.recordless
            || !self.gaps.is_empty())
    }
}

/// Drift check over lock entries; non-zero exit on any failing row.
/// Consuming repos use this exit status in shell pipelines.
///
/// The checked count covers lock entries only. Failures outside those
/// entries have their own rows and closing count. An unsupported hook
/// delivery fails even without a recorded entry, under the contract in
/// docs/architecture/engine.md. Intentional harness exclusions and advisory
/// copies are not failed deliveries. A declared hook's `harnesses` pin
/// deciding a tool against the hook's own reading is a notice row, which
/// fails no run, `--strict` included.
///
/// A project may keep an agent's tracked output local on purpose, so an
/// ignored output is a warning unless `warnings` is [`Warnings::Fail`].
/// Warnings have a separate closing count. The arming and ignore checks
/// fail closed: an unmeasured recorded arming or a git query that cannot
/// settle whether a declared path is ignored fails the run.
///
/// A recorded entry nothing in the scope declares fails its row, and a
/// declared installation the record does not hold is a gap, for every
/// kind: the row set is closed against the declarations in both
/// directions, so a record edit that moves an entry's kind, harness or
/// name is a failed row and a gap rather than a passing row. The one
/// exception is a declaration its own harnesses line leaves off every tool
/// the scope installs on: apply records nothing for it, so it is named on
/// the pass-over line and is never a gap.
///
/// A missing or unreadable install record closes the run non-zero, except
/// a missing one where the expansion reached every declaration and each
/// one it reached is a hook its own harnesses line leaves off every tool
/// the scope installs on: apply writes no record there. A declaration no
/// configured tool can hold by kind still owes a record. The verb still weighs
/// current manifest and render bytes, so a recovery decision has the
/// measured rows and the original record failure together.
///
/// `--json` prints one document on stdout after the human rows: every row
/// above with its state and the positions the engine resolved for it,
/// which is what a reader owning changed paths reads instead of the rows'
/// wording. The human rows, the closing counts line and the exit status
/// are the same with or without it. With `--base` under the project scope,
/// where the base revision's record was read, the document also carries
/// `base_owned`, the whole files and trees that record names, which a
/// reader granting a deletion reads because no row prints a position the
/// head no longer renders.
///
/// `--at-record` renders each package that follows its source and that
/// the record can place at the commit the record names rather than at the
/// source's revision now, which weighs a record on its own terms after the
/// source has moved on. That commit is held to the source's history and,
/// with `--base`, to no older than the commit the base revision's record
/// names. A package with a revision of its own resolves as usual.
pub fn run(
    env: &Env,
    names: Vec<String>,
    filter: ScopeFilter,
    output: Output,
    warnings: Warnings,
) -> Result<ExitCode, Box<dyn std::error::Error>> {
    let style = ui::style();
    let scopes = resolve_scopes(env, filter)?;
    ui::stderr(
        &style.header(
            "verify",
            &scopes
                .iter()
                .map(Scope::label)
                .collect::<Vec<_>>()
                .join(", "),
        ),
    );
    let base_owned = base_owned(&scopes, output.base.as_deref());
    let mut tally = Tally::default();
    for scope in scopes {
        check_scope(env, scope, &names, &output, warnings, &mut tally, &style)?;
    }
    print_unmanaged(&tally.unmanaged);
    print_left_out(&style, &tally.left_out);
    print_gaps(&style, &tally.gaps);
    let clean = tally.clean();
    ui::stderr(&style.summary(
        if clean { Status::Done } else { Status::Failed },
        &head(
            tally.checked,
            tally.failed,
            !tally.gaps.is_empty(),
            tally.beside_failed(),
            tally.warned,
        ),
    ));
    if output.json {
        super::answer(&serde_json::to_string_pretty(&Document::new(
            clean,
            tally.checked,
            tally.failed,
            tally.rows,
            tally.stale,
            base_owned,
        ))?);
    }
    Ok(match clean {
        true => ExitCode::SUCCESS,
        false => ExitCode::FAILURE,
    })
}

/// [`attest::owned_at`] the base revision for the one project scope a run
/// checks, spelled as a row's positions are; `None` without `--base` or a
/// project scope. The global scope has no project revision to read.
fn base_owned(scopes: &[Scope], base: Option<&str>) -> Option<Vec<Placed>> {
    let (root, rev) = scopes.iter().find_map(|scope| match (scope, base) {
        (Scope::Project { root }, Some(rev)) => Some((root, rev)),
        (Scope::Project { .. }, None) | (Scope::Global, _) => None,
    })?;
    let owned = attest::owned_at(root, rev)?;
    Some(
        owned
            .into_iter()
            .map(|position| Placed {
                path: spelled(root, &position.path),
                owns: position.owns,
                foreign: None,
            })
            .collect(),
    )
}

/// One scope's rows, into the tally. A scope whose record or manifest
/// cannot be read is said and skipped; the exit code remembers it.
fn check_scope(
    env: &Env,
    scope: Scope,
    names: &[String],
    output: &Output,
    warnings: Warnings,
    tally: &mut Tally,
    style: &Style,
) -> Result<(), Box<dyn std::error::Error>> {
    let reading = output.reading();
    let path = lock_path(env, &scope);
    let records = kendex_core::ownership::read(env, &scope);
    let fallback = records.fallback;
    let manifest = records.manifest.as_deref();
    // A missing record owes an answer only once the plan says what the
    // scope installs; an unreadable one is a failure whatever it declares.
    let absent =
        fallback && records.record_problem.is_none() && manifest.is_some_and(declares_items);
    if records.record_problem.is_some() {
        report_record_problem(style, &scope, &path, records.record_problem.as_deref());
        tally.recordless = true;
    }
    if let Some(error) = &records.manifest_problem {
        scope_refusal(style, &scope, error);
        tally.recordless |= records.record_problem.is_some() || !records.lock.entries.is_empty();
        return Ok(());
    }
    record_warnings(style, &scope, &records.warnings);
    if manifest.is_none() && !records.warnings.is_empty() {
        tally.recordless = true;
        return Ok(());
    }
    let audited = kendex_core::ownership::audit(env, &scope, &records, &reading.plan_options());
    let declared = match (&audited, manifest) {
        (Ok(audited), Some(manifest)) => declared_packages(env, &scope, manifest, &audited.report),
        (Err(_), _) | (Ok(_), None) => Declared::unread(),
    };
    if absent && !declared.owes_record_nothing() {
        report_record_problem(style, &scope, &path, None);
        tally.recordless = true;
    }
    let audited = match audited {
        Ok(audited) => audited,
        Err(error) => {
            scope_refusal(style, &scope, &error);
            tally.recordless = true;
            return Ok(());
        }
    };
    let (lock, report) = (audited.matching, audited.report);
    let stale = trailed(style, &scope, &lock, &report, reading);
    tally.stale.extend(stale);
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
    declaration_rows(&scope, declared, &lock, &report, &placer, &named, tally);
    failed_hook_delivery_rows(&lock, &report, &placer, &named, tally, style);
    pinned_hook_rows(&report, &placer, &named, tally, style);
    for (key, entry) in &lock.entries {
        if !named(&entry.name) {
            continue;
        }
        tally.checked += 1;
        let problem = say_row(env, style, entry, &report);
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
        let problem = say_shim(style, shim);
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
    if let Scope::Project { root } = &scope {
        tracked_output_rows(root, &report, &placer, &named, warnings, tally, style);
    }
    let record = match fallback {
        true => None,
        false => attest::record(env, &scope, &lock, &report, &output.floor(&scope))?,
    };
    bookkeeping_rows(&scope, record, &report, &placer, tally, style)?;
    Ok(())
}

/// Unsupported hook deliveries without a record entry fail verification.
/// Recorded failures belong to `say_row`, so each is counted once.
fn failed_hook_delivery_rows(
    lock: &kendex_core::lock::Lock,
    report: &EngineReport,
    placer: &Placer,
    named: &dyn Fn(&str) -> bool,
    tally: &mut Tally,
    style: &Style,
) {
    for row in report.failed_hook_deliveries() {
        if named(&row.name)
            && !lock.entries.contains_key(&kendex_core::lock::entry_key(
                row.kind,
                &row.name,
                row.harness,
            ))
        {
            ui::stderr(&style.report_verdict(
                &format!("{} {}", row.kind.name(), row.name),
                Some(&row.reason),
            ));
            tally.deliveries_failed += 1;
            tally.rows.push(placer.row(
                row.kind.name(),
                &row.name,
                Some(row.harness),
                State::Failed,
                Some(row.reason.clone()),
                &[],
            ));
        }
    }
}

/// Each tool a declared hook's `harnesses` pin decides against the hook's
/// own reading, as a notice and a `notice` row naming the hook, the tool
/// and the remedy. The engine's report is the one judge of which those
/// are. Nothing on disk disagrees with the record, so no run fails on
/// one, `--strict` included.
fn pinned_hook_rows(
    report: &EngineReport,
    placer: &Placer,
    named: &dyn Fn(&str) -> bool,
    tally: &mut Tally,
    style: &Style,
) {
    for pinned in report
        .pinned_hooks
        .iter()
        .filter(|pinned| named(&pinned.name))
    {
        let harness = pinned.harness.name();
        let detail = match pinned.pin {
            Pin::LeavesOut => format!(
                "its harnesses pin in kendex.toml leaves out {harness}, where kendex would write the hook with no pin; drop the pin, or add {harness} to it"
            ),
            Pin::NamesExcluded => format!(
                "its harnesses pin in kendex.toml names {harness}, which the hook's own harnesses line leaves out; drop the pin, or take {harness} off it"
            ),
        };
        ui::stderr(&style.report_row(
            Status::Notice,
            &[Span::Prose(&format!(
                "{}: hook {}: {detail}",
                scope_label(placer.scope),
                pinned.name
            ))],
            "",
        ));
        tally.rows.push(placer.row(
            "hook",
            &pinned.name,
            Some(pinned.harness),
            State::Notice,
            Some(detail),
            &[],
        ));
    }
}

/// The source commits this scope's record trails, each said beside the
/// rows where the run rendered at the record's commits: the rows then
/// pass on a render the source has moved past, and this is its age.
fn trailed(
    style: &Style,
    scope: &Scope,
    lock: &kendex_core::lock::Lock,
    report: &kendex_core::engine::EngineReport,
    reading: Reading,
) -> Vec<Stale> {
    let stale = attest::stale(scope, lock, report);
    if reading == Reading::Recorded {
        for behind in &stale {
            ui::stderr(&style.report_row(
                Status::Notice,
                &[Span::Prose(&format!(
                    "{}: source {} checked at recorded commit {}; it resolves to {} now",
                    scope_label(scope),
                    behind.source,
                    behind.recorded,
                    behind.resolved
                ))],
                "",
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
    style: &Style,
) -> Result<(), Box<dyn std::error::Error>> {
    for (kind, standing) in [
        ("record", record),
        ("inventory", attest::inventory(scope, report)?),
    ]
    .into_iter()
    .chain(
        attest::adopted_workflows(report)
            .into_iter()
            .map(|standing| ("adopted-workflow", Some(standing))),
    ) {
        let Some(standing) = standing else {
            continue;
        };
        let name = spelled(&placer.root, &standing.path);
        let problem = say_bookkeeping(style, kind, &name, &standing);
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

/// Each path an agent the project declares names as tracked output that
/// the project's repository ignores, as a warning row, or a failed one
/// under [`Warnings::Fail`]: a plan or report the agent writes there
/// reaches no other checkout and no review, which the project may intend.
/// A path left tracked is the ordinary state and makes no row. The global
/// scope has no repository to ask, so only a project comes here.
fn tracked_output_rows(
    root: &Path,
    report: &kendex_core::engine::EngineReport,
    placer: &Placer,
    named: &dyn Fn(&str) -> bool,
    warnings: Warnings,
    tally: &mut Tally,
    style: &Style,
) {
    let declared = report
        .tracked_outputs
        .iter()
        .filter(|(agent, _)| named(agent))
        .map(|(agent, paths)| (agent.as_str(), paths.as_slice()));
    let standings = match kendex_core::tracked_output::standings(root, declared) {
        Ok(standings) => standings,
        Err(error) => {
            ui::stderr(&style.refusal(
                &format!(
                    "{}: tracked outputs not checked: ",
                    scope_label(placer.scope)
                ),
                &error,
            ));
            tally.outputs_failed += 1;
            return;
        }
    };
    for standing in standings {
        let rule = match standing.held {
            Held::Ignored { rule } => rule,
            Held::Tracked => continue,
        };
        let problem = format!(
            "tracked output {} is ignored ({rule}); a file the agent writes there reaches no other checkout",
            standing.path
        );
        let label = format!("agent {}", standing.agent);
        let state = match warnings {
            Warnings::Warn => {
                ui::stderr(&style.report_warning(&format!("{label}: {problem}")));
                tally.warned += 1;
                State::Warning
            }
            Warnings::Fail => {
                ui::stderr(&style.report_verdict(&label, Some(&problem)));
                tally.outputs_failed += 1;
                State::Failed
            }
        };
        tally.rows.push(placer.row(
            "tracked-output",
            &standing.agent,
            None,
            state,
            Some(problem),
            &[],
        ));
    }
}

/// One scope's declarations held to its record, into the tally: what it
/// declares and the record does not hold, and what installs on none of
/// its tools and so owes the record nothing.
fn declaration_rows(
    scope: &Scope,
    declared: Declared,
    lock: &kendex_core::lock::Lock,
    report: &EngineReport,
    placer: &Placer,
    named: &dyn Fn(&str) -> bool,
    tally: &mut Tally,
) {
    let left_out: Vec<(ItemKind, String)> = declared
        .left_out
        .into_iter()
        .filter(|(_, name)| named(name))
        .collect();
    if !left_out.is_empty() {
        tally.left_out.push((scope.clone(), left_out));
    }
    let gap = gap_rows(
        &declared.wanted,
        lock,
        report,
        placer,
        named,
        &mut tally.rows,
    );
    if !gap.is_empty() {
        tally.gaps.push((scope.clone(), gap));
    }
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
            (Scope::Project { root }, Some(rev)) => {
                Some(attest::foreign_since(env, root, rev, report))
            }
            (Scope::Global, Some(_)) => Some(BTreeMap::new()),
            (_, None) => None,
        };
        Placer {
            scope,
            root,
            foreign,
        }
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
                    path: spelled(&self.root, &position.path),
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

/// The path as the document spells it: the remainder under the scope's
/// root, slashed, or the whole path slashed where it sits elsewhere.
fn spelled(root: &Path, path: &Path) -> String {
    kendex_core::paths::slashed(path.strip_prefix(root).unwrap_or(path))
}

/// The line that closes the run: the count, or why there was none, and
/// the failed rows beside the count.
///
/// A scope whose declarations were named above is not a machine with
/// nothing installed on it, and saying so would close the run on the one
/// reading the reader came for. A count that closes on `0 failed` while a
/// row beside it failed reads as a pass to the one reading only the last
/// line, so those rows are counted here too. Warnings close the line,
/// counted apart from every failure.
fn head(checked: usize, failed: usize, named: bool, beside: usize, warned: usize) -> String {
    let count = match (checked, named) {
        (0, true) => "nothing checked".to_owned(),
        (0, false) => "nothing installed".to_owned(),
        _ => format!(
            "{checked} checked, {} OK, {failed} failed",
            checked - failed
        ),
    };
    let count = match beside {
        0 => count,
        1 => format!("{count}; 1 other row failed"),
        _ => format!("{count}; {beside} other rows failed"),
    };
    match warned {
        0 => count,
        1 => format!("{count}; 1 warning"),
        _ => format!("{count}; {warned} warnings"),
    }
}

/// What a scope asks to have installed, by kind and name.
///
/// [`planned_closure`] is the engine's own answer to that question, with
/// whether its expansion reached every declaration, so a bundle counts as the members it brings in rather than as a name
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
///
/// A package the plan writes on none of its tools because its own
/// harnesses line leaves each one out is not asked for here: apply records
/// nothing for it, so it goes to `left_out` and never to the gap. The
/// engine's report answers which those are
/// ([`EngineReport::left_out_by_own_line`]).
fn declared_packages(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    report: &EngineReport,
) -> Declared {
    let (planned, status) = planned_closure(env, scope, manifest);
    let (left_out, wanted): (Vec<_>, Vec<_>) = planned.into_iter().partition(|declared| {
        report.left_out_by_own_line(declared.kind, &declared.name, &declared.harnesses)
    });
    let pair = |declared: kendex_core::engine::PlannedDeclaration| (declared.kind, declared.name);
    Declared {
        wanted: wanted
            .into_iter()
            .map(pair)
            .chain(
                manifest
                    .plugins
                    .keys()
                    .map(|name| (ItemKind::Plugin, name.clone())),
            )
            .collect(),
        left_out: left_out.into_iter().map(pair).collect(),
        status,
    }
}

/// A scope's declarations, split by whether the record owes them an entry.
struct Declared {
    /// What the record must hold.
    wanted: Vec<(ItemKind, String)>,
    /// What installs on none of the scope's tools, by its own harnesses line.
    left_out: Vec<(ItemKind, String)>,
    /// Whether the expansion reached every declaration. An incomplete one
    /// may have missed a package the record must hold.
    status: DeclarationStatus,
}

impl Declared {
    /// Declarations this run could not read: the audit failed, or the
    /// scope has no manifest to read them from. Nothing proves apply
    /// writes no record for them, so they owe one.
    fn unread() -> Self {
        Declared {
            wanted: Vec::new(),
            left_out: Vec::new(),
            status: DeclarationStatus::Incomplete,
        }
    }

    /// Whether a missing record is excused: the expansion reached every
    /// declaration, and each one it reached is a hook its own harnesses
    /// line leaves off every configured tool, so apply records nothing.
    /// Everything else sits in `wanted` and owes a record, a declaration
    /// no configured tool can hold by kind included, although apply writes
    /// no entry for it either.
    fn owes_record_nothing(&self) -> bool {
        match self.status {
            DeclarationStatus::Complete => self.wanted.is_empty(),
            DeclarationStatus::Incomplete => false,
        }
    }
}

/// Whether the scope's manifest asks for anything at all — every
/// declaration table, read as it sits.
///
/// The refusal binds to this rather than to the expanded plan. An
/// expansion asks a catalog what a bundle holds and what a skill requires,
/// and every way that read can come back short is a way the refusal would
/// stop firing on a scope that is still missing its record. The expansion
/// only excuses a missing record, and only when it reports itself complete
/// ([`Declared::owes_record_nothing`]).
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

/// What each scope declares that installs on none of its tools, one line
/// per scope: a notice, not a failure, since apply records nothing for it.
fn print_left_out(style: &Style, scopes: &[(Scope, Vec<(ItemKind, String)>)]) {
    for (scope, items) in scopes {
        let named: Vec<String> = items
            .iter()
            .map(|(kind, name)| format!("{} {name}", kind.name()))
            .collect();
        ui::stderr(&style.report_row(
            Status::Notice,
            &[Span::Prose(&format!(
                "{}: {} package{} on no tool here, {} own harnesses line names none of them: {}",
                scope_label(scope),
                items.len(),
                match items.len() {
                    1 => " installs",
                    _ => "s install",
                },
                match items.len() {
                    1 => "its",
                    _ => "their",
                },
                named.join(", ")
            ))],
            "",
        ));
    }
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
fn print_gaps(style: &Style, scopes: &[(Scope, Vec<(ItemKind, String)>)]) {
    for (scope, items) in scopes {
        ui::stderr(&style.report_row(
            Status::Notice,
            &[Span::Prose(&format!(
                "{}: {} package{} listed and not in the install record",
                scope_label(scope),
                items.len(),
                if items.len() == 1 { "" } else { "s" }
            ))],
            "",
        ));
        for (kind, name) in items {
            let text = format!(
                "{} {name} — {}",
                kind.name(),
                match kind {
                    ItemKind::PiExtension => "kendex update-pi records it",
                    ItemKind::Agent
                    | ItemKind::Skill
                    | ItemKind::Hook
                    | ItemKind::OutputStyle
                    | ItemKind::Command
                    | ItemKind::McpServer
                    | ItemKind::Plugin => "kendex apply records it",
                }
            );
            ui::stderr(&style.report_row(Status::Decision, &[Span::Prose(&text)], "  - "));
        }
    }
}

/// One instruction shim's row, and the problem that failed it. A shim is
/// content, not a lock entry: the row reads its state off the engine's
/// standing for it, which compared the bytes (invariant 12).
fn say_shim(style: &Style, shim: &ShimStanding) -> Option<String> {
    let harness = shim.harness.name();
    let name = &shim.name;
    let problem = shim.problem();
    ui::stderr(&style.report_verdict(&format!("shim {name} [{harness}]"), problem.as_deref()));
    problem
}

/// One bookkeeping file's row, printed only where it fails: a passing one
/// is the ordinary state of every project and says nothing a reader came
/// for, while the machine-readable document carries it either way.
fn say_bookkeeping(style: &Style, kind: &str, name: &str, standing: &Standing) -> Option<String> {
    if standing.problems.is_empty() {
        return None;
    }
    let problem = standing.problems.join("; ");
    ui::stderr(&style.report_verdict(&format!("{kind} {name}"), Some(&problem)));
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
    env: &Env,
    style: &Style,
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
        Some(row) if row.state == DriftState::Stale => Some(
            entry
                .source_commit
                .as_deref()
                .and_then(|commit| {
                    attest::missing_commit_problem(
                        env,
                        &entry.source_repo,
                        commit,
                        &format!("sourceCommit {commit}"),
                    )
                })
                .unwrap_or_else(|| row.detail.clone()),
        ),
        Some(row) => Some(row.detail.clone()),
        None if unreachable_source => {
            let detail = "where this package comes from is unavailable".to_owned();
            Some(detail)
        }
        None => None,
    };
    ui::stderr(&style.report_verdict(&format!("{kind} {name} [{harness}]"), bad.as_deref()));
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
        match ui::report::is_run_model_warning(&warning.message) {
            true => ui::report::run_model_warning(&warning.message),
            false => ui::stderr(&style.report_detail(&[Span::Prose(&warning.message)], "  ! ")),
        }
    }
    bad
}
