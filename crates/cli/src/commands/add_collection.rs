//! `kendex add https://kendex.ai/c/<id>` — one link, one preview, then:
//! subscribe each repository the scope lacks (at the snapshot commit) and
//! install every member. Existing subscriptions are reused only when
//! their revision matches the snapshot; the steps refuse before anything
//! changes otherwise.

use kendex_core::engine::ops::{self, AddRequest};
use kendex_core::env::Env;
use kendex_core::model::Scope;
use kendex_core::registry::{CurlFetch, collections};
use kendex_core::source_ops::{self, SourceAction};

use super::engine_common::{apply_report, ask_before_writing, print_report, print_safety};
use super::ledger::{Wrote, say_ledger};
use super::offers::Blocked;
use super::{CliResult, fail_refusal, say, scope_label};

pub fn run(env: &Env, scope: &Scope, id: &str, yes: bool, allow_effects: bool) -> CliResult {
    let collection = collections::resolve(&CurlFetch, id)?;
    let steps = source_ops::collection_steps(env, scope, &collection)?;
    // Every part of this listing came down a wire: the collection's own
    // name, the repositories it points at, and the members it claims.
    say(&format!(
        "collection '{}': {} package(s) across {} repositor{}",
        collection.name,
        collection.members.len(),
        steps.len(),
        if steps.len() == 1 { "y" } else { "ies" }
    ));
    for step in &steps {
        let action = match &step.action {
            SourceAction::Reuse { name } => {
                format!("using existing subscription '{}'", name)
            }
            SourceAction::Subscribe { .. } => match &step.commit {
                Some(commit) => format!("subscribe at {}", &commit[..commit.len().min(7)]),
                None => "subscribe (follows its default branch)".to_owned(),
            },
        };
        let members: Vec<&str> = step.members().map(|(_, name)| name.as_str()).collect();
        say(&format!(
            "  {}  [{action}]  {}",
            step.repo,
            members.join(", ")
        ));
    }
    ask_before_writing(
        &format!(
            "install all {} package{}?",
            collection.members.len(),
            if collection.members.len() == 1 {
                ""
            } else {
                "s"
            }
        ),
        yes,
    )?;
    // Every repository is fetched and every member proven present before
    // the first mutation — a collection whose third repository is broken
    // must refuse up front, not leave the first two half-installed.
    for step in &steps {
        prevalidate(env, step)?;
    }
    // Prevalidation refuses a broken collection before the first
    // mutation, so a failure here is a repository that moved under the
    // run. The steps before it are installed either way, and the error is
    // held until the close has reported them.
    let (closing, failed) =
        install_steps(steps, |step, wrote| install_step(env, scope, step, wrote));
    if failed.is_none() {
        say("collection installed — every member is in the lock at its resolved commit");
    }
    // The same close `add <package>` gives, over every step at once: a
    // collection is one install, and a run that opened a frame has to end
    // on what it wrote, skipped and flagged like any other. The parts are
    // the ones each step already counted, never re-derived.
    let close = || {
        say_ledger(
            scope,
            Wrote {
                verb: "added",
                count: closing.count,
            },
            &closing.blocked,
            &closing.scored,
        );
    };
    let (outcome, refused) = finish(
        closing.count.is_some_and(|changes| changes > 0),
        failed,
        close,
        |close| {
            // Every member is installed by now, so the account and its
            // separate yes come last — and the close is handed over, so
            // what the run wrote is reported whatever the reader answers.
            super::repo_effects::disclose_and_finish(
                env,
                scope,
                &closing.pending,
                allow_effects,
                close,
            )
        },
        || super::project::register_destination(env, scope),
    );
    if let Some(refused) = refused {
        fail_refusal("warning: ", refused.as_ref());
    }
    outcome
}

/// How a collection run ends: the ledger, the repository account, and the
/// registration of the folder the packages landed in.
///
/// The parts are handed in so the order can be asked without a registry, a
/// network and a git host — the same reason [`install_steps`] takes its
/// installer. What it decides is the whole of what a reviewer of this file
/// would otherwise have to read the callers to know.
///
/// The registration runs on every arm where packages landed, and never
/// behind the account's answer: a package's declared installer exiting
/// nonzero, or a cancel at its prompt, leaves the packages on disk, and a
/// folder the app cannot see is what the registration exists to prevent. A
/// run that wrote nothing installed into nowhere and registers nothing.
///
/// What comes back is what the run reports — the step's failure first,
/// then the account's — and, separately, a registry refusal to be said
/// beside it rather than in place of it.
type Refusal = Box<dyn std::error::Error>;

fn finish<C: FnOnce()>(
    wrote: bool,
    failed: Option<Refusal>,
    close: C,
    effects: impl FnOnce(C) -> CliResult,
    register: impl FnOnce() -> CliResult,
) -> (CliResult, Option<Refusal>) {
    let registered = |wrote: bool| match wrote {
        true => register(),
        false => Ok(()),
    };
    if let Some(error) = failed {
        // A step failed with earlier steps already installed. What they
        // wrote is reported before the error goes up, and the repository
        // account is not asked for on a run that is already failing.
        close();
        return (Err(error), registered(wrote).err());
    }
    let walked = effects(close);
    let registry = registered(wrote);
    match walked {
        Ok(()) => (registry, None),
        Err(error) => (Err(error), registry.err()),
    }
}

/// Take the steps in order, stopping at the first failure, and reduce
/// what the run wrote into its close.
///
/// The written set, never the succeeded set. A step is not outcome-free
/// before it fails: it can apply a new subscription, apply the pins that
/// hold reused members at the snapshot, and print blocked and safety rows
/// before a later fetch returns an error. Dropping that with the error
/// closes a run that changed the repository on a ledger naming less than
/// it did. Each step fills its own [`Written`] as it goes, so the outcome
/// is kept whichever way the step returned.
fn install_steps(
    steps: Vec<kendex_core::source_ops::CollectionStep>,
    mut install: impl FnMut(kendex_core::source_ops::CollectionStep, &mut Written) -> CliResult,
) -> (Closing, Option<Box<dyn std::error::Error>>) {
    let mut written: Vec<Written> = Vec::new();
    let mut failed: Option<Box<dyn std::error::Error>> = None;
    for step in steps {
        let mut wrote = Written::default();
        let outcome = install(step, &mut wrote);
        written.push(wrote);
        if let Err(error) = outcome {
            failed = Some(error);
            break;
        }
    }
    (closing(written), failed)
}

/// What the run says at the end: the ledger's count, the collapsed
/// repository-effects screen, and the rows each step could not settle.
struct Closing {
    count: Option<usize>,
    pending: Vec<kendex_core::repo_effects::DeclaredEffects>,
    blocked: Vec<Blocked>,
    scored: Vec<kendex_core::engine::ItemSafety>,
}

fn closing(written: Vec<Written>) -> Closing {
    // One screen for the collection, and one question.
    //
    // A package can arrive by more than one route in a single command — the
    // repository that carries it, and a dependency of something else — and a
    // person should read what it does to their repository once. Collapsed by
    // name over the whole run's writes.
    let mut once: std::collections::BTreeMap<&str, &kendex_core::repo_effects::DeclaredEffects> =
        std::collections::BTreeMap::new();
    for step in &written {
        for effect in &step.effects {
            once.entry(effect.name.as_str()).or_insert(effect);
        }
    }
    let pending: Vec<kendex_core::repo_effects::DeclaredEffects> =
        once.into_values().cloned().collect();
    // Read off what the run applied, not off the member plans alone: a
    // reused source whose member is already declared plans nothing and
    // still writes — its subscription, or the pin that holds it at the
    // snapshot — and a ledger deciding from the plan would call that run
    // up to date over changes it had just made. `None` only where
    // nothing was planned and nothing was written, the way `add` reads a
    // scope that had nothing to do.
    let count = wrote_count(
        written.iter().map(|step| step.applied).sum(),
        written.iter().any(|step| step.planned),
    );
    let mut blocked: Vec<Blocked> = Vec::new();
    let mut scored: Vec<kendex_core::engine::ItemSafety> = Vec::new();
    for step in written {
        blocked.extend(step.blocked);
        scored.extend(step.scored);
    }
    Closing {
        count,
        pending,
        blocked,
        scored,
    }
}

/// Whether the run has a count to report, and what it is.
///
/// `None` only where nothing was planned and nothing was written, which
/// is how `add` reads a scope that had nothing to do. Read off the member
/// plans alone it says "up to date" over a run that wrote: a reused
/// source whose member is already declared plans nothing and still writes
/// its subscription, or the pin holding it at the snapshot.
fn wrote_count(applied: usize, planned_anything: bool) -> Option<usize> {
    (applied > 0 || planned_anything).then_some(applied)
}

/// What one step wrote, and what it could not, gathered as it writes it.
/// The collection's closing ledger and its repository-effects screen are
/// the sum of these, so each step hands back the counts it already took
/// rather than leaving them to be worked out again — and a step that
/// fails hands back everything it had written before it did.
#[derive(Default)]
struct Written {
    /// The repository effects this step's plan declared.
    effects: Vec<kendex_core::repo_effects::DeclaredEffects>,
    /// Whether the step planned anything at all, which is the one thing
    /// separating a silent run from one that wrote nothing.
    planned: bool,
    blocked: Vec<Blocked>,
    scored: Vec<kendex_core::engine::ItemSafety>,
    applied: usize,
}

/// Subscribe (or reuse), install every member, and — for a reused
/// subscription that may track a moved branch — pin each member to the
/// snapshot commit so what installs is the snapshot, not the branch head.
///
/// Every write lands in `wrote` before the next fallible call, so the
/// error path carries what the step had already done.
fn install_step(
    env: &Env,
    scope: &Scope,
    step: kendex_core::source_ops::CollectionStep,
    wrote: &mut Written,
) -> CliResult {
    let reused = matches!(step.action, SourceAction::Reuse { .. });
    let source = match step.action {
        SourceAction::Reuse { name } => name,
        SourceAction::Subscribe { reference } => {
            let subscribed = source_ops::subscribe(env, scope, &reference, None)?;
            // What the subscription itself wrote counts the way `add`
            // counts its own manifest save: the ledger reports changes,
            // not packages.
            wrote.applied += apply_report(env, &subscribed.report)?;
            say(&format!(
                "{}: subscribed to '{}'",
                scope_label(scope),
                subscribed.name
            ));
            subscribed.name
        }
    };
    let members: Vec<(kendex_core::model::ItemKind, String)> = [
        (kendex_core::model::ItemKind::Agent, &step.agents),
        (kendex_core::model::ItemKind::Skill, &step.skills),
        (kendex_core::model::ItemKind::Hook, &step.hooks),
        (kendex_core::model::ItemKind::Command, &step.commands),
        (kendex_core::model::ItemKind::McpServer, &step.mcp_servers),
    ]
    .into_iter()
    .flat_map(|(kind, names)| names.iter().map(move |name| (kind, name.clone())))
    .collect();
    // The fetch must land before installing from it; the snapshot commit
    // rode in on the subscription's rev.
    if let kendex_core::manifest::ManifestFile::Current(manifest) =
        kendex_core::manifest::load(&kendex_core::manifest::manifest_path(env, scope))?
        && let Some(decl) = manifest.sources.get(&source)
        && let Some(repo) = decl.repo.clone()
    {
        kendex_core::remote::sync(env, &repo, decl.rev.as_deref())?;
    }
    let report = ops::add(
        env,
        scope,
        &AddRequest {
            source: Some(source.clone()),
            agents: step.agents,
            skills: step.skills,
            hooks: step.hooks,
            commands: step.commands,
            mcp_servers: step.mcp_servers,
            pi_extensions: Vec::new(),
            all: false,
            harnesses: None,
            method: None,
            no_auto_skills: false,
            optional: Vec::new(),
            bundles: Vec::new(),
            hold: false,
        },
    )?;
    // The step's own plan goes to the caller, which discloses over the
    // whole collection at once. Nothing here runs an effect.
    wrote.effects.extend(report.repo_effects.iter().cloned());
    wrote.planned = !report.plan.is_empty();
    wrote.blocked.extend(print_report(env, &report));
    wrote.scored.extend(report.safety.iter().cloned());
    wrote.applied += apply_report(env, &report)?;
    if reused && let Some(commit) = &step.commit {
        for (kind, name) in &members {
            let pinned = kendex_core::package::set_rev(env, scope, *kind, name, Some(commit))?;
            print_safety(&pinned);
            wrote.scored.extend(pinned.safety.iter().cloned());
            wrote.applied += apply_report(env, &pinned)?;
        }
    }
    Ok(())
}

/// Fetch one step's repository at its snapshot commit and prove every
/// member exists there, mutating nothing.
fn prevalidate(env: &Env, step: &kendex_core::source_ops::CollectionStep) -> CliResult {
    let resolution = kendex_core::remote::sync(env, &step.repo, step.commit.as_deref())
        .map_err(|error| format!("{}: {error}", step.repo))?;
    let sealed = kendex_core::source_read::SealedSource::open(&resolution.root)?;
    let config =
        kendex_core::source::source_config(&sealed, kendex_core::source::repo_leaf(&step.repo))?;
    for (kind, name) in step.members() {
        if kendex_core::source::find_item(&sealed, &config, kind, name).is_none() {
            return Err(format!(
                "{} does not offer {} '{name}' at the collection's snapshot — nothing was installed",
                step.repo,
                kind.name()
            )
            .into());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{Written, finish, install_steps, wrote_count};
    use kendex_core::repo_effects::{DeclaredEffects, RepoEffects};
    use kendex_core::source_ops::{CollectionStep, SourceAction};

    fn step(repo: &str) -> CollectionStep {
        CollectionStep {
            repo: repo.to_owned(),
            commit: None,
            action: SourceAction::Subscribe {
                reference: repo.to_owned(),
            },
            agents: Vec::new(),
            skills: vec!["guard".to_owned()],
            hooks: Vec::new(),
            commands: Vec::new(),
            mcp_servers: Vec::new(),
        }
    }

    fn declared(name: &str) -> DeclaredEffects {
        DeclaredEffects {
            name: name.to_owned(),
            root: std::path::PathBuf::from("packages").join(name),
            effects: RepoEffects {
                summary: "arms this repository's commit hooks".to_owned(),
                writes: Vec::new(),
                installer: None,
                uninstaller: None,
                checker: None,
                removal: None,
                notes: Vec::new(),
                companions: Vec::new(),
            },
        }
    }

    /// A step that subscribed and then failed changed the repository, so
    /// the close names what it wrote: its subscription in the ledger's
    /// count, and the declaration it installed on the repository-effects
    /// screen. Read off the steps that succeeded alone, a run that had
    /// just written twice closes on one.
    #[test]
    fn a_failed_step_still_names_what_it_wrote() {
        let (closing, failed) = install_steps(
            vec![step("owner/first"), step("owner/second")],
            |step, wrote: &mut Written| {
                wrote.applied += 1;
                wrote.planned = true;
                wrote.effects.push(declared(&step.repo));
                match step.repo.as_str() {
                    "owner/second" => Err("owner/second moved under the run".into()),
                    _ => Ok(()),
                }
            },
        );
        assert!(failed.is_some());
        assert_eq!(closing.count, Some(2));
        let named: Vec<&str> = closing
            .pending
            .iter()
            .map(|effects| effects.name.as_str())
            .collect();
        assert_eq!(named, ["owner/first", "owner/second"]);
    }

    /// A run that wrote reports what it wrote, whatever the member plans
    /// said. The pin and the subscription are writes the member plan
    /// never carries, so a ledger deciding from that plan alone calls a
    /// run that has just changed the scope up to date.
    #[test]
    fn a_run_that_wrote_never_reads_as_up_to_date() {
        assert_eq!(wrote_count(2, false), Some(2));
        // Unchanged where the plan carried the work.
        assert_eq!(wrote_count(4, true), Some(4));
        assert_eq!(wrote_count(0, true), Some(0));
        // Nothing planned and nothing written is the one silent case.
        assert_eq!(wrote_count(0, false), None);
    }

    /// Every way a collection run can end, and what each does about the
    /// registry. A collection needs a directory service, a git host and a
    /// registry to reach this by any other route, so the parts are handed
    /// in — the shape `install_steps` above is already tested through.
    ///
    /// The claim every row makes is the one the issue turns on: the folder
    /// the packages landed in is registered on every arm where they
    /// landed, the arms that end in an error included, and on no arm where
    /// nothing was written.
    #[test]
    fn the_close_registers_wherever_packages_landed() {
        // wrote, a step failed, the effects step's answer, the registry's;
        // then what ran (closed, effects, registered), whether the run
        // came back ok, and whether a registry refusal was handed back to
        // be said beside it.
        type Ran = (bool, bool, bool);
        type Row = (&'static str, bool, bool, bool, bool, Ran, bool, bool);
        let rows: [Row; 6] = [
            (
                "clean",
                true,
                false,
                true,
                true,
                (true, true, true),
                true,
                false,
            ),
            (
                "step failed, wrote",
                true,
                true,
                true,
                true,
                (true, false, true),
                false,
                false,
            ),
            (
                "step failed, wrote nothing",
                false,
                true,
                true,
                true,
                (true, false, false),
                false,
                false,
            ),
            (
                "installer exited nonzero",
                true,
                false,
                false,
                true,
                (true, true, true),
                false,
                false,
            ),
            (
                "installer failed, registry refused",
                true,
                false,
                false,
                false,
                (true, true, true),
                false,
                true,
            ),
            (
                "clean, registry refused",
                true,
                false,
                true,
                false,
                (true, true, true),
                false,
                false,
            ),
        ];

        for (name, wrote, failed, effects_ok, registry_ok, expected, ok, said) in rows {
            let (mut closed, mut ran_effects, mut registered) = (false, false, false);
            let (outcome, refusal) = finish(
                wrote,
                failed.then(|| -> Box<dyn std::error::Error> { "the repository moved".into() }),
                || closed = true,
                |close| {
                    close();
                    ran_effects = true;
                    match effects_ok {
                        true => Ok(()),
                        false => Err("the installer exited 1".into()),
                    }
                },
                || {
                    registered = true;
                    match registry_ok {
                        true => Ok(()),
                        false => Err("the settings file could not be written".into()),
                    }
                },
            );

            assert_eq!((closed, ran_effects, registered), expected, "{name}");
            assert_eq!(outcome.is_ok(), ok, "{name}: {outcome:?}");
            assert_eq!(refusal.is_some(), said, "{name}");
        }
    }
}
