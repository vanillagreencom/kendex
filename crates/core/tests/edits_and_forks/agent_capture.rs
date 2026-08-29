//! What a fork writes into the local source: the publisher's frontmatter,
//! the person's own prose, and none of the generated document that carried
//! them. Everything the render writes again has to be gone from the prose,
//! and everything it will not write again has to stay.

use std::fs;

use kendex_core::error::CoreError;

use super::*;

/// Claude states denies in `disallowedTools:`, a key the source form has
/// no spelling for. Captured from the rendering it is dropped on the way
/// back in, and the fork comes out able to run the tools the agent was
/// installed without.
#[test]
#[allow(clippy::unwrap_used)]
fn forking_a_claude_agent_keeps_its_denies_its_allowlist_and_one_banner() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\ntools: Read, Grep\n---\nUpstream body.\n",
        "[agent-frontmatter.claude]\nrev = { deny-tools = [\"WebFetch\"] }\n",
        "",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    assert!(
        deny_line(&fs::read_to_string(&file).unwrap(), "disallowedTools:").contains("WebFetch")
    );
    edit_body(&file);

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan, None).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    assert!(
        source.contains("tools: Read, Grep") && source.contains("My body."),
        "the captured source is the publisher's frontmatter over the person's prose: {source}"
    );
    assert_eq!(banners(&source), 0, "{source}");

    let text = fs::read_to_string(&file).unwrap();
    assert!(
        deny_line(&text, "disallowedTools:").contains("WebFetch"),
        "the fork must not hand back a tool the installation denied: {text}"
    );
    assert!(text.contains("tools: Read, Grep"), "{text}");
    assert!(text.contains("My body."), "{text}");
    assert_eq!(banners(&text), 1, "{text}");
}

/// The catalog's frontmatter defaults are not harness-scoped to the
/// rendering a fork captures: keeping the Gemini copy has to carry
/// Claude's denies too, or the very next apply widens the copy the fork
/// never touched.
#[test]
#[allow(clippy::unwrap_used)]
fn forking_a_gemini_agent_keeps_its_allowlist_and_the_other_tools_denies() {
    let w = agent_world(
        "\"claude\", \"gemini\"",
        "---\nname: rev\ndescription: agent rev\ntools: Read, Grep\n---\nUpstream body.\n",
        "[agent-frontmatter.claude]\nrev = { deny-tools = [\"WebFetch\"] }\n",
        "",
    );
    let file = rendered(&w, HarnessId::Gemini, "rev");
    edit_body(&file);

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
    apply::execute(&w.env, &plan, None).unwrap();
    resettle(&w);

    let text = fs::read_to_string(&file).unwrap();
    assert!(
        text.contains("- read_file") && text.contains("- grep_search"),
        "the fork keeps Gemini's allowlist: {text}"
    );
    assert!(text.contains("My body."), "{text}");
    assert_eq!(banners(&text), 1, "{text}");

    let claude = fs::read_to_string(rendered(&w, HarnessId::Claude, "rev")).unwrap();
    assert!(
        deny_line(&claude, "disallowedTools:").contains("WebFetch"),
        "keeping the Gemini copy must not widen the Claude one: {claude}"
    );
    assert!(claude.contains("tools: Read, Grep"), "{claude}");
}

/// Pi states tool access as a deny list and nothing else, so everything
/// that restricts a Pi agent is in the key the source form cannot hold.
#[test]
#[allow(clippy::unwrap_used)]
fn forking_a_pi_agent_keeps_its_deny_list_and_one_banner() {
    let w = agent_world(
        "\"pi\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "[agent-frontmatter.pi]\nrev = { deny-tools = [\"read_file\"] }\n",
        "",
    );
    let file = rendered(&w, HarnessId::Pi, "rev");
    assert!(deny_line(&fs::read_to_string(&file).unwrap(), "deny-tools:").contains("read_file"));
    edit_body(&file);

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Pi).unwrap();
    apply::execute(&w.env, &plan, None).unwrap();
    resettle(&w);

    let text = fs::read_to_string(&file).unwrap();
    assert!(
        deny_line(&text, "deny-tools:").contains("read_file"),
        "the fork must not hand back a tool the installation denied: {text}"
    );
    assert!(text.contains("My body."), "{text}");
    assert_eq!(banners(&text), 1, "{text}");
}

/// A fork of an agent nobody tightened by hand goes through: the ordinary
/// path stays ordinary, and an edit to the prose alone is not a permission
/// question.
#[test]
#[allow(clippy::unwrap_used)]
fn an_ordinary_agent_still_forks() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "",
    );
    edit_body(&rendered(&w, HarnessId::Claude, "rev"));
    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan, None).unwrap();
    resettle(&w);
    assert!(
        fs::read_to_string(rendered(&w, HarnessId::Claude, "rev"))
            .unwrap()
            .contains("My body.")
    );
    assert!(audit(&w.env, &w.scope).unwrap().drift.is_empty());
}

/// The generated sections are written again by the next render out of the
/// manifest entries this fork carries, so prose that kept a copy of them
/// renders twice. The banner was the first of these; the instructions and
/// the skills prose are the rest.
#[test]
#[allow(clippy::unwrap_used)]
fn the_generated_sections_are_written_once_after_a_fork() {
    let w = world();
    write_skill(&w.upstream, "recon", "Recon.");
    let agents = w.upstream.join("agents");
    fs::create_dir_all(&agents).unwrap();
    fs::write(
        agents.join("rev.md"),
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
    )
    .unwrap();
    fs::write(
        w.upstream.join("kendex.toml"),
        "[agent-skills]\nrev = [\"recon\"]\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"gemini\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n\n[skills.recon]\nsource = \"cat\"\n\n[agent-launch-instructions]\nrev = \"Read the brief first.\"\n\n[agent-additional-instructions]\nrev = \"Say what you changed.\"\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    let file = rendered(&w, HarnessId::Gemini, "rev");
    let before = fs::read_to_string(&file).unwrap();
    assert_eq!(times(&before, "## Required Skills"), 1, "{before}");
    edit_body(&file);

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
    apply::execute(&w.env, &plan, None).unwrap();
    resettle(&w);

    // Every generated section is keyed by the agent's name and travels
    // into the manifest, the skill assignment included: the fork writes
    // them all again, so the captured prose must hold none of them.
    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    for section in [
        "## Launch Instructions",
        "## Additional Instructions",
        "## Required Skills",
    ] {
        assert_eq!(
            times(&source, section),
            0,
            "the captured prose must not carry {section}, which the render writes: {source}"
        );
    }
    assert!(source.contains("My body."), "{source}");

    // Every section stands exactly once in the settled rendering, written
    // from the manifest entries the fork carries.
    let text = fs::read_to_string(&file).unwrap();
    for section in [
        "## Launch Instructions",
        "## Additional Instructions",
        "## Required Skills",
    ] {
        assert_eq!(times(&text, section), 1, "{section} count wrong: {text}");
    }
    assert_eq!(text.matches("- recon: ").count(), 1, "{text}");
    assert_eq!(banners(&text), 1, "{text}");
    assert_eq!(times(&text, "My body."), 1, "{text}");
}

/// What resolving a fork's assignment against the scope costs is a
/// dependency the fork does not declare. The scope losing the source that
/// offered the skill is said out loud, naming the skill and that source —
/// never by taking the section off the agent in silence.
#[test]
#[allow(clippy::unwrap_used)]
fn a_fork_refuses_when_the_scope_loses_the_source_its_skill_came_from() {
    let w = world();
    write_skill(&w.upstream, "recon", "Recon.");
    write_agent(&w.upstream, "rev", "Upstream body.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[agent-skills]\nrev = [\"recon\"]\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"gemini\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    let file = rendered(&w, HarnessId::Gemini, "rev");
    edit_body(&file);

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
    apply::execute(&w.env, &plan, None).unwrap();
    resettle(&w);
    let text = fs::read_to_string(&file).unwrap();
    assert_eq!(times(&text, "## Required Skills"), 1, "{text}");

    // The catalog goes, and with it the only source offering `recon`. The
    // assignment the fork carries stays exactly where it was.
    let before = manifest_text(&w);
    let start = before.find("[sources.cat]").unwrap();
    let end = before[start..]
        .find("\n[")
        .map(|at| start + at + 1)
        .unwrap_or(before.len());
    let after = format!("{}{}", &before[..start], &before[end..]);
    assert!(!after.contains("[sources.cat]"), "{after}");
    assert!(after.contains("rev = [\"recon\"]"), "{after}");
    fs::write(&path, after).unwrap();

    match audit(&w.env, &w.scope) {
        Err(CoreError::AgentSkillUnavailable {
            name,
            skill,
            source_name,
        }) => assert_eq!(
            (name.as_str(), skill.as_str(), source_name.as_str()),
            ("rev", "recon", "cat")
        ),
        other => panic!("the render must refuse, naming both halves: {other:?}"),
    }
}

/// The capture takes the person's prose byte for byte. An indented code
/// block on the first line is content, not padding, and trimming it would
/// render the block as ordinary prose.
#[test]
#[allow(clippy::unwrap_used)]
fn an_indented_first_line_keeps_its_indentation() {
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
        text.replace("Upstream body.", "    cargo run --release"),
    )
    .unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan, None).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    assert!(
        source.contains("\n    cargo run --release"),
        "the code block lost its indentation: {source:?}"
    );
}
