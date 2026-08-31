//! The name a fork or a rename lands under, against every harness the
//! declaration targets. Claude, Pi and OpenCode each withhold a tool from
//! subagents unless the author declared `role: planner`, so the deny
//! belongs to the role and no name a fork or a rename picks can take it
//! off — and no name can put it back on an agent whose author declared
//! that role.

use std::collections::BTreeSet;
use std::fs;

use super::*;

/// Every harness that withholds a tool from an agent that is not a
/// planner: the tool it withholds, and one it denies a subagent whatever
/// the role. The second is what makes the first readable — a rendering
/// that stated no deny line at all would satisfy every "does not contain"
/// on its own, so each case asserts the baseline is there first.
const ROLE_KEYED: [(HarnessId, &str, &str); 3] = [
    (HarnessId::Claude, "AskUserQuestion", "Agent"),
    (HarnessId::Pi, "question", "subagent"),
    (HarnessId::Opencode, "question", "task"),
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
fn forked_world(agent: &str) -> World {
    let w = agent_world(ALL_THREE, agent, "", "");
    edit_body(&rendered(&w, HarnessId::Claude, "rev"));
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);
    w
}

const ROLELESS: &str = "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n";
const PLANNER: &str =
    "---\nname: rev\ndescription: agent rev\nrole: planner\n---\nUpstream body.\n";

/// The rename the old name-keyed deny could not survive, taken both ways.
/// `planner` is a name like any other now: an agent whose author declared
/// no role keeps every harness's deny through a move onto it, and through
/// the move back off it.
#[test]
#[allow(clippy::unwrap_used)]
fn renaming_a_fork_onto_planner_and_off_it_keeps_every_harnesss_deny() {
    let w = forked_world(ROLELESS);
    for (harness, tool, _) in ROLE_KEYED {
        assert!(
            denied(&w, harness, "rev").contains(tool),
            "the fixture has to start with the deny the rename must not drop on {harness:?}"
        );
    }

    let plan = fork::rename_fork(&w.env, &w.scope, ItemKind::Agent, "rev", "planner").unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);
    for (harness, tool, _) in ROLE_KEYED {
        assert!(
            denied(&w, harness, "planner").contains(tool),
            "the deny is the role's, so it survives the move onto that name on {harness:?}"
        );
    }
    assert!(
        manifest_of(&w).agents.contains_key("planner"),
        "the declaration moved"
    );

    let plan = fork::rename_fork(&w.env, &w.scope, ItemKind::Agent, "planner", "my-rev").unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);
    for (harness, tool, _) in ROLE_KEYED {
        assert!(
            denied(&w, harness, "my-rev").contains(tool),
            "and it survives the move back off that name on {harness:?}"
        );
    }
}

/// The other direction, and the case only `role:` can answer: an author
/// who declared `role: planner` keeps the tool under whatever name the
/// fork lands on, on every harness the declaration targets — including the
/// two the fork was not captured from.
#[test]
#[allow(clippy::unwrap_used)]
fn a_forked_planner_keeps_its_questions_under_a_new_name() {
    let w = agent_world(ALL_THREE, PLANNER, "", "");
    for (harness, tool, baseline) in ROLE_KEYED {
        let denies = denied(&w, harness, "rev");
        assert!(
            denies.contains(baseline),
            "a rendering stating no deny line would pass every assertion below on {harness:?}: {denies:?}"
        );
        assert!(
            !denies.contains(tool),
            "the fixture starts with the planner's own {tool} on {harness:?}"
        );
    }

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

    for (harness, tool, baseline) in ROLE_KEYED {
        let denies = denied(&w, harness, "rev-mine");
        assert!(
            denies.contains(baseline),
            "the copy has to state a deny list at all before it can be read on {harness:?}: {denies:?}"
        );
        assert!(
            !denies.contains(tool),
            "the copy declares the role, so it keeps {tool} on {harness:?} under its new name"
        );
        assert_eq!(
            denies,
            denied(&w, harness, "rev"),
            "and denies exactly what the original denies on {harness:?}"
        );
    }
    assert!(
        fs::read_to_string(captured(&w, "rev-mine"))
            .unwrap()
            .contains("role: planner"),
        "the captured source form carries the role the deny is read from"
    );
}

/// A catalog's own per-harness defaults are part of what the original
/// renders with, and they reach the copy through the carry — read from the
/// catalog once, by the capture, because the fork stops reading it. A
/// default that retires a generated deny — Pi's `allowed-subagents`, which
/// retires the `delegate_subagent` deny — has to land on the copy too.
#[test]
#[allow(clippy::unwrap_used)]
fn a_catalog_default_that_retires_a_generated_deny_reaches_the_copy() {
    let w = agent_world(
        "\"claude\", \"pi\"",
        ROLELESS,
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
