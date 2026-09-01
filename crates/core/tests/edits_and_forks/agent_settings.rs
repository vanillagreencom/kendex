use std::fs;

use kendex_core::error::CoreError;

use super::*;

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
