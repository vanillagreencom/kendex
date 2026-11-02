use kendex_core::commit_offer::Before;
use kendex_core::engine::{EngineReport, PlanOptions, plan_apply};
use kendex_core::env::Env;
use kendex_core::lock::{load as load_lock, lock_path};

use super::advisory::Listing;
use super::attention::{Attention, print_attention};
use super::commit_offer::after_writing;
use super::engine_common::{
    Confirmation, PlanApplication, before_writing, confirm_before_writing, confirm_plan_and_apply,
    print_synced, refresh_failures, require_yes_in_non_interactive, write_report,
};
use super::ledger::{Folded, Wrote, say_ledger};
use super::offers::Reached;
use super::update_pi::{Pending, PendingChange};
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

fn print_changes_needing_consent(
    scope: &kendex_core::model::Scope,
    report: &EngineReport,
    pending: &[Pending],
) {
    print_set_changes(scope, report);
    for pending in pending {
        let name = &pending.name;
        let change = match &pending.change {
            PendingChange::Missing => format!("install Pi extension {name}"),
            PendingChange::Stale {
                from_version,
                to_version,
                from,
                to,
            } => {
                format!(
                    "update Pi extension {name}: from version {} (source {from}) to version {} (source {to})",
                    from_version.as_deref().unwrap_or("unknown"),
                    to_version.as_deref().unwrap_or("unknown")
                )
            }
        };
        ui::stderr(&ui::style().report_row(
            ui::Status::Decision,
            &[Span::Prose(&format!("{change}; {}", consent_scope(scope)))],
            "  - ",
        ));
    }
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
fn finish_scopes(env: &Env, reached: &[kendex_core::model::Scope], closing: Vec<Closing>) {
    record_snapshots(env, reached);
    super::engine_common::tidy_trash(env);
    for scope in closing {
        say_ledger(
            &scope.scope,
            refreshed(scope.count),
            &scope.attention.blocked,
            &scope.scored,
            match scope.attention.folded {
                true => Folded::BehindVerbose,
                false => Folded::None,
            },
        );
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
    count: Option<usize>,
    attention: Attention,
    scored: Vec<kendex_core::engine::ItemSafety>,
}

/// Final plan and known writes, including a stop after Pi settlement.
struct Written {
    report: kendex_core::engine::EngineReport,
    /// `None` is a scope with nothing to write, up to date.
    count: Option<usize>,
    stop: Option<Box<dyn std::error::Error>>,
}

enum ScopeWrite {
    Written(Box<Written>),
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
type Planned = Result<(EngineReport, Vec<Pending>), String>;

impl PreparedScope {
    fn needs_consent(&self) -> bool {
        match &self.planned {
            Ok((report, pending)) => {
                report.recovers.is_some() || !report.set_changes.is_empty() || !pending.is_empty()
            }
            Err(_) => false,
        }
    }
}

fn sync_scope(env: &Env, scope: &kendex_core::model::Scope) -> kendex_core::remote::Synced {
    match kendex_core::engine::ops::manifest_for_reading(env, scope) {
        Ok(manifest) => {
            let _reading = ui::spinner(&format!("reading marketplaces for {}", scope_label(scope)));
            kendex_core::remote::sync_declared_sources(env, &manifest)
        }
        Err(_) => kendex_core::remote::Synced::default(),
    }
}

fn prepare_scope(
    env: &Env,
    scope: kendex_core::model::Scope,
    synced: kendex_core::remote::Synced,
    (catalog, takes, reach): (Catalog, Takes, Reached),
) -> Result<PreparedScope, Box<dyn std::error::Error>> {
    let options = PlanOptions {
        sweep_unneeded: true,
        overwrite_edited: takes.discard_edits,
        prune_retired: takes.prune,
        ..catalog.plan_options()
    };
    let planned = plan_scope(env, &scope, &synced, &options)?;
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
            match super::update_pi::pending_settle(env, scope, options) {
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
    let prepared: Vec<_> = scopes
        .into_iter()
        .zip(synced)
        .map(|(scope, synced)| {
            let reach = Reached::of(target.path());
            prepare_scope(env, scope, synced, (catalog, takes, reach))
        })
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
                    print_attention(env, report, listing(verbose), scope.reach);
                    failures.extend(refresh_failures(report));
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
            print_changes_needing_consent(&scope.scope, report, pending);
        }
    }
}

/// Remove only dependency-only Pi drift from this verb's failure report.
/// Settlement owns eligibility; the install plan and durable record stay intact.
fn defer_process_installs(
    env: &Env,
    scope: &kendex_core::model::Scope,
    options: &PlanOptions,
    report: &mut EngineReport,
) -> CliResult {
    let deferred = super::update_pi::deferred_settle(env, scope, options)?;
    report.drift.retain(|row| {
        let defer = row.kind == kendex_core::model::ItemKind::PiExtension
            && row.harness == kendex_core::model::HarnessId::Pi
            && row.state == kendex_core::engine::DriftState::Stale
            && deferred.contains(&row.name);
        if defer {
            ui::report::notice(&format!(
                "{}: install needs a process; use kendex update-pi to settle it",
                row.name
            ));
        }
        !defer
    });
    Ok(())
}

/// One scope's write: the yes it needs, the settle that yes covers, and
/// the plan applied after it.
///
/// One closing line for every path: a run that first asked about what it
/// installs still ends on the same ledger, since the outcomes it has to
/// report are the same either way. An empty plan closes on `None` — up to
/// date — and still reaches the commit offer, on whatever an earlier run
/// left uncommitted.
#[allow(clippy::too_many_arguments)]
fn write_scope(
    env: &Env,
    scope: &kendex_core::model::Scope,
    report: kendex_core::engine::EngineReport,
    pending: &[Pending],
    options: &PlanOptions,
    yes: bool,
    recovered: Option<&Recovered>,
    report_after_settle: impl FnOnce(&mut kendex_core::engine::EngineReport) -> CliResult,
) -> Result<ScopeWrite, Box<dyn std::error::Error>> {
    let before = recovered.map(|recovered| &recovered.before);
    if pending.is_empty() {
        let needs_consent = !report.set_changes.is_empty()
            && !recovered.is_some_and(|recovered| recovered.covers(&report.set_changes));
        if needs_consent && !report.plan.is_empty() {
            print_changes_needing_consent(scope, &report, pending);
        }
        let count = match confirm_plan_and_apply(env, &report, yes || !needs_consent, before)? {
            PlanApplication::Applied(applied) => (!report.plan.is_empty()).then_some(applied),
            // The recovery is written whatever the answer to what came
            // after it, and is owed its offer and its closing line.
            PlanApplication::Declined => match recovered {
                Some(recovered) => {
                    after_writing(env, scope, &report.generated, &recovered.before)?;
                    Some(0)
                }
                None => return Ok(ScopeWrite::Declined),
            },
        };
        let count = match recovered {
            Some(recovered) => Some(recovered.count + count.unwrap_or(0)),
            None => count,
        };
        return Ok(ScopeWrite::Written(Box::new(Written {
            report,
            count,
            stop: None,
        })));
    }
    print_changes_needing_consent(scope, &report, pending);
    let changes = report.plan.ops.len() + pending.len();
    if confirm_before_writing(
        &format!(
            "write {changes} change{}?",
            if changes == 1 { "" } else { "s" }
        ),
        yes,
    )? == Confirmation::Declined
    {
        return Ok(ScopeWrite::Declined);
    }
    let names: Vec<_> = pending.iter().map(|pending| pending.name.clone()).collect();
    let settled = super::update_pi::settle_scope(env, scope, &names, options)?;
    let mut after = {
        let _planning = ui::spinner(&format!("planning {}", scope_label(scope)));
        plan_apply(env, scope, options)?
    };
    // The carrier can make hooks enforceable. Show their diagnostics
    // before confirming the final writes, using this plan for the ledger.
    report_after_settle(&mut after)?;
    let approved: std::collections::BTreeSet<String> =
        report.plan.ops.iter().map(|op| op.line()).collect();
    let added_changes: Vec<_> = after
        .set_changes
        .iter()
        .filter(|change| !report.set_changes.contains(change))
        .collect();
    let added_ops: Vec<_> = after
        .plan
        .ops
        .iter()
        .filter(|op| !approved.contains(&op.line()))
        .collect();
    let added = added_changes.len() + added_ops.len();
    if added > 0 {
        ui::stderr(&ui::style().report_row(
            ui::Status::Decision,
            &[Span::Prose(&format!(
                "{}: settling added to what this run writes",
                scope_label(scope)
            ))],
            "",
        ));
        for change in added_changes {
            say_set_change(change);
        }
        for op in added_ops {
            ui::stderr(&ui::style().plan_row(op));
        }
    }
    // The recovery's yes answers a follow-up that installs nothing it did
    // not list; the Pi settlement above kept its own.
    let covered = recovered.is_some_and(|recovered| recovered.covers(&after.set_changes));
    let applied = match confirm_plan_and_apply(env, &after, yes || covered, before) {
        Ok(PlanApplication::Applied(applied)) => Ok(applied),
        Ok(PlanApplication::Declined) => {
            ui::report::notice(&format!(
                "{}: remaining changes declined",
                consent_scope(scope)
            ));
            after_writing(
                env,
                scope,
                &after.generated,
                before.unwrap_or(&Before::Untaken),
            )
            .map(|()| 0)
        }
        Err(error) => Err(error),
    };
    let recovered = recovered.map_or(0, |recovered| recovered.count);
    Ok(ScopeWrite::Written(Box::new(Written {
        report: after,
        count: Some(recovered + settled + applied.as_ref().map_or(0, |count| *count)),
        stop: applied.err(),
    })))
}

/// A version 10 record this run recovered, before the scope's own write.
struct Recovered {
    /// What the recovery wrote.
    count: usize,
    /// The project as it stood before the recovery: the scope's one offer
    /// comes after its last write, and covers what the whole run changed.
    before: Before,
    /// What the recovery's consent listed as installed.
    set_changes: Vec<kendex_core::engine::SetChange>,
}

impl Recovered {
    /// Whether the recovery's consent already answered these changes: a
    /// later plan of the same run that installs or removes nothing it did
    /// not list adds no effect the person was not asked about.
    fn covers(&self, changes: &[kendex_core::engine::SetChange]) -> bool {
        changes
            .iter()
            .all(|change| self.set_changes.contains(change))
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
    for planned in report
        .plan
        .ops
        .iter()
        .filter(|planned| matches!(planned.op, kendex_core::apply::Op::Rename { .. }))
    {
        ui::stderr(&ui::style().plan_row(planned));
    }
    if !report.set_changes.is_empty() {
        print_set_changes(scope, report);
    }
    let changes = report.plan.ops.len();
    if confirm_before_writing(
        &format!(
            "write {changes} change{}?",
            if changes == 1 { "" } else { "s" }
        ),
        yes,
    )? == Confirmation::Declined
    {
        return Ok(None);
    }
    let before = before_writing(report);
    let count = write_report(env, report)?;
    Ok(Some(Recovered {
        count,
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

    for prepared in prepared {
        let scope = prepared.scope;
        reached.push(scope.clone());
        let context = (
            &prepared.synced,
            &prepared.options,
            prepared.reach,
            verbose,
            yes,
        );
        let ready = ready_to_write(env, &scope, prepared.planned, context, &mut failures)?;
        let (mut report, pending, recovered) = match ready {
            Ready::Write(planned) => *planned,
            Ready::Skip => continue,
            Ready::Stopped(stop) => {
                reached.pop();
                refreshed_anything = true;
                match stop {
                    Some(error) => cancelled = Some(error),
                    None => continue,
                }
                break;
            }
        };
        // A declared Pi package installs outside the plan, through the
        // install `update-pi` owns, and its record is machine-local: a
        // clone carries the package and no record, and this plan reports
        // every such package as drift. What the settle would install is
        // read here, to be shown before the yes that lets it write. The
        // diagnostics come from the plan derived after settlement, so a
        // package this run settles never prints a stale update-pi remedy.
        // Only process-only deferrals become notices; every other Pi drift fails.
        // The record refusing to read is what stops the scope here.
        let mut attention = Attention::default();
        let lock = load_lock(&lock_path(env, &scope))?;
        // A scope settling nothing is reported off this plan, and a run
        // that refused every install is not "nothing installed": a scope
        // carrying a refusal is never passed over. A scope that settles is
        // reported off the plan derived after its settle.
        if pending.is_empty() {
            defer_process_installs(env, &scope, &prepared.options, &mut report)?;
            attention = print_attention(env, &report, listing(verbose), prepared.reach);
            let reported = refresh_failures(&report);
            let failed = !prepared.synced.failures.is_empty() || !reported.is_empty();
            failures.extend(reported);
            // A recovery wrote a record this run, whatever the plan after it.
            let unrecorded = recovered.is_none() && lock.entries.is_empty();
            if unrecorded && report.plan.is_empty() && attention.blocked.is_empty() {
                // Nothing left to write is not a reason to leave the
                // named project off the projects list: the run got
                // through this scope, which is what registration follows.
                //
                // A scope that reported a failure is the exception. It
                // wrote nothing and the run exits nonzero, so listing the
                // folder would be the one lasting effect of a run that
                // failed.
                if !failed {
                    register_written(env, &registering, &scope, &mut failures);
                }
                continue;
            }
        }
        refreshed_anything = true;
        match write_scope(
            env,
            &scope,
            report,
            &pending,
            &prepared.options,
            yes,
            recovered.as_ref(),
            |after| {
                prepared.synced.suppress_busy_pending(&mut after.notes);
                defer_process_installs(env, &scope, &prepared.options, after)?;
                attention = print_attention(env, after, listing(verbose), prepared.reach);
                Ok(())
            },
        ) {
            Ok(ScopeWrite::Declined) => {
                reached.pop();
                declined_scope(&scope);
            }
            Ok(ScopeWrite::Written(written)) => {
                if !pending.is_empty() {
                    failures.extend(refresh_failures(&written.report));
                }
                // What the scope's armed packages say now that it is
                // written. Said, never acted on: a refresh arms nothing,
                // and `commands::repo_effects` says why the record of an
                // earlier yes does not change that.
                super::repo_effects::say_lapsed(env, &scope, &[]);
                register_written(env, &registering, &scope, &mut failures);
                closing.push(Closing {
                    scope: scope.clone(),
                    count: written.count,
                    attention,
                    scored: written.report.safety.clone(),
                });
                if let Some(error) =
                    stopped(env, &scope, *written, recovered.as_ref(), &mut failures)
                {
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
            // the ones before it: the confirm asks before it writes, so
            // this scope wrote nothing and drops off the reached list,
            // while what earlier scopes wrote is on disk and owed both a
            // snapshot and a closing line.
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
    finish_scopes(env, &reached, closing);
    refresh_result(refreshed_anything, &failures, cancelled)
}

/// What a write that stopped part way owes: a cancel ends the run, and
/// any other stop is a failure whose writes still reach the offer, from
/// the reading taken before the scope's first write where there was one.
fn stopped(
    env: &Env,
    scope: &kendex_core::model::Scope,
    written: Written,
    recovered: Option<&Recovered>,
    failures: &mut Vec<String>,
) -> Option<Box<dyn std::error::Error>> {
    let error = written.stop?;
    if ui::cancelled(error.as_ref()) {
        return Some(error);
    }
    failures.push(error.to_string());
    let before = recovered.map_or(&Before::Untaken, |recovered| &recovered.before);
    if let Err(error) = after_writing(env, scope, &written.report.generated, before) {
        failures.push(error.to_string());
    }
    None
}

/// Where a scope stands before its write.
enum Ready {
    /// The plan to write, the Pi settlement it owes, and the version 10
    /// record recovered before it, where there was one.
    Write(Box<(EngineReport, Vec<Pending>, Option<Recovered>)>),
    /// The scope failed before its write, said among the run's failures.
    Skip,
    /// Nothing written: the recovery was declined (`None`), or the run
    /// cancelled.
    Stopped(Option<Box<dyn std::error::Error>>),
}

/// A prepared scope made ready to write. A scope whose version 10 record
/// the plan recovers writes the recovery first, then is planned again over
/// the record that wrote, Pi settlement included; a plan after the
/// recovery that fails still owes the recovery its offer.
fn ready_to_write(
    env: &Env,
    scope: &kendex_core::model::Scope,
    planned: Planned,
    run: (
        &kendex_core::remote::Synced,
        &PlanOptions,
        Reached,
        bool,
        bool,
    ),
    failures: &mut Vec<String>,
) -> Result<Ready, Box<dyn std::error::Error>> {
    let (synced, options, reached, verbose, yes) = run;
    // An unreachable catalog is reported, not fatal: what came from every
    // other catalog still refreshes.
    print_synced(synced);
    failures.extend(synced.failures.iter().cloned());
    let (report, pending) = match planned {
        Ok(planned) => planned,
        Err(error) => {
            failures.push(error);
            return Ok(Ready::Skip);
        }
    };
    if report.recovers.is_none() {
        return Ok(Ready::Write(Box::new((report, pending, None))));
    }
    let written = match recover_scope(env, scope, &report, yes) {
        Ok(Some(written)) => written,
        Ok(None) => {
            declined_scope(scope);
            return Ok(Ready::Stopped(None));
        }
        Err(error) if ui::cancelled(error.as_ref()) => return Ok(Ready::Stopped(Some(error))),
        Err(error) => {
            print_attention(env, &report, listing(verbose), reached);
            failures.push(error.to_string());
            return Ok(Ready::Skip);
        }
    };
    match plan_scope(env, scope, synced, options)? {
        Ok((report, pending)) => Ok(Ready::Write(Box::new((report, pending, Some(written))))),
        Err(error) => {
            failures.push(error);
            if let Err(error) = after_writing(env, scope, &report.generated, &written.before) {
                failures.push(error.to_string());
            }
            Ok(Ready::Skip)
        }
    }
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
