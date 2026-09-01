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
