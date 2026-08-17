//! The Codex prose fallback: what counts as the block being installed, and
//! what an install does when it finds one that no longer carries the hook's
//! behavior. Install and every presence read answer from one predicate, so
//! these cases pin both at once.

use super::tests::{hook_fixture, tmpdir};
use super::*;

/// The presence read, for content every one of these fixtures builds as valid
/// TOML — a parse failure here is the fixture's bug, not the case under test.
fn prose_section<'a>(content: &'a str, hook_name: &str) -> Option<&'a str> {
    crate::installer::codex_agent_prose_section(content, hook_name)
        .unwrap_or_else(|reason| panic!("the fixture must be valid TOML: {reason}\n{content}"))
}

fn agent_fixture(name: &str) -> Agent {
    Agent {
        name: name.into(),
        description: format!("{name} agent"),
        model: "sonnet".into(),
        role: crate::agent::AgentRole::Engineer,
        color: None,
        effort: None,
        body: "Body\n".into(),
        source_path: PathBuf::new(),
    }
}

/// Fallback prose is installed for EVERY Codex agent or not claimed at all.
/// Accumulating success across agents let one agent that already carried the
/// marker report the whole install done while a newly added agent whose TOML
/// has no `developer_instructions` block silently got no safety prose.
#[test]
fn codex_prose_install_fails_on_an_agent_it_cannot_write_and_names_it() {
    let dir = tmpdir("codex_prose_partial");
    let agents_dir = dir.join("agents");
    std::fs::create_dir_all(&agents_dir).unwrap();
    let well_formed =
        |name: &str| format!("name = \"{name}\"\ndeveloper_instructions = '''\nBody\n'''\n");
    std::fs::write(agents_dir.join("first.toml"), well_formed("first")).unwrap();
    // Second agent's TOML has no closing ''' — nowhere to put the block.
    std::fs::write(
        agents_dir.join("second.toml"),
        "name = \"second\"\ndescription = \"no instructions block\"\n",
    )
    .unwrap();
    let hook = hook_fixture("post-edit-lint", "TaskCompleted", None);
    let agents = [agent_fixture("first"), agent_fixture("second")];

    let err = crate::test_util::with_codex_home(&dir, || {
        install_codex_fallback_hooks_for_agents(std::slice::from_ref(&hook), true, &agents)
            .expect_err("an agent that cannot receive the block must not report success")
    });
    let message = format!("{err:#}");
    assert!(message.contains("second"), "names the agent: {message}");
    assert!(
        message.contains(&agents_dir.join("second.toml").display().to_string()),
        "names the file: {message}"
    );

    // Control: both well-formed → success, and both files carry the block.
    std::fs::write(agents_dir.join("second.toml"), well_formed("second")).unwrap();
    crate::test_util::with_codex_home(&dir, || {
        install_codex_fallback_hooks_for_agents(std::slice::from_ref(&hook), true, &agents)
            .unwrap();
    });
    let marker = "## Safety: post-edit-lint";
    for name in ["first", "second"] {
        let body = std::fs::read_to_string(agents_dir.join(format!("{name}.toml"))).unwrap();
        assert!(body.contains(marker), "{name} must carry the block: {body}");
    }

    // Control: a rerun over agents that already carry it is still success and
    // writes no second copy.
    crate::test_util::with_codex_home(&dir, || {
        install_codex_fallback_hooks_for_agents(std::slice::from_ref(&hook), true, &agents)
            .unwrap();
    });
    for name in ["first", "second"] {
        let body = std::fs::read_to_string(agents_dir.join(format!("{name}.toml"))).unwrap();
        assert_eq!(
            body.matches(marker).count(),
            1,
            "no duplicate block: {body}"
        );
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// The marker only counts where the prose has to live. Text carrying it in a
/// comment or an unrelated field made the install skip its write, and the
/// presence read — the same whole-file search — then called the missing
/// fallback installed: both wrong, and agreeing with each other.
#[test]
fn marker_text_outside_developer_instructions_is_not_the_prose_fallback() {
    let dir = tmpdir("codex_prose_scope");
    let agents_dir = dir.join("agents");
    std::fs::create_dir_all(&agents_dir).unwrap();
    let hook = hook_fixture("post-edit-lint", "TaskCompleted", None);
    let marker = super::codex::codex_hook_safety_marker(&hook.name);
    // The whole block, verbatim — in a comment and in another field. Every
    // line the old whole-file search matched on is here; none of it is prose
    // Codex will ever hand the agent.
    let decoy = format!(
        "# {marker}\nname = \"rust\"\nnotes = '''\n{}\n'''\ndeveloper_instructions = '''\nBody\n'''\n",
        crate::installer::codex_hook_safety_block(&hook)
    );
    let toml = agents_dir.join("rust.toml");
    std::fs::write(&toml, &decoy).unwrap();
    let agents = [agent_fixture("rust")];

    // Presence, before anything is installed: the decoy is not the block.
    assert!(
        prose_section(&decoy, &hook.name).is_none(),
        "marker text outside developer_instructions must not read as installed"
    );

    // …so the install writes the block instead of skipping it.
    crate::test_util::with_codex_home(&dir, || {
        install_codex_fallback_hooks_for_agents(std::slice::from_ref(&hook), true, &agents)
            .unwrap();
    });
    let written = std::fs::read_to_string(&toml).unwrap();
    let section = prose_section(&written, &hook.name)
        .expect("the install must write the block the presence read looks for");
    assert!(
        section.contains("the agent should verify this constraint is met"),
        "the section carries the hook's own prose: {section}"
    );
    assert!(
        written.starts_with(&format!("# {marker}\n")),
        "the decoy comment is left exactly as it was: {written}"
    );

    // Control: a rerun sees its own block and writes no second copy.
    crate::test_util::with_codex_home(&dir, || {
        install_codex_fallback_hooks_for_agents(std::slice::from_ref(&hook), true, &agents)
            .unwrap();
    });
    let reread = std::fs::read_to_string(&toml).unwrap();
    assert_eq!(reread, written, "a second run must change nothing");

    // Control: a longer-named hook's block is not this hook's. A substring
    // reading answered yes and skipped the install for good.
    let sibling = hook_fixture("post-edit-lint-extra", "TaskCompleted", None);
    let sibling_only = format!(
        "developer_instructions = '''\n{}\n'''\n",
        crate::installer::codex_hook_safety_block(&sibling)
    );
    assert!(
        prose_section(&sibling_only, &hook.name).is_none(),
        "`## Safety: x-extra` must not answer for `## Safety: x`: {sibling_only}"
    );
    assert!(
        prose_section(&sibling_only, &sibling.name).is_some(),
        "…while its own name still finds it: {sibling_only}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// The section is where the prose lives; the ACTION LINE is the prose. A
/// heading whose body was edited away left codex carrying no behavior at all,
/// while install skipped the write — "already installed" — and every presence
/// read agreed with it. Nothing ever reported the hook, and no rerun could
/// repair it.
#[test]
fn a_prose_section_that_lost_its_action_line_is_rewritten_not_skipped() {
    let dir = tmpdir("codex_prose_gutted");
    let agents_dir = dir.join("agents");
    std::fs::create_dir_all(&agents_dir).unwrap();
    let toml = agents_dir.join("rust.toml");
    std::fs::write(
        &toml,
        "name = \"rust\"\ndeveloper_instructions = '''\nBody\n'''\n",
    )
    .unwrap();
    let hook = hook_fixture("post-edit-lint", "TaskCompleted", None);
    let agents = [agent_fixture("rust")];
    let install = || {
        crate::test_util::with_codex_home(&dir, || {
            install_codex_fallback_hooks_for_agents(std::slice::from_ref(&hook), true, &agents)
                .unwrap();
        });
    };

    install();
    let installed = std::fs::read_to_string(&toml).unwrap();
    let action_line = crate::config::generated_safety_action_line(&hook).unwrap();
    assert!(
        installed.contains(&action_line),
        "control: the install writes the action line: {installed}"
    );

    // Control: a rerun over an intact block changes nothing at all.
    install();
    assert_eq!(
        std::fs::read_to_string(&toml).unwrap(),
        installed,
        "an intact block must be left alone"
    );

    // The body is deleted; the heading stays.
    let gutted = installed.replace(&format!("\n{action_line}"), "");
    assert_ne!(gutted, installed, "the fixture must actually gut the body");
    assert!(
        prose_section(&gutted, &hook.name).is_some(),
        "the heading survives, which is exactly what made install skip it"
    );
    std::fs::write(&toml, &gutted).unwrap();

    install();
    let repaired = std::fs::read_to_string(&toml).unwrap();
    assert_eq!(
        repaired, installed,
        "a marker-only section must be rewritten whole, not skipped"
    );
    assert_eq!(
        repaired
            .matches(&crate::installer::codex_hook_safety_block(&hook))
            .count(),
        1,
        "and repaired in place, not duplicated: {repaired}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// A stale section sitting BEFORE another hook's block is repaired without
/// disturbing the block that follows it.
#[test]
fn repairing_one_prose_section_leaves_a_following_section_intact() {
    let dir = tmpdir("codex_prose_gutted_middle");
    let agents_dir = dir.join("agents");
    std::fs::create_dir_all(&agents_dir).unwrap();
    let toml = agents_dir.join("rust.toml");
    std::fs::write(
        &toml,
        "name = \"rust\"\ndeveloper_instructions = '''\nBody\n'''\n",
    )
    .unwrap();
    let first = hook_fixture("post-edit-lint", "TaskCompleted", None);
    let second = hook_fixture("verify-done", "TaskCompleted", None);
    let agents = [agent_fixture("rust")];
    let install = |hooks: &[Hook]| {
        crate::test_util::with_codex_home(&dir, || {
            install_codex_fallback_hooks_for_agents(hooks, true, &agents).unwrap();
        });
    };

    install(&[first.clone(), second.clone()]);
    let installed = std::fs::read_to_string(&toml).unwrap();
    let action_line = crate::config::generated_safety_action_line(&first).unwrap();
    let gutted = installed.replacen(&format!("\n{action_line}"), "", 1);
    assert_ne!(gutted, installed, "the fixture must gut the first body");
    std::fs::write(&toml, &gutted).unwrap();

    install(std::slice::from_ref(&first));
    let repaired = std::fs::read_to_string(&toml).unwrap();
    assert!(
        crate::installer::codex_hook_prose(&dir, &first).carried(),
        "the gutted section is repaired: {repaired}"
    );
    assert!(
        crate::installer::codex_hook_prose(&dir, &second).carried(),
        "and the section that followed it survives: {repaired}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// Removal reads the block the same way installation and presence do. The
/// whole-file search it replaced cut from the first `## Safety: <name>` line
/// ANYWHERE in the file through to the next heading or string delimiter: a
/// marker a user wrote in an unrelated field took the rest of that field with
/// it, and the real block — further down, inside `developer_instructions` —
/// survived, so the hook stayed installed and the user lost content instead.
#[test]
fn removing_prose_cuts_the_installed_block_and_nothing_that_merely_looks_like_it() {
    let dir = tmpdir("codex_prose_remove_scope");
    let agents_dir = dir.join("agents");
    std::fs::create_dir_all(&agents_dir).unwrap();
    let hook = hook_fixture("post-edit-lint", "TaskCompleted", None);
    let marker = super::codex::codex_hook_safety_marker(&hook.name);
    let decoy = format!(
        "# {marker}\nname = \"rust\"\nnotes = '''\n{}\n\nthe user's own words, after the decoy\n'''\n",
        crate::installer::codex_hook_safety_block(&hook)
    );
    let toml = agents_dir.join("rust.toml");
    std::fs::write(
        &toml,
        format!("{decoy}developer_instructions = '''\nBody\n'''\n"),
    )
    .unwrap();
    let agents = [agent_fixture("rust")];

    crate::test_util::with_codex_home(&dir, || {
        install_codex_fallback_hooks_for_agents(std::slice::from_ref(&hook), true, &agents)
            .unwrap();
    });
    let installed = std::fs::read_to_string(&toml).unwrap();
    assert!(prose_section(&installed, &hook.name).is_some());

    crate::test_util::with_codex_home(&dir, || {
        super::codex::strip_hook_prose_from_codex_agents(true, &hook.name).unwrap();
    });
    let after = std::fs::read_to_string(&toml).unwrap();
    assert!(
        prose_section(&after, &hook.name).is_none(),
        "the installed block must be gone: {after}"
    );
    assert!(
        after.starts_with(&decoy),
        "the comment and the unrelated field are the user's, byte for byte: {after}"
    );
    assert_eq!(
        after,
        format!("{decoy}developer_instructions = '''\nBody\n'''\n"),
        "removal restores the file the install started from"
    );

    // Control: a second removal changes nothing.
    crate::test_util::with_codex_home(&dir, || {
        super::codex::strip_hook_prose_from_codex_agents(true, &hook.name).unwrap();
    });
    assert_eq!(std::fs::read_to_string(&toml).unwrap(), after);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Where the block lives is a TOML question, and only a TOML parser answers
/// it. The line scan this replaces took the FIRST line in the file that read
/// like the assignment — a `developer_instructions = '''` quoted inside
/// another field's multi-line string counted — and then ran to the next `'''`
/// it could find, which was the real key's opening delimiter. Installing spliced
/// the safety block into the middle of the user's own text and left behind a
/// file Codex could no longer parse.
#[test]
fn the_block_is_the_parsed_root_value_not_the_first_line_that_looks_like_it() {
    let dir = tmpdir("codex_prose_parsed_location");
    let agents_dir = dir.join("agents");
    std::fs::create_dir_all(&agents_dir).unwrap();
    let hook = hook_fixture("post-edit-lint", "TaskCompleted", None);
    let agents = [agent_fixture("rust")];
    let toml = agents_dir.join("rust.toml");
    // The decoy is a whole assignment, verbatim, inside a field that is the
    // user's. Everything the line scan matched on is here.
    let decoy = "name = \"rust\"\nnotes = \"\"\"\ndeveloper_instructions = '''\nthe user's own words\n\"\"\"\n";
    let real = "developer_instructions = '''\nBody\n'''\n";
    std::fs::write(&toml, format!("{decoy}{real}")).unwrap();

    // Presence, before anything is installed: the decoy is not the block.
    let before = std::fs::read_to_string(&toml).unwrap();
    assert!(
        prose_section(&before, &hook.name).is_none(),
        "a quoted assignment is not the agent's block"
    );

    crate::test_util::with_codex_home(&dir, || {
        install_codex_fallback_hooks_for_agents(std::slice::from_ref(&hook), true, &agents)
            .unwrap();
    });
    let written = std::fs::read_to_string(&toml).unwrap();
    written
        .parse::<toml_edit::DocumentMut>()
        .unwrap_or_else(|err| panic!("the install must leave valid TOML: {err}\n{written}"));
    assert!(
        written.starts_with(decoy),
        "the user's own field is untouched, byte for byte: {written}"
    );
    let section = prose_section(&written, &hook.name)
        .expect("the block lands in the real developer_instructions");
    assert!(
        section.contains("the agent should verify this constraint is met"),
        "…carrying the hook's own prose: {section}"
    );

    // Removal puts the file back exactly as it was, decoy included.
    crate::test_util::with_codex_home(&dir, || {
        super::codex::strip_hook_prose_from_codex_agents(true, &hook.name).unwrap();
    });
    assert_eq!(
        std::fs::read_to_string(&toml).unwrap(),
        format!("{decoy}{real}"),
        "removal restores the file the install started from"
    );
}

/// A `developer_instructions` belonging to some other TABLE is not the
/// agent's: Codex hands the agent the ROOT key, and only that one. Nothing is
/// written into a table vstack does not own, and the presence read calls the
/// fallback absent rather than adopting a stranger's value as its own.
#[test]
fn a_developer_instructions_in_another_table_is_not_the_agents_block() {
    let dir = tmpdir("codex_prose_other_table");
    let agents_dir = dir.join("agents");
    std::fs::create_dir_all(&agents_dir).unwrap();
    let hook = hook_fixture("post-edit-lint", "TaskCompleted", None);
    let agents = [agent_fixture("rust")];
    let toml = agents_dir.join("rust.toml");
    let content = format!(
        "name = \"rust\"\n\n[experimental]\ndeveloper_instructions = '''\n{}\n'''\n",
        crate::installer::codex_hook_safety_block(&hook)
    );
    std::fs::write(&toml, &content).unwrap();

    assert!(
        prose_section(&content, &hook.name).is_none(),
        "another table's value must not answer for the agent's: {content}"
    );

    // …so the install refuses instead of splicing into it, and the file is
    // left exactly as the user wrote it.
    let err = crate::test_util::with_codex_home(&dir, || {
        install_codex_fallback_hooks_for_agents(std::slice::from_ref(&hook), true, &agents)
            .expect_err("there is no root developer_instructions to write into")
    });
    let message = format!("{err:#}");
    assert!(
        message.contains("no developer_instructions block"),
        "{message}"
    );
    assert_eq!(std::fs::read_to_string(&toml).unwrap(), content);
    let _ = std::fs::remove_dir_all(&dir);
}

/// An agent TOML that does not parse is UNREADABLE, never "the block is
/// absent". Every path answers alike: the presence read names the file, the
/// install refuses it rather than counting it covered, and removal rewrites
/// nothing — cutting a byte range out of a document whose structure was never
/// established is how the whole-file search destroyed user content.
#[test]
fn an_unparseable_codex_agent_is_unreadable_and_never_rewritten() {
    let dir = tmpdir("codex_prose_unparseable");
    let agents_dir = dir.join("agents");
    std::fs::create_dir_all(&agents_dir).unwrap();
    let hook = hook_fixture("post-edit-lint", "TaskCompleted", None);
    let agents = [agent_fixture("rust")];
    let toml = agents_dir.join("rust.toml");
    let broken = "name = \"rust\ndeveloper_instructions = '''\n## Safety: post-edit-lint\n'''\n";
    std::fs::write(&toml, broken).unwrap();

    match crate::installer::codex_hook_prose(&dir, &hook) {
        crate::installer::CodexProse::Unreadable(reason) => {
            assert!(
                reason.contains(&toml.display().to_string()),
                "the note names the file: {reason}"
            );
            assert!(reason.contains("not valid TOML"), "{reason}");
        }
        other => panic!("a file that does not parse is not an answer about the block: {other:?}"),
    }

    let err = crate::test_util::with_codex_home(&dir, || {
        install_codex_fallback_hooks_for_agents(std::slice::from_ref(&hook), true, &agents)
            .expect_err("a file vstack cannot parse is never rewritten")
    });
    let message = format!("{err:#}");
    assert!(message.contains("not TOML vstack can rewrite"), "{message}");
    assert!(
        message.contains(&toml.display().to_string()),
        "names the file: {message}"
    );

    let err = crate::test_util::with_codex_home(&dir, || {
        super::codex::strip_hook_prose_from_codex_agents(true, &hook.name)
            .expect_err("removal must refuse it too")
    });
    assert!(
        format!("{err:#}").contains("refusing to rewrite"),
        "{err:#}"
    );
    assert_eq!(
        std::fs::read_to_string(&toml).unwrap(),
        broken,
        "and the file is untouched by every one of them"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
