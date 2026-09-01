//! What a fork writes into the local source: the publisher's frontmatter,
//! the person's own prose, and none of the generated document that carried
//! them. Everything the render writes again has to be gone from the prose,
//! and everything it will not write again has to stay.

use std::fs;

use std::os::unix::fs::PermissionsExt;

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
    apply::execute(&w.env, &plan).unwrap();
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
    apply::execute(&w.env, &plan).unwrap();
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
    apply::execute(&w.env, &plan).unwrap();
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
    apply::execute(&w.env, &plan).unwrap();
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
    apply::execute(&w.env, &plan).unwrap();
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

/// One TOML table taken out of a manifest, header through to the next
/// header. Removing the header alone leaves the table's own keys behind,
/// where they read as a duplicate of whatever table precedes them.
#[allow(clippy::unwrap_used)]
fn without_section(manifest: &str, header: &str) -> String {
    let start = manifest.find(header).unwrap();
    let end = manifest[start..]
        .find("\n[")
        .map(|at| start + at + 1)
        .unwrap_or(manifest.len());
    format!("{}{}", &manifest[..start], &manifest[end..])
}

/// What resolving a fork's assignment against the scope costs is a
/// dependency the fork does not declare. The scope losing what supplied
/// the skill is said out loud, naming the skill and no source: nothing
/// records which source supplied it, and by the time a skill is
/// unresolved none of them does, so an attribution could only be
/// invented. What it must never do is take the section off in silence.
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
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);
    let text = fs::read_to_string(&file).unwrap();
    assert_eq!(times(&text, "## Required Skills"), 1, "{text}");

    // The catalog goes, and with it the only source offering `recon`. The
    // assignment the fork carries stays exactly where it was.
    let before = manifest_text(&w);
    let after = without_section(&before, "[sources.cat]");
    assert!(!after.contains("[sources.cat]"), "{after}");
    assert!(after.contains("rev = [\"recon\"]"), "{after}");
    fs::write(&path, after).unwrap();

    match audit(&w.env, &w.scope) {
        Err(CoreError::AgentSkillUnavailable { name, skill }) => {
            assert_eq!((name.as_str(), skill.as_str()), ("rev", "recon"))
        }
        other => panic!("the render must refuse, naming the skill: {other:?}"),
    }
}

/// The assignment resolves across every source, so the source that
/// supplied a skill is not the fork's own and is recorded nowhere. The
/// refusal names the skill alone. Destructuring the variant whole is what
/// holds that: an attribution field added back stops this compiling
/// instead of quietly sending someone to restore a source that still
/// stands and never carried the skill.
#[test]
#[allow(clippy::unwrap_used)]
fn a_fork_refuses_without_blaming_a_source_that_never_supplied_the_skill() {
    let w = world();
    write_agent(&w.upstream, "rev", "Upstream body.");
    commit(&w.upstream, "one");
    // `recon` comes from a second source, never from the catalog `rev`
    // itself was published in.
    let other = w.home.join("other-catalog");
    write_skill(&other, "recon", "Recon.");
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let sources = format!(
        "[sources.cat]\nrepo = \"{REPO}\"\n\n[sources.extra]\npath = \"{}\"\n",
        other.display()
    );
    fs::write(
        &path,
        format!(
            "schema = 6\n\n{sources}\n[install]\nharnesses = [\"gemini\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n\n[agent-skills]\nrev = [\"recon\"]\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    let file = rendered(&w, HarnessId::Gemini, "rev");
    assert_eq!(
        times(&fs::read_to_string(&file).unwrap(), "## Required Skills"),
        1
    );
    edit_body(&file);

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    // The supplying source goes. `cat` stays, enabled, and never held it.
    let before = manifest_text(&w);
    let after = without_section(&before, "[sources.extra]");
    assert!(!after.contains("[sources.extra]"), "{after}");
    assert!(after.contains("[sources.cat]"), "{after}");
    fs::write(&path, after).unwrap();

    match audit(&w.env, &w.scope) {
        Err(CoreError::AgentSkillUnavailable { name, skill }) => {
            assert_eq!((name.as_str(), skill.as_str()), ("rev", "recon"))
        }
        other => panic!("the render must refuse, naming the skill: {other:?}"),
    }
}

/// A skill adopted in place is supplied by the reserved `in-place` source,
/// which no `[sources]` table lists. Left out of the scope's set, a fork
/// carrying one is refused for a skill whose file is sitting in the tree.
#[test]
#[allow(clippy::unwrap_used)]
fn a_fork_keeps_a_skill_adopted_in_place() {
    let w = world();
    write_agent(&w.upstream, "rev", "Upstream body.");
    commit(&w.upstream, "one");
    write_skill(&w.home.join("app/.agents"), "recon", "Recon.");
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"gemini\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n\n[agent-skills]\nrev = [\"recon\"]\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    let file = rendered(&w, HarnessId::Gemini, "rev");
    let before = fs::read_to_string(&file).unwrap();
    assert_eq!(times(&before, "## Required Skills"), 1, "{before}");
    edit_body(&file);

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let text = fs::read_to_string(&file).unwrap();
    assert_eq!(times(&text, "## Required Skills"), 1, "{text}");
    assert_eq!(text.matches("- recon: ").count(), 1, "{text}");
}

/// The scope-wide scan is incidental to most of the work that triggers
/// it. A source whose checkout has to be rebuilt and cannot be must read
/// as supplying no skills, the way pending, disabled and missing ones
/// already do — never as a reason to fail an audit that has no agents to
/// resolve for and installs nothing from that source.
#[test]
#[allow(clippy::unwrap_used)]
fn a_source_that_will_not_resolve_does_not_fail_an_audit() {
    let w = world();
    write_skill(&w.upstream, "recon", "Recon.");
    commit(&w.upstream, "one");
    // A second subscription nothing in this scope installs from.
    let spare = w.home.join("git/owner/spare");
    fs::create_dir_all(&spare).unwrap();
    git(&spare, &["init", "--quiet", "-b", "main"]);
    write_skill(&spare, "idle", "Idle.");
    commit(&spare, "one");
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[sources.spare]\nrepo = \"owner/spare\"\n\n[install]\nharnesses = [\"gemini\"]\nmethod = \"symlink\"\n\n[skills.recon]\nsource = \"cat\"\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);

    // Take the spare's checkout away and close the directory it would be
    // rebuilt into. Its mirror still holds the commit, so resolution goes
    // as far as rebuilding and fails there.
    let commits = w.env.source_cache_dir().join("commits");
    let spare_key = fs::read_dir(&commits)
        .unwrap()
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .find(|key| !holds_recon(key))
        .expect("two cached repositories, one of them the spare");
    fs::remove_dir_all(&spare_key).unwrap();
    let mode = fs::metadata(&commits).unwrap().permissions().mode();
    fs::set_permissions(&commits, fs::Permissions::from_mode(0o500)).unwrap();
    assert!(
        fs::create_dir(commits.join("probe")).is_err(),
        "the fixture cannot close the cache directory, so it proves nothing"
    );

    let report = audit(&w.env, &w.scope);
    fs::set_permissions(&commits, fs::Permissions::from_mode(mode)).unwrap();
    let report = report.unwrap();
    assert!(
        report.plan.is_empty(),
        "the scope's own work is settled and must stay that way: {:?}",
        report.plan.ops
    );
}

/// Whether a cached repository is the one carrying `recon` — the scope's
/// own source, which must keep resolving.
#[allow(clippy::unwrap_used)]
fn holds_recon(key: &std::path::Path) -> bool {
    fs::read_dir(key).is_ok_and(|entries| {
        entries
            .filter_map(|entry| entry.ok())
            .any(|entry| entry.path().join("skills/recon/SKILL.md").exists())
    })
}

/// A fork made while the supplying source is already gone cannot wait for
/// the renderer to catch it: nothing is a recorded fork until the fork is
/// written. Left to the render it succeeds, keeps the section as prose,
/// fails its next audit, and writes a second copy the day the source comes
/// back. The capture refuses instead, and nothing is written.
#[test]
#[allow(clippy::unwrap_used)]
fn a_fork_refuses_at_capture_when_the_source_is_already_gone() {
    let w = world();
    write_skill(&w.upstream, "recon", "Recon.");
    write_agent(&w.upstream, "rev", "Upstream body.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[agent-skills]\nrev = [\"recon\"]\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    let other = w.home.join("other-catalog");
    write_skill(&other, "recon", "Recon.");
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[sources.extra]\npath = \"{}\"\n\n[install]\nharnesses = [\"gemini\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n\n[agent-skills]\nrev = [\"recon\"]\n",
            other.display()
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    let file = rendered(&w, HarnessId::Gemini, "rev");
    assert_eq!(
        times(&fs::read_to_string(&file).unwrap(), "## Required Skills"),
        1
    );
    edit_body(&file);

    // Both providers go before the fork is asked for.
    fs::remove_dir_all(&other).unwrap();
    fs::write(
        &path,
        without_section(&manifest_text(&w), "[sources.extra]"),
    )
    .unwrap();
    fs::remove_dir_all(w.upstream.join("skills/recon")).unwrap();
    fs::write(w.upstream.join("kendex.toml"), "").unwrap();
    commit(&w.upstream, "two");
    let loaded = manifest::load_for_mutation(&path).unwrap().unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    match fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini) {
        Err(CoreError::AgentSkillUnavailable { name, skill }) => {
            assert_eq!((name.as_str(), skill.as_str()), ("rev", "recon"))
        }
        other => panic!("the capture must refuse before writing: {other:?}"),
    }
    assert!(
        !captured(&w, "rev").exists(),
        "a refused capture writes nothing"
    );
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
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    assert!(
        source.contains("\n    cargo run --release"),
        "the code block lost its indentation: {source:?}"
    );
}
