//! Taking the generated wrapper off an agent's prose. The rendering a fork
//! is captured from is the person's own words inside everything the
//! renderer wrote around them, and a person may have edited or deleted any
//! of it: what comes off has to be what the renderer wrote and nothing of
//! theirs, however much theirs reads like it.

use std::fs;

use super::*;

/// The generated banner is the one line a person reaches for when they
/// want it out of their way, and deleting it leaves a body the wrapper no
/// longer starts with. Every section that wrapper introduced is still
/// generated, so a capture that keeps them renders each of them twice.
#[test]
#[allow(clippy::unwrap_used)]
fn deleting_the_banner_alone_still_takes_the_generated_sections_off() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "[agent-launch-instructions]\nrev = \"Read the brief first.\"\n\n[agent-additional-instructions]\nrev = \"Say what you changed.\"\n",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    edit_body(&file);
    let edited = fs::read_to_string(&file)
        .unwrap()
        .replace(&format!("{BANNER}\n"), "");
    assert_eq!(banners(&edited), 0, "{edited}");
    fs::write(&file, &edited).unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    // Each section is counted by its heading and by a line only that
    // section holds: a heading the capture kept and the render wrote again
    // stands twice, and so does the text under it.
    let generated = [
        "## Launch Instructions",
        "Read the brief first.",
        "## Additional Instructions",
        "Say what you changed.",
    ];
    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    for line in generated {
        assert_eq!(
            times(&source, line),
            0,
            "the capture kept {line}, which the render writes again: {source}"
        );
    }
    assert!(source.contains("My body."), "{source}");

    let text = fs::read_to_string(&file).unwrap();
    for line in generated {
        assert_eq!(times(&text, line), 1, "{line} stands twice: {text}");
    }
    assert_eq!(banners(&text), 1, "{text}");
    assert_eq!(times(&text, "My body."), 1, "{text}");
}

/// A generated section comes off the prose whole, rows and all. Keeping
/// any part of one leaves a headerless fragment in the body, standing
/// beside the freshly generated section it was cut from.
#[test]
#[allow(clippy::unwrap_used)]
fn a_section_the_fork_writes_again_comes_off_whole() {
    let w = world();
    write_skill(&w.upstream, "mine", "Mine.");
    write_skill(&w.upstream, "theirs", "Theirs.");
    write_agent(&w.upstream, "rev", "Upstream body.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[agent-skills]\nrev = [\"mine\", \"theirs\"]\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"gemini\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n\n[skills.mine]\nsource = \"cat\"\n\n[skills.theirs]\nsource = \"cat\"\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    let file = rendered(&w, HarnessId::Gemini, "rev");
    edit_body(&file);

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    assert_eq!(
        times(&source, "## Required Skills"),
        0,
        "the fork writes the section again, so the capture must not hold it: {source}"
    );
    for row in [
        "- mine: .agents/skills/mine/SKILL.md",
        "- theirs: .agents/skills/theirs/SKILL.md",
    ] {
        assert_eq!(
            times(&source, row),
            0,
            "a row of the section the fork writes again is a headerless fragment: {source}"
        );
    }
    assert!(source.contains("My body."), "{source}");

    let text = fs::read_to_string(&file).unwrap();
    assert_eq!(times(&text, "## Required Skills"), 1, "{text}");
    for row in [
        "- mine: .agents/skills/mine/SKILL.md",
        "- theirs: .agents/skills/theirs/SKILL.md",
    ] {
        assert_eq!(
            times(&text, row),
            1,
            "the fork keeps the skills it was rendered with, each once: {text}"
        );
    }
    assert_eq!(banners(&text), 1, "{text}");
    assert_eq!(times(&text, "My body."), 1, "{text}");
}

/// A section is what wrote it, not what it reads like. An agent whose own
/// instructions spell `## Required Skills` has not made that heading a
/// section: the instructions are one section, inner heading and all, so
/// deleting the real skills section leaves the walk to pass over it and
/// still take the instructions off whole.
#[test]
#[allow(clippy::unwrap_used)]
fn a_heading_inside_instruction_text_is_not_a_generated_section() {
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
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"gemini\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n\n[skills.recon]\nsource = \"cat\"\n\n[agent-additional-instructions]\nrev = \"\"\"\nBefore the heading.\n\n## Required Skills\n\nAfter the heading.\"\"\"\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    let file = rendered(&w, HarnessId::Gemini, "rev");

    // The person deletes the generated skills section and leaves the
    // instructions standing. What follows their prose is now one section
    // whose own words spell the heading of the one they deleted.
    let edited = fs::read_to_string(&file)
        .unwrap()
        .replace(
            "\n## Required Skills\n\nRead each before acting:\n- recon: .agents/skills/recon/SKILL.md\n",
            "",
        )
        .replace("Upstream body.", "My body.");
    assert_eq!(times(&edited, "## Required Skills"), 1, "{edited}");
    assert_eq!(times(&edited, "Read each before acting:"), 0, "{edited}");
    fs::write(&file, &edited).unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    for line in [
        "## Required Skills",
        "## Additional Instructions",
        "Before the heading.",
        "After the heading.",
    ] {
        assert_eq!(
            times(&source, line),
            0,
            "the render writes {line} again, so the capture must not hold it: {source}"
        );
    }
    assert!(source.contains("My body."), "{source}");

    let text = fs::read_to_string(&file).unwrap();
    for line in [
        "Read each before acting:",
        "- recon: .agents/skills/recon/SKILL.md",
        "## Additional Instructions",
        "Before the heading.",
        "After the heading.",
        "My body.",
    ] {
        assert_eq!(times(&text, line), 1, "{line} count wrong: {text}");
    }
    assert_eq!(
        times(&text, "## Required Skills"),
        2,
        "the generated section and the instructions' own heading, one each: {text}"
    );
    assert_eq!(banners(&text), 1, "{text}");
}

/// A generated instruction saying what the person's own prose already says
/// is the ordinary reason to delete the generated one. Their line is then
/// their own, standing where the wrapper's used to, and a subtraction that
/// goes looking for a line rather than for a whole section takes it.
#[test]
#[allow(clippy::unwrap_used)]
fn prose_borrowing_the_wrappers_words_at_either_end_is_kept() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "[agent-launch-instructions]\nrev = \"Read the brief first.\"\n\n[agent-additional-instructions]\nrev = \"Say what you changed.\"\n",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    let edited = fs::read_to_string(&file)
        .unwrap()
        .replace("## Launch Instructions\n\nRead the brief first.\n\n", "")
        .replace(
            "\n## Additional Instructions\n\nSay what you changed.\n",
            "",
        )
        .replace(
            "Upstream body.",
            "Read the brief first.\n\nMiddle of my body.\n\nSay what you changed.",
        );
    // Both generated sections deleted, and each of their lines now stands
    // once — as the person's own first and last line.
    for line in ["## Launch Instructions", "## Additional Instructions"] {
        assert_eq!(times(&edited, line), 0, "{edited}");
    }
    for line in ["Read the brief first.", "Say what you changed."] {
        assert_eq!(times(&edited, line), 1, "{edited}");
    }
    fs::write(&file, &edited).unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    for line in [
        "Read the brief first.",
        "Middle of my body.",
        "Say what you changed.",
    ] {
        assert_eq!(
            times(&source, line),
            1,
            "the capture took {line} for the wrapper's, and it was the person's: {source}"
        );
    }
    for line in ["## Launch Instructions", "## Additional Instructions"] {
        assert_eq!(times(&source, line), 0, "{source}");
    }

    // Their line stands beside the generated one it duplicates, which is
    // what deleting the generated one and writing their own asked for.
    let text = fs::read_to_string(&file).unwrap();
    for line in ["Read the brief first.", "Say what you changed."] {
        assert_eq!(times(&text, line), 2, "{line} count wrong: {text}");
    }
    for line in [
        "## Launch Instructions",
        "## Additional Instructions",
        "Middle of my body.",
    ] {
        assert_eq!(times(&text, line), 1, "{line} count wrong: {text}");
    }
    assert_eq!(banners(&text), 1, "{text}");
}

/// Nothing here can tell a generated section the person edited from prose
/// of their own that resembles one — that is the forgery this reading
/// exists to refuse — so a section the body does not hold whole is kept as
/// their words, and the canonical one is written beside it. Two copies are
/// visible and a person can settle them; words taken for the wrapper's are
/// gone.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edited_generated_section_is_kept_and_the_canonical_one_written_beside_it() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "[agent-launch-instructions]\nrev = \"Read the brief first.\"\n",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    let edited = fs::read_to_string(&file)
        .unwrap()
        .replace(
            "Read the brief first.",
            "Read the brief first, then the tests.",
        )
        .replace("Upstream body.", "My body.");
    // The heading still stands; only the line under it was rewritten.
    assert_eq!(times(&edited, "## Launch Instructions"), 1, "{edited}");
    assert_eq!(times(&edited, "Read the brief first."), 0, "{edited}");
    fs::write(&file, &edited).unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    for line in [
        "## Launch Instructions",
        "Read the brief first, then the tests.",
        "My body.",
    ] {
        assert_eq!(
            times(&source, line),
            1,
            "the edited section is the person's words now, and {line} is one of them: {source}"
        );
    }

    let text = fs::read_to_string(&file).unwrap();
    assert_eq!(
        times(&text, "## Launch Instructions"),
        2,
        "the section the person edited, and the canonical one beside it: {text}"
    );
    assert_eq!(times(&text, "Read the brief first."), 1, "{text}");
    assert_eq!(
        times(&text, "Read the brief first, then the tests."),
        1,
        "{text}"
    );
    assert_eq!(banners(&text), 1, "{text}");
}

/// The published prose may open and close with sections of its own that
/// read exactly like the generated ones. Delete the generated copies and
/// the publisher's are what stands at each boundary — so a walk that knows
/// only what the renderer writes takes them, and a whole section of
/// somebody's catalog prose is gone.
#[test]
#[allow(clippy::unwrap_used)]
fn a_published_section_standing_where_a_generated_one_did_is_not_taken() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\n## Launch Instructions\n\nRead the brief first.\n\nUpstream body.\n\n## Additional Instructions\n\nSay what you changed.\n",
        "",
        "[agent-launch-instructions]\nrev = \"Read the brief first.\"\n\n[agent-additional-instructions]\nrev = \"Say what you changed.\"\n",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    let text = fs::read_to_string(&file).unwrap();
    // Each section stands twice: the catalog's own copy, and the generated
    // one that is a duplicate of it.
    for section in ["## Launch Instructions", "## Additional Instructions"] {
        assert_eq!(times(&text, section), 2, "{text}");
    }

    // The person deletes the generated copy of each, keeping the
    // publisher's. Only theirs is left standing at either boundary.
    let head = "## Launch Instructions\n\nRead the brief first.\n\n";
    let tail = "\n## Additional Instructions\n\nSay what you changed.\n";
    let edited = text.replacen(head, "", 1);
    let cut = edited.rfind(tail).unwrap();
    let edited = format!("{}{}", &edited[..cut], &edited[cut + tail.len()..])
        .replace("Upstream body.", "My body.");
    for section in ["## Launch Instructions", "## Additional Instructions"] {
        assert_eq!(times(&edited, section), 1, "{edited}");
    }
    assert_eq!(banners(&edited), 1, "{edited}");
    fs::write(&file, &edited).unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    for line in [
        "## Launch Instructions",
        "Read the brief first.",
        "## Additional Instructions",
        "Say what you changed.",
        "My body.",
    ] {
        assert_eq!(
            times(&source, line),
            1,
            "{line} is the publisher's own prose and the capture took it for the wrapper's: {source}"
        );
    }

    let text = fs::read_to_string(&file).unwrap();
    for line in [
        "## Launch Instructions",
        "Read the brief first.",
        "## Additional Instructions",
        "Say what you changed.",
    ] {
        assert_eq!(times(&text, line), 2, "{line} count wrong: {text}");
    }
    assert_eq!(times(&text, "My body."), 1, "{text}");
    assert_eq!(banners(&text), 1, "{text}");
}

/// Every harness but Claude says an agent's tool references in its own
/// words, so the catalog's bytes and what those bytes stand as in the
/// rendering are different text. A published section the rewrite turns
/// into an exact copy of a generated one is invisible to a count taken
/// from the source: the count has to be taken from the rendering, or the
/// publisher's own section goes when the person deletes the generated one.
#[test]
#[allow(clippy::unwrap_used)]
fn a_published_section_the_rewrite_makes_identical_is_not_taken() {
    let w = agent_world(
        "\"gemini\"",
        "---\nname: rev\ndescription: agent rev\n---\n## Launch Instructions\n\nUse the Read tool.\n\nUpstream body.\n\n## Additional Instructions\n\nUse the Bash tool.\n",
        "",
        "[agent-launch-instructions]\nrev = \"Use the read_file tool.\"\n\n[agent-additional-instructions]\nrev = \"Use the run_shell_command tool.\"\n",
    );
    let file = rendered(&w, HarnessId::Gemini, "rev");
    let text = fs::read_to_string(&file).unwrap();
    // The catalog wrote Claude's names, and Gemini's rendering says them
    // in Gemini's — which is what makes each published section read
    // exactly like the generated one standing beside it.
    for line in ["Use the Read tool.", "Use the Bash tool."] {
        assert_eq!(times(&text, line), 0, "{text}");
    }
    for line in [
        "## Launch Instructions",
        "Use the read_file tool.",
        "## Additional Instructions",
        "Use the run_shell_command tool.",
    ] {
        assert_eq!(times(&text, line), 2, "{line} count wrong: {text}");
    }

    // The person deletes the generated copy at each boundary, keeping the
    // publisher's.
    let head = "## Launch Instructions\n\nUse the read_file tool.\n\n";
    let tail = "\n## Additional Instructions\n\nUse the run_shell_command tool.\n";
    let edited = text.replacen(head, "", 1);
    let cut = edited.rfind(tail).unwrap();
    let edited = format!("{}{}", &edited[..cut], &edited[cut + tail.len()..])
        .replace("Upstream body.", "My body.");
    for section in ["## Launch Instructions", "## Additional Instructions"] {
        assert_eq!(times(&edited, section), 1, "{edited}");
    }
    assert_eq!(banners(&edited), 1, "{edited}");
    fs::write(&file, &edited).unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    // Kept, and kept in the words the catalog published them in.
    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    for line in [
        "## Launch Instructions",
        "Use the Read tool.",
        "## Additional Instructions",
        "Use the Bash tool.",
        "My body.",
    ] {
        assert_eq!(
            times(&source, line),
            1,
            "{line} is the publisher's own prose and the capture took it for the wrapper's: {source}"
        );
    }
    assert_eq!(times(&source, "Use the read_file tool."), 0, "{source}");

    let text = fs::read_to_string(&file).unwrap();
    for line in [
        "## Launch Instructions",
        "Use the read_file tool.",
        "## Additional Instructions",
        "Use the run_shell_command tool.",
    ] {
        assert_eq!(times(&text, line), 2, "{line} count wrong: {text}");
    }
    assert_eq!(times(&text, "My body."), 1, "{text}");
    assert_eq!(banners(&text), 1, "{text}");
}

/// A body may spell the banner as an example of it — indented into a code
/// block, where it is the person's own content. The walk had the banner
/// already, as the section the renderer wrote at the top; a filter run
/// over what the walk kept takes their line as well, wherever it stands.
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

/// A generated section may carry a fenced code block, and inside one a
/// blank line is a line of the block rather than separation between
/// sections. A person who edits that whitespace has edited the section,
/// so it is theirs now and the canonical one is written beside it — a
/// walk that reads their blank lines as separators subtracts the block
/// they edited and their edit is gone with it.
#[test]
#[allow(clippy::unwrap_used)]
fn whitespace_a_person_edits_inside_a_generated_code_block_is_their_edit() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "[agent-additional-instructions]\nrev = \"\"\"\nRun each in turn:\n\n```sh\nfirst\n\nsecond\n```\"\"\"\n",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    let text = fs::read_to_string(&file).unwrap();
    assert!(text.contains("```sh\nfirst\n\nsecond\n```"), "{text}");

    // The person closes the gap inside the block and leaves every other
    // line of the section standing.
    let edited = text
        .replace("first\n\nsecond", "first\nsecond")
        .replace("Upstream body.", "My body.");
    assert_eq!(times(&edited, "## Additional Instructions"), 1, "{edited}");
    fs::write(&file, &edited).unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    assert!(
        source.contains("```sh\nfirst\nsecond\n```"),
        "the block they edited is their words now, gap and all: {source}"
    );
    for line in [
        "## Additional Instructions",
        "Run each in turn:",
        "My body.",
    ] {
        assert_eq!(times(&source, line), 1, "{line} count wrong: {source}");
    }

    let text = fs::read_to_string(&file).unwrap();
    assert_eq!(
        times(&text, "## Additional Instructions"),
        2,
        "the section the person edited, and the canonical one beside it: {text}"
    );
    assert!(text.contains("```sh\nfirst\nsecond\n```"), "{text}");
    assert!(text.contains("```sh\nfirst\n\nsecond\n```"), "{text}");
    assert_eq!(banners(&text), 1, "{text}");
}

/// The renderer writes a section per hook, so the wrapper has to hold one
/// entry per hook. Held together, a body one hook was deleted from
/// matches none of them, and the walk stops where they stand — every
/// generated section written before them stays in the capture and the
/// next render writes it a second time.
#[test]
#[allow(clippy::unwrap_used)]
fn deleting_one_of_several_hooks_still_takes_the_sections_before_them_off() {
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
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"gemini\"]\nmethod = \"symlink\"\n\n[agents.rev]\nsource = \"cat\"\n\n[skills.recon]\nsource = \"cat\"\n\n[[custom-hooks]]\nname = \"first\"\nevent = \"PreToolUse\"\ncommand = \"./scripts/first.sh\"\nagents = [\"rev\"]\n\n[[custom-hooks]]\nname = \"second\"\nevent = \"PostToolUse\"\ncommand = \"./scripts/second.sh\"\nagents = [\"rev\"]\n"
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    let file = rendered(&w, HarnessId::Gemini, "rev");
    let text = fs::read_to_string(&file).unwrap();
    let first = "## Safety: PreToolUse on every match";
    let second = "## Safety: PostToolUse on every match";
    for line in ["## Required Skills", first, second] {
        assert_eq!(times(&text, line), 1, "{line} count wrong: {text}");
    }

    // The person deletes the last hook's section and leaves the other
    // hook and the skills section standing.
    let tail = format!("\n{second}\n\nRun: `./scripts/second.sh`\n");
    let cut = text.rfind(&tail).unwrap();
    let edited = format!("{}{}", &text[..cut], &text[cut + tail.len()..])
        .replace("Upstream body.", "My body.");
    assert_eq!(times(&edited, second), 0, "{edited}");
    assert_eq!(times(&edited, first), 1, "{edited}");
    fs::write(&file, &edited).unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Gemini).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    for line in [
        "## Required Skills",
        "- recon: .agents/skills/recon/SKILL.md",
        first,
    ] {
        assert_eq!(
            times(&source, line),
            0,
            "the fork writes {line} again, so the capture must not hold it: {source}"
        );
    }
    assert!(source.contains("My body."), "{source}");

    let text = fs::read_to_string(&file).unwrap();
    for line in [
        "## Required Skills",
        "- recon: .agents/skills/recon/SKILL.md",
        first,
        second,
        "My body.",
    ] {
        assert_eq!(times(&text, line), 1, "{line} count wrong: {text}");
    }
    assert_eq!(banners(&text), 1, "{text}");
}

/// The other half of the same rule: a blank line inside a generated code
/// block that the person did NOT touch is the wrapper's own line, so the
/// section still comes off whole. Read as separation the walk would leave
/// the block's blank line standing, take none of the section, and the
/// next render would write the whole thing a second time.
#[test]
#[allow(clippy::unwrap_used)]
fn a_generated_code_block_the_person_left_alone_still_comes_off() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "[agent-additional-instructions]\nrev = \"\"\"\nRun each in turn:\n\n```sh\nfirst\n\nsecond\n```\"\"\"\n",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    let text = fs::read_to_string(&file).unwrap();
    assert!(text.contains("```sh\nfirst\n\nsecond\n```"), "{text}");

    // Only the body changes. The generated section, blank line and all,
    // is exactly as the renderer wrote it.
    fs::write(&file, text.replace("Upstream body.", "My body.")).unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    assert_eq!(times(&source, "My body."), 1, "{source}");
    for line in ["## Additional Instructions", "Run each in turn:", "```sh"] {
        assert_eq!(times(&source, line), 0, "{line} was kept: {source}");
    }

    // And the rendering carries the section once, not twice.
    let text = fs::read_to_string(&file).unwrap();
    assert_eq!(times(&text, "## Additional Instructions"), 1, "{text}");
    assert!(
        text.contains("```sh\nfirst\n\nsecond\n```"),
        "the block came back from the manifest with its blank line: {text}"
    );
    assert_eq!(banners(&text), 1, "{text}");
}

/// A code block indented into the prose is a block like a fenced one, and
/// a blank line inside it is the block's own. A walk that reads a block
/// only where its markers are takes the section the person edited, and
/// their edit goes with it.
#[test]
#[allow(clippy::unwrap_used)]
fn whitespace_a_person_edits_inside_an_indented_block_is_their_edit() {
    let w = agent_world(
        "\"claude\"",
        "---\nname: rev\ndescription: agent rev\n---\nUpstream body.\n",
        "",
        "[agent-additional-instructions]\nrev = \"\"\"\nRun each in turn:\n\n    first\n\n    second\"\"\"\n",
    );
    let file = rendered(&w, HarnessId::Claude, "rev");
    let text = fs::read_to_string(&file).unwrap();
    assert!(text.contains("    first\n\n    second"), "{text}");

    // The person closes the gap inside the block and leaves every other
    // line of the section standing.
    let edited = text
        .replace("    first\n\n    second", "    first\n    second")
        .replace("Upstream body.", "My body.");
    assert_eq!(times(&edited, "## Additional Instructions"), 1, "{edited}");
    fs::write(&file, &edited).unwrap();

    let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude).unwrap();
    apply::execute(&w.env, &plan).unwrap();
    resettle(&w);

    let source = fs::read_to_string(captured(&w, "rev")).unwrap();
    assert!(
        source.contains("    first\n    second"),
        "the block they edited is their words now, gap and all: {source}"
    );
    for line in [
        "## Additional Instructions",
        "Run each in turn:",
        "My body.",
    ] {
        assert_eq!(times(&source, line), 1, "{line} count wrong: {source}");
    }

    let text = fs::read_to_string(&file).unwrap();
    assert_eq!(
        times(&text, "## Additional Instructions"),
        2,
        "the section the person edited, and the canonical one beside it: {text}"
    );
    assert!(text.contains("    first\n    second"), "{text}");
    assert!(text.contains("    first\n\n    second"), "{text}");
    assert_eq!(banners(&text), 1, "{text}");
}

/// The wrapper is read by rendering the agent around a stand-in body and
/// taking what surrounds it, so a publisher who wrote no body at all is
/// the end of the range where that reading could break. The fork still
/// captures, and what it captures is the person's line and no wrapper.
#[test]
#[allow(clippy::unwrap_used)]
fn a_publisher_body_with_nothing_in_it_still_forks() {
    for published in [
        "---\nname: rev\ndescription: agent rev\n---\n",
        "---\nname: rev\ndescription: agent rev\n---\n\n",
        "---\nname: rev\ndescription: agent rev\n---\n   \n",
    ] {
        let w = agent_world(
            "\"claude\"",
            published,
            "",
            "[agent-additional-instructions]\nrev = \"Say what you changed.\"\n",
        );
        let file = rendered(&w, HarnessId::Claude, "rev");
        // Their line goes where the body goes: between the banner and the
        // generated section, the region the publisher left empty.
        let text = fs::read_to_string(&file).unwrap();
        let edited = text.replacen(
            "## Additional Instructions",
            "Mine.\n\n## Additional Instructions",
            1,
        );
        assert_ne!(edited, text, "{published:?}: {text}");
        fs::write(&file, &edited).unwrap();

        let plan = fork::fork(&w.env, &w.scope, ItemKind::Agent, "rev", HarnessId::Claude)
            .unwrap_or_else(|e| panic!("{published:?}: {e}"));
        apply::execute(&w.env, &plan).unwrap();
        let source = fs::read_to_string(captured(&w, "rev")).unwrap();
        assert_eq!(times(&source, "Mine."), 1, "{published:?}: {source}");
        let kept = times(&source, "## Additional Instructions");
        assert_eq!(kept, 0, "{published:?}: the wrapper was kept: {source}");
    }
}
