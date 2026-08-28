//! What a fork carries, refuses, and moves. An agent's tool access, its
//! delegation, its hooks and its settings all shape what it may do, and a
//! copy of it must be no more permissive than the agent it came from: what
//! can ride does, what cannot refuses, and what is keyed by the agent's
//! name travels with the name.

use std::fs;

use kendex_core::error::CoreError;

use super::*;

/// Every manifest table an agent answers to is keyed by its installed
/// name. A copy under a new name reads none of them unless they come with
/// it, and the original — still declared from its source — has to keep
/// its own.
#[test]
#[allow(clippy::unwrap_used)]
fn forking_beside_carries_the_projects_denies_without_taking_them() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "[agent-frontmatter.claude]\nrev = { deny-tools = [\"Bash\"] }\n\n[agent-launch-instructions]\nrev = \"Read the brief first.\"\n",
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
    apply::execute(&w.env, &plan, None).unwrap();
    resettle(&w);

    let copy = fs::read_to_string(rendered(&w, HarnessId::Claude, "rev-mine")).unwrap();
    assert!(
        deny_line(&copy, "disallowedTools:").contains("Bash"),
        "the copy must not be more permissive than the agent it came from: {copy}"
    );
    assert!(copy.contains("Read the brief first."), "{copy}");
    assert!(copy.contains("My body."), "{copy}");

    let original = fs::read_to_string(rendered(&w, HarnessId::Claude, "rev")).unwrap();
    assert!(
        deny_line(&original, "disallowedTools:").contains("Bash"),
        "the original stays declared from its source and keeps its own denies: {original}"
    );
}

/// A rename is the same problem with the old name gone: the tables move
/// rather than being copied, and nothing is left keyed to a name no item
/// answers to.
#[test]
#[allow(clippy::unwrap_used)]
fn renaming_an_agent_fork_carries_its_denies_and_instructions() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "[agent-frontmatter.claude]\nrev = { deny-tools = [\"Bash\"] }\n\n[agent-launch-instructions]\nrev = \"Read the brief first.\"\n",
    );
    edit_body(&rendered(&w, HarnessId::Claude, "rev"));
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan, None).unwrap();
    resettle(&w);

    let plan = fork::rename_fork(&w.env, &w.scope, ItemKind::Agent, "rev", "my-rev").unwrap();
    apply::execute(&w.env, &plan, None).unwrap();
    resettle(&w);

    let text = fs::read_to_string(rendered(&w, HarnessId::Claude, "my-rev")).unwrap();
    assert!(
        deny_line(&text, "disallowedTools:").contains("Bash"),
        "the renamed fork must not be more permissive than it was: {text}"
    );
    assert!(text.contains("Read the brief first."), "{text}");
    let recorded = manifest_text(&w);
    assert!(
        recorded.contains("[agent-frontmatter.claude.my-rev]")
            && recorded.contains("my-rev = \"Read the brief first.\""),
        "the settings and the instructions both move: {recorded}"
    );
    assert!(
        !recorded.contains("[agent-frontmatter.claude.rev]")
            && !recorded.contains("\nrev = \"Read the brief first.\""),
        "nothing stays keyed to a name no item answers to: {recorded}"
    );
}

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
    apply::execute(&w.env, &plan, None).unwrap();
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

/// A hook scoped to one agent by name reaches the copy only if its
/// selector says so, and after a rename it points at a name nothing
/// answers to. Either way an agent-scoped PreToolUse restriction quietly
/// stops applying, which is this issue's own defect in the one table the
/// first round did not move.
#[test]
#[allow(clippy::unwrap_used)]
fn an_agent_scoped_hook_reaches_the_copy_and_follows_a_rename() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "[[custom-hooks]]\nevent = \"PreToolUse\"\nmatcher = \"Bash\"\ncommand = \"./guard.sh\"\nagents = \"rev\"\n",
    );
    let guarded = |name: &str| {
        fs::read_to_string(rendered(&w, HarnessId::Claude, name))
            .unwrap()
            .contains("./guard.sh")
    };
    assert!(
        guarded("rev"),
        "the hook reaches the original to begin with"
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
    apply::execute(&w.env, &plan, None).unwrap();
    resettle(&w);
    assert!(
        guarded("rev-mine"),
        "the copy must not escape the hook the agent it came from runs under"
    );
    assert!(guarded("rev"), "and the original keeps it");

    let plan =
        fork::rename_fork(&w.env, &w.scope, ItemKind::Agent, "rev-mine", "rev-ours").unwrap();
    apply::execute(&w.env, &plan, None).unwrap();
    resettle(&w);
    assert!(guarded("rev-ours"), "the hook follows the rename");
    let recorded = manifest_text(&w);
    assert!(
        !recorded.contains("rev-mine"),
        "nothing stays selected by a name no agent answers to: {recorded}"
    );
}

/// Forking a skill beside its source must not touch an agent's settings.
/// The manifest keys agents and skills in separate tables but one shared
/// namespace of names, so an unguarded rekey copies the settings of an
/// agent that merely shares the skill's name.
#[test]
#[allow(clippy::unwrap_used)]
fn forking_a_skill_beside_leaves_a_same_named_agents_settings_alone() {
    let w = world();
    write_skill(&w.upstream, "rev", "Upstream skill.");
    let agents = w.upstream.join("agents");
    fs::create_dir_all(&agents).unwrap();
    fs::write(
        agents.join("rev.md"),
        "---\nname: rev\ndescription: agent rev\n---\nAgent body.\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.rev]\nsource = \"cat\"\n\n[agents.rev]\nsource = \"cat\"\n\n[agent-frontmatter.claude]\nrev = { deny-tools = [\"Bash\"] }\n",
    );
    sync_and_apply(&w);
    fs::write(
        w.home.join("app/.agents/skills/rev/SKILL.md"),
        "---\nname: rev\ndescription: mine\n---\nMy skill.\n",
    )
    .unwrap();

    let plan = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "rev",
        HarnessId::Claude,
        "rev-mine",
        None,
    )
    .unwrap();
    apply::execute(&w.env, &plan, None).unwrap();

    let recorded = manifest_text(&w);
    assert!(
        !recorded.contains("agent-frontmatter.claude.rev-mine"),
        "a skill fork must not copy an agent's settings onto its new name: {recorded}"
    );
}

/// A name already carrying an agent's settings is not free for a copy to
/// land on. Writing the copy's own settings under it would replace what
/// the person wrote, and merging the two would invent a policy nobody
/// asked for, so the fork refuses the way it refuses every other thing it
/// cannot carry.
#[test]
#[allow(clippy::unwrap_used)]
fn forking_beside_refuses_a_name_that_already_carries_settings() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "[agent-frontmatter.claude]\nrev-mine = { deny-tools = [\"Bash\"] }\n",
    );
    edit_body(&rendered(&w, HarnessId::Claude, "rev"));

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Agent,
        "rev",
        HarnessId::Claude,
        "rev-mine",
        None,
    )
    .unwrap_err();
    assert!(
        matches!(refused, CoreError::ForkNameUnusable { .. }),
        "{refused:?}"
    );
    assert!(
        refused.to_string().contains("agent-frontmatter"),
        "the refusal names where the settings are: {refused}"
    );
    assert!(!captured(&w, "rev-mine").exists(), "nothing was written");
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
    apply::execute(&w.env, &plan, None).unwrap();
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
    apply::execute(&w.env, &plan, None).unwrap();
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
    apply::execute(&w.env, &plan, None).unwrap();
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
