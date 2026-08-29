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
    apply::execute(&w.env, &plan, None).unwrap();
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

/// A rename that changes no harness's generated deny list still runs. The
/// proof refuses a name that widens access, not every name.
#[test]
#[allow(clippy::unwrap_used)]
fn a_rename_that_widens_nothing_still_moves_the_fork() {
    let w = forked_world("");
    let plan = fork::rename_fork(&w.env, &w.scope, ItemKind::Agent, "rev", "my-rev").unwrap();
    apply::execute(&w.env, &plan, None).unwrap();
    resettle(&w);
    for (harness, tool) in NAME_KEYED {
        assert!(
            denied(&w, harness, "my-rev").contains(tool),
            "the renamed agent keeps the deny on {harness:?}"
        );
    }
}
