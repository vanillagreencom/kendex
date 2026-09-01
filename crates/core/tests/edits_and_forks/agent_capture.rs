use std::fs;

use super::*;

#[test]
#[allow(clippy::unwrap_used)]
fn a_gemini_fork_keeps_its_words_and_one_copy_of_each_generated_section() {
    let w = world();
    write_skill(&w.upstream, "recon", "Recon.");
    write_agent(
        &w.upstream,
        "rev",
        &format!("Use the Read tool.\n\nUpstream body.\n\nExample:\n\n{BANNER}"),
    );
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
    let hook = "\n## Safety: PreToolUse on every match\n\nRun: `./scripts/check.sh`\n";
    assert!(before.contains(hook), "{before}");
    fs::write(
        &gemini_path,
        before
            .replace("Upstream body.", "My body.")
            .replace("Read the brief first.", "Edited generated launch.")
            .replace(hook, ""),
    )
    .unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    assert!(source.contains("Use the read_file tool."), "{source}");
    assert!(!source.contains("Use the Read tool."), "{source}");
    assert!(source.contains("Edited generated launch."), "{source}");
    assert!(
        source.contains(&format!("Example:\n\n{BANNER}")),
        "{source}"
    );
    assert_eq!(banners(&source), 1, "{source}");
    assert_eq!(times(&source, "## Launch Instructions"), 1, "{source}");
    for section in [
        "## Additional Instructions",
        "## Required Skills",
        "## Safety: PreToolUse on every match",
    ] {
        assert_eq!(times(&source, section), 0, "{section}: {source}");
    }

    let gemini = fs::read_to_string(&gemini_path).unwrap();
    assert_eq!(times(&gemini, "## Launch Instructions"), 2, "{gemini}");
    for section in [
        "## Additional Instructions",
        "## Required Skills",
        "## Safety: PreToolUse on every match",
    ] {
        assert_eq!(times(&gemini, section), 1, "{section}: {gemini}");
    }

    let claude = fs::read_to_string(rendered(&w, HarnessId::Claude, "rev")).unwrap();
    assert!(claude.contains("Use the read_file tool."), "{claude}");
    for text in [&gemini, &claude] {
        assert_eq!(banners(text), 2, "{text}");
        assert_eq!(times(text, "My body."), 1, "{text}");
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_generated_section_away_from_its_position_refuses() {
    let w = agent_world(
        "\"gemini\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "[agent-launch-instructions]\nrev = \"Read the brief first.\"\n",
    );
    let file = rendered(&w, HarnessId::Gemini, "rev");
    let text = fs::read_to_string(&file).unwrap();
    let section = "## Launch Instructions\n\nRead the brief first.\n\n";
    assert!(text.contains(section), "{text}");
    fs::write(&file, format!("{}\n{section}", text.replace(section, ""))).unwrap();

    let error = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini)
        .unwrap_err()
        .to_string();
    assert!(error.contains("away from its rendered position"), "{error}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_authored_edge_copy_refuses_when_the_generated_copy_was_deleted() {
    let agent =
        format!("---\nname: rev\ndescription: agent rev\n---\n{BANNER}\n\nUpstream body.\n");
    let w = agent_world("\"gemini\"", &agent, "", "");
    let file = rendered(&w, HarnessId::Gemini, "rev");
    let text = fs::read_to_string(&file).unwrap();
    let opening = format!("{BANNER}\n\n");
    let at = text.find(&opening).unwrap();
    fs::write(
        &file,
        format!("{}{}", &text[..at], &text[at + opening.len()..]),
    )
    .unwrap();

    let error = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini)
        .unwrap_err()
        .to_string();
    assert!(error.contains("cannot be told from"), "{error}");
}
