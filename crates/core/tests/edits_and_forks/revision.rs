//! One captured file, and every tool that will render from it. A fork
//! beside writes one source form into the local source; before it, each
//! tool renders from its own installed revision, and the lock records one
//! per tool. A revision the capture did not read can state tools its own
//! does not, so the capture refuses rather than write a copy whose other
//! tools quietly lose what they were rendered with.

use std::collections::BTreeSet;
use std::fs;

use super::*;

const ROLELESS: &str = "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n";
const REVIEWER: &str =
    "---\nname: rev\ndescription: agent rev\nrole: reviewer\n---\nUpstream body.\n";

/// Pi's deny list, as the set of tool names it states.
#[allow(clippy::unwrap_used)]
fn pi_denies(w: &World, name: &str) -> BTreeSet<String> {
    let text = fs::read_to_string(rendered(w, HarnessId::Pi, name)).unwrap();
    deny_line(&text, "deny-tools:")
        .trim_start_matches("deny-tools:")
        .split(',')
        .map(|tool| tool.trim().to_owned())
        .filter(|tool| !tool.is_empty())
        .collect()
}

/// A world whose catalog moved on: `rev` was published with a reviewer
/// role, which is what puts `tasks_write` in Pi's deny list, and the next
/// commit takes the role away. Returns the world and that later commit.
#[allow(clippy::unwrap_used)]
fn moved_on() -> (World, String) {
    let w = agent_world("\"claude\", \"pi\"", REVIEWER, "", "");
    fs::write(w.upstream.join("agents/rev.md"), ROLELESS).unwrap();
    commit(&w.upstream, "two");
    let two = head_commit(&w.upstream);
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();
    (w, two)
}

/// Claude's installation moves to the later revision while Pi's stays on
/// the one that earned the deny. The capture reads Claude's, so the file it
/// writes cannot say what Pi's rendering restricts.
#[test]
#[allow(clippy::unwrap_used)]
fn a_fork_beside_is_refused_where_the_targeted_tools_sit_at_different_revisions() {
    let (w, two) = moved_on();
    let path = lock_path(&w.env, &w.scope);
    let mut lock = load_lock(&path).unwrap();
    let key = kendex_core::lock::entry_key(ItemKind::Agent, "rev", HarnessId::Claude);
    lock.entries.get_mut(&key).unwrap().source_commit = Some(two.clone());
    kendex_core::lock::save(&path, &lock).unwrap();

    // The control: Pi's rendering holds a deny that the revision the
    // capture will read cannot state.
    assert!(
        pi_denies(&w, "rev").contains("tasks_write"),
        "the fixture needs a deny that lives only in the revision Pi is installed from"
    );

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Agent,
        "rev",
        HarnessId::Claude,
        "rev-mine",
        None,
    )
    .unwrap_err()
    .to_string();
    assert!(
        refused.contains(HarnessId::Pi.display_name()) && refused.contains(&two),
        "the refusal names the tool sitting elsewhere and both revisions: {refused}"
    );
    assert!(
        pi_denies(&w, "rev").contains("tasks_write"),
        "and nothing was written, so the deny still stands"
    );
    assert!(!captured(&w, "rev-mine").exists());
}

/// A lock entry holding no revision is not agreement. Something is
/// installed on that tool and what it was rendered from cannot be
/// established, so the captured file cannot be shown to answer for it —
/// the same rule as a recorded mismatch, reaching its other reason.
#[test]
#[allow(clippy::unwrap_used)]
fn a_fork_beside_is_refused_where_a_targeted_tools_revision_is_not_recorded() {
    let (w, two) = moved_on();
    let path = lock_path(&w.env, &w.scope);
    let mut lock = load_lock(&path).unwrap();
    let entry = |harness| kendex_core::lock::entry_key(ItemKind::Agent, "rev", harness);
    lock.entries
        .get_mut(&entry(HarnessId::Claude))
        .unwrap()
        .source_commit = Some(two);
    lock.entries
        .get_mut(&entry(HarnessId::Pi))
        .unwrap()
        .source_commit = None;
    kendex_core::lock::save(&path, &lock).unwrap();
    assert!(
        pi_denies(&w, "rev").contains("tasks_write"),
        "the fixture needs a deny the captured revision cannot state"
    );

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Agent,
        "rev",
        HarnessId::Claude,
        "rev-mine",
        None,
    )
    .unwrap_err()
    .to_string();
    assert!(
        refused.contains(HarnessId::Pi.display_name()) && refused.contains("does not record"),
        "the refusal names the tool and says its revision could not be established: {refused}"
    );
    assert!(
        pi_denies(&w, "rev").contains("tasks_write"),
        "and nothing was written"
    );
    assert!(!captured(&w, "rev-mine").exists());
}

/// A source whose revisions are not commits records none for anybody, and
/// every tool reading that one directory does agree. Treating an absent
/// revision as unproven must not turn every fork of a local package into a
/// refusal — the control on the rule above.
#[test]
#[allow(clippy::unwrap_used)]
fn forking_a_local_package_beside_itself_still_runs_with_no_revision_anywhere() {
    let w = agent_world("\"claude\", \"pi\"", ROLELESS, "", "");
    edit_body(&rendered(&w, HarnessId::Claude, "rev"));
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let recorded: Vec<Option<String>> = load_lock(&lock_path(&w.env, &w.scope))
        .unwrap()
        .entries
        .iter()
        .filter(|(key, _)| key.contains("rev"))
        .map(|(_, entry)| entry.source_commit.clone())
        .collect();
    assert!(
        !recorded.is_empty() && recorded.iter().all(Option::is_none),
        "the fixture only bites while nothing records a revision: {recorded:?}"
    );

    let plan = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Agent,
        "rev",
        HarnessId::Claude,
        "rev-mine",
        None,
    )
    .unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);
    assert_eq!(
        pi_denies(&w, "rev-mine"),
        pi_denies(&w, "rev"),
        "the copy denies what the original denies"
    );
}
