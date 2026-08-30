//! The name a fork or a rename lands under, proven against every harness
//! the declaration targets. Each harness computes part of its deny list
//! from the agent's own name, so a destination name can take a built-in
//! restriction off — on harnesses the operation was never invoked from,
//! and through a rename that compares nothing at all.

use std::collections::BTreeSet;
use std::fs;

use kendex_core::error::CoreError;

use super::*;

/// Every harness that withholds a tool by the agent's name, and the tool
/// it withholds. The rename below has to be refused for each of them.
const NAME_KEYED: [(HarnessId, &str); 3] = [
    (HarnessId::Claude, "AskUserQuestion"),
    (HarnessId::Pi, "question"),
    (HarnessId::Opencode, "question"),
];

const ALL_THREE: &str = "\"claude\", \"pi\", \"opencode\"";

/// What one harness's rendering denies, as the set of tool names it
/// states — the identifying state, not the bytes around it. Every harness
/// spells the deny its own way: Claude and Pi write one comma list, and
/// OpenCode a `permission:` block of `<name>: deny` lines.
#[allow(clippy::unwrap_used)]
fn denied(w: &World, harness: HarnessId, name: &str) -> BTreeSet<String> {
    let text = fs::read_to_string(rendered(w, harness, name)).unwrap();
    let listed = |key: &str| {
        deny_line(&text, key)
            .trim_start_matches(key)
            .split(',')
            .map(|tool| tool.trim().to_owned())
            .filter(|tool| !tool.is_empty())
            .collect()
    };
    match harness {
        HarnessId::Claude => listed("disallowedTools:"),
        HarnessId::Pi => listed("deny-tools:"),
        HarnessId::Opencode => text
            .lines()
            .skip_while(|line| *line != "permission:")
            .skip(1)
            .map_while(|line| line.strip_prefix("  ")?.strip_suffix(": deny"))
            .map(str::to_owned)
            .collect(),
        other => unreachable!("no deny reader for {other:?}"),
    }
}

/// A multi-harness agent forked in place, ready to be renamed. The fork is
/// captured from Claude; the point of every test here is what happens to
/// the harnesses it was not captured from.
#[allow(clippy::unwrap_used)]
fn forked_world(project: &str) -> World {
    let w = agent_world(
        ALL_THREE,
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        project,
    );
    edit_body(&rendered(&w, HarnessId::Claude, "rev"));
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);
    w
}

/// Renaming onto a name a harness reads is refused, and every rendering is
/// left as it stood — the rename is proven before a single op is planned.
#[test]
#[allow(clippy::unwrap_used)]
fn renaming_onto_a_name_that_drops_a_built_in_deny_is_refused() {
    let w = forked_world("");
    for (harness, tool) in NAME_KEYED {
        assert!(
            denied(&w, harness, "rev").contains(tool),
            "the fixture has to start with the deny it is about to lose on {harness:?}"
        );
    }

    let refused =
        fork::rename_fork(&w.env, &w.scope, ItemKind::Agent, "rev", "planner").unwrap_err();
    assert!(
        matches!(refused, CoreError::ForkWidensAccess { .. }),
        "{refused:?}"
    );

    // Nothing was written: the agent still answers to its own name on
    // every harness, and every deny still stands.
    for (harness, tool) in NAME_KEYED {
        assert!(
            denied(&w, harness, "rev").contains(tool),
            "the deny survives the refused rename on {harness:?}"
        );
        assert!(
            !rendered(&w, harness, "planner").exists(),
            "no rendering lands under the refused name on {harness:?}"
        );
    }
    assert!(
        manifest_of(&w).agents.contains_key("rev"),
        "the declaration is untouched"
    );
}

/// The proof reaches every harness the declaration targets, not the one
/// the fork was captured from. Each case pins the built-in deny as an
/// explicit override on the other two harnesses, so the name change moves
/// nothing there and the one harness left is the only thing that can
/// refuse the rename — which is what makes the refusal name it.
#[test]
#[allow(clippy::unwrap_used)]
fn the_proof_covers_each_targeted_harness_on_its_own() {
    for (victim, lost) in NAME_KEYED {
        let pinned: String = NAME_KEYED
            .iter()
            .filter(|(harness, _)| *harness != victim)
            .map(|(harness, tool)| {
                format!(
                    "[agent-frontmatter.{}]\nrev = {{ deny-tools = [\"{tool}\"] }}\n\n",
                    harness.name()
                )
            })
            .collect();
        let w = forked_world(&pinned);

        let refused = fork::rename_fork(&w.env, &w.scope, ItemKind::Agent, "rev", "planner")
            .unwrap_err()
            .to_string();
        assert!(
            refused.contains(victim.display_name()) && refused.contains(lost),
            "only {victim:?} loses {lost} here, so it is what the refusal has to name: {refused}"
        );
    }
}

/// The fork the proof exists for: captured from a harness that states no
/// deny list at all, so comparing that harness's rendering before and
/// after sees nothing, while every other harness the declaration targets
/// loses its deny to the new name.
#[test]
#[allow(clippy::unwrap_used)]
fn forking_beside_onto_a_name_a_harness_reads_is_refused_from_one_that_states_no_denies() {
    let w = agent_world(
        "\"claude\", \"gemini\", \"pi\", \"opencode\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "",
    );
    let from = rendered(&w, HarnessId::Gemini, "rev");
    edit_body(&from);
    assert!(
        !fs::read_to_string(&from).unwrap().contains("deny"),
        "the captured harness states no deny list, which is what makes it the case that passes"
    );

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Agent,
        "rev",
        HarnessId::Gemini,
        "planner",
        None,
    )
    .unwrap_err();
    assert!(
        matches!(refused, CoreError::ForkWidensAccess { .. }),
        "{refused:?}"
    );
    for (harness, tool) in NAME_KEYED {
        assert!(
            denied(&w, harness, "rev").contains(tool),
            "the deny survives the refused fork on {harness:?}"
        );
    }
    assert!(
        !captured(&w, "planner").exists(),
        "nothing was captured under the refused name"
    );
}

/// A catalog's own per-harness defaults are part of what the original
/// renders with, and they reach the copy through the carry. Both sides of
/// the proof have to hold them: reading the manifest alone leaves the
/// default on the copy's side only, and a default that removes a generated
/// deny — Pi's `allowed-subagents`, which retires the `delegate_subagent`
/// deny — then reads as a deny that vanished and refuses a fork that
/// widens nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn a_catalog_default_that_retires_a_generated_deny_does_not_refuse_the_fork() {
    let w = agent_world(
        "\"claude\", \"pi\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "[agent-frontmatter.pi]\nrev = { allowed-subagents = [\"scout\"] }\n",
        "",
    );
    // The fixture only bites while the catalog default is doing something:
    // an agent that never lost the deny cannot show it coming back.
    let was = denied(&w, HarnessId::Pi, "rev");
    assert!(
        !was.contains("delegate_subagent"),
        "the catalog default has to have retired the deny for this to be about carrying it: {was:?}"
    );

    edit_body(&rendered(&w, HarnessId::Claude, "rev"));
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
        denied(&w, HarnessId::Pi, "rev-mine"),
        was,
        "the copy denies what the original denied, no more and no less"
    );
    assert_eq!(
        denied(&w, HarnessId::Claude, "rev-mine"),
        denied(&w, HarnessId::Claude, "rev"),
        "and the harness the fork was captured from is unchanged too"
    );
}

/// A fork captures one published file and every tool renders from it
/// afterwards, but before it each renders from its own installed revision
/// — and those may differ, which the lock records per tool. A revision the
/// capture did not read can state tools its own does not, so what that
/// tool's rendering restricts is unreadable from the captured file and its
/// loss would pass unseen. The proof refuses instead of guessing.
#[test]
#[allow(clippy::unwrap_used)]
fn a_fork_is_refused_where_the_targeted_tools_sit_at_different_revisions() {
    // One revision gives the agent a reviewer role, which is what puts
    // `tasks_write` in Pi's deny list; the next takes the role away.
    let w = agent_world(
        "\"claude\", \"pi\"",
        "---\nname: rev\ndescription: agent rev\nrole: reviewer\n---\nUpstream body.\n",
        "",
        "",
    );
    let roleless = "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n";
    fs::write(w.upstream.join("agents/rev.md"), roleless).unwrap();
    commit(&w.upstream, "two");
    let two = head_commit(&w.upstream);
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    // Claude's installation moves to the roleless revision; Pi's stays on
    // the one that earned the deny. The capture reads Claude's.
    let path = lock_path(&w.env, &w.scope);
    let mut lock = load_lock(&path).unwrap();
    let key = kendex_core::lock::entry_key(ItemKind::Agent, "rev", HarnessId::Claude);
    lock.entries.get_mut(&key).unwrap().source_commit = Some(two.clone());
    kendex_core::lock::save(&path, &lock).unwrap();

    // The control: Pi's rendering holds a deny that the revision the
    // capture will read cannot state.
    assert!(
        denied(&w, HarnessId::Pi, "rev").contains("tasks_write"),
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
        denied(&w, HarnessId::Pi, "rev").contains("tasks_write"),
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
fn a_fork_is_refused_where_a_targeted_tools_revision_is_not_recorded() {
    let w = agent_world(
        "\"claude\", \"pi\"",
        "---\nname: rev\ndescription: agent rev\nrole: reviewer\n---\nUpstream body.\n",
        "",
        "",
    );
    let roleless = "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n";
    fs::write(w.upstream.join("agents/rev.md"), roleless).unwrap();
    commit(&w.upstream, "two");
    let two = head_commit(&w.upstream);
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    // Claude records the roleless revision; Pi records none at all, while
    // its rendering on disk still carries the deny the role earned.
    let path = lock_path(&w.env, &w.scope);
    let mut lock = load_lock(&path).unwrap();
    let entry = |harness| kendex_core::lock::entry_key(ItemKind::Agent, "rev", harness);
    lock.entries
        .get_mut(&entry(HarnessId::Claude))
        .unwrap()
        .source_commit = Some(two.clone());
    lock.entries
        .get_mut(&entry(HarnessId::Pi))
        .unwrap()
        .source_commit = None;
    kendex_core::lock::save(&path, &lock).unwrap();
    assert!(
        denied(&w, HarnessId::Pi, "rev").contains("tasks_write"),
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
        denied(&w, HarnessId::Pi, "rev").contains("tasks_write"),
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
    let w = forked_world("");
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
    for (harness, tool) in NAME_KEYED {
        assert_eq!(
            denied(&w, harness, "rev-mine"),
            denied(&w, harness, "rev"),
            "the copy denies what the original denies on {harness:?}"
        );
        assert!(denied(&w, harness, "rev-mine").contains(tool));
    }
}

/// A rename that changes no harness's generated deny list still runs. The
/// proof refuses a name that widens access, not every name.
#[test]
#[allow(clippy::unwrap_used)]
fn a_rename_that_widens_nothing_still_moves_the_fork() {
    let w = forked_world("");
    let plan = fork::rename_fork(&w.env, &w.scope, ItemKind::Agent, "rev", "my-rev").unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);
    for (harness, tool) in NAME_KEYED {
        assert!(
            denied(&w, harness, "my-rev").contains(tool),
            "the renamed agent keeps the deny on {harness:?}"
        );
    }
}
