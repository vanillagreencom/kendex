//! What one hand-edited rendering states, and what a fork makes of it.
//! An agent's tool access, its delegation and its hooks all shape what it
//! may do, and a copy of it must be no more permissive than the agent it
//! came from: what the override table can hold rides into the manifest,
//! and what nothing can hold refuses.

use std::fs;

use kendex_core::error::CoreError;

use super::*;

/// A person who tightens a generated file by hand states something the
/// local source has no key for and the manifest is not being written from.
/// Forking anyway would hand them back the tools they took away, so the
/// fork refuses and writes nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hand_tightened_deny_refuses_the_fork_and_writes_nothing() {
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

    let refused =
        fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap_err();
    let said = refused.to_string();
    assert!(
        matches!(refused, CoreError::ForkWidensAccess { .. }),
        "{refused:?}"
    );
    assert!(
        said.contains("Bash") && said.contains("WebFetch") && said.contains("nothing was written"),
        "the refusal names what it stopped on: {said}"
    );
    assert!(!captured(&w, "rev").exists(), "nothing was written");
    assert!(!manifest_text(&w).contains("[forks.agent.rev]"));
}

/// The same refusal from the other direction: an allowlist added by hand
/// to a file that stated none. What the fork would give back is every
/// tool outside it, so the refusal names the allowlist instead.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hand_added_allowlist_refuses_the_fork() {
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

    let refused =
        fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap_err();
    let said = refused.to_string();
    assert!(
        matches!(refused, CoreError::ForkWidensAccess { .. }),
        "{refused:?}"
    );
    assert!(said.contains("Read, Grep"), "{said}");
    assert!(!captured(&w, "rev").exists(), "nothing was written");
}

/// Frontmatter that will not parse is not the same answer as frontmatter
/// stating nothing. What the person took away cannot be read, so it cannot
/// be proven carried either, and the fork refuses rather than guess.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_frontmatter_refuses_the_fork() {
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

    let refused =
        fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap_err();
    assert!(
        matches!(refused, CoreError::ForkWidensAccess { .. }),
        "{refused:?}"
    );
    assert!(refused.to_string().contains("cannot be read"), "{refused}");
    assert!(!captured(&w, "rev").exists(), "nothing was written");
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

    let recorded = manifest_text(&w);
    assert!(
        recorded.contains("[agent-frontmatter.claude.rev]"),
        "the settings the person changed ride as overrides: {recorded}"
    );
    let settled = fs::read_to_string(&file).unwrap();
    assert!(settled.contains("color: magenta"), "{settled}");
    assert!(settled.contains("background: false"), "{settled}");
    assert!(
        settled.contains("description: \"agent rev\""),
        "a description edit has no override field and comes back from the publisher: {settled}"
    );
}

/// Deleting a rendered key is an edit in the restrictive direction, and
/// the fork must not answer it by putting the publisher's value back. An
/// override states what a value is and never that there is none, so only
/// an effort can be cleared; everything else refuses, naming what was
/// deleted.
#[test]
#[allow(clippy::unwrap_used)]
fn a_deleted_setting_is_carried_where_it_can_be_and_refused_where_it_cannot() {
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
    let refused =
        fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap_err();
    assert!(
        matches!(refused, CoreError::ForkWidensAccess { .. }),
        "{refused:?}"
    );
    assert!(
        refused.to_string().contains("deleted") && refused.to_string().contains("color"),
        "the refusal names the deleted setting: {refused}"
    );
    assert!(!captured(&w, "rev").exists(), "nothing was written");
}

/// Pi's allowed-subagents governs which child agents this one may invoke,
/// so narrowing it is access shaping exactly as narrowing a tool list is.
/// It rides as an override rather than refusing, because unlike a scalar
/// its clearing is representable: an empty list is what the renderer reads
/// as no delegation at all.
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

/// A hook written into a Claude agent file gates tool use from inside that
/// file. No override table holds one — a hook is a custom-hooks entry with
/// a selector, not a field — so a hook the fork would not run again is a
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

    let refused =
        fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap_err();
    assert!(
        matches!(refused, CoreError::ForkWidensAccess { .. }),
        "{refused:?}"
    );
    assert!(
        refused.to_string().contains("./guard.sh"),
        "the refusal names the hook it stopped on: {refused}"
    );
    assert!(!captured(&w, "rev").exists(), "nothing was written");
}

/// A hook is its scope as well as its command. Tightening the scope by
/// hand — the same command moved to an earlier event, or onto a broader
/// matcher — leaves the command alone, so a reading that compares commands
/// sees no difference and lets the fork restore the looser gate.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hand_tightened_hook_scope_refuses_the_fork() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "[[custom-hooks]]\nevent = \"PostToolUse\"\nmatcher = \"Bash\"\ncommand = \"./guard.sh\"\nagents = \"rev\"\n",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    let text = fs::read_to_string(&file).unwrap();
    assert!(text.contains("PostToolUse:"), "{text}");
    // The same command, moved to gate the call before it runs instead of
    // reporting on it afterwards.
    fs::write(&file, text.replace("PostToolUse:", "PreToolUse:")).unwrap();

    let refused =
        fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap_err();
    assert!(
        matches!(refused, CoreError::ForkWidensAccess { .. }),
        "{refused:?}"
    );
    let said = refused.to_string();
    assert!(
        said.contains("PreToolUse") && said.contains("Bash") && said.contains("./guard.sh"),
        "the refusal names the gate whole, not just its command: {said}"
    );
    assert!(!captured(&w, "rev").exists(), "nothing was written");
}

/// The other reading `split` reports the same error for. A block that
/// opens and never ends is frontmatter that will not read, not a file
/// stating nothing: whatever the person restricted in it cannot be read
/// back, so it cannot be proven carried either, and the fork refuses
/// rather than proceed on an empty reading of a file full of denies.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unterminated_frontmatter_refuses_the_fork() {
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
        "the block the edit leaves unterminated is the one stating the denies: {text}"
    );
    assert_eq!(
        times(&text, "---"),
        2,
        "the rendering opens and closes exactly one block: {text}"
    );
    let mut lines: Vec<&str> = text.lines().collect();
    let closer = lines.iter().rposition(|line| line.trim() == "---").unwrap();
    lines.remove(closer);
    fs::write(
        &file,
        lines
            .iter()
            .map(|line| format!("{line}\n"))
            .collect::<String>(),
    )
    .unwrap();

    let refused =
        fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap_err();
    assert!(
        matches!(refused, CoreError::ForkWidensAccess { .. }),
        "{refused:?}"
    );
    assert!(
        refused.to_string().contains("unterminated frontmatter"),
        "the refusal names why the file could not be read: {refused}"
    );
    assert!(!captured(&w, "rev").exists(), "nothing was written");
}

/// The reading on the other side of that split, which stays a fork rather
/// than a refusal: a file opening no block at all states nothing, and a
/// person who replaced the whole rendering with their own prose took no
/// tools away.
#[test]
#[allow(clippy::unwrap_used)]
fn a_rendering_replaced_with_prose_still_forks() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "[agent-frontmatter.claude]\nrev = { deny-tools = [\"Bash\"] }\n",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    fs::write(&file, "My own notes, and nothing the harness reads.\n").unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let settled = fs::read_to_string(&file).unwrap();
    assert!(settled.contains("My own notes,"), "{settled}");
    assert!(
        deny_line(&settled, "disallowedTools:").contains("Bash"),
        "the fork is still no wider than the installation: {settled}"
    );
}
