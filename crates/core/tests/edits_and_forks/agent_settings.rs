//! What one hand-edited rendering states, and what a fork makes of it. An
//! agent's tool access, its delegation and its settings all shape what it
//! may do, and a copy must be no more permissive than the agent it came
//! from. The source form has no key for any of them, so what the override
//! table can hold rides into `[agent-frontmatter.<harness>]` under the
//! copy's name — and there is no third outcome: what nothing can hold
//! refuses the fork, naming the keys, before anything is written.

use std::fs;

use super::*;

/// The refusal a fork raises, as its printed reason. Every caller here
/// wants the same two facts of it: which keys it names, and that nothing
/// reached disk.
#[allow(clippy::unwrap_used)]
fn refuses(w: &World, harness: HarnessId) -> String {
    let refused = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", harness).unwrap_err();
    assert!(
        matches!(
            refused,
            kendex_core::error::CoreError::ForkKeysUncarried { .. }
        ),
        "{refused:?}"
    );
    assert!(!captured(w, "rev").exists(), "nothing was written");
    assert!(!manifest_text(w).contains("[forks.agent.rev]"));
    refused.to_string()
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

/// A person who changes a setting the override table has a field for gets
/// it carried. One it has no field for gets the fork refused: `description:`
/// would otherwise come back as the publisher wrote it, which is the
/// person's edit undone by the very operation meant to keep it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_settings_edit_rides_into_the_manifest_and_a_description_edit_refuses() {
    let source = "---\nname: rev\ndescription: agent rev\ncolor: blue\n---\nUpstream body.\n";
    let w = agent_world("\"claude\"", source, "", "");
    let file = rendered(&w, HarnessId::Claude, "rev");
    let text = fs::read_to_string(&file).unwrap();
    fs::write(
        &file,
        text.replace("color: blue", "color: magenta")
            .replace("background: true", "background: false"),
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

    // The same edit with a description change beside it: no field holds
    // one, so the fork refuses rather than reverting it.
    let w = agent_world("\"claude\"", source, "", "");
    let file = rendered(&w, HarnessId::Claude, "rev");
    let text = fs::read_to_string(&file).unwrap();
    fs::write(
        &file,
        text.replace("description: \"agent rev\"", "description: \"my rev\""),
    )
    .unwrap();
    let refused = refuses(&w, HarnessId::Claude);
    assert!(
        refused.contains("description"),
        "the refusal names the key it cannot carry: {refused}"
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
/// an effort can be cleared; a deleted colour would come back from the
/// publisher, so the fork refuses instead of undoing the deletion.
#[test]
#[allow(clippy::unwrap_used)]
fn a_cleared_effort_rides_and_a_deleted_colour_refuses() {
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
    let refused = refuses(&w, HarnessId::Claude);
    assert!(
        refused.contains("color"),
        "the refusal names the deleted setting: {refused}"
    );
    assert!(
        !fs::read_to_string(&file).unwrap().contains("color:"),
        "and the person's file is left as they wrote it"
    );
}

/// A hook written into a Claude agent file gates tool use from inside that
/// file. No override table holds one — a hook is a custom-hooks entry with
/// a selector, not a field — so a gate the fork would not run again is a
/// restriction it cannot carry, and it refuses.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hand_written_hook_refuses_the_fork() {
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

    let refused = refuses(&w, HarnessId::Claude);
    assert!(
        refused.contains("hooks"),
        "the refusal names the key it cannot carry: {refused}"
    );
    assert!(
        fs::read_to_string(&file).unwrap().contains("./guard.sh"),
        "and the gate still stands, because nothing was written"
    );
}

/// Frontmatter that will not parse is not the same answer as frontmatter
/// stating nothing. What the person set cannot be read, so it cannot be
/// shown carried either, and a reading that took it for an empty file
/// would take every absent value for a deliberate clearing — writing
/// `effort: none` over the effort the publisher set. The fork refuses
/// rather than guess.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_frontmatter_refuses_the_fork() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\neffort: high\n---\nUpstream body.\n",
        "",
        "",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    let text = fs::read_to_string(&file).unwrap();
    assert!(text.contains("effort: high"), "{text}");
    fs::write(
        &file,
        text.replace(
            "disallowedTools:",
            "tools: Read\ntools: Grep\ndisallowedTools:",
        ),
    )
    .unwrap();

    let refused = refuses(&w, HarnessId::Claude);
    assert!(
        refused.contains("cannot be read"),
        "the refusal says why the file could not be read: {refused}"
    );
    assert!(
        !manifest_text(&w).contains("effort"),
        "and no clearing was invented from an unreadable file: {}",
        manifest_text(&w)
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

/// A deny the person deleted from the rendered list. `deny-tools` is
/// unioned into what the renderer computes and never subtracted from it,
/// so no override can state the deletion — the copy would come back
/// denying what they took off. The direction is safe and the refusal is
/// still the rule: what cannot be carried is named, never dropped.
#[test]
#[allow(clippy::unwrap_used)]
fn a_deleted_deny_refuses_the_fork() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "[agent-frontmatter.claude]\nrev = { deny-tools = [\"Bash\"] }\n",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    let text = fs::read_to_string(&file).unwrap();
    assert!(
        deny_line(&text, "disallowedTools:").contains("Bash"),
        "the fixture needs a deny in the rendering to delete: {text}"
    );
    fs::write(&file, text.replace(", Bash", "")).unwrap();

    let refused = refuses(&w, HarnessId::Claude);
    assert!(
        refused.contains("disallowedTools"),
        "the refusal names the key no override can subtract from: {refused}"
    );
}

/// A document the person wrote over the rendering — their own frontmatter
/// and their own prose — is not a rendering with a key deleted. There was
/// never a rendered value in it to take away, so nothing absent from it
/// reads as a clearing: a reading that took the missing `allowed-subagents:`
/// for a deliberate one would write an empty list into kendex.toml and put
/// `delegate_subagent` back in the copy's deny list.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hand_written_frontmatter_clears_nothing() {
    let w = agent_world(
        "\"pi\"",
        "---\nname: rev\ndescription: agent rev\nrole: engineer\n---\nUpstream body.\n",
        "",
        "",
    );
    let file = rendered(&w, HarnessId::Pi, "rev");
    let rendering = fs::read_to_string(&file).unwrap();
    assert_eq!(
        deny_line(&rendering, "allowed-subagents:"),
        "allowed-subagents: scout",
        "the fixture needs a delegation list the wrong reading would strip"
    );
    fs::write(
        &file,
        "---\nname: rev\ndescription: mine\n---\n\nMy own notes.\n",
    )
    .unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Pi).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let settled = fs::read_to_string(&file).unwrap();
    assert_eq!(
        deny_line(&settled, "allowed-subagents:"),
        "allowed-subagents: scout",
        "an absent key in a file the person wrote is not a clearing: {settled}"
    );
    assert!(
        !deny_line(&settled, "deny-tools:").contains("delegate_subagent"),
        "and the tool that goes with it is not denied either: {settled}"
    );
    assert_eq!(
        record(&w, "pi", "rev").allowed_subagents,
        None,
        "nothing was invented into kendex.toml"
    );
}
