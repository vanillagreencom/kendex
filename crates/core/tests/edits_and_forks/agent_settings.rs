//! What one hand-edited rendering states, and what a fork makes of it.
//! An agent's tool access, its delegation and its hooks all shape what it
//! may do, and a copy of it must be no more permissive than the agent it
//! came from: what the override table can hold rides into the manifest,
//! and what nothing can hold refuses.

use std::fs;

use kendex_core::error::CoreError;

use super::*;

/// A hand edit the fork cannot carry refuses before writing anything, one
/// row per edit, the refusal's own `problem` naming what it stopped on. A
/// person who tightens a generated file by hand states something the local
/// source has no key for and the manifest is not being written from, so
/// forking would hand back the tools they took away: a widened deny list;
/// an allowlist written into a file that stated none (what the fork would
/// give back is every tool outside it, so the refusal names the allowlist);
/// frontmatter that will not parse, which is not a file stating nothing
/// (what the person took away cannot be read, so it cannot be proven
/// carried either), whether a key stated twice or a block that opens and
/// never ends; a deleted colour (an override states what a value is and
/// never that there is none); a Pi allowlist override the renderer cannot
/// express, which the updates report already marks unforkable; a hook
/// written into the file (no override table holds one, a hook being a
/// custom-hooks entry with a selector rather than a field); and the same
/// hook moved to gate the call before it runs, since a hook is its scope as
/// well as its command and a reading that compares commands alone would
/// let the fork restore the looser gate. Afterwards nothing is captured and
/// the manifest records no fork.
#[test]
#[allow(clippy::unwrap_used, clippy::too_many_lines)]
fn a_hand_edit_the_fork_cannot_carry_refuses_and_names_it() {
    type Edit = fn(&World, &std::path::Path);
    type Row = (
        &'static str,
        &'static str,
        HarnessId,
        &'static str,
        &'static str,
        Edit,
        &'static [&'static str],
    );
    let rows: [Row; 8] = [
        (
            "a hand-tightened deny list",
            "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
            HarnessId::Claude,
            "",
            "",
            |_, file| {
                edit_line(
                    file,
                    "disallowedTools: Agent, AskUserQuestion",
                    "disallowedTools: Agent, AskUserQuestion, Bash, WebFetch",
                );
            },
            &["Bash", "WebFetch"],
        ),
        (
            "a hand-added allowlist",
            "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
            HarnessId::Claude,
            "",
            "",
            |_, file| {
                edit_line(
                    file,
                    "disallowedTools:",
                    "tools: Read, Grep\ndisallowedTools:",
                )
            },
            &["Read, Grep"],
        ),
        (
            "a key stated twice",
            "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
            HarnessId::Claude,
            "",
            "",
            |_, file| {
                edit_line(
                    file,
                    "disallowedTools:",
                    "tools: Read\ntools: Grep\ndisallowedTools:",
                );
            },
            &["cannot be read"],
        ),
        (
            "a deleted colour",
            "---\nname: rev\ndescription: agent rev\ncolor: blue\n---\nUpstream body.\n",
            HarnessId::Claude,
            "",
            "",
            |_, file| {
                let rendering = fs::read_to_string(file).unwrap();
                assert!(rendering.contains("color: blue"), "{rendering}");
                let without: String = rendering
                    .lines()
                    .filter(|line| !line.starts_with("color:"))
                    .map(|line| format!("{line}\n"))
                    .collect();
                fs::write(file, without).unwrap();
            },
            &["deleted", "color"],
        ),
        (
            "a Pi allowlist the renderer cannot express",
            "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
            HarnessId::Pi,
            "",
            "",
            |w, file| {
                edit_line(file, "deny-tools:", "deny-tools: Bash,");
                let manifest = format!(
                    "{}\n[agent-frontmatter.pi]\nrev = {{ allow-tools = [\"Read\"] }}\n",
                    manifest_text(w)
                );
                fs::write(manifest::manifest_path(&w.env, &w.scope), manifest).unwrap();
                let report = kendex_core::package::updates::updates(&w.env, &w.scope).unwrap();
                let row = report
                    .rows
                    .iter()
                    .find(|row| row.kind == ItemKind::Agent && row.name == "rev")
                    .unwrap();
                assert_eq!(row.forkable_harness, None, "{row:?}");
            },
            &["the access settings its Pi renderer rejected: Pi cannot express a tool allowlist"],
        ),
        (
            "a hand-written hook",
            "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
            HarnessId::Claude,
            "",
            "",
            |_, file| {
                edit_line(
                    file,
                    "disallowedTools:",
                    "hooks:\n  PreToolUse:\n    \"Bash\":\n      - type: command\n        command: \"./guard.sh\"\ndisallowedTools:",
                );
            },
            &["./guard.sh"],
        ),
        (
            "a hook moved to a tighter event",
            "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
            HarnessId::Claude,
            "",
            "[[custom-hooks]]\nevent = \"PostToolUse\"\nmatcher = \"Bash\"\ncommand = \"./guard.sh\"\nagents = \"rev\"\n",
            |_, file| {
                // The same command, moved to gate the call before it runs
                // instead of reporting on it afterwards.
                edit_line(file, "PostToolUse:", "PreToolUse:");
            },
            &["PreToolUse", "Bash", "./guard.sh"],
        ),
        (
            "an unterminated frontmatter block",
            "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
            HarnessId::Claude,
            "",
            "[agent-frontmatter.claude]\nrev = { deny-tools = [\"Bash\"] }\n",
            |_, file| {
                let text = fs::read_to_string(file).unwrap();
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
                    file,
                    lines
                        .iter()
                        .map(|line| format!("{line}\n"))
                        .collect::<String>(),
                )
                .unwrap();
            },
            &["unterminated frontmatter"],
        ),
    ];
    for (what, agent, harness, catalog, project, edit, names) in rows {
        let harnesses = format!("\"{}\"", harness.name());
        let w = agent_world(&harnesses, agent, catalog, project);
        let file = rendered(&w, harness, "rev");
        edit(&w, &file);

        let refused = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", harness).unwrap_err();

        let CoreError::ForkWidensAccess { name, problem } = &refused else {
            panic!("{what}: {refused:?}");
        };
        assert_eq!(name, "rev", "{what}");
        for clause in names {
            assert!(
                problem.contains(clause),
                "{what}: {clause:?} missing from {problem:?}"
            );
        }
        assert!(
            !captured(&w, "rev").exists(),
            "{what}: something was written"
        );
        assert!(
            !manifest_text(&w).contains("[forks.agent.rev]"),
            "{what}: the manifest records a fork"
        );
    }
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
/// effort can be cleared, since every renderer reads `none` as no effort
/// (the keys nothing can clear are rows of the refusals table above).
#[test]
#[allow(clippy::unwrap_used)]
fn a_deleted_effort_is_carried_as_cleared() {
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
