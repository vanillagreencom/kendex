//! What one hand-edited rendering states, and what a fork makes of it. An
//! agent's tool access, its delegation and its settings all shape what it
//! may do, and a copy must be no more permissive than the agent it came
//! from. The source form has no key for any of them, so what the override
//! table can hold rides into `[agent-frontmatter.<harness>]` under the
//! copy's name, and what nothing can hold is named on the plan.

use std::fs;

use super::*;

/// Every line the plan draws, which is where the fork says what it will
/// not reproduce.
fn preview(plan: &kendex_core::apply::Plan) -> String {
    plan.ops
        .iter()
        .map(|op| format!("{}\n", op.line()))
        .collect()
}

/// The `[agent-frontmatter.<harness>]` record the fork wrote for this
/// name, read back through the loader rather than searched for in the
/// text: a record holding one field and the same record holding three
/// spell the same header.
#[allow(clippy::unwrap_used)]
fn record(w: &World, harness: &str, name: &str) -> kendex_core::manifest::FrontmatterOverrides {
    manifest_of(w)
        .agent_frontmatter
        .get(harness)
        .and_then(|by_agent| by_agent.get(name))
        .cloned()
        .unwrap_or_default()
}

/// A person who tightens a generated file by hand states something the
/// local source has no key for. The fork carries it into the override
/// table instead of handing the tools back: the copy denies what the file
/// on disk denied, and the person's own file is never overwritten wider.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hand_tightened_deny_rides_into_the_manifest() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    let text = fs::read_to_string(&file).unwrap();
    fs::write(
        &file,
        text.replace(
            "disallowedTools: Agent, AskUserQuestion",
            "disallowedTools: Agent, AskUserQuestion, Bash, WebFetch",
        ),
    )
    .unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    assert_eq!(
        record(&w, "claude", "rev").deny_tools.as_deref(),
        Some(["Bash".to_owned(), "WebFetch".to_owned()].as_slice()),
        "only what the person added rides, not the denies the renderer writes anyway"
    );
    let settled = deny_line(&fs::read_to_string(&file).unwrap(), "disallowedTools:");
    for tool in ["Agent", "AskUserQuestion", "Bash", "WebFetch"] {
        assert!(
            settled.contains(tool),
            "the copy denies what the file denied: {settled}"
        );
    }
}

/// The same edit from the other direction: an allowlist added by hand to a
/// file that stated none. An `allow-tools` override replaces the source's
/// outright, so the file's own list is what reproduces the file.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hand_added_allowlist_rides_into_the_manifest() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    let text = fs::read_to_string(&file).unwrap();
    fs::write(
        &file,
        text.replace("disallowedTools:", "tools: Read, Grep\ndisallowedTools:"),
    )
    .unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    assert_eq!(
        record(&w, "claude", "rev").allow_tools.as_deref(),
        Some(["Read".to_owned(), "Grep".to_owned()].as_slice()),
        "the allowlist the person wrote is the one the copy renders from"
    );
    let settled = fs::read_to_string(&file).unwrap();
    assert_eq!(
        deny_line(&settled, "tools:"),
        "tools: Read, Grep",
        "and the copy states it: {settled}"
    );
}

/// A person who changes a setting in the generated file changed something
/// the override table has a field for. Those ride into the manifest rather
/// than being dropped, so the set a fork loses is only what nothing can
/// hold: `description:` and `tags:`, which the table has no field for.
#[test]
#[allow(clippy::unwrap_used)]
fn a_settings_edit_rides_into_the_manifest_and_a_description_edit_does_not() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\ncolor: blue\n---\nUpstream body.\n",
        "",
        "",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    let text = fs::read_to_string(&file).unwrap();
    fs::write(
        &file,
        text.replace("color: blue", "color: magenta")
            .replace("background: true", "background: false")
            .replace("description: \"agent rev\"", "description: \"my rev\""),
    )
    .unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let recorded = record(&w, "claude", "rev");
    assert_eq!(recorded.color.as_deref(), Some("magenta"), "{recorded:?}");
    assert_eq!(recorded.background, Some(false), "{recorded:?}");
    let settled = fs::read_to_string(&file).unwrap();
    assert!(settled.contains("color: magenta"), "{settled}");
    assert!(settled.contains("background: false"), "{settled}");
    assert!(
        settled.contains("description: \"agent rev\""),
        "a description edit has no override field and comes back from the publisher: {settled}"
    );
}

/// Pi's allowed-subagents governs which child agents this one may invoke,
/// so narrowing it is access shaping exactly as narrowing a tool list is.
#[test]
#[allow(clippy::unwrap_used)]
fn a_narrowed_pi_delegation_list_survives_the_fork() {
    let w = agent_world(
        "\"pi\"",
        "---\nname: rev\ndescription: agent rev\nrole: engineer\n---\nUpstream body.\n",
        "[agent-frontmatter.pi]\nrev = { allowed-subagents = [\"scout\", \"researcher\"] }\n",
        "",
    );
    let file = rendered(&w, HarnessId::Pi, "rev");
    let rendering = fs::read_to_string(&file).unwrap();
    assert_eq!(
        deny_line(&rendering, "allowed-subagents:"),
        "allowed-subagents: scout, researcher"
    );
    fs::write(
        &file,
        rendering
            .replace(
                "allowed-subagents: scout, researcher",
                "allowed-subagents: scout",
            )
            .replace("Upstream body.", "My body."),
    )
    .unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Pi).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let settled = fs::read_to_string(&file).unwrap();
    assert_eq!(
        deny_line(&settled, "allowed-subagents:"),
        "allowed-subagents: scout",
        "the fork must not hand back a child agent the person removed: {settled}"
    );
    assert!(settled.contains("My body."), "{settled}");
}

/// Deleting the delegation list entirely is the same edit taken all the
/// way, and it rides too: an empty override is a list the renderer writes
/// nothing for, and it denies the delegation tool along with it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_deleted_pi_delegation_list_survives_the_fork() {
    let w = agent_world(
        "\"pi\"",
        "---\nname: rev\ndescription: agent rev\nrole: engineer\n---\nUpstream body.\n",
        "",
        "",
    );
    let file = rendered(&w, HarnessId::Pi, "rev");
    let rendering = fs::read_to_string(&file).unwrap();
    assert!(
        rendering.contains("allowed-subagents: scout"),
        "{rendering}"
    );
    let without: String = rendering
        .lines()
        .filter(|line| !line.starts_with("allowed-subagents:"))
        .map(|line| format!("{line}\n"))
        .collect();
    fs::write(&file, &without).unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Pi).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let settled = fs::read_to_string(&file).unwrap();
    assert!(
        !settled.contains("allowed-subagents:"),
        "a cleared delegation list must not come back: {settled}"
    );
    assert!(
        deny_line(&settled, "deny-tools:").contains("delegate_subagent"),
        "and the delegation tool goes with it: {settled}"
    );
}

/// Deleting a rendered key is an edit in the restrictive direction. An
/// override states what a value is and never that there is none, so only
/// an effort can be cleared; a deleted colour comes back from the
/// publisher, and the plan says so rather than the copy changing in
/// silence.
#[test]
#[allow(clippy::unwrap_used)]
fn a_cleared_effort_rides_and_a_deleted_colour_is_named_on_the_plan() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\nmodel: sonnet\neffort: high\ncolor: blue\n---\nUpstream body.\n",
        "",
        "",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    let rendering = fs::read_to_string(&file).unwrap();
    assert!(rendering.contains("effort: high") && rendering.contains("color: blue"));

    // An effort can be cleared: every renderer reads `none` as no effort.
    let without_effort: String = rendering
        .lines()
        .filter(|line| !line.starts_with("effort:"))
        .map(|line| format!("{line}\n"))
        .collect();
    fs::write(&file, &without_effort).unwrap();
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    let drawn = preview(&plan);
    assert!(
        !drawn.contains("not carried"),
        "a cleared effort is carried, so nothing is named: {drawn}"
    );
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);
    let settled = fs::read_to_string(&file).unwrap();
    assert!(
        !settled.lines().any(|line| line.starts_with("effort:")),
        "a cleared effort must not come back: {settled}"
    );

    // A colour cannot: nothing in the override table says there is none.
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\ncolor: blue\n---\nUpstream body.\n",
        "",
        "",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    let rendering = fs::read_to_string(&file).unwrap();
    let without_color: String = rendering
        .lines()
        .filter(|line| !line.starts_with("color:"))
        .map(|line| format!("{line}\n"))
        .collect();
    fs::write(&file, &without_color).unwrap();
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    let drawn = preview(&plan);
    assert!(
        drawn.contains("not carried") && drawn.contains("`color:`"),
        "the plan names the setting the copy will not reproduce: {drawn}"
    );
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);
    assert!(
        fs::read_to_string(&file).unwrap().contains("color: blue"),
        "and it does come back, which is why the plan had to say so"
    );
}

/// A hook written into a Claude agent file gates tool use from inside that
/// file. No override table holds one — a hook is a custom-hooks entry with
/// a selector, not a field — so a gate the fork would not run again is
/// named on the plan. The gate's scope is part of its name: the same
/// command on another event is a different gate.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hand_written_hook_is_named_on_the_plan() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    let text = fs::read_to_string(&file).unwrap();
    fs::write(
        &file,
        text.replace(
            "disallowedTools:",
            "hooks:\n  PreToolUse:\n    \"Bash\":\n      - type: command\n        command: \"./guard.sh\"\ndisallowedTools:",
        ),
    )
    .unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    let drawn = preview(&plan);
    assert!(
        drawn.contains("./guard.sh") && drawn.contains("PreToolUse on Bash"),
        "the plan names the gate it will not run again, scope and all: {drawn}"
    );
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);
    assert!(
        !fs::read_to_string(&file).unwrap().contains("./guard.sh"),
        "and the gate is gone, which is why the plan had to say so"
    );
}

/// Frontmatter that will not parse is not the same answer as frontmatter
/// stating nothing. What the person set cannot be read, so none of it can
/// be carried, and the plan says that rather than the copy going quietly
/// wider.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_frontmatter_is_named_on_the_plan() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    let text = fs::read_to_string(&file).unwrap();
    fs::write(
        &file,
        text.replace(
            "disallowedTools:",
            "tools: Read\ntools: Grep\ndisallowedTools:",
        ),
    )
    .unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    let drawn = preview(&plan);
    assert!(
        drawn.contains("not carried") && drawn.contains("cannot be read"),
        "the plan says the file's settings could not be read: {drawn}"
    );
}

/// The carry holds the catalog's default merged with the project's own
/// entry, and it wins the fold field by field — so the project's value has
/// to be in it. Read from the catalog alone, the copy would render the
/// publisher's colour over the one the project set.
#[test]
#[allow(clippy::unwrap_used)]
fn the_projects_entry_beats_the_catalogs_default_through_the_carry() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "[agent-frontmatter.claude]\nrev = { color = \"green\" }\n",
        "[agent-frontmatter.claude]\nrev = { color = \"red\" }\n",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    assert!(
        fs::read_to_string(&file).unwrap().contains("color: red"),
        "the fixture starts with the project's colour winning"
    );
    edit_body(&file);

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    assert_eq!(
        record(&w, "claude", "rev").color.as_deref(),
        Some("red"),
        "the carry must not put the catalog's default over the project's entry"
    );
    assert!(
        fs::read_to_string(&file).unwrap().contains("color: red"),
        "and the copy renders it"
    );
}
