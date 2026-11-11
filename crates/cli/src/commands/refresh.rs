use kendex_core::commit_offer::Before;
use kendex_core::decision::{Approved, Consent, Effect, PiChange, PiSettle};
use kendex_core::engine::{EngineReport, PlanOptions, plan_apply};
use kendex_core::env::Env;
use kendex_core::lock::{load as load_lock, lock_path};

use super::advisory::Listing;
use super::attention::{Attention, print_attention};
use super::commit_offer::after_writing;
use super::engine_common::{
    AfterFailed, Confirmation, answerable, apply_report_accounted, before_writing,
    confirm_before_writing, confirm_writing, print_synced, refresh_failures,
    require_yes_in_non_interactive, write_report,
};
use super::ledger::{Folded, Wrote, say_ledger_with};
use super::offers::Reached;
use super::{CliResult, resolve_scopes_at, scope_label};
use crate::scope::ScopeFilter;
use crate::ui::{self, Span};

/// Regenerate every declared installation, and re-derive what those
/// declarations pull in — a dependency that appeared upstream, one that went
/// away. Regenerating is automatic; changing *what is installed* is shown
/// first and needs an answer. A record nothing declares or derives anymore
/// is removed, an edited copy held; an item its catalog retired stays as
/// recorded unless `--prune` takes it.
#[derive(clap::Args)]
pub struct RefreshArgs {
    #[arg(short = 'g', long)]
    global: bool,
    /// project | global | all (default all)
    #[arg(long)]
    scope: Option<String>,
    /// Per-item detail instead of the compact summary
    #[arg(short = 'v', long)]
    verbose: bool,
    /// Accept changes to what is installed without asking
    #[arg(short = 'y', long)]
    yes: bool,
    /// Overwrite installations you edited by hand
    #[arg(long)]
    discard_edits: bool,
    /// Remove every item its catalog retired, with its files and its entry in kendex.toml, except a copy you edited; without it a retired item stays installed
    #[arg(long)]
    prune: bool,
    /// Render each package that follows its source at the commit the install record names, so a re-render of a project-side change moves no catalog; a package the record cannot place resolves as usual
    #[arg(long)]
    locked: bool,
    // The project this run writes, named rather than walked up to. The
    // help clap prints is the flag's own, on `flags::ProjectTargetFlag`;
    // a doc comment here would reach no output.
    #[command(flatten)]
    pub(super) target: crate::flags::ProjectTargetFlag,
    // The commit offer's answer, without asking. Its help is
    // `commit_offer::CommitFlags`' own, for the same reason.
    #[command(flatten)]
    _commit: crate::commands::commit_offer::CommitFlags,
}

impl RefreshArgs {
    /// The scope selection shared by dispatch and the pre-bootstrap lane check.
    pub(super) fn effective_scope(&self) -> Result<ScopeFilter, String> {
        ScopeFilter::resolve(self.scope.as_deref(), self.global, ScopeFilter::All)
    }

    fn catalog(&self) -> Catalog {
        match self.locked {
            true => Catalog::Recorded,
            false => Catalog::Current,
        }
    }

    fn takes(&self) -> Takes {
        Takes {
            discard_edits: self.discard_edits,
            prune: self.prune,
        }
    }
}

/// What a refresh may take beyond what it regenerates: the person's edits,
/// and the items their catalogs retired.
#[derive(Debug, Clone, Copy, Default)]
pub struct Takes {
    pub discard_edits: bool,
    pub prune: bool,
}

/// Which commit a refresh renders each package that follows its source at.
#[derive(Debug, Clone, Copy)]
pub enum Catalog {
    /// The commit the source resolves to now: the catalog comes current.
    Current,
    /// The commit the install record names: a re-render that moves no
    /// catalog.
    Recorded,
}

impl Catalog {
    /// Either catalog recovers a version 10 project record inside the
    /// run's write rather than refusing it.
    fn plan_options(self) -> PlanOptions {
        let options = match self {
            Catalog::Current => PlanOptions::current(),
            Catalog::Recorded => PlanOptions::locked(),
        };
        PlanOptions {
            recover_version_10: true,
            ..options
        }
    }
}

/// What this refresh would add to or drop from the installed set — the part
/// that needs an answer before it runs.
fn print_set_changes(
    scope: &kendex_core::model::Scope,
    report: &kendex_core::engine::EngineReport,
) {
    ui::stderr(&ui::style().report_row(
        ui::Status::Decision,
        &[Span::Prose(&format!(
            "{}: this changes what is installed",
            consent_scope(scope)
        ))],
        "",
    ));
    for change in &report.set_changes {
        say_set_change(change);
    }
}

fn say_set_change(change: &kendex_core::engine::SetChange) {
    let verb = match change.direction {
        kendex_core::engine::SetDirection::Add => "install",
        kendex_core::engine::SetDirection::Remove => "remove",
    };
    ui::stderr(&ui::style().report_row(
        ui::Status::Decision,
        &[Span::Prose(&format!(
            "{verb} {} {} for {} — {}",
            change.kind.name(),
            change.name,
            change.harness.display_name(),
            change.reason
        ))],
        "  - ",
    ));
}

/// The proven orphan settings comments this plan removes. A question the
/// scope asks anyway answers them with everything else; alone they get
/// their own ([`offer_removals`]).
fn say_removed_comments(scope: &kendex_core::model::Scope, report: &EngineReport) {
    for key in &report.removed_settings_comments {
        ui::stderr(&ui::style().report_row(
            ui::Status::Decision,
            &[Span::Prose(&format!(
                "remove orphan settings comment for {key}; {}",
                consent_scope(scope)
            ))],
            "  - ",
        ));
    }
}

/// What a question about writing covers, drawn from the one list it
/// counts: the installs and removals the plan makes, as the reason, then
/// every change the yes lets run, each in the unit its writer counts.
fn print_consent(scope: &kendex_core::model::Scope, report: &EngineReport, consent: &Consent) {
    if !report.set_changes.is_empty() {
        print_set_changes(scope, report);
    }
    say_removed_comments(scope, report);
    say_effects(scope, consent);
}

/// Each change one list holds: a Pi package as what it installs and where
/// it is used, an op as its plan line.
fn say_effects(scope: &kendex_core::model::Scope, consent: &Consent) {
    for effect in &consent.effects {
        match effect {
            Effect::Pi(settle) => ui::stderr(&ui::style().report_row(
                ui::Status::Decision,
                &[Span::Prose(&format!(
                    "{}; {}",
                    pi_change(settle),
                    consent_scope(scope)
                ))],
                "  - ",
            )),
            Effect::Op(planned) => ui::stderr(&ui::style().plan_row(planned)),
        }
    }
}

fn pi_change(settle: &PiSettle) -> String {
    let name = &settle.name;
    match &settle.change {
        PiChange::Missing => format!("install Pi extension {name}"),
        PiChange::Stale {
            from_version,
            to_version,
            from,
            to,
        } => format!(
            "update Pi extension {name}: from version {} (source {from}) to version {} (source {to})",
            from_version.as_deref().unwrap_or("unknown"),
            to_version.as_deref().unwrap_or("unknown")
        ),
    }
}

/// The question asked about one list, counting exactly what it holds.
fn ask(consent: &Consent, yes: bool) -> Result<Confirmation, Box<dyn std::error::Error>> {
    confirm_writing(consent.count(), yes)
}

fn consent_scope(scope: &kendex_core::model::Scope) -> String {
    match scope {
        kendex_core::model::Scope::Global => "your user account, used by every project".into(),
        kendex_core::model::Scope::Project { root } => format!("this project ({})", root.display()),
    }
}

fn declined_scope(scope: &kendex_core::model::Scope) {
    ui::stderr(&ui::style().summary(
        ui::Status::Done,
        &format!("{}: unchanged; update declined", consent_scope(scope)),
    ));
}

/// A refresh draws what needs the reader, and every line with `--verbose`;
/// its closing ledger counts what the compact report left out.
fn listing(verbose: bool) -> Listing {
    match verbose {
        true => Listing::Verbose,
        false => Listing::Attention,
    }
}

fn refreshed(count: Option<usize>) -> Wrote<'static> {
    Wrote {
        verb: "refreshed",
        count,
    }
}

/// What a run owes the scopes it got through, whether it got through all
/// of them or stopped at a cancel: their snapshots derived, the trash
/// brought within its bounds now that every write is done, and the
/// closing line each one earned. Skipped on a cancel, writes are left on
/// disk the run said nothing about, and the next session-start check
/// reads a stale snapshot.
///
/// The snapshot warnings and the trash pass come first because a warning
/// under a closing line is a run that ended twice.
fn finish_scopes(
    env: &Env,
    reached: &[kendex_core::model::Scope],
    closing: Vec<Closing>,
    verbose: bool,
) {
    record_snapshots(env, reached);
    super::engine_common::tidy_trash(env);
    for scope in closing {
        let named = match (&scope.done, scope.listed) {
            (Some(done), false) => say_done(done, verbose),
            (Some(_), true) | (None, _) => true,
        };
        say_ledger_with(
            &scope.scope,
            refreshed(scope.done.as_ref().map(Vec::len)),
            &scope.attention.blocked,
            scope.attention.pi_left,
            &scope.scored,
            match scope.attention.folded || !named {
                true => Folded::BehindVerbose,
                false => Folded::None,
            },
        );
    }
}

/// What a scope's closing line counts, named: each package the settle
/// landed and each op the plan wrote, in the order they landed. A compact
/// run names the first few and how many more, and answers whether it named
/// every one; `--verbose` names every one.
fn say_done(done: &[Effect], verbose: bool) -> bool {
    let shown = match verbose {
        true => done.len(),
        false => done.len().min(DONE_SHOWN),
    };
    let mut lines = Vec::new();
    let style = ui::style();
    for effect in &done[..shown] {
        let said = match effect {
            Effect::Pi(settle) => pi_done(settle),
            Effect::Op(planned) => planned.line(),
        };
        lines.extend(style.report_row(ui::Status::Done, &[Span::Prose(&said)], "  - "));
    }
    if done.len() > shown {
        lines.extend(style.report_row(
            ui::Status::Done,
            &[Span::Prose(&format!("… and {} more", done.len() - shown))],
            "  - ",
        ));
    }
    ui::stderr(&lines);
    shown == done.len()
}

/// Whether two lists name the same changes in the same order: a package
/// by its change, an op by what it writes (`Op::same_effect`), so a plan
/// derived again after a settle still reads as the one the question drew.
fn same_changes(done: &[Effect], asked: &[Effect]) -> bool {
    done.len() == asked.len()
        && done.iter().zip(asked).all(|pair| match pair {
            (Effect::Pi(done), Effect::Pi(asked)) => done == asked,
            (Effect::Op(done), Effect::Op(asked)) => done.op.same_effect(&asked.op),
            (Effect::Pi(_), Effect::Op(_)) | (Effect::Op(_), Effect::Pi(_)) => false,
        })
}

/// Enough of a scope's changes to recognise them without burying its
/// closing line.
const DONE_SHOWN: usize = 10;

/// A landed package, in the past tense its write earned.
fn pi_done(settle: &PiSettle) -> String {
    let name = &settle.name;
    match &settle.change {
        PiChange::Missing => format!("installed Pi extension {name}"),
        PiChange::Stale { to_version, .. } => format!(
            "updated Pi extension {name} to version {}",
            to_version.as_deref().unwrap_or("unknown")
        ),
    }
}

/// The deep work just ran for every scope; the snapshot is what the next
/// session-start check reads instead of redoing it. A scope whose
/// snapshot will not derive is a line, never a failure: what was written
/// was written, and the next deep pass rewrites the file.
fn record_snapshots(env: &Env, scopes: &[kendex_core::model::Scope]) {
    for scope in scopes {
        if declares(env, scope)
            && let Err(error) = kendex_core::drift::snapshot::record(env, scope)
        {
            ui::report::warning(&format!("snapshot not derived ({})", error));
        }
    }
}

/// Whether this scope has a declaration file of its own to work from.
fn declares(env: &Env, scope: &kendex_core::model::Scope) -> bool {
    matches!(
        kendex_core::manifest::load(&kendex_core::manifest::manifest_path(env, scope)),
        Ok(kendex_core::manifest::ManifestFile::Current(_))
    )
}

/// The named project on the projects list, now that this run has got
/// through that scope; [`super::project::register_target`] owns when that
/// is and when it is not.
///
/// The rule's undeclared-scope exception is asked here rather than at
/// either caller, because both of them reach such a scope: this verb
/// goes through its write for one wherever an old lock still names
/// installs there.
///
/// A registry that refuses is a failure of the run, not of the install:
/// the packages are on disk and the message says so.
fn register_written(
    env: &Env,
    registering: &super::project::Registering,
    scope: &kendex_core::model::Scope,
    failures: &mut Vec<String>,
) {
    if !declares(env, scope) {
        return;
    }
    if let Err(error) = super::project::register_target(env, registering, scope) {
        failures.push(error.to_string());
    }
}

/// One scope's outcome, held until the run has nothing left to say.
///
/// The snapshot pass runs after every scope is written and can warn, and
/// a warning under a closing line is a run that ended twice. Held here,
/// each scope still closes on its own ledger and every one of them is
/// genuinely last.
struct Closing {
    scope: kendex_core::model::Scope,
    /// What the scope's writes did, `None` for nothing to write.
    done: Option<Vec<Effect>>,
    /// The question above already listed every change in `done`.
    listed: bool,
    attention: Attention,
    scored: Vec<kendex_core::engine::ItemSafety>,
}

/// Final plan and known writes, and where the write stopped short of its
/// last one.
struct Written {
    report: kendex_core::engine::EngineReport,
    /// Every change that landed, in the order it did. `None` is a scope
    /// with nothing to write, up to date.
    done: Option<Vec<Effect>>,
    /// What the scope's question listed, where one was drawn: a closing
    /// line over the same changes does not list them again.
    asked: Vec<Effect>,
    /// The scope reported a failure before a write that had nothing to
    /// write, which leaves the named project unregistered
    /// (`project::register_target`).
    failed: bool,
    /// The reading the offer this scope still owes covers from, `None`
    /// where its write already made it.
    owed: Option<Before>,
    stop: Option<Stop>,
}

/// Why a write that had already written stopped short of its last write.
enum Stop {
    /// The person declined what was left.
    Declined,
    /// A cancel, or a failure.
    Failed(Box<dyn std::error::Error>),
}

enum ScopeWrite {
    Written(Box<Written>),
    /// Nothing written, and the person said no.
    Declined,
}

/// A selected scope after every read needed to decide whether this run will
/// need consent. No scope writes until every preparation has finished.
struct PreparedScope {
    scope: kendex_core::model::Scope,
    synced: kendex_core::remote::Synced,
    options: PlanOptions,
    planned: Planned,
    reach: Reached,
}

/// One scope's plan and the Pi settlement it owes, or why it has neither.
type Planned = Result<(EngineReport, Vec<PiSettle>), String>;

impl PreparedScope {
    /// Orphan comment removals are absent: a run nobody can answer never
    /// plans them ([`prepare_scope`]), so they never refuse a run.
    fn needs_consent(&self) -> bool {
        match &self.planned {
            Ok((report, pending)) => {
                report.recovers.is_some() || !report.set_changes.is_empty() || !pending.is_empty()
            }
            Err(_) => false,
        }
    }
}

/// What a scope's write reads of its own preparation and of the run.
struct Context<'a> {
    synced: &'a kendex_core::remote::Synced,
    options: &'a PlanOptions,
    /// Every scope the run writes, whose Pi roots each settle's install
    /// guard checks (`pi_ext::paired_roots`).
    targeted: &'a [kendex_core::model::Scope],
    reach: Reached,
    verbose: bool,
    yes: bool,
}

fn sync_scope(env: &Env, scope: &kendex_core::model::Scope) -> kendex_core::remote::Synced {
    match kendex_core::engine::ops::manifest_for_reading(env, scope) {
        Ok(manifest) => {
            let _reading = ui::spinner(&format!("reading marketplaces for {}", scope_label(scope)));
            kendex_core::remote::sync_declared_sources(env, scope, &manifest)
        }
        Err(_) => kendex_core::remote::Synced::default(),
    }
}

/// What every scope of this refresh plans with. Orphan settings comment
/// removals are an offer: planned only where the run can be answered, so a
/// scripted refresh without `--yes` keeps the comments and writes what it
/// would write without them.
fn refresh_options(catalog: Catalog, takes: Takes, yes: bool) -> PlanOptions {
    PlanOptions {
        remove_orphan_settings_comments: answerable(yes),
        sweep_unneeded: true,
        overwrite_edited: takes.discard_edits,
        prune_retired: takes.prune,
        ..catalog.plan_options()
    }
}

fn prepare_scope(
    env: &Env,
    scope: kendex_core::model::Scope,
    synced: kendex_core::remote::Synced,
    options: PlanOptions,
    reach: Reached,
    targeted: &[kendex_core::model::Scope],
) -> Result<PreparedScope, Box<dyn std::error::Error>> {
    let planned = plan_scope(env, &scope, &synced, &options, targeted)?;
    Ok(PreparedScope {
        scope,
        synced,
        options,
        planned,
        reach,
    })
}

/// One scope's plan and the Pi settlement it owes, or the reason it has
/// neither; only a catalog compatibility failure stops the whole run.
///
/// A plan that recovers a version 10 record settles nothing yet: the
/// settlement reads the record, and is read again once the recovery has
/// written the current one.
fn plan_scope(
    env: &Env,
    scope: &kendex_core::model::Scope,
    synced: &kendex_core::remote::Synced,
    options: &PlanOptions,
    targeted: &[kendex_core::model::Scope],
) -> Result<Planned, Box<dyn std::error::Error>> {
    let report = {
        let _planning = ui::spinner(&format!("planning {}", scope_label(scope)));
        plan_apply(env, scope, options)
    };
    Ok(match report {
        Ok(mut report) => {
            synced.suppress_busy_pending(&mut report.notes);
            if report.recovers.is_some() {
                return Ok(Ok((report, Vec::new())));
            }
            match super::update_pi::pending_settle(env, scope, options, targeted) {
                Ok(pending) => Ok((report, pending)),
                Err(error)
                    if error
                        .downcast_ref::<kendex_core::error::CoreError>()
                        .is_some_and(kendex_core::error::CoreError::is_catalog_compatibility) =>
                {
                    return Err(error);
                }
                Err(error) => Err(error.to_string()),
            }
        }
        Err(error) if error.is_catalog_compatibility() => return Err(error.into()),
        Err(error) => Err(error.to_string()),
    })
}

fn prepare_scopes(
    env: &Env,
    filter: ScopeFilter,
    target: &crate::flags::ProjectTargetFlag,
    verbose: bool,
    yes: bool,
    catalog: Catalog,
    takes: Takes,
) -> Result<(Vec<PreparedScope>, super::project::Registering), Box<dyn std::error::Error>> {
    let scopes = resolve_scopes_at(env, filter, target.path())?;
    super::header("refresh", &scopes);
    // The refusal that registration carries, asked before the first write
    // so a run never installs into a folder it would then decline to
    // register. `project::register_target` owns the rule itself.
    let registering = super::project::target_registrable(env, target, &scopes)?;
    // Fetching cache snapshots precedes the gate; rendering and install writes do not.
    let synced: Vec<_> = scopes.iter().map(|scope| sync_scope(env, scope)).collect();
    let options = catalog.plan_options();
    for scope in &scopes {
        if let Err(error) = kendex_core::engine::check_catalog_compatibility(env, scope, &options)
            && error.is_catalog_compatibility()
        {
            return Err(error.into());
        }
    }
    let reach = Reached::of(target.path());
    let planning = refresh_options(catalog, takes, yes);
    let prepared: Vec<_> = scopes
        .iter()
        .cloned()
        .zip(synced)
        .map(|(scope, synced)| prepare_scope(env, scope, synced, planning.clone(), reach, &scopes))
        .collect::<Result<_, Box<dyn std::error::Error>>>()?;
    if prepared.iter().any(PreparedScope::needs_consent)
        && let Err(error) = require_yes_in_non_interactive(yes)
    {
        print_refusal_context(env, &prepared, verbose);
        return Err(error);
    }
    Ok((prepared, registering))
}

/// Print everything the read-only preparation can establish before a
/// non-interactive run refuses its missing consent. A pending Pi settlement
/// keeps its diagnostics for the plan derived after settlement.
fn print_refusal_context(env: &Env, prepared: &[PreparedScope], verbose: bool) {
    let mut failures = Vec::new();
    for scope in prepared {
        print_synced(&scope.synced);
        failures.extend(scope.synced.failures.iter().cloned());
        match &scope.planned {
            Ok((report, pending)) => {
                if pending.is_empty() {
                    print_attention(env, report, listing(verbose), scope.reach, &[]);
                    failures.extend(refresh_failures(report, &[]));
                }
            }
            Err(error) => failures.push(error.clone()),
        }
    }
    for failure in failures {
        ui::report::failure(&failure);
    }
    for scope in prepared {
        if let Ok((report, pending)) = &scope.planned
            && scope.needs_consent()
        {
            print_consent(&scope.scope, report, &Consent::of(report, pending));
        }
    }
}

/// The declared Pi packages this scope leaves for `update-pi` only because
/// their install runs a process, which a refresh never starts: a notice
/// each, and their names for the run's failures to pass over. Their rows
/// stay in the plan, carrying the engine's `RowRemedy::UpdatePi`, so the
/// attention, the closing ledger and the completion name `update-pi` for
/// them as for every other package it settles. Settlement owns
/// eligibility; the install plan and durable record stay intact.
fn defer_process_installs(
    env: &Env,
    scope: &kendex_core::model::Scope,
    context: &Context,
    report: &EngineReport,
) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let deferred =
        super::update_pi::deferred_settle(env, scope, context.options, context.targeted)?;
    for row in &report.drift {
        if row.remedy == Some(kendex_core::engine::RowRemedy::UpdatePi)
            && deferred.contains(&row.name)
        {
            ui::report::notice(&format!(
                "{}: install needs a process; use kendex update-pi to settle it",
                row.name
            ));
        }
    }
    Ok(deferred)
}

/// One scope's write: the yes it needs, the settle that yes covers, and
/// the plan applied after it.
///
/// One question covers the settle and the plan before either writes: it
/// lists every package the settle lands and every op the plan writes, and
/// counts that list. The plan derived after the settle runs without a
/// further question where the yes already covers every op it writes
/// (`decision::Approved`); an op it does not cover is listed and asked
/// about on its own, and what the settle landed stays landed whatever
/// that answer is.
///
/// One closing line for every path: a run that first asked about what it
/// installs still ends on the same ledger, since the outcomes it has to
/// report are the same either way. An empty plan closes on `None` — up to
/// date — and still reaches the commit offer, on whatever an earlier run
/// left uncommitted. Every stop this function sees before the last write
/// goes through [`Start::stopped_short`], which owns what a scope that
/// already wrote is owed; a plan's write that did not land is one of
/// them. A failure after the plan's write landed, in the render or the
/// commit offer, ends the scope written, through [`Start::wrote_plan`].
fn write_scope(
    env: &Env,
    scope: &kendex_core::model::Scope,
    report: kendex_core::engine::EngineReport,
    pending: &[PiSettle],
    start: &Start,
    context: &Context,
    report_after_settle: impl FnOnce(&mut kendex_core::engine::EngineReport, &Shown) -> CliResult,
) -> Result<ScopeWrite, Box<dyn std::error::Error>> {
    let yes = context.yes;
    if pending.is_empty() {
        return write_unsettled(env, scope, report, start, context);
    }
    let consent = Consent::of(&report, pending);
    print_consent(scope, &report, &consent);
    // What the plan read before the settle flagged is said before the yes
    // that lets it write; the report after the settle leaves those rows
    // out rather than draw them twice.
    let shown = safety_before_consent(&report, context);
    match ask(&consent, yes) {
        Ok(Confirmation::Accepted) => {}
        Ok(Confirmation::Declined) => return start.stopped_short(report, None, Stop::Declined),
        Err(error) => return start.stopped_short(report, None, Stop::Failed(error)),
    }
    let approved = Approved::of(&report, &consent);
    let names: Vec<_> = pending.iter().map(|pending| pending.name.clone()).collect();
    let landed =
        match super::update_pi::settle_scope(env, scope, &names, context.options, context.targeted)
        {
            Ok(landed) => landed,
            Err(error) => return start.stopped_short(report, None, Stop::Failed(error)),
        };
    let settled: Vec<Effect> = pending
        .iter()
        .filter(|pending| landed.contains(&pending.name))
        .cloned()
        .map(Effect::Pi)
        .collect();
    let planned = {
        let _planning = ui::spinner(&format!("planning {}", scope_label(scope)));
        plan_apply(env, scope, context.options)
    };
    let mut after = match planned {
        Ok(after) => after,
        Err(error) => {
            return start.stopped_short(report, Some(settled), Stop::Failed(error.into()));
        }
    };
    // The carrier can make hooks enforceable. Show their diagnostics
    // before the further question, using this plan for the ledger.
    if let Err(error) = report_after_settle(&mut after, &shown) {
        return start.stopped_short(after, Some(settled), Stop::Failed(error));
    }
    let added = approved.added(&after);
    if !added.consent.is_empty() {
        ui::stderr(&ui::style().report_row(
            ui::Status::Decision,
            &[Span::Prose(&format!(
                "{}: settling added to what this run writes",
                scope_label(scope)
            ))],
            "",
        ));
        for change in &added.set_changes {
            say_set_change(change);
        }
        say_effects(scope, &added.consent);
        let stop = match ask(&added.consent, yes) {
            Ok(Confirmation::Accepted) => None,
            Ok(Confirmation::Declined) => Some(Stop::Declined),
            Err(error) => Some(Stop::Failed(error)),
        };
        if let Some(stop) = stop {
            return start.stopped_short(after, Some(settled), stop);
        }
    }
    let asked = match added.consent.is_empty() {
        true => consent.effects,
        false => Vec::new(),
    };
    let write = match apply_report_accounted(env, &after, start.before()) {
        Ok(wrote) => {
            let written = after.plan.ops.iter().cloned().map(Effect::Op);
            let done = start.done(Some(settled.into_iter().chain(written).collect()));
            start.wrote_plan(after, done, wrote.after)
        }
        Err(error) => start.stopped_short(after, Some(settled), Stop::Failed(error))?,
    };
    Ok(asked_over(write, asked))
}

/// [`write_scope`] for a scope with no Pi package to settle: its orphan
/// comment removals asked about alone where nothing else asks, the one
/// question over the plan where it changes what is installed, then the
/// plan's write.
fn write_unsettled(
    env: &Env,
    scope: &kendex_core::model::Scope,
    report: EngineReport,
    start: &Start,
    context: &Context,
) -> Result<ScopeWrite, Box<dyn std::error::Error>> {
    let yes = context.yes;
    let set_consent = |report: &EngineReport| {
        !report.set_changes.is_empty() && !start.covers(&report.set_changes)
    };
    let report = if set_consent(&report) || report.removed_settings_comments.is_empty() {
        report
    } else {
        match offer_removals(env, scope, report, context) {
            Ok(report) => report,
            Err((report, error)) => {
                return start.stopped_short(*report, None, Stop::Failed(error));
            }
        }
    };
    let consent = Consent::of(&report, &[]);
    if set_consent(&report) && !consent.is_empty() {
        print_consent(scope, &report, &consent);
        match ask(&consent, yes) {
            Ok(Confirmation::Accepted) => {}
            Ok(Confirmation::Declined) => {
                return start.stopped_short(report, None, Stop::Declined);
            }
            Err(error) => return start.stopped_short(report, None, Stop::Failed(error)),
        }
    }
    let asked = match set_consent(&report) {
        true => consent.effects.clone(),
        false => Vec::new(),
    };
    match apply_report_accounted(env, &report, start.before()) {
        Ok(wrote) => {
            let done = start.done((!consent.is_empty()).then_some(consent.effects));
            Ok(asked_over(
                start.wrote_plan(report, done, wrote.after),
                asked,
            ))
        }
        Err(error) => start.stopped_short(report, None, Stop::Failed(error)),
    }
}

/// A written scope, with what its question listed.
fn asked_over(write: ScopeWrite, asked: Vec<Effect>) -> ScopeWrite {
    match write {
        ScopeWrite::Written(mut written) => {
            written.asked = asked;
            ScopeWrite::Written(written)
        }
        ScopeWrite::Declined => ScopeWrite::Declined,
    }
}

/// The safety rows of the plan a settle's question is asked over, drawn
/// before that question, and handed back so the report after the settle
/// does not draw them again.
fn safety_before_consent(report: &EngineReport, context: &Context) -> Shown {
    let style = ui::style();
    let listed = listing(context.verbose);
    let lines = super::advisory::safety_section(&style, &report.safety, listed);
    let folded = listed == Listing::Attention
        && super::advisory::safety_section(&style, &report.safety, Listing::Verbose) != lines;
    ui::stderr(&lines);
    Shown {
        safety: report.safety.clone(),
        folded,
    }
}

/// What a scope drew before its settle's question, which the report after
/// the settle neither draws again nor forgets it folded.
struct Shown {
    safety: Vec<kendex_core::engine::ItemSafety>,
    /// The compact drawing left out detail a verbose one draws.
    folded: bool,
}

/// A plan whose only question is its orphan settings comment removals asks
/// that question alone. A yes keeps the plan, whose other writes need no
/// answer; a no plans the scope again without the removals, so declining
/// keeps the comments and never the rest of the refresh. The error carries
/// the plan it stopped at.
fn offer_removals(
    env: &Env,
    scope: &kendex_core::model::Scope,
    report: EngineReport,
    context: &Context,
) -> Result<EngineReport, (Box<EngineReport>, Box<dyn std::error::Error>)> {
    say_removed_comments(scope, &report);
    let removals = report.removed_settings_comments.len();
    let question = format!(
        "remove {removals} orphan settings comment{}?",
        if removals == 1 { "" } else { "s" }
    );
    match confirm_before_writing(&question, context.yes) {
        Ok(Confirmation::Accepted) => return Ok(report),
        Ok(Confirmation::Declined) => {}
        Err(error) => return Err((Box::new(report), error)),
    }
    let options = PlanOptions {
        remove_orphan_settings_comments: false,
        ..context.options.clone()
    };
    let planned = {
        let _planning = ui::spinner(&format!("planning {}", scope_label(scope)));
        plan_apply(env, scope, &options)
    };
    match planned {
        Ok(mut kept) => {
            context.synced.suppress_busy_pending(&mut kept.notes);
            Ok(kept)
        }
        Err(error) => Err((Box::new(report), error.into())),
    }
}

/// What a scope's write starts from: a version 10 record this run
/// recovered before it, or nothing written.
enum Start {
    Fresh,
    Recovered(Recovered),
}

/// A version 10 record this run recovered, before the scope's own write.
struct Recovered {
    /// What the recovery wrote.
    done: Vec<Effect>,
    /// The project as it stood before the recovery: the scope's one offer
    /// comes after its last write, and covers what the whole run changed.
    before: Before,
    /// What the recovery's consent listed as installed.
    set_changes: Vec<kendex_core::engine::SetChange>,
}

impl Start {
    /// Whether this run already wrote into the scope.
    fn wrote(&self) -> bool {
        matches!(self, Start::Recovered(_))
    }

    /// The reading the scope's one offer covers from, where the recovery
    /// took it; `None` where the scope's own write reads it.
    fn before(&self) -> Option<&Before> {
        match self {
            Start::Fresh => None,
            Start::Recovered(recovered) => Some(&recovered.before),
        }
    }

    /// Whether the recovery's consent already answered these changes: a
    /// later plan of the same run that installs or removes nothing it did
    /// not list adds no effect the person was not asked about. A scope
    /// with no recovery was asked nothing yet.
    fn covers(&self, changes: &[kendex_core::engine::SetChange]) -> bool {
        match self {
            Start::Fresh => false,
            Start::Recovered(recovered) => changes
                .iter()
                .all(|change| recovered.set_changes.contains(change)),
        }
    }

    /// What the scope's writes did, `here` being what the write itself
    /// did, `None` for nothing to write: the recovery's writes come first
    /// whatever came after them.
    fn done(&self, here: Option<Vec<Effect>>) -> Option<Vec<Effect>> {
        match self {
            Start::Fresh => here,
            Start::Recovered(recovered) => Some(
                recovered
                    .done
                    .iter()
                    .cloned()
                    .chain(here.unwrap_or_default())
                    .collect(),
            ),
        }
    }

    /// A scope whose plan's write landed, `after` being how the steps
    /// after it went. A render that failed made no offer, which is owed
    /// over what the write changed from the reading it took; an offer
    /// that was made, failed or not, is not made again.
    fn wrote_plan(
        &self,
        report: EngineReport,
        done: Option<Vec<Effect>>,
        after: Result<(), AfterFailed>,
    ) -> ScopeWrite {
        let (stop, owed) = match after {
            Ok(()) => (None, None),
            Err(AfterFailed::Render { error, before }) => (Some(error), Some(before)),
            Err(AfterFailed::Offer(error)) => (Some(error), None),
        };
        ScopeWrite::Written(Box::new(Written {
            report,
            done,
            asked: Vec::new(),
            failed: false,
            owed,
            stop: stop.map(Stop::Failed),
        }))
    }

    /// The one rule for a write that stops before its last write, `wrote`
    /// being what it already wrote itself: a scope this run has written
    /// into — the recovery, or a settle — is owed its offer, its closing
    /// line and its snapshot whatever stopped it, so it ends written,
    /// carrying the stop for [`stopped`], and the offer it owes covers
    /// from the reading taken before its first write. A scope with nothing
    /// written ends declined, or on the error itself.
    fn stopped_short(
        &self,
        report: EngineReport,
        wrote: Option<Vec<Effect>>,
        stop: Stop,
    ) -> Result<ScopeWrite, Box<dyn std::error::Error>> {
        match (self.done(wrote), stop) {
            (None, Stop::Declined) => Ok(ScopeWrite::Declined),
            (None, Stop::Failed(error)) => Err(error),
            (done, stop) => Ok(ScopeWrite::Written(Box::new(Written {
                report,
                done,
                asked: Vec::new(),
                failed: false,
                owed: Some(self.before().cloned().unwrap_or(Before::Untaken)),
                stop: Some(stop),
            }))),
        }
    }
}

/// Move a version 10 record aside and install from the declarations, in
/// one transaction under one yes, with no offer yet: the scope is planned
/// again over the record this writes, and its own write, Pi settlement
/// included, ends on the offer. `None` where the person declined.
fn recover_scope(
    env: &Env,
    scope: &kendex_core::model::Scope,
    report: &EngineReport,
    yes: bool,
) -> Result<Option<Recovered>, Box<dyn std::error::Error>> {
    let consent = Consent::of(report, &[]);
    print_consent(scope, report, &consent);
    if ask(&consent, yes)? == Confirmation::Declined {
        return Ok(None);
    }
    let before = before_writing(report);
    write_report(env, report)?;
    Ok(Some(Recovered {
        done: consent.effects,
        before,
        set_changes: report.set_changes.clone(),
    }))
}

pub fn run_args(env: &Env, args: RefreshArgs) -> CliResult {
    let filter = args.effective_scope()?;
    run(
        env,
        filter,
        &args.target,
        args.verbose,
        args.yes,
        args.catalog(),
        args.takes(),
    )
}

pub fn run(
    env: &Env,
    filter: ScopeFilter,
    target: &crate::flags::ProjectTargetFlag,
    verbose: bool,
    yes: bool,
    catalog: Catalog,
    takes: Takes,
) -> CliResult {
    let mut refreshed_anything = false;
    let mut failures: Vec<String> = Vec::new();
    let mut closing: Vec<Closing> = Vec::new();
    // The scopes this run got through, and the cancel that stopped it at
    // one of them. A cancel ends the run, but it does not unwrite what
    // the scopes before it already wrote.
    let mut reached: Vec<kendex_core::model::Scope> = Vec::new();
    let mut cancelled: Option<Box<dyn std::error::Error>> = None;
    let (prepared, registering) =
        prepare_scopes(env, filter, target, verbose, yes, catalog, takes)?;
    let targeted: Vec<_> = prepared.iter().map(|scope| scope.scope.clone()).collect();

    for prepared in prepared {
        let PreparedScope {
            scope,
            synced,
            options,
            planned,
            reach,
        } = prepared;
        reached.push(scope.clone());
        let context = Context {
            synced: &synced,
            options: &options,
            targeted: &targeted,
            reach,
            verbose,
            yes,
        };
        let mut attention = Attention::default();
        let outcome = match ready_to_write(env, &scope, planned, &context, &mut failures)? {
            Ready::Skip => continue,
            Ready::Ended(outcome) => outcome,
            Ready::Write(writing) => {
                match write_ready(
                    env,
                    &scope,
                    *writing,
                    &context,
                    &registering,
                    &mut attention,
                    &mut failures,
                )? {
                    Some(outcome) => outcome,
                    None => continue,
                }
            }
        };
        refreshed_anything = true;
        match outcome {
            Ok(ScopeWrite::Declined) => {
                reached.pop();
                declined_scope(&scope);
            }
            Ok(ScopeWrite::Written(written)) => {
                let close = Closing {
                    scope: scope.clone(),
                    done: written.done.clone(),
                    listed: written
                        .done
                        .as_deref()
                        .is_some_and(|done| same_changes(done, &written.asked)),
                    attention,
                    scored: written.report.safety.clone(),
                };
                if let Some(error) = close_written(
                    env,
                    &registering,
                    *written,
                    close,
                    &mut closing,
                    &mut failures,
                ) {
                    cancelled = Some(error);
                    break;
                }
            }
            // A cancel is the reader stopping the run, not one scope
            // failing to refresh. Collected as a failure it would come out
            // as "refresh failed: 1 problem(s), listed above" and exit 1,
            // and the exit code a script keys a cancel on is 130.
            //
            // It stops the scopes after this one, never the finishing of
            // the ones before it. An error reaches here from a scope
            // `Start::stopped_short` reads as unwritten, so this scope
            // drops off the reached list, while what earlier scopes wrote
            // is on disk and owed both a snapshot and a closing line.
            Err(error) if ui::cancelled(error.as_ref()) => {
                reached.pop();
                cancelled = Some(error);
                break;
            }
            Err(error) => failures.push(error.to_string()),
        }
    }

    for failure in &failures {
        ui::report::failure(failure);
    }
    finish_scopes(env, &reached, closing, verbose);
    refresh_result(refreshed_anything, &failures, cancelled)
}

/// A ready scope's diagnostics and its write; `None` for a scope passed
/// over with nothing to write. A declared Pi package installs outside the
/// plan, through the install `update-pi` owns, and its record is
/// machine-local: a clone carries the package and no record, and this
/// plan reports every such package as drift. What the settle would
/// install is read before the yes that lets it write, and the
/// diagnostics come from the plan derived after settlement, so a package
/// this run settles never prints a stale update-pi remedy; a package left
/// for `update-pi` because its install runs a process is no failure of
/// this run. A scope settling nothing is reported off this plan, and a
/// run that refused every install is not "nothing installed": a scope
/// carrying a refusal is never passed over.
fn write_ready(
    env: &Env,
    scope: &kendex_core::model::Scope,
    writing: Writing,
    context: &Context,
    registering: &super::project::Registering,
    attention: &mut Attention,
    failures: &mut Vec<String>,
) -> Result<Option<Outcome>, Box<dyn std::error::Error>> {
    let Writing {
        report,
        pending,
        start,
    } = writing;
    let listed = listing(context.verbose);
    let mut failed = false;
    if pending.is_empty() {
        let deferred = match defer_process_installs(env, scope, context, &report) {
            Ok(deferred) => deferred,
            Err(error) => return Ok(Some(start.stopped_short(report, None, Stop::Failed(error)))),
        };
        *attention = print_attention(env, &report, listed, context.reach, &[]);
        let reported = refresh_failures(&report, &deferred);
        failed = !context.synced.failures.is_empty() || !reported.is_empty();
        failures.extend(reported);
        // A recovery wrote a record this run, whatever the plan after it.
        // The record refusing to read is what stops a scope with none.
        if !start.wrote()
            && load_lock(&lock_path(env, scope))?.entries.is_empty()
            && report.plan.is_empty()
            && attention.blocked.is_empty()
            && attention.pi_left.is_none()
        {
            // Nothing left to write is not a reason to leave the named
            // project off the projects list: the run got through this
            // scope, which is what registration follows.
            //
            // A scope that reported a failure is the exception. It wrote
            // nothing and the run exits nonzero, so listing the folder
            // would be the one lasting effect of a run that failed.
            if !failed {
                register_written(env, registering, scope, failures);
            }
            return Ok(None);
        }
    }
    let mut outcome = write_scope(
        env,
        scope,
        report,
        &pending,
        &start,
        context,
        |after, shown| {
            context.synced.suppress_busy_pending(&mut after.notes);
            let deferred = defer_process_installs(env, scope, context, after)?;
            *attention = print_attention(env, after, listed, context.reach, &shown.safety);
            attention.folded |= shown.folded;
            failures.extend(refresh_failures(after, &deferred));
            Ok(())
        },
    );
    // A scope with packages left goes on to its closing ledger even with
    // nothing to write, and the ledger is not a write: with a failure to
    // report, `close_written` lists nothing.
    if let Ok(ScopeWrite::Written(written)) = &mut outcome {
        written.failed = failed;
    }
    Ok(Some(outcome))
}

/// What a written scope owes before the run moves on: what its armed
/// packages say now that it is written, said and never acted on (a
/// refresh arms nothing, and `commands::repo_effects` says why the record
/// of an earlier yes does not change that), its registration where it
/// wrote or reported no failure (`project::register_target`), its closing
/// line, and what a write that stopped short owes ([`stopped`]). `Some`
/// is the cancel that ends the run.
fn close_written(
    env: &Env,
    registering: &super::project::Registering,
    written: Written,
    close: Closing,
    closing: &mut Vec<Closing>,
    failures: &mut Vec<String>,
) -> Option<Box<dyn std::error::Error>> {
    let scope = close.scope.clone();
    super::repo_effects::say_lapsed(env, &scope, &[]);
    if written.done.is_some() || !written.failed {
        register_written(env, registering, &scope, failures);
    }
    closing.push(close);
    stopped(env, &scope, written, failures)
}

/// What a write that stopped short of its last write owes: a cancel ends
/// the run, and a decline or any other stop still reaches the offer the
/// scope owes, where its write did not already make it.
/// The scope's closing line and snapshot are the caller's, for every
/// written scope alike.
fn stopped(
    env: &Env,
    scope: &kendex_core::model::Scope,
    written: Written,
    failures: &mut Vec<String>,
) -> Option<Box<dyn std::error::Error>> {
    match written.stop? {
        Stop::Failed(error) if ui::cancelled(error.as_ref()) => return Some(error),
        Stop::Failed(error) => failures.push(error.to_string()),
        Stop::Declined => ui::report::notice(&format!(
            "{}: remaining changes declined",
            consent_scope(scope)
        )),
    }
    if let Some(before) = &written.owed
        && let Err(error) = after_writing(env, scope, &written.report.generated, before)
    {
        failures.push(error.to_string());
    }
    None
}

/// A scope ready to write: its plan, the Pi settlement it owes, and what
/// this run already wrote into it.
struct Writing {
    report: EngineReport,
    pending: Vec<PiSettle>,
    start: Start,
}

/// Where a scope stands before its write.
enum Ready {
    Write(Box<Writing>),
    /// The scope failed before its write, said among the run's failures.
    Skip,
    /// The scope's outcome is settled before its own write: the recovery
    /// declined or cancelled, which wrote nothing, or a plan after a
    /// written recovery that failed, which ends written.
    Ended(Outcome),
}

/// How one scope's write ended: written, declined with nothing written,
/// or stopped by an error before anything was.
type Outcome = Result<ScopeWrite, Box<dyn std::error::Error>>;

/// A prepared scope made ready to write. A scope whose version 10 record
/// the plan recovers writes the recovery first, then is planned again over
/// the record that wrote, Pi settlement included; a plan after the
/// recovery that fails ends the scope through [`Start::stopped_short`].
fn ready_to_write(
    env: &Env,
    scope: &kendex_core::model::Scope,
    planned: Planned,
    context: &Context,
    failures: &mut Vec<String>,
) -> Result<Ready, Box<dyn std::error::Error>> {
    // An unreachable catalog is reported, not fatal: what came from every
    // other catalog still refreshes.
    print_synced(context.synced);
    failures.extend(context.synced.failures.iter().cloned());
    let (report, pending) = match planned {
        Ok(planned) => planned,
        Err(error) => {
            failures.push(error);
            return Ok(Ready::Skip);
        }
    };
    if report.recovers.is_none() {
        return Ok(Ready::Write(Box::new(Writing {
            report,
            pending,
            start: Start::Fresh,
        })));
    }
    let start = match recover_scope(env, scope, &report, context.yes) {
        Ok(Some(recovered)) => Start::Recovered(recovered),
        Ok(None) => return Ok(Ready::Ended(Ok(ScopeWrite::Declined))),
        Err(error) if ui::cancelled(error.as_ref()) => return Ok(Ready::Ended(Err(error))),
        Err(error) => {
            print_attention(env, &report, listing(context.verbose), context.reach, &[]);
            failures.push(error.to_string());
            return Ok(Ready::Skip);
        }
    };
    let replanned = match plan_scope(
        env,
        scope,
        context.synced,
        context.options,
        context.targeted,
    ) {
        Ok(Ok(replanned)) => Ok(replanned),
        Ok(Err(error)) => Err(error.into()),
        Err(error) => Err(error),
    };
    Ok(match replanned {
        Ok((report, pending)) => Ready::Write(Box::new(Writing {
            report,
            pending,
            start,
        })),
        Err(error) => Ready::Ended(start.stopped_short(report, None, Stop::Failed(error))),
    })
}

fn refresh_result(
    refreshed_anything: bool,
    failures: &[String],
    cancelled: Option<Box<dyn std::error::Error>>,
) -> CliResult {
    if let Some(error) = cancelled {
        return Err(error);
    }

    if !refreshed_anything && failures.is_empty() {
        ui::stderr(&ui::style().summary(ui::Status::Done, "nothing installed"));
        return Ok(());
    }
    if !failures.is_empty() {
        return Err(format!(
            "refresh failed: {} problem(s), listed above",
            failures.len()
        )
        .into());
    }
    Ok(())
}
