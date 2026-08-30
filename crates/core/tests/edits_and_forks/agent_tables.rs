//! The manifest configuration an agent answers to, every table of it keyed
//! by the installed name. A copy under a new name reads none of it unless
//! it comes along, a rename leaves nothing behind keyed to a name no item
//! answers to, and neither operation may take configuration off the agents
//! it never mentioned.

use std::fs;

use kendex_core::error::CoreError;
use kendex_core::manifest::HookAgents;

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
    apply::execute(&w.env, &plan).unwrap();
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

/// A carry holds a frontmatter record only for a harness the catalog
/// configured this agent under. Where the catalog configured none and the
/// project did, the whole carried record is the person's own edit, so
/// writing it over the entry the rekey just copied takes the project's
/// denies off the copy — the widening the fork exists to prevent, arriving
/// through the table meant to carry it.
#[test]
#[allow(clippy::unwrap_used)]
fn forking_beside_keeps_a_deny_the_catalog_never_configured() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\ncolor: blue\n---\nUpstream body.\n",
        "",
        "[agent-frontmatter.claude]\nrev = { deny-tools = [\"Bash\"] }\n",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    let text = fs::read_to_string(&file).unwrap();
    fs::write(
        &file,
        text.replace("color: blue", "color: magenta")
            .replace("Upstream body.", "My body."),
    )
    .unwrap();

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

    let manifest = manifest_of(&w);
    let record = manifest
        .agent_frontmatter
        .get("claude")
        .and_then(|by_agent| by_agent.get("rev-mine"))
        .unwrap();
    assert_eq!(
        record.deny_tools.as_deref(),
        Some(["Bash".to_owned()].as_slice()),
        "the copy keeps the deny the original was installed with: {record:?}"
    );
    assert_eq!(
        record.color.as_deref(),
        Some("magenta"),
        "and the edit that rode in beside it: {record:?}"
    );
    let copy = fs::read_to_string(rendered(&w, HarnessId::Claude, "rev-mine")).unwrap();
    assert!(
        deny_line(&copy, "disallowedTools:").contains("Bash"),
        "the record is what the copy renders from: {copy}"
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
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let plan = fork::rename_fork(&w.env, &w.scope, ItemKind::Agent, "rev", "my-rev").unwrap();
    apply::execute(&w.env, &plan).unwrap();
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

/// The skill assignment is the one table an agent does not read by exact
/// name: a `reviewer-` agent with no row of its own reads the base
/// agent's. A rename that moves exact rows alone leaves that assignment
/// behind, and the new name resolves nothing — so the skills the person
/// took off the reviewer family come back on the renamed agent. Nothing
/// else covers it: unlike a fork beside, a rename runs no carry.
#[test]
#[allow(clippy::unwrap_used)]
fn renaming_an_agent_carries_the_skill_assignment_it_read_through_the_base_row() {
    let w = world();
    write_skill(&w.upstream, "recon", "Recon.");
    let agents = w.upstream.join("agents");
    fs::create_dir_all(&agents).unwrap();
    for name in ["reviewer-rust", "reviewer-helper"] {
        fs::write(
            agents.join(format!("{name}.md")),
            format!(
                "---\nname: {name}\ndescription: agent {name}\nrole: reviewer\n---\nUpstream body.\n"
            ),
        )
        .unwrap();
    }
    fs::write(
        w.upstream.join("kendex.toml"),
        "[role-skills]\nreviewer = [\"recon\"]\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    declare(
        &w,
        "[agents.reviewer-rust]\nsource = \"cat\"\n\n[agents.reviewer-helper]\nsource = \"cat\"\n\n[skills.recon]\nsource = \"cat\"\n\n[agent-skills]\nrust = []\n",
    );
    sync_and_apply(&w);

    // The row is the reviewer family's, written under the base name. The
    // second reviewer is the control: it holds the role that assigns
    // `recon` and no row, so the empty row is what takes the skill away
    // rather than the fixture never having assigned one.
    let assigned = |name: &str| {
        deny_line(
            &fs::read_to_string(rendered(&w, HarnessId::Claude, name)).unwrap(),
            "skills:",
        )
    };
    assert_eq!(assigned("reviewer-helper"), "skills: recon");
    assert_eq!(assigned("reviewer-rust"), "");

    edit_body(&rendered(&w, HarnessId::Claude, "reviewer-rust"));
    let plan = fork::fork(
        &w.env,
        &w.scope,
        ItemKind::Agent,
        "reviewer-rust",
        HarnessId::Claude,
    )
    .unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);
    assert!(
        !manifest_of(&w).agent_skills.contains_key("reviewer-rust"),
        "the capture carries no row of its own, so the rename is the only thing that can move the assignment: {:?}",
        manifest_of(&w).agent_skills
    );

    let plan = fork::rename_fork(
        &w.env,
        &w.scope,
        ItemKind::Agent,
        "reviewer-rust",
        "reviewer-mine",
    )
    .unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let settled = manifest_of(&w);
    assert_eq!(
        settled.agent_skills.get("reviewer-mine").map(Vec::as_slice),
        Some([].as_slice()),
        "the assignment the old name resolved has to reach the new one: {:?}",
        settled.agent_skills
    );
    assert_eq!(
        settled.agent_skills.get("rust").map(Vec::as_slice),
        Some([].as_slice()),
        "and the base row is shared, so it stays under its own key: {:?}",
        settled.agent_skills
    );
    assert_eq!(
        assigned("reviewer-helper"),
        "skills: recon",
        "the reviewer that shares the row still reads it"
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
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);
    assert!(
        guarded("rev-mine"),
        "the copy must not escape the hook the agent it came from runs under"
    );
    assert!(guarded("rev"), "and the original keeps it");

    let plan =
        fork::rename_fork(&w.env, &w.scope, ItemKind::Agent, "rev-mine", "rev-ours").unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);
    assert!(guarded("rev-ours"), "the hook follows the rename");
    let recorded = manifest_text(&w);
    assert!(
        !recorded.contains("rev-mine"),
        "nothing stays selected by a name no agent answers to: {recorded}"
    );
}

/// A role selector describes a population, not one agent. An agent that
/// happens to be named for a role does not own the selector spelling it,
/// and renaming that agent must not rewrite it: doing so takes the gate
/// off every other agent holding the role, from an operation that never
/// mentioned them.
#[test]
#[allow(clippy::unwrap_used)]
fn renaming_an_agent_named_for_a_role_leaves_the_roles_hook_alone() {
    let w = world();
    let agents = w.upstream.join("agents");
    fs::create_dir_all(&agents).unwrap();
    fs::write(
        agents.join("engineer.md"),
        "---\nname: engineer\ndescription: agent engineer\n---\nUpstream body.\n",
    )
    .unwrap();
    fs::write(
        agents.join("rev.md"),
        "---\nname: rev\ndescription: agent rev\nrole: engineer\n---\nOther body.\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[agents.engineer]\nsource = \"cat\"\n\n[agents.rev]\nsource = \"cat\"\n\n[[custom-hooks]]\nevent = \"PreToolUse\"\nmatcher = \"Bash\"\ncommand = \"./guard.sh\"\nagents = \"engineer\"\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    let guarded = |name: &str| {
        fs::read_to_string(rendered(&w, HarnessId::Claude, name))
            .unwrap()
            .contains("./guard.sh")
    };
    assert!(guarded("rev"), "the role's hook reaches an engineer");

    edit_body(&rendered(&w, HarnessId::Claude, "engineer"));
    let plan = fork::fork(
        &w.env,
        &w.scope,
        ItemKind::Agent,
        "engineer",
        HarnessId::Claude,
    )
    .unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);
    let plan = fork::rename_fork(&w.env, &w.scope, ItemKind::Agent, "engineer", "my-eng").unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    assert!(
        guarded("rev"),
        "renaming one agent took the gate off every other engineer: {}",
        manifest_text(&w)
    );
    assert!(
        manifest_text(&w).contains("agents = \"engineer\""),
        "the role selector is untouched: {}",
        manifest_text(&w)
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
    apply::execute(&w.env, &plan).unwrap();

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

/// The skill assignment is the one table an agent does not read by exact
/// name, so a destination holding no row of its own is not free: it reads
/// the base agent's. A copy landing there writes an exact row that shadows
/// the person's, and their assignment stops reaching the agent — silently,
/// because the exact-key question calls that name vacant. The refusal asks
/// the reader that resolves the fallback instead.
#[test]
#[allow(clippy::unwrap_used)]
fn forking_beside_refuses_a_name_that_reads_the_base_agents_skill_row() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "[agent-skills]\nrust = []\n",
    );
    edit_body(&rendered(&w, HarnessId::Claude, "rev"));

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Agent,
        "rev",
        HarnessId::Claude,
        "reviewer-rust",
        None,
    )
    .unwrap_err();
    assert!(
        matches!(refused, CoreError::ForkNameUnusable { .. }),
        "{refused:?}"
    );
    assert!(
        refused.to_string().contains("agent-skills"),
        "the refusal names where the assignment is: {refused}"
    );
    assert_eq!(
        manifest_of(&w).agent_skills.keys().collect::<Vec<_>>(),
        vec!["rust"],
        "the row the destination reads is the base agent's, and it stays the only one"
    );
    assert!(
        !captured(&w, "reviewer-rust").exists(),
        "nothing was written"
    );

    // The control: a reviewer name whose base row nobody wrote resolves
    // nothing by either key, and refusing it there would turn the fallback
    // into a naming rule the operation never needed.
    let plan = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Agent,
        "rev",
        HarnessId::Claude,
        "reviewer-mine",
        None,
    )
    .unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);
    assert!(
        rendered(&w, HarnessId::Claude, "reviewer-mine").exists(),
        "{}",
        manifest_text(&w)
    );
    assert_eq!(
        manifest_of(&w).agent_skills.keys().collect::<Vec<_>>(),
        vec!["rust"],
        "and the copy the fallback never reached wrote no row of its own: {}",
        manifest_text(&w)
    );
}

/// The mirror of the refusal above. A destination reaches the base row
/// only because the source agent owns it, so nothing there would be
/// shadowed: that row is the very assignment the copy carries away with
/// it. Refusing it would tell the person to clear the entry the operation
/// exists to move, which is the assignment gone rather than kept.
#[test]
#[allow(clippy::unwrap_used)]
fn forking_beside_takes_a_name_that_reads_the_source_agents_own_skill_row() {
    let w = world();
    write_skill(&w.upstream, "recon", "Recon.");
    write_agent(&w.upstream, "go", "Upstream body.");
    fs::write(w.upstream.join("kendex.toml"), "").unwrap();
    commit(&w.upstream, "one");
    declare(
        &w,
        "[agents.go]\nsource = \"cat\"\n\n[skills.recon]\nsource = \"cat\"\n\n[agent-skills]\ngo = [\"recon\"]\n",
    );
    sync_and_apply(&w);
    edit_body(&rendered(&w, HarnessId::Claude, "go"));

    let plan = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Agent,
        "go",
        HarnessId::Claude,
        "reviewer-go",
        None,
    )
    .unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let settled = manifest_of(&w);
    assert_eq!(
        settled.agent_skills.keys().collect::<Vec<_>>(),
        vec!["go", "reviewer-go"],
        "the copy holds a row of its own and the source keeps the one it owns: {}",
        manifest_text(&w)
    );
    assert_eq!(
        settled.agent_skills.get("reviewer-go").map(Vec::as_slice),
        Some(["recon".to_owned()].as_slice()),
        "and what travelled is the source's assignment: {}",
        manifest_text(&w)
    );
}

/// A hook selects one agent by spelling its name, so the selector has to
/// travel when the name does — but a selector spelling `all` or a role
/// name is read as a population, and rewriting one to the new name would
/// move the gate onto every agent that population holds. Nothing in the
/// representation can say "this one agent, despite the spelling", so the
/// destination is refused rather than written.
#[test]
#[allow(clippy::unwrap_used)]
fn a_population_name_is_refused_where_a_hook_gates_the_agent_by_name() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "[[custom-hooks]]\nevent = \"PreToolUse\"\nmatcher = \"Bash\"\ncommand = \"./guard.sh\"\nagents = \"rev\"\n",
    );
    edit_body(&rendered(&w, HarnessId::Claude, "rev"));

    let refused = fork::fork_beside(
        &w.env,
        &w.scope,
        ItemKind::Agent,
        "rev",
        HarnessId::Claude,
        "all",
        None,
    )
    .unwrap_err();
    assert!(
        matches!(refused, CoreError::ForkNameUnusable { .. }),
        "{refused:?}"
    );
    assert!(
        refused.to_string().contains("every agent"),
        "the refusal names what the new spelling would gate: {refused}"
    );
    assert!(!captured(&w, "all").exists(), "nothing was written");

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);
    let refused =
        fork::rename_fork(&w.env, &w.scope, ItemKind::Agent, "rev", "engineer").unwrap_err();
    assert!(
        matches!(refused, CoreError::ForkNameUnusable { .. }),
        "{refused:?}"
    );
    assert!(
        refused.to_string().contains("the engineer role"),
        "the refusal names the population the role selector would gate: {refused}"
    );

    let settled = manifest_of(&w);
    assert_eq!(settled.custom_hooks.len(), 1, "{:?}", settled.custom_hooks);
    assert_eq!(
        settled.custom_hooks[0].agents,
        HookAgents::One("rev".to_owned()),
        "a refused move rewrites no selector"
    );
}

/// The same destination with nothing to carry onto it. A role name is an
/// ordinary name for an agent no hook gates, and refusing it there would
/// turn the selector rule into a naming rule the operation never needed.
#[test]
#[allow(clippy::unwrap_used)]
fn a_population_name_is_free_where_no_hook_gates_the_agent() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "",
    );
    edit_body(&rendered(&w, HarnessId::Claude, "rev"));
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let plan = fork::rename_fork(&w.env, &w.scope, ItemKind::Agent, "rev", "engineer").unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);
    assert!(
        rendered(&w, HarnessId::Claude, "engineer").exists(),
        "{}",
        manifest_text(&w)
    );
}

/// An instructions entry under `all` is the one every agent reads, not the
/// configuration of an agent that happens to be called `all` — a legal
/// item name. Moving it because that agent moved rewrites what every other
/// agent in the project renders, from an operation that named one.
#[test]
#[allow(clippy::unwrap_used)]
fn renaming_an_agent_named_all_leaves_the_shared_instructions_alone() {
    let w = world();
    let agents = w.upstream.join("agents");
    fs::create_dir_all(&agents).unwrap();
    for name in ["all", "rev"] {
        fs::write(
            agents.join(format!("{name}.md")),
            format!("---\nname: {name}\ndescription: agent {name}\n---\nUpstream body.\n"),
        )
        .unwrap();
    }
    commit(&w.upstream, "one");
    declare(
        &w,
        "[agents.all]\nsource = \"cat\"\n\n[agents.rev]\nsource = \"cat\"\n\n[agent-launch-instructions]\nall = \"Read the brief first.\"\n\n[agent-additional-instructions]\nall = \"Say what you changed.\"\n",
    );
    sync_and_apply(&w);
    let reads = |name: &str| {
        let text = fs::read_to_string(rendered(&w, HarnessId::Claude, name)).unwrap();
        (
            times(&text, "Read the brief first."),
            times(&text, "Say what you changed."),
        )
    };
    assert_eq!(reads("rev"), (1, 1), "the shared entries reach every agent");

    edit_body(&rendered(&w, HarnessId::Claude, "all"));
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "all", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);
    let plan = fork::rename_fork(&w.env, &w.scope, ItemKind::Agent, "all", "mine").unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let settled = manifest_of(&w);
    assert_eq!(
        settled.agent_launch_instructions.keys().collect::<Vec<_>>(),
        vec!["all"],
        "the shared entry stays under the key every agent reads"
    );
    assert_eq!(
        settled
            .agent_additional_instructions
            .keys()
            .collect::<Vec<_>>(),
        vec!["all"]
    );
    assert_eq!(
        reads("rev"),
        (1, 1),
        "an agent the rename never mentioned renders exactly as it did"
    );
    assert_eq!(
        reads("mine"),
        (1, 1),
        "and the renamed agent still reads them, being an agent like any other"
    );
}
