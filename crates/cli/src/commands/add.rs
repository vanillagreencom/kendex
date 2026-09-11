use kendex_core::engine::ops::{self, AddRequest};
use kendex_core::env::Env;
use kendex_core::lock::{load as load_lock, lock_path};
use kendex_core::model::Scope;

use kendex_core::manifest::Method;

use super::engine_common::{confirm_and_apply, parse_harnesses, print_report};
use super::ledger::{Wrote, say_ledger};
use super::{CliResult, fail_refusal, harness_picker, install_destination, warn};
use crate::ui;

#[derive(Default)]
pub struct AddArgs {
    pub source: Option<String>,
    pub global: bool,
    pub harness: Vec<String>,
    pub all_harnesses: bool,
    pub agent: Vec<String>,
    pub skill: Vec<String>,
    pub bundle: Vec<String>,
    pub optional: Vec<String>,
    pub hook: Vec<String>,
    pub command: Vec<String>,
    pub mcp_server: Vec<String>,
    pub pi_extension: Vec<String>,
    pub copy: bool,
    pub method: Option<String>,
    pub yes: bool,
    pub all: bool,
    pub clobber: bool,
    pub no_auto_skills: bool,
    pub hold: bool,
    pub allow_repo_effects: bool,
    /// The subscription to install from, where the verb has already
    /// resolved which one carries what it installs. It is read in the
    /// place that declares it rather than against the destination's own
    /// declarations, and replaces `source`.
    pub subscription: Option<Declared>,
}

/// A subscription, named by the place that declares it and the alias it is
/// keyed under there.
pub struct Declared {
    pub scope: Scope,
    pub name: String,
}

/// Where this install goes and how it is delivered. Flags settle both
/// where they were given; otherwise a terminal is asked and a session
/// without one keeps the scope's own defaults. What the request would
/// declare decides which tools can take it, so the picker and
/// `--all-harnesses` offer only those.
fn settle_targets(
    env: &Env,
    scope: &Scope,
    request: &mut AddRequest,
    args: &AddArgs,
) -> Result<(), Box<dyn std::error::Error>> {
    let kinds = ops::requested_kinds(request);
    request.harnesses = match (args.all_harnesses, args.harness.is_empty()) {
        (true, _) => Some(harness_picker::installable_at(scope, &kinds)),
        (false, false) => Some(parse_harnesses(&args.harness)?),
        (false, true) => None,
    };
    request.method = match (args.copy, args.method.as_deref()) {
        (true, _) | (_, Some("copy")) => Some(Method::Copy),
        (_, Some("symlink")) => Some(Method::Symlink),
        _ => None,
    };
    let chosen = harness_picker::ask(
        env,
        scope,
        &kinds,
        request.harnesses.is_some(),
        request.method,
        args.yes,
    )?;
    request.harnesses = request.harnesses.take().or(chosen.harnesses);
    request.method = chosen.method;
    Ok(())
}

fn split(values: &[String]) -> Vec<String> {
    values
        .iter()
        .flat_map(|v| v.split(','))
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(str::to_owned)
        .collect()
}

pub fn run(env: &Env, args: AddArgs) -> CliResult {
    ui::intro("kendex add");
    let scope = match args.global {
        true => Scope::Global,
        false => install_destination(env, args.yes)?,
    };
    run_into(env, &scope, args)
}

/// The install itself, into a place the caller has already settled.
///
/// Split from [`run`] so a verb that names its own destination — the
/// bookmark verb's install, which takes `--project` — performs the same
/// run rather than a second one of its own: the same selection rules, the
/// same planning, the same repository-effects disclosure and the same
/// registration of the folder the packages landed in.
pub fn run_into(env: &Env, scope: &Scope, mut args: AddArgs) -> CliResult {
    let scope = scope.clone();

    // A collection link is a whole install of its own: the set the link
    // resolves to, never mixed with item flags.
    if let Some(reference) = &args.source
        && let Ok(kendex_core::source_ref::SourceRef::Collection { id }) =
            kendex_core::source_ref::parse_typed(reference)
    {
        return super::add_collection::run(env, &scope, &id, args.yes, args.allow_repo_effects);
    }

    let agents = split(&args.agent);
    let skills = split(&args.skill);
    let hooks = split(&args.hook);
    let commands = split(&args.command);
    let mcp_servers = split(&args.mcp_server);
    let bundles = split(&args.bundle);
    let pi_extensions = split(&args.pi_extension);
    if args.global
        && !args.all
        && [
            &agents,
            &skills,
            &hooks,
            &commands,
            &mcp_servers,
            &bundles,
            &pi_extensions,
        ]
        .iter()
        .all(|names| names.is_empty())
    {
        return Err(
            "global installs need --all or explicit --agent/--skill/--bundle selections".into(),
        );
    }
    if args.global && args.all && !args.clobber {
        let lock = load_lock(&lock_path(env, &Scope::Global))?;
        if !lock.entries.is_empty() {
            return Err(
                "the global scope already has installs — pass --clobber to redeclare everything"
                    .into(),
            );
        }
    }

    let mut request = AddRequest {
        source: args.source.take(),
        agents,
        skills,
        hooks,
        commands,
        mcp_servers,
        pi_extensions,
        all: args.all,
        harnesses: None,
        method: None,
        no_auto_skills: args.no_auto_skills,
        optional: split(&args.optional),
        bundles,
        hold: args.hold,
    };
    settle_targets(env, &scope, &mut request, &args)?;
    let planned = {
        let _planning = ui::spinner("planning the install");
        plan(env, &scope, args.subscription.as_ref(), &request)
    };
    let report = match planned {
        Err(kendex_core::error::CoreError::SourcePending { name }) => {
            let manifest = ops::manifest_for_mutation(env, &scope)?;
            let synced = {
                let _reading = ui::spinner("reading sources");
                let mut synced = kendex_core::remote::sync_sources(env, &manifest)?;
                // A bare add into a project can reach the personal scope's
                // default marketplace, declared nowhere in the project:
                // pending, it is fetched from the scope that declares it.
                // A request that names its source never does, so a pending
                // positional repository is not mistaken for a personal alias
                // that happens to share its name.
                if request.source.is_none()
                    && !manifest.sources.contains_key(&name)
                    && let Scope::Project { .. } = &scope
                    && let Some(decl) = ops::manifest_for_reading(env, &Scope::Global)?
                        .sources
                        .get(&name)
                {
                    synced.extend(kendex_core::remote::sync_source(env, &name, decl)?);
                }
                synced
            };
            for warning in synced {
                warn(&format!("warning: {}", warning));
            }
            let _planning = ui::spinner("planning the install");
            plan(env, &scope, args.subscription.as_ref(), &request)?
        }
        other => other?,
    };
    write_and_close(env, &scope, &report, args.yes, args.allow_repo_effects)
}

/// The plan for this request: read against the destination's own
/// declarations, or from the subscription the verb already resolved, in
/// the place that declares it.
fn plan(
    env: &Env,
    scope: &Scope,
    subscription: Option<&Declared>,
    request: &AddRequest,
) -> kendex_core::error::Result<kendex_core::engine::EngineReport> {
    match subscription {
        Some(declared) => kendex_core::source_ops::install_from(
            env,
            &declared.scope,
            &declared.name,
            scope,
            request,
        ),
        None => ops::add(env, scope, request),
    }
}

/// The write, the repository-effects account, the close, and the
/// registration of the folder the packages landed in.
///
/// Disclosed after the write, because the script an effect runs is the one
/// this install just put on disk. That leaves a prompt between the write
/// and the closing line, so the close is handed over rather than written
/// under it: what the run wrote is reported whatever the reader answers.
///
/// The registration is last, and it is its own step, reached on every arm
/// the write itself survived. A cancelled apply returns above it, so
/// nothing registers a folder no package reached — but a package's
/// installer that exits nonzero, or a cancel at the repository-effects
/// prompt, is not that: the packages are on disk by then, and a folder the
/// app cannot see is what this registration exists to prevent. So the
/// effects step's answer is held rather than propagated through it, and a
/// registry that refuses says so beside that answer rather than displacing
/// it.
///
/// Arming a repository's commit hooks is the separate yes above, and says
/// nothing about this one: a tracked folder is a folder the app can show,
/// not consent to change what happens on every commit.
fn write_and_close(
    env: &Env,
    scope: &Scope,
    report: &kendex_core::engine::EngineReport,
    yes: bool,
    allow_effects: bool,
) -> CliResult {
    let blocked = print_report(env, report);
    let applied = confirm_and_apply(env, report, yes)?;
    let walked = super::repo_effects::disclose_and_finish(
        env,
        scope,
        &report.repo_effects,
        allow_effects,
        || {
            // "done" answered whether the process ended, never what it
            // did. The verb is the one that was typed, because the count
            // is of changes and not of packages: a run whose only change
            // is its declaration writes something, and installs nothing.
            let count = (!report.plan.is_empty()).then_some(applied);
            say_ledger(
                scope,
                Wrote {
                    verb: "added",
                    count,
                },
                &blocked,
                &report.safety,
            );
        },
    );
    // Unconditional here, where the collection close reads its own count
    // first: a collection can refuse its first step having written
    // nothing, and `add` cannot. `ops::add` puts the manifest save in
    // every plan it returns (`ensure_manifest_persisted`), and a declined
    // or failed apply returns above this line — so a run that reaches here
    // has written, and a branch for one that had not is a branch nothing
    // reaches. Registration is not the effects step's to skip either way.
    let registered = super::project::register_destination(env, scope);
    match walked {
        Ok(()) => registered,
        Err(error) => {
            if let Err(refused) = registered {
                fail_refusal("warning: ", refused.as_ref());
            }
            Err(error)
        }
    }
}
