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
use super::{CliResult, say, scope_label};

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
    let mut settled = Vec::new();
    let mut failed: Option<Box<dyn std::error::Error>> = None;
    for step in steps {
        match install_step(env, scope, step) {
            Ok(done) => settled.push(done),
            Err(error) => {
                failed = Some(error);
                break;
            }
        }
    }
    if failed.is_none() {
        say("collection installed — every member is in the lock at its resolved commit");
    }

    // One screen for the collection, and one question.
    //
    // A package can arrive by more than one route in a single command — the
    // repository that carries it, and a dependency of something else — and a
    // person should read what it does to their repository once. Collapsed by
    // name over the settled plans, which is the same set each plan already
    // answers for itself.
    let mut once: std::collections::BTreeMap<&str, &kendex_core::repo_effects::DeclaredEffects> =
        std::collections::BTreeMap::new();
    for step in &settled {
        for effect in &step.report.repo_effects {
            once.entry(effect.name.as_str()).or_insert(effect);
        }
    }
    let pending: Vec<kendex_core::repo_effects::DeclaredEffects> =
        once.into_values().cloned().collect();
    // The same close `add <package>` gives, over every step at once: a
    // collection is one install, and a run that opened a frame has to end
    // on what it wrote, skipped and flagged like any other. The parts are
    // the ones each step already counted, never re-derived.
    let applied: usize = settled.iter().map(|step| step.applied).sum();
    // Read off what the run applied, not off the member plans alone: a
    // reused source whose member is already declared plans nothing and
    // still writes — its subscription, or the pin that holds it at the
    // snapshot — and a ledger deciding from the plan would call that run
    // up to date over changes it had just made. `None` only where
    // nothing was planned and nothing was written, the way `add` reads a
    // scope that had nothing to do.
    let count = wrote_count(
        applied,
        settled.iter().any(|step| !step.report.plan.is_empty()),
    );
    let mut blocked: Vec<Blocked> = Vec::new();
    let mut scored: Vec<kendex_core::engine::ItemSafety> = Vec::new();
    for step in settled {
        blocked.extend(step.blocked);
        scored.extend(step.scored);
    }
    let close = || {
        say_ledger(
            scope,
            Wrote {
                verb: "added",
                count,
            },
            &blocked,
            &scored,
        );
    };
    if let Some(error) = failed {
        // A step failed with earlier steps already installed. What they
        // wrote is reported before the error goes up, and the repository
        // account is not asked for on a run that is already failing.
        close();
        return Err(error);
    }
    // Every member is installed by now, so the account and its separate
    // yes come last — and the close is handed over, so what the run wrote
    // is reported whatever the reader answers.
    super::repo_effects::disclose_and_finish(env, scope, &pending, allow_effects, close)
}

/// Whether the run has a count to report, and what it is.
///
/// `None` only where nothing was planned and nothing was written, which
/// is how `add` reads a scope that had nothing to do. Reading it off the
/// member plans alone said "up to date" over a run that wrote: a reused
/// source whose member is already declared plans nothing and still writes
/// its subscription, or the pin holding it at the snapshot.
fn wrote_count(applied: usize, planned_anything: bool) -> Option<usize> {
    (applied > 0 || planned_anything).then_some(applied)
}

/// What one step wrote, and what it could not. The collection's closing
/// ledger is the sum of these, so each step hands back the counts it
/// already took rather than leaving them to be worked out again.
struct Installed {
    report: kendex_core::engine::EngineReport,
    blocked: Vec<Blocked>,
    scored: Vec<kendex_core::engine::ItemSafety>,
    applied: usize,
}

/// Subscribe (or reuse), install every member, and — for a reused
/// subscription that may track a moved branch — pin each member to the
/// snapshot commit so what installs is the snapshot, not the branch head.
fn install_step(
    env: &Env,
    scope: &Scope,
    step: kendex_core::source_ops::CollectionStep,
) -> Result<Installed, Box<dyn std::error::Error>> {
    let reused = matches!(step.action, SourceAction::Reuse { .. });
    // What the subscription itself wrote counts the way `add` counts its
    // own manifest save: the ledger reports changes, not packages.
    let mut applied = 0usize;
    let source = match step.action {
        SourceAction::Reuse { name } => name,
        SourceAction::Subscribe { reference } => {
            let subscribed = source_ops::subscribe(env, scope, &reference, None)?;
            applied += apply_report(env, &subscribed.report)?;
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
    let blocked = print_report(env, &report);
    applied += apply_report(env, &report)?;
    let mut scored = report.safety.clone();
    if reused && let Some(commit) = &step.commit {
        for (kind, name) in &members {
            let pinned = kendex_core::package::set_rev(env, scope, *kind, name, Some(commit))?;
            print_safety(&pinned);
            scored.extend(pinned.safety.iter().cloned());
            applied += apply_report(env, &pinned)?;
        }
    }
    // The step's own plan goes back to the caller, which discloses over the
    // whole collection at once. Nothing here runs an effect.
    Ok(Installed {
        report,
        blocked,
        scored,
        applied,
    })
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
    use super::wrote_count;

    /// A run that wrote reports what it wrote, whatever the member plans
    /// said. The pin and the subscription are writes the member plan
    /// never carries, so a ledger deciding from that plan alone called a
    /// run that had just changed the scope up to date.
    #[test]
    fn a_run_that_wrote_never_reads_as_up_to_date() {
        // The defect: empty member plans, and writes all the same.
        assert_eq!(wrote_count(2, false), Some(2));
        // Unchanged where the plan carried the work.
        assert_eq!(wrote_count(4, true), Some(4));
        assert_eq!(wrote_count(0, true), Some(0));
        // Nothing planned and nothing written is the one silent case.
        assert_eq!(wrote_count(0, false), None);
    }
}
