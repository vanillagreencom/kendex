use std::fs;

use super::*;

/// The rendered body is the fork's source. A Gemini tool name therefore
/// stays a Gemini tool name when Claude renders the fork, while generated
/// sections still come from the manifest exactly once.
#[test]
#[allow(clippy::unwrap_used)]
fn a_gemini_fork_keeps_its_words_and_one_copy_of_each_generated_section() {
    let w = world();
    write_skill(&w.upstream, "recon", "Recon.");
    write_agent(&w.upstream, "rev", "Use the Read tool.\n\nUpstream body.");
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
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\", \"gemini\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n\n[skills.recon]\nsource = \"cat\"\n\n[agent-launch-instructions]\nrev = \"Read the brief first.\"\n\n[agent-additional-instructions]\nrev = \"Say what you changed.\"\n\n[[custom-hooks]]\nname = \"check\"\nevent = \"PreToolUse\"\ncommand = \"./scripts/check.sh\"\nagents = [\"rev\"]\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);

    let gemini_path = rendered(&w, HarnessId::Gemini, "rev");
    let before = fs::read_to_string(&gemini_path).unwrap();
    assert!(before.contains("Use the read_file tool."), "{before}");
    edit_body(&gemini_path);

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    assert!(source.contains("Use the read_file tool."), "{source}");
    assert!(!source.contains("Use the Read tool."), "{source}");
    for section in [
        "## Launch Instructions",
        "## Additional Instructions",
        "## Required Skills",
        "## Safety: PreToolUse on every match",
    ] {
        assert_eq!(times(&source, section), 0, "{section}: {source}");
    }

    let gemini = fs::read_to_string(&gemini_path).unwrap();
    for section in [
        "## Launch Instructions",
        "## Additional Instructions",
        "## Required Skills",
        "## Safety: PreToolUse on every match",
    ] {
        assert_eq!(times(&gemini, section), 1, "{section}: {gemini}");
    }

    let claude = fs::read_to_string(rendered(&w, HarnessId::Claude, "rev")).unwrap();
    assert!(claude.contains("Use the read_file tool."), "{claude}");
    for text in [&gemini, &claude] {
        assert_eq!(banners(text), 1, "{text}");
        assert_eq!(times(text, "My body."), 1, "{text}");
    }
}

/// The other half of the ruling: an edited Claude rendering forks and
/// renders again byte for byte. The wrapper the render put around the
/// prose comes off whole and goes back on whole, so nothing about the
/// person's edit shifts and no generated section doubles.
#[test]
#[allow(clippy::unwrap_used)]
fn a_claude_fork_renders_back_the_bytes_it_was_captured_from() {
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
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n\n[skills.recon]\nsource = \"cat\"\n\n[agent-launch-instructions]\nrev = \"Read the brief first.\"\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);

    let file = rendered(&w, HarnessId::Claude, "rev");
    let before = fs::read_to_string(&file).unwrap();
    assert!(before.contains("Read the brief first."), "{before}");
    assert_eq!(times(&before, "## Launch Instructions"), 1, "{before}");
    edit_body(&file);
    let edited = fs::read_to_string(&file).unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    assert_eq!(fs::read_to_string(&file).unwrap(), edited);
    assert!(audit(&w.env, &w.scope).unwrap().drift.is_empty());
}

/// A body may spell the banner as an example of it — indented into a code
/// block, where it is the person's own content. The generated banner is
/// the first thing the rendered prefix holds, so it comes off with that
/// prefix and their example stays where they wrote it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_banner_line_the_body_spells_as_an_example_is_kept() {
    let example = format!("    {BANNER}");
    let w = agent_world(
        "\"claude\"",
        &format!(
            "---\nname: rev\ndescription: agent rev\n---\nUpstream body. Every rendering opens with:\n\n{example}\n"
        ),
        "",
        "",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    let text = fs::read_to_string(&file).unwrap();
    // The generated banner, and the person's example of one.
    assert_eq!(banners(&text), 2, "{text}");
    edit_body(&file);

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    assert_eq!(
        banners(&source),
        1,
        "the example is the person's own line and the capture took it for the renderer's: {source}"
    );
    assert!(
        source.contains(&example),
        "the example keeps the indent that makes it a code block: {source}"
    );

    let text = fs::read_to_string(&file).unwrap();
    assert_eq!(banners(&text), 2, "{text}");
    assert_eq!(
        times(&text, "My body. Every rendering opens with:"),
        1,
        "{text}"
    );
}

/// A rendering an editor saved with CRLF endings is still that rendering.
/// The wrapper comes off, so nothing it wrote stands twice after the next
/// render, and the lines the person kept still end the way they saved
/// them — the half that proves the cut came off their own text.
#[test]
#[allow(clippy::unwrap_used)]
fn a_crlf_rendering_forks_with_its_wrapper_off_and_its_endings_kept() {
    let w = world();
    write_agent(&w.upstream, "rev", "Upstream body.\n\nSecond line.");
    commit(&w.upstream, "one");
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n\n[agent-launch-instructions]\nrev = \"Read the brief first.\"\n\n[agent-additional-instructions]\nrev = \"Say what you changed.\"\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);

    let file = rendered(&w, HarnessId::Claude, "rev");
    let text = fs::read_to_string(&file).unwrap();
    for (section, count) in [
        ("## Launch Instructions", 1),
        ("## Additional Instructions", 1),
    ] {
        assert_eq!(times(&text, section), count, "{section}: {text}");
    }
    assert_eq!(banners(&text), 1, "{text}");
    // What an editor that rewrites line endings leaves behind: every one
    // of them, frontmatter and body alike.
    let crlf = text
        .replace("Upstream body.", "My body.")
        .replace('\n', "\r\n");
    fs::write(&file, &crlf).unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    assert_eq!(
        banners(&source),
        0,
        "the wrapper has to come off a CRLF rendering too: {source:?}"
    );
    for section in ["## Launch Instructions", "## Additional Instructions"] {
        assert_eq!(times(&source, section), 0, "{section}: {source:?}");
    }
    assert!(
        source.contains("My body.\r\n"),
        "the kept line keeps the ending it was saved with: {source:?}"
    );

    let after = fs::read_to_string(&file).unwrap();
    assert_eq!(banners(&after), 1, "{after}");
    for section in ["## Launch Instructions", "## Additional Instructions"] {
        assert_eq!(times(&after, section), 1, "{section}: {after}");
    }
}
