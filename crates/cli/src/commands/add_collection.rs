//! `kendex add https://kendex.ai/c/<id>` — one link, one preview, then:
//! subscribe each repository the scope lacks (at the snapshot commit) and
//! install every member. Existing subscriptions are reused only when
//! their revision matches the snapshot; the steps refuse before anything
//! changes otherwise. Core prepares and checks the whole collection before
//! this command applies its single plan.

use kendex_core::env::Env;
use kendex_core::model::Scope;
use kendex_core::registry::{CurlFetch, collections};
use kendex_core::source_ops::{self, SourceAction};

use super::advisory::Listing;
use super::engine_common::{apply_report, ask_before_writing, print_report};
use super::ledger::{Folded, Wrote, say_ledger};
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
    let prepared = source_ops::prepare_collection(env, scope, &steps)?;
    let subscribed: Vec<String> = prepared.subscription_names().map(str::to_owned).collect();
    let report = prepared.plan(env)?;
    let mut wrote = Written::default();
    let failed = install_report(env, &report, &mut wrote).err();
    if failed.is_none() {
        for name in subscribed {
            say(&format!("{}: subscribed to '{name}'", scope_label(scope)));
        }
    }
    let mut closing = closing(vec![wrote]);
    let skipped = std::mem::take(&mut closing.skipped);
    // A member skipped on conflict is not a step failure, and it is not
    // installed either: the line would claim a member the ledger then
    // names as skipped, terminal or not.
    if failed.is_none() && skipped.is_empty() {
        say("collection installed — kendex recorded every member at its version");
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
            Folded::None,
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
    outcome.and_then(|()| super::ledger::refuse_skipped(skipped))
}

/// How a collection run ends: the ledger, the repository account, and the
/// registration of the folder the packages landed in.
///
/// The parts are handed in so the order can be asked without a registry, a
/// network and a git host.
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
        // A failed apply reports its ledger before the error goes up.
        // Repository effects are not run after an installation failure.
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

/// What the run says at the end: the ledger's count, the collapsed
/// repository-effects screen, and the rows each step could not settle.
struct Closing {
    count: Option<usize>,
    pending: Vec<kendex_core::repo_effects::DeclaredEffects>,
    blocked: Vec<Blocked>,
    /// The blocked items the collection asked for, which a run with no
    /// terminal ends on.
    skipped: Vec<(kendex_core::model::ItemKind, String)>,
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
    let mut skipped = Vec::new();
    let mut scored: Vec<kendex_core::engine::ItemSafety> = Vec::new();
    for step in written {
        blocked.extend(step.blocked);
        skipped.extend(step.skipped);
        scored.extend(step.scored);
    }
    Closing {
        count,
        pending,
        blocked,
        skipped,
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
    skipped: Vec<(kendex_core::model::ItemKind, String)>,
    scored: Vec<kendex_core::engine::ItemSafety>,
    applied: usize,
}

/// Apply the core collection plan and retain its outcome for the ledger.
fn install_report(
    env: &Env,
    report: &kendex_core::engine::EngineReport,
    wrote: &mut Written,
) -> CliResult {
    wrote.effects.extend(report.repo_effects.iter().cloned());
    wrote.planned = !report.plan.is_empty();
    let blocked = print_report(env, report, Listing::Attention);
    wrote.skipped.extend(report.skipped_asked());
    wrote.blocked.extend(blocked);
    wrote.scored.extend(report.safety.iter().cloned());
    wrote.applied += apply_report(env, report)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{finish, wrote_count};
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
    /// registry to reach this by any other route, so the parts are handed in.
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
